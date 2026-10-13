// tools/live-call/worker.mjs
//
// Edge entry for the live-call transport. Routes a WebSocket signaling connection to the per-room Durable Object
// (one DO instance per roomId, via idFromName) and FAIL-CLOSED authorizes it at the edge BEFORE the upgrade, so an
// unauthenticated or non-member socket never reaches the room. It also mints CF Realtime SFU sessions on behalf of
// a verified client — the App Secret lives in this Worker (a `wrangler secret`) and is never shipped to the client.
// GET /health is the only unauthenticated route.
//
// AUTHORIZATION MODEL — mirrors the gateway, not a reinvention:
//   The Pocket gateway holds NO signing key. It authorizes by forwarding the caller's OWN Senti bearer to the
//   SentinelLayer API and trusting the role it returns (owner/admin/contributor/viewer) — see
//   services/pocket-gateway/src/senti-target-membership.mjs. So there is no token to mint here, and the connecting
//   client is authorized by ITS bearer, never by a caller-supplied participant id (that shape is the confused-deputy
//   bug the resolver exists to prevent). This Worker therefore forwards the client's bearer to a configured gateway
//   authorize endpoint and trusts ONLY a member role + the participant id the gateway BOUND to that bearer. The exact
//   endpoint is being co-designed with warden (gateway owns /dial + the resolver; a store-backed one-time join grant
//   via the existing dialSignalStore is one candidate). Until GATEWAY_AUTHORIZE_URL is set, the Worker admits NO ONE.
//
// Routes:
//   GET  /health                                  -> liveness (unauthenticated)
//   GET  /call/:roomId/ws?session&token           (Upgrade: websocket) -> per-room DO signaling channel
//   POST /call/:roomId/sfu/session?session        (Authorization: Bearer) -> mint a CF Realtime session (body = SDP offer)

import { createCfRealtimeSfu } from './cf-realtime-sfu.mjs';

export { CallRoomDO } from './call-do.mjs';

const MEMBER_ROLES = new Set(['owner', 'admin', 'contributor', 'viewer']);
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

// Browsers cannot set headers on a WebSocket handshake, so the bearer rides a query param for WS; plain HTTP routes
// use the Authorization header. Either way it is the CLIENT's own Senti bearer.
function bearerFrom(request, url) {
  const header = request.headers.get('authorization');
  if (header && /^Bearer\s+\S/i.test(header)) return header;
  const token = url.searchParams.get('token');
  return token ? `Bearer ${token}` : '';
}

// Fail-closed authorization: forward the client's bearer to the gateway authorize endpoint; trust only a member role
// and the participant id the gateway bound to that bearer. No GATEWAY_AUTHORIZE_URL -> admit no one.
async function authorizeSessionMember(env, { authorization, sessionId }) {
  if (!env.GATEWAY_AUTHORIZE_URL || !authorization || !sessionId) return { ok: false };
  try {
    const r = await fetch(env.GATEWAY_AUTHORIZE_URL, {
      method: 'POST',
      headers: { authorization, 'content-type': 'application/json' },
      body: JSON.stringify({ sessionId }),
    });
    if (!r.ok) return { ok: false };
    const j = await r.json().catch(() => ({}));
    const role = typeof j.role === 'string' ? j.role : '';
    const participantId = typeof j.participantId === 'string' ? j.participantId : '';
    if (!MEMBER_ROLES.has(role) || !participantId) return { ok: false };
    return { ok: true, participantId, role }; // the principal is the gateway's, never the caller's
  } catch {
    return { ok: false };
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health') return json({ ok: true, service: 'live-call' });

    const m = url.pathname.match(/^\/call\/([^/]+)\/(ws|sfu\/session)$/);
    if (!m) return new Response('not found', { status: 404 });
    const roomId = decodeURIComponent(m[1]);
    const sessionId = url.searchParams.get('session') || '';

    const authz = await authorizeSessionMember(env, { authorization: bearerFrom(request, url), sessionId });
    if (!authz.ok) return new Response('forbidden', { status: 403 });

    if (m[2] === 'sfu/session') {
      if (request.method !== 'POST') return new Response('method not allowed', { status: 405 });
      const sfu = createCfRealtimeSfu({ appId: env.CF_REALTIME_APP_ID, appSecret: env.CF_REALTIME_APP_SECRET });
      const body = await request.json().catch(() => ({}));
      try {
        return json(await sfu.newSession(body));
      } catch (e) {
        return json({ ok: false, error: String(e && e.message) }, 502);
      }
    }

    // WS signaling -> route to the per-room DO. The AUTHORIZED participant id (bound by the gateway to the bearer)
    // and roomId travel on the query so the DO can seed identity; the caller never chooses its own id.
    if (request.headers.get('Upgrade') !== 'websocket') return new Response('expected websocket', { status: 426 });
    url.searchParams.set('room', roomId);
    url.searchParams.set('participant', authz.participantId);
    const stub = env.CALL_ROOM.get(env.CALL_ROOM.idFromName(roomId));
    return stub.fetch(new Request(url.toString(), request));
  },
};
