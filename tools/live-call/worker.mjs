// tools/live-call/worker.mjs
//
// Edge entry for the live-call transport. Authorizes a client at the edge (fail-closed) BEFORE any DO access, then
// routes WebSocket signaling to the per-(session,room) Durable Object and mints/forwards CF Realtime SFU calls on
// the client's behalf — the App Secret lives here and never reaches the client. GET /health is the only open route.
//
// AUTHORIZATION — mirrors the gateway (which holds no signing key): forward the client's OWN Senti bearer to the
// gateway authorize endpoint, which returns the role + the participant id it BOUND to that bearer for the (session,
// room) pair. The caller never chooses its own participant id or room. Every SFU op is additionally authorized
// against the DO (which owns the per-participant minted sessions + the room's published set), so no client can
// renegotiate, pull, or over-mint another participant's / another room's CF session.

import { createCfRealtimeSfu } from './cf-realtime-sfu.mjs';
import { INTERNAL_OP_PATH } from './call-do.mjs';

export { CallRoomDO } from './call-do.mjs';
export { INTERNAL_OP_PATH };

const MEMBER_ROLES = new Set(['owner', 'admin', 'contributor', 'viewer']);
const MAX_SFU_BODY = 64 * 1024;
// The gateway answers after its bearer check (/auth/me, up to 5 s) and then the membership lookup (up to 3 s), and a cold
// start first loads its secrets (up to ~3.75 s): ~11.75 s worst case, well inside API Gateway's 29 s. A shorter bound here
// would refuse a legitimate member whenever those are uncached and slow.
const AUTHZ_TIMEOUT_MS = 14000;
// Bounds every SFU call the Worker makes, so an authorized pull lands well inside the DO's PULL_GRACE_MS window.
const SFU_DISPATCH_TIMEOUT_MS = 10000;
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

function bearerFrom(request, url) {
  const header = request.headers.get('authorization');
  if (header && /^Bearer\s+\S/i.test(header)) return header;
  const token = url.searchParams.get('token');
  return token ? `Bearer ${token}` : '';
}

// Pin the authorize endpoint: GATEWAY_HOST is REQUIRED (unset => fail closed), https only, host must match exactly.
export function authorizeEndpoint(env) {
  if (!env.GATEWAY_AUTHORIZE_URL || !env.GATEWAY_HOST) return null;
  try {
    const u = new URL(env.GATEWAY_AUTHORIZE_URL);
    if (u.protocol !== 'https:' || u.host !== env.GATEWAY_HOST) return null;
    return u.toString();
  } catch {
    return null;
  }
}

// Authorize the client's bearer for the (session, room) pair. Fail closed; the gateway binds the principal + room.
export async function authorize(env, { authorization, sessionId, roomId }) {
  const endpoint = authorizeEndpoint(env);
  if (!endpoint || !authorization || !sessionId || !roomId) return { ok: false };
  try {
    const r = await fetch(endpoint, {
      method: 'POST',
      headers: { authorization, 'content-type': 'application/json' },
      body: JSON.stringify({ sessionId, roomId }),
      redirect: 'manual', // never follow a redirect to another host with the bearer attached
      signal: AbortSignal.timeout(AUTHZ_TIMEOUT_MS),
    });
    if (!r.ok) return { ok: false };
    const j = await r.json().catch(() => ({}));
    if (j.sessionId !== sessionId || j.roomId !== roomId) return { ok: false }; // the gateway must echo what it bound
    const role = typeof j.role === 'string' ? j.role : '';
    const participantId = typeof j.participantId === 'string' ? j.participantId : '';
    if (!MEMBER_ROLES.has(role) || !participantId) return { ok: false };
    return { ok: true, participantId, role };
  } catch {
    return { ok: false };
  }
}

// DO instance name for an authorized (session, room) — BOTH parts are encoded so neither can forge a collision into
// another session's room (reverting this to roomId-only is the room-squat regression).
export function doName(sessionId, roomId) {
  return `${encodeURIComponent(sessionId)}::${encodeURIComponent(roomId)}`;
}
function doStub(env, sessionId, roomId) {
  return env.CALL_ROOM.get(env.CALL_ROOM.idFromName(doName(sessionId, roomId)));
}

// WS forward URL: the bearer token is STRIPPED and participant + role are the AUTHORIZED values, never the caller's.
export function buildForwardUrl(incomingUrl, { roomId, participantId, role }) {
  const fwd = new URL(incomingUrl);
  fwd.searchParams.delete('token');
  fwd.searchParams.set('room', roomId);
  fwd.searchParams.set('participant', participantId);
  fwd.searchParams.set('role', role);
  return fwd.toString();
}

// Call the DO's internal op (bind / mint-reserve / sfu-authz). Requires a configured key; the DO rejects a default.
async function internalOp(env, sessionId, roomId, op, payload) {
  const res = await doStub(env, sessionId, roomId).fetch(
    new Request(`https://do${INTERNAL_OP_PATH}`, {
      method: 'POST',
      headers: { 'x-live-call-internal': env.INTERNAL_BIND_KEY, 'content-type': 'application/json' },
      body: JSON.stringify({ op, ...payload }),
    }),
  );
  return (res && typeof res.json === 'function' ? await res.json().catch(() => ({})) : {}) || {};
}

// The SFU only ever receives a body rebuilt here from validated fields. Client bodies are never forwarded: an extra or
// case-variant key ("Location", "Mid") must not reach a decoder that might read it differently from this check, so any
// key outside the exact allow-list is refused rather than dropped.
const MAX_SDP = 60 * 1024;
const TRACK_KEYS = {
  local: new Set(['location', 'trackName', 'mid', 'kind', 'bidirectionalMediaStream']),
  // A pull may not reuse an existing transceiver (mid "#name" / bidirectional): closing such a pull on a floor change
  // would also stop the listener's own publication on that transceiver.
  remote: new Set(['location', 'sessionId', 'trackName', 'kind', 'simulcast']),
};
const BODY_KEYS = {
  'sfu/session': new Set(['sessionDescription']),
  'sfu/tracks': new Set(['sessionId', 'sessionDescription', 'tracks', 'autoDiscover']),
  'sfu/renegotiate': new Set(['sessionId', 'sessionDescription']),
};
const plainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const onlyKeys = (v, allowed) => Object.keys(v).every((k) => allowed.has(k));
const nonEmpty = (v) => typeof v === 'string' && v.length > 0 && v.length <= 256;

function sessionDescription(v) {
  if (!plainObject(v) || !onlyKeys(v, new Set(['type', 'sdp'])) || !['offer', 'answer'].includes(v.type) ||
      typeof v.sdp !== 'string' || v.sdp.length > MAX_SDP) return null;
  return { type: v.type, sdp: v.sdp };
}

function simulcast(v) {
  const order = new Set(['none', 'asciibetical']);
  if (!plainObject(v) || !onlyKeys(v, new Set(['preferredRid', 'priorityOrdering', 'ridNotAvailable']))) return null;
  if (v.preferredRid !== undefined && !nonEmpty(v.preferredRid)) return null;
  if (v.priorityOrdering !== undefined && !order.has(v.priorityOrdering)) return null;
  if (v.ridNotAvailable !== undefined && !order.has(v.ridNotAvailable)) return null;
  return { ...v };
}

function track(t) {
  if (!plainObject(t) || !Object.hasOwn(TRACK_KEYS, t.location) || !onlyKeys(t, TRACK_KEYS[t.location]) || !nonEmpty(t.trackName)) return null;
  if (t.kind !== undefined && !['audio', 'video'].includes(t.kind)) return null;
  if (t.location === 'local') {
    if (t.mid !== undefined && !nonEmpty(t.mid)) return null;
    if (t.bidirectionalMediaStream !== undefined && typeof t.bidirectionalMediaStream !== 'boolean') return null;
    return { location: 'local', trackName: t.trackName, ...(t.mid !== undefined ? { mid: t.mid } : {}),
      ...(t.kind ? { kind: t.kind } : {}), ...(t.bidirectionalMediaStream !== undefined ? { bidirectionalMediaStream: t.bidirectionalMediaStream } : {}) };
  }
  if (!nonEmpty(t.sessionId)) return null;
  const sim = t.simulcast === undefined ? undefined : simulcast(t.simulcast);
  if (sim === null) return null;
  return { location: 'remote', sessionId: t.sessionId, trackName: t.trackName, ...(t.kind ? { kind: t.kind } : {}), ...(sim ? { simulcast: sim } : {}) };
}

/** Rebuild the outgoing SFU body for `route`, or null if anything is outside the allow-list. */
export function buildSfuBody(route, body) {
  if (!plainObject(body) || !onlyKeys(body, BODY_KEYS[route])) return null;
  const out = {};
  if (body.sessionDescription !== undefined) {
    const sd = sessionDescription(body.sessionDescription);
    if (!sd) return null;
    out.sessionDescription = sd;
  }
  if (route === 'sfu/session') return { out, listener: '', remote: [] };
  if (!nonEmpty(body.sessionId)) return null;
  if (route === 'sfu/renegotiate') return { out, listener: body.sessionId, remote: [] };
  if (body.autoDiscover !== undefined) {
    if (typeof body.autoDiscover !== 'boolean') return null;
    out.autoDiscover = body.autoDiscover;
  }
  if (!Array.isArray(body.tracks) || body.tracks.length > 64) return null;
  const tracks = body.tracks.map(track);
  if (tracks.some((t) => t === null)) return null; // never silently filter a malformed track away
  out.tracks = tracks;
  return { out, listener: body.sessionId, remote: tracks.filter((t) => t.location === 'remote').map(({ sessionId, trackName }) => ({ sessionId, trackName })) };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health') return json({ ok: true, service: 'live-call' });

    const m = url.pathname.match(/^\/call\/([^/]+)\/(ws|sfu\/session|sfu\/tracks|sfu\/renegotiate)$/);
    if (!m) return new Response('not found', { status: 404 });
    let roomId;
    try {
      roomId = decodeURIComponent(m[1]);
    } catch {
      return new Response('not found', { status: 404 });
    }
    const sessionId = url.searchParams.get('session') || '';

    const authz = await authorize(env, { authorization: bearerFrom(request, url), sessionId, roomId });
    if (!authz.ok) return new Response('forbidden', { status: 403 });

    const route = m[2];
    if (route.startsWith('sfu/')) {
      if (request.method !== 'POST') return new Response('method not allowed', { status: 405 });
      if (!env.INTERNAL_BIND_KEY) return json({ ok: false, error: 'bind-not-configured' }, 503); // fail closed, no default
      const raw = await request.text();
      if (raw.length > MAX_SFU_BODY) return json({ ok: false, error: 'body-too-large' }, 413);
      let body;
      try {
        body = raw ? JSON.parse(raw) : {};
      } catch {
        return json({ ok: false, error: 'bad-json' }, 400);
      }
      try {
        const sfu = createCfRealtimeSfu({
          appId: env.CF_REALTIME_APP_ID, appSecret: env.CF_REALTIME_APP_SECRET, timeoutMs: SFU_DISPATCH_TIMEOUT_MS,
        });
        const built = buildSfuBody(route, body);
        if (!built) return json({ ok: false, error: route === 'sfu/tracks' ? 'bad-tracks' : 'bad-body' }, 400);
        if (route === 'sfu/session') {
          const reserve = await internalOp(env, sessionId, roomId, 'mint-reserve', { participantId: authz.participantId });
          if (!reserve.ok) return json({ ok: false, error: 'mint-cap' }, 429);
          const minted = await sfu.newSession(built.out);
          if (minted && minted.sessionId) {
            await internalOp(env, sessionId, roomId, 'bind', { participantId: authz.participantId, cfSessionId: minted.sessionId });
          }
          return json(minted);
        }
        // The DO checks each exact coordinate against THIS listener's current floor subscriptions.
        const authzOp = await internalOp(env, sessionId, roomId, 'sfu-authz', {
          participantId: authz.participantId,
          sessionId: built.listener,
          remoteTracks: built.remote,
        });
        if (!authzOp.ok) return new Response('forbidden', { status: 403 });
        if (route === 'sfu/tracks') {
          try {
            return json(await sfu.addRemoteTracks(built.listener, built.out));
          } finally {
            // Success or not (a timeout or error can follow the SFU allocating the pull), the DO re-decides that session
            // against the room as it is now and closes the pull server-side if it lost permission. If this invocation
            // is cancelled before getting here, the DO's own post-authorization re-check covers it.
            if (built.remote.length) {
              await internalOp(env, sessionId, roomId, 'reconcile', { participantId: authz.participantId, cfSessionId: built.listener })
                .catch(() => {});
            }
          }
        }
        return json(await sfu.renegotiate(built.listener, built.out));
      } catch (e) {
        return json({ ok: false, error: String(e && e.message) }, 502);
      }
    }

    // WS signaling -> per-(session,room) DO. GET-only; forward a FRESH upgrade request that copies NO client header
    // or body (drops the client's Authorization + any x-live-call-internal + any body) — only the signed-in
    // participant/role/room travel, on the URL. This closes the internal-bind bypass at the edge.
    if (request.method !== 'GET' || request.headers.get('Upgrade') !== 'websocket') {
      return new Response('expected websocket', { status: 426 });
    }
    const fwd = buildForwardUrl(url, { roomId, participantId: authz.participantId, role: authz.role });
    return doStub(env, sessionId, roomId).fetch(new Request(fwd, { method: 'GET', headers: { Upgrade: 'websocket' } }));
  },
};
