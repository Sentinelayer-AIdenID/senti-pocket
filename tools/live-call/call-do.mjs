// tools/live-call/call-do.mjs
//
// Durable Object that hosts ONE live-call room (one per authorized (session, room) pair): a CallRoom + the
// CF-Realtime track registry, driven over a WebSocket signaling channel. Uses the WebSocket Hibernation API so an
// idle call costs nothing yet survives eviction — on wake the constructor rebuilds from the surviving sockets'
// attachments + persisted meta. Every socket's identity (participantId, sessionId, role) is bound at accept from the
// Worker's AUTHORIZED values and is never trusted from a message body.
//
// The decision logic lives in the pure, unit-tested modules (call-room / signaling / call-fanout). THIS class is the
// CF-runtime shell: accept, broadcast, alarm sweep, and the security glue warden required —
//   - floor control (set/grant/advance) is privileged: owner/admin only, by the gateway role carried in the socket;
//   - published CF coords are accepted ONLY if they match a session the Worker MINTED for that participant;
//   - a reconnecting participant kicks its own stale socket; joins sweep idle peers; messages are size-capped.

import { createCallRoom } from './call-room.mjs';
import { handleSignal } from './signaling.mjs';
import { buildFanout } from './call-fanout.mjs';

const SWEEP_INTERVAL_MS = 30000;
const MAX_MSG_BYTES = 16 * 1024;
const FLOOR_OPS = new Set(['set-floor', 'grant-floor', 'advance-floor']);
const FLOOR_ROLES = new Set(['owner', 'admin']); // who may change the floor
const decode = (raw) => (typeof raw === 'string' ? raw : new TextDecoder().decode(raw));

export class CallRoomDO {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.publishedTracks = {}; // participantId -> { sessionId, trackName } actually published
    this.mintedTracks = {}; // participantId -> cfSessionId the Worker minted (authoritative; set via /bind)
    this.sockets = new Map(); // participantId -> live WebSocket (this instance)
    this.meta = { roomId: '', sessionId: '', floor: 'open', holder: null };

    state.blockConcurrencyWhile(async () => {
      const saved = await state.storage.get('meta');
      if (saved) this.meta = saved;
      const savedMinted = await state.storage.get('mintedTracks');
      if (savedMinted) this.mintedTracks = savedMinted;
      this.room = createCallRoom({
        roomId: this.meta.roomId || 'room',
        sessionId: this.meta.sessionId || 'pending',
        floor: this.meta.floor || 'open',
        isMember: () => true, // authorized at the Worker edge before accept
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

    // Internal, Worker-only: bind a minted CF session to a participant. The client never reaches this path (the
    // Worker only routes external traffic to /ws and /sfu/*); the shared key is defense-in-depth.
    if (request.method === 'POST' && request.headers.get('x-live-call-internal') != null) {
      if (request.headers.get('x-live-call-internal') !== (this.env.INTERNAL_BIND_KEY || 'internal')) {
        return new Response('forbidden', { status: 403 });
      }
      const b = await request.json().catch(() => ({}));
      if (b && typeof b.participantId === 'string' && typeof b.cfSessionId === 'string') {
        this.mintedTracks[b.participantId] = b.cfSessionId;
        await this.state.storage.put('mintedTracks', this.mintedTracks);
      }
      return new Response(null, { status: 204 });
    }

    if (request.headers.get('Upgrade') !== 'websocket') return new Response('expected websocket', { status: 426 });
    const participantId = url.searchParams.get('participant') || '';
    const sessionId = url.searchParams.get('session') || '';
    const role = url.searchParams.get('role') || 'viewer';
    if (!participantId || !sessionId) return new Response('missing participant/session', { status: 400 });

    if (!this.meta.sessionId) {
      this.meta.roomId = url.searchParams.get('room') || 'room';
      this.meta.sessionId = sessionId;
      this.meta.floor = this.meta.floor || 'open';
      await this.persistMeta();
      this.room = createCallRoom({ roomId: this.meta.roomId, sessionId, floor: this.meta.floor, isMember: () => true });
    }
    if (sessionId !== this.meta.sessionId) return new Response('wrong-session', { status: 403 });

    // Reconnect kick: a fresh socket for an existing participant replaces (and closes) the stale one.
    const prior = this.sockets.get(participantId);
    if (prior) {
      try {
        prior.close(1012, 'reconnected');
      } catch {
        /* already gone */
      }
    }

    const { 0: client, 1: server } = new WebSocketPair();
    this.state.acceptWebSocket(server, [participantId]);
    server.serializeAttachment({ participantId, sessionId, role }); // identity + role bound here; never from a body
    this.sockets.set(participantId, server);
    this.room.sweep(); // drop idle peers whenever someone joins
    await this.ensureAlarm();
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, raw) {
    const text = decode(raw);
    if (text.length > MAX_MSG_BYTES) return ws.send(JSON.stringify({ type: 'error', reason: 'message-too-large' }));
    let msg;
    try {
      msg = JSON.parse(text);
    } catch {
      return ws.send(JSON.stringify({ type: 'error', reason: 'bad-json' }));
    }
    const att = ws.deserializeAttachment() || {};

    if (msg.type === 'join') {
      msg.participantId = att.participantId; // anti-spoof: identity is the attachment's, never the body's
      msg.sessionId = att.sessionId;
      // Accept published CF coords ONLY if they match a session the Worker minted for THIS participant.
      if (msg.cfSessionId && msg.cfTrackName && this.mintedTracks[att.participantId] === msg.cfSessionId) {
        this.publishedTracks[att.participantId] = { sessionId: msg.cfSessionId, trackName: msg.cfTrackName };
        ws.serializeAttachment({ ...att, trackId: msg.trackId, published: this.publishedTracks[att.participantId] });
      }
    } else if (msg.type === 'leave' || msg.type === 'touch') {
      msg.participantId = att.participantId;
    } else if (FLOOR_OPS.has(msg.type) && !FLOOR_ROLES.has(att.role)) {
      // Floor control is privileged — only owner/admin, by the gateway role carried in the socket.
      return ws.send(JSON.stringify({ type: 'ack', op: msg.type, ok: false, reason: 'forbidden-role', state: this.room.state() }));
    }

    const res = handleSignal(this.room, msg);

    if (msg.type === 'leave') this.forget(att.participantId);
    if (FLOOR_OPS.has(msg.type) && res.state) {
      this.meta.floor = res.state.floor;
      this.meta.holder = res.state.holder;
      await this.persistMeta();
    }

    ws.send(JSON.stringify({ type: 'ack', op: msg.type, ok: res.ok, reason: res.reason, state: res.state }));
    this.broadcast();
  }

  async webSocketClose(ws) {
    const att = ws.deserializeAttachment() || {};
    if (!att.participantId) return;
    // Only clear membership if THIS socket is still the live one (a reconnect already replaced a kicked socket).
    if (this.sockets.get(att.participantId) === ws || !this.sockets.has(att.participantId)) {
      this.room.leave(att.participantId);
      this.forget(att.participantId);
      this.broadcast();
    }
  }

  async webSocketError(ws) {
    return this.webSocketClose(ws);
  }

  forget(participantId) {
    this.sockets.delete(participantId);
    delete this.publishedTracks[participantId];
    delete this.mintedTracks[participantId];
    void this.state.storage.put('mintedTracks', this.mintedTracks);
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
      this.forget(id);
    }
    if (dropped.length) this.broadcast();
    if (this.state.getWebSockets().length > 0) await this.state.storage.setAlarm(Date.now() + SWEEP_INTERVAL_MS);
  }

  async persistMeta() {
    await this.state.storage.put('meta', this.meta);
  }
}
