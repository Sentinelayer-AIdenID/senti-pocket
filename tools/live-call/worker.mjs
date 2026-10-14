// tools/live-call/worker.mjs
//
// Edge entry for the live-call transport. Authorizes a client at the edge (fail-closed) BEFORE any DO access, then
// routes WebSocket signaling to the per-(session,room) Durable Object and mints/forwards CF Realtime SFU calls on
// the client's behalf — the App Secret lives here and never reaches the client. GET /health is the only open route.
//
// AUTHORIZATION — mirrors the gateway (which holds no signing key): forward the client's OWN Senti bearer to the
// gateway authorize endpoint, which returns the role + the participant id it BOUND to that bearer for the (session,
// room) pair. The caller never chooses its own participant id or room — that's the confused-deputy / room-squatting
// class warden flagged. Fail closed: no GATEWAY_AUTHORIZE_URL (or a mismatched host) admits no one.

import { createCfRealtimeSfu } from './cf-realtime-sfu.mjs';

export { CallRoomDO } from './call-do.mjs';

const MEMBER_ROLES = new Set(['owner', 'admin', 'contributor', 'viewer']);
const MAX_SFU_BODY = 64 * 1024;
const AUTHZ_TIMEOUT_MS = 3000;
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

// Browsers cannot set headers on a WS handshake, so the bearer rides a query param for WS; HTTP routes use the header.
function bearerFrom(request, url) {
  const header = request.headers.get('authorization');
  if (header && /^Bearer\s+\S/i.test(header)) return header;
  const token = url.searchParams.get('token');
  return token ? `Bearer ${token}` : '';
}

// Pin the authorize endpoint: https only, and if GATEWAY_HOST is set the URL host must match it exactly.
export function authorizeEndpoint(env) {
  try {
    const u = new URL(env.GATEWAY_AUTHORIZE_URL);
    if (u.protocol !== 'https:') return null;
    if (env.GATEWAY_HOST && u.host !== env.GATEWAY_HOST) return null;
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
    // The gateway must echo the (session, room) it authorized — a mismatch is a confused-deputy signal.
    if (j.sessionId !== sessionId || j.roomId !== roomId) return { ok: false };
    const role = typeof j.role === 'string' ? j.role : '';
    const participantId = typeof j.participantId === 'string' ? j.participantId : '';
    if (!MEMBER_ROLES.has(role) || !participantId) return { ok: false };
    return { ok: true, participantId, role };
  } catch {
    return { ok: false };
  }
}

// Namespace the DO by (session, room): a member of one session can never reach another session's room by roomId.
function doStub(env, sessionId, roomId) {
  return env.CALL_ROOM.get(env.CALL_ROOM.idFromName(`${sessionId}::${roomId}`));
}

// Build the URL forwarded to the DO: the bearer token is STRIPPED, and participant + role are the AUTHORIZED values
// (never the caller's query). Pure + exported so the anti-spoof / token-strip invariants are unit-tested directly.
export function buildForwardUrl(incomingUrl, { roomId, participantId, role }) {
  const fwd = new URL(incomingUrl);
  fwd.searchParams.delete('token');
  fwd.searchParams.set('room', roomId);
  fwd.searchParams.set('participant', participantId);
  fwd.searchParams.set('role', role);
  return fwd.toString();
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health') return json({ ok: true, service: 'live-call' });

    const m = url.pathname.match(/^\/call\/([^/]+)\/(ws|sfu\/session|sfu\/tracks|sfu\/renegotiate)$/);
    if (!m) return new Response('not found', { status: 404 });
    const roomId = decodeURIComponent(m[1]);
    const sessionId = url.searchParams.get('session') || '';

    const authz = await authorize(env, { authorization: bearerFrom(request, url), sessionId, roomId });
    if (!authz.ok) return new Response('forbidden', { status: 403 });

    const route = m[2];
    if (route.startsWith('sfu/')) {
      if (request.method !== 'POST') return new Response('method not allowed', { status: 405 });
      const raw = await request.text();
      if (raw.length > MAX_SFU_BODY) return json({ ok: false, error: 'body-too-large' }, 413);
      let body;
      try {
        body = raw ? JSON.parse(raw) : {};
      } catch {
        return json({ ok: false, error: 'bad-json' }, 400);
      }
      const sfu = createCfRealtimeSfu({ appId: env.CF_REALTIME_APP_ID, appSecret: env.CF_REALTIME_APP_SECRET });
      try {
        if (route === 'sfu/session') {
          const minted = await sfu.newSession(body);
          // Bind (participant -> minted cfSessionId) into the room DO so a client cannot later claim another's session.
          if (minted && minted.sessionId) {
            await doStub(env, sessionId, roomId).fetch(
              new Request('https://do/bind', {
                method: 'POST',
                headers: { 'x-live-call-internal': env.INTERNAL_BIND_KEY || 'internal', 'content-type': 'application/json' },
                body: JSON.stringify({ participantId: authz.participantId, cfSessionId: minted.sessionId }),
              }),
            );
          }
          return json(minted);
        }
        if (route === 'sfu/tracks') return json(await sfu.addRemoteTracks(String(body.sessionId || ''), body));
        if (route === 'sfu/renegotiate') return json(await sfu.renegotiate(String(body.sessionId || ''), body));
      } catch (e) {
        return json({ ok: false, error: String(e && e.message) }, 502);
      }
    }

    // WS signaling -> per-(session,room) DO. Forward the AUTHORIZED participant id + role; STRIP the bearer token.
    if (request.headers.get('Upgrade') !== 'websocket') return new Response('expected websocket', { status: 426 });
    const fwd = buildForwardUrl(url, { roomId, participantId: authz.participantId, role: authz.role });
    return doStub(env, sessionId, roomId).fetch(new Request(fwd, request));
  },
};
