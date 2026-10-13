// tools/live-call/worker.mjs
//
// Edge entry for the live-call transport. Routes a WebSocket signaling connection to the per-room Durable Object
// (one DO instance per roomId, via idFromName) and FAIL-CLOSED membership-gates it at the edge BEFORE the upgrade,
// so an unauthenticated or non-member socket never reaches the room. It also mints CF Realtime SFU sessions on
// behalf of a verified client — the App Secret lives in this Worker (a `wrangler secret`) and is never shipped to
// the client. GET /health is the only unauthenticated route.
//
// Routes:
//   GET  /health                       -> liveness (unauthenticated)
//   GET  /call/:roomId/ws?participant&session   (Upgrade: websocket) -> per-room DO signaling channel
//   POST /call/:roomId/sfu/session?participant&session              -> mint a CF Realtime session (body = SDP offer)

import { createCfRealtimeSfu } from './cf-realtime-sfu.mjs';

export { CallRoomDO } from './call-do.mjs';

const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

// Gateway-verified membership — the same authority as the Pocket gateway. Fail closed on any error / non-200 / missing config.
async function verifyMembership(env, { participantId, sessionId }) {
  if (!env.GATEWAY_URL || !env.GATEWAY_TOKEN || !participantId || !sessionId) return false;
  try {
    const r = await fetch(
      `${env.GATEWAY_URL}/sessions/${encodeURIComponent(sessionId)}/members/${encodeURIComponent(participantId)}`,
      { headers: { authorization: `Bearer ${env.GATEWAY_TOKEN}` } },
    );
    if (!r.ok) return false;
    const j = await r.json().catch(() => ({}));
    return j.member === true;
  } catch {
    return false;
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health') return json({ ok: true, service: 'live-call' });

    const m = url.pathname.match(/^\/call\/([^/]+)\/(ws|sfu\/session)$/);
    if (!m) return new Response('not found', { status: 404 });
    const roomId = decodeURIComponent(m[1]);
    const participantId = url.searchParams.get('participant') || '';
    const sessionId = url.searchParams.get('session') || '';

    if (!(await verifyMembership(env, { participantId, sessionId }))) return new Response('forbidden', { status: 403 });

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

    // WS signaling -> route to the per-room DO. roomId travels on the query so the DO can seed its identity.
    if (request.headers.get('Upgrade') !== 'websocket') return new Response('expected websocket', { status: 426 });
    url.searchParams.set('room', roomId);
    const stub = env.CALL_ROOM.get(env.CALL_ROOM.idFromName(roomId));
    return stub.fetch(new Request(url.toString(), request));
  },
};
