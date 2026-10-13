// tools/live-call/call-do.mjs
//
// Durable Object that hosts ONE live-call room: a single CallRoom + the CF-Realtime track registry, driven over a
// WebSocket signaling channel. Uses the WebSocket Hibernation API so an idle call costs nothing yet survives
// eviction — on wake the constructor rebuilds the room from the surviving sockets' attachments + persisted floor
// meta. Membership is gateway-verified in the Worker BEFORE the upgrade; this DO additionally binds each socket to
// its (participantId, sessionId) at accept time and refuses a cross-session join (confused-deputy-safe, the same
// guard CallRoom enforces).
//
// The decision logic lives in the pure, unit-tested modules: call-room.mjs (membership + floor + who-hears-whom),
// signaling.mjs (protocol), call-fanout.mjs (per-listener subscribe directives). THIS class is the thin CF-runtime
// shell — WebSocketPair, acceptWebSocket, alarm-driven idle sweep, broadcast — exercised by deploy / miniflare,
// not by the node unit tests. Identity for auth is always the attachment bound at accept, never a body field.

import { createCallRoom } from './call-room.mjs';
import { handleSignal } from './signaling.mjs';
import { buildFanout } from './call-fanout.mjs';

const SWEEP_INTERVAL_MS = 30000;
const decode = (raw) => (typeof raw === 'string' ? raw : new TextDecoder().decode(raw));

export class CallRoomDO {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.publishedTracks = {}; // participantId -> { sessionId, trackName } (CF publish coords)
    this.sockets = new Map(); // participantId -> live WebSocket (this instance)
    this.meta = { roomId: '', sessionId: '', floor: 'open', holder: null };

    // Rebuild the in-memory room from the survivors after a hibernation wake. Must complete before any delivery.
    state.blockConcurrencyWhile(async () => {
      const saved = await state.storage.get('meta');
      if (saved) this.meta = saved;
      this.room = createCallRoom({
        roomId: this.meta.roomId || 'room',
        sessionId: this.meta.sessionId || 'pending',
        floor: this.meta.floor || 'open',
        isMember: () => true, // membership already verified at the Worker edge before accept
      });
      for (const ws of state.getWebSockets()) {
        const a = ws.deserializeAttachment();
        if (!a?.participantId || !this.meta.sessionId) continue;
        this.sockets.set(a.participantId, ws);
        this.room.join({ participantId: a.participantId, sessionId: a.sessionId, trackId: a.trackId });
        if (a.published) this.publishedTracks[a.participantId] = a.published;
      }
      if (this.meta.floor && this.meta.floor !== 'open') this.room.setFloor(this.meta.floor);
      if (this.meta.holder) this.room.grantFloor(this.meta.holder);
    });
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.headers.get('Upgrade') !== 'websocket') return new Response('expected websocket', { status: 426 });
    const participantId = url.searchParams.get('participant') || '';
    const sessionId = url.searchParams.get('session') || '';
    if (!participantId || !sessionId) return new Response('missing participant/session', { status: 400 });

    // The first socket seeds this room's identity (roomId + the Senti session it belongs to).
    if (!this.meta.sessionId) {
      this.meta.roomId = url.searchParams.get('room') || 'room';
      this.meta.sessionId = sessionId;
      this.meta.floor = this.meta.floor || 'open';
      await this.persistMeta();
      this.room = createCallRoom({ roomId: this.meta.roomId, sessionId, floor: this.meta.floor, isMember: () => true });
    }
    if (sessionId !== this.meta.sessionId) return new Response('wrong-session', { status: 403 });

    const { 0: client, 1: server } = new WebSocketPair();
    this.state.acceptWebSocket(server, [participantId]);
    server.serializeAttachment({ participantId, sessionId }); // identity bound here; never trusted from the body
    this.sockets.set(participantId, server);
    await this.ensureAlarm();
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, raw) {
    let msg;
    try {
      msg = JSON.parse(decode(raw));
    } catch {
      return ws.send(JSON.stringify({ type: 'error', reason: 'bad-json' }));
    }
    const att = ws.deserializeAttachment() || {};

    // Bind the authenticated identity onto ops that act on "me". grant-floor's participantId is the GRANTEE, so it
    // is deliberately NOT overwritten — a member may hand the floor to someone else, but can never spoof their own id.
    if (msg.type === 'join') {
      msg.participantId = att.participantId;
      msg.sessionId = att.sessionId;
      if (msg.cfSessionId && msg.cfTrackName) {
        this.publishedTracks[att.participantId] = { sessionId: msg.cfSessionId, trackName: msg.cfTrackName };
        ws.serializeAttachment({ ...att, trackId: msg.trackId, published: this.publishedTracks[att.participantId] });
      }
    } else if (msg.type === 'leave' || msg.type === 'touch') {
      msg.participantId = att.participantId;
    }

    const res = handleSignal(this.room, msg);

    if (msg.type === 'leave') {
      this.sockets.delete(att.participantId);
      delete this.publishedTracks[att.participantId];
    }
    if ((msg.type === 'set-floor' || msg.type === 'grant-floor' || msg.type === 'advance-floor') && res.state) {
      this.meta.floor = res.state.floor;
      this.meta.holder = res.state.holder;
      await this.persistMeta();
    }

    // Ack the sender with the op result, then fan fresh directives out to everyone so the SFU reconciles in one hop.
    ws.send(JSON.stringify({ type: 'ack', op: msg.type, ok: res.ok, reason: res.reason, state: res.state }));
    this.broadcast();
  }

  async webSocketClose(ws) {
    const att = ws.deserializeAttachment() || {};
    if (!att.participantId) return;
    this.room.leave(att.participantId);
    this.sockets.delete(att.participantId);
    delete this.publishedTracks[att.participantId];
    this.broadcast();
  }

  async webSocketError(ws) {
    return this.webSocketClose(ws);
  }

  broadcast() {
    const { directives } = buildFanout(this.room, this.publishedTracks);
    for (const ws of this.state.getWebSockets()) {
      const att = ws.deserializeAttachment() || {};
      const d = directives[att.participantId];
      if (!d) continue;
      try {
        ws.send(JSON.stringify(d));
      } catch {
        /* a closing socket is swept by the alarm; never let one dead peer break the fan-out */
      }
    }
  }

  async ensureAlarm() {
    if ((await this.state.storage.getAlarm()) === null) await this.state.storage.setAlarm(Date.now() + SWEEP_INTERVAL_MS);
  }

  async alarm() {
    const dropped = this.room.sweep();
    for (const id of dropped) {
      const ws = this.sockets.get(id);
      if (ws) {
        try {
          ws.close(1000, 'idle-timeout');
        } catch {
          /* already gone */
        }
      }
      this.sockets.delete(id);
      delete this.publishedTracks[id];
    }
    if (dropped.length) this.broadcast();
    if (this.state.getWebSockets().length > 0) await this.state.storage.setAlarm(Date.now() + SWEEP_INTERVAL_MS);
  }

  async persistMeta() {
    await this.state.storage.put('meta', this.meta);
  }
}
