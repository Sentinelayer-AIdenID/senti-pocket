// tools/live-call/call-do.mjs
//
// Durable Object that hosts ONE live-call room (one per authorized (session, room) pair): a CallRoom + the
// CF-Realtime track registry, driven over a WebSocket signaling channel. Uses the WebSocket Hibernation API so an
// idle call costs nothing yet survives eviction. Every socket's identity (participantId, sessionId, role) is bound at
// accept from the Worker's AUTHORIZED values and is never trusted from a message body.
//
// Security glue warden required:
//   - floor control (set/grant/advance) is owner/admin only, by the gateway role carried in the socket;
//   - published CF coords are accepted only if they match a session the Worker MINTED for that participant;
//   - Worker-only internal ops (bind / mint-reserve / sfu-authz) are reachable ONLY at an exact path with a
//     configured key (NO default) — the Worker forwards GET-only fresh upgrades, so a client can never reach them;
//   - SFU session minting is capped; new pulls require owned sessions + exact floor-authorized published tracks;
//   - every minted SFU session stays in a durable ledger, and after any floor/membership change (and after every new
//     pull) the DO reads each session's SFU state and force-closes pulls the floor no longer permits, plus every track
//     of a departed participant. Failed closes retry on a short alarm (VOICE-08 server-side revocation).

import { createCallRoom } from './call-room.mjs';
import { handleSignal } from './signaling.mjs';
import { buildFanout } from './call-fanout.mjs';
import { createCfRealtimeSfu } from './cf-realtime-sfu.mjs';
import { revokeSession } from './sfu-revocation.mjs';

export const INTERNAL_OP_PATH = '/__live-call/internal/op'; // exact path; the client can never cause a forward here
const SWEEP_INTERVAL_MS = 30000;
export const REVOKE_RETRY_MS = 2000; // a failed server-side close is retried this soon, not at the next sweep
const REVOKE_FAST_RETRIES = 5;
const SFU_CALL_TIMEOUT_MS = 3000;
const SFU_PARALLEL = 4; // under the Workers per-invocation connection limit, so queued reads don't time out
// An authorized pull can still land this long after its authorization (the Worker bounds its own SFU call at 10 s), so
// its session is never dropped from the ledger before then, even if a read in between shows it empty.
export const PULL_GRACE_MS = 30000;
// A session minted for someone who never joined and holds no socket for this long is treated as departed.
const ORPHAN_MS = 300000;
const MAX_MSG_BYTES = 16 * 1024;
const MINT_CAP = 5; // per-participant active-mint cap
const FLOOR_OPS = new Set(['set-floor', 'grant-floor', 'advance-floor']);
const FLOOR_ROLES = new Set(['owner', 'admin']);
const decode = (raw) => (typeof raw === 'string' ? raw : new TextDecoder().decode(raw));
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

// Run fn over items with at most `limit` in flight, preserving result order.
async function mapLimit(items, limit, fn) {
  const results = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i], i);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

// Constant-time string compare for the internal key (content compare doesn't short-circuit; length is allowed to leak).
function ctEqual(a, b) {
  const x = typeof a === 'string' ? a : '';
  const y = typeof b === 'string' ? b : '';
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i += 1) diff |= x.charCodeAt(i) ^ y.charCodeAt(i);
  return diff === 0;
}

export class CallRoomDO {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.publishedTracks = {}; // participantId -> { sessionId, trackName } actually published
    this.mintedTracks = {}; // participantId -> cfSessionId the Worker minted (authoritative)
    this.mintCount = {}; // participantId -> active mint count (cap)
    // cfSessionId -> { participantId, departed, boundAt, closed: [trackKey], pullPendingUntil? }: every minted session
    // until it is drained.
    this.sfuSessions = {};
    this.sockets = new Map();
    this.meta = { roomId: '', sessionId: '', floor: 'open', holder: null };
    // The App Secret is a Worker secret shared with this DO; without it no session can have been minted.
    this.sfu = env.CF_REALTIME_APP_ID && env.CF_REALTIME_APP_SECRET
      ? createCfRealtimeSfu({ appId: env.CF_REALTIME_APP_ID, appSecret: env.CF_REALTIME_APP_SECRET, timeoutMs: SFU_CALL_TIMEOUT_MS })
      : null;

    state.blockConcurrencyWhile(async () => {
      this.meta = (await state.storage.get('meta')) || this.meta;
      this.mintedTracks = (await state.storage.get('mintedTracks')) || {};
      this.mintCount = (await state.storage.get('mintCount')) || {};
      this.sfuSessions = (await state.storage.get('sfuSessions')) || {};
      this.revokeFailures = (await state.storage.get('revokeFailures')) || 0;
      this.room = createCallRoom({
        roomId: this.meta.roomId || 'room',
        sessionId: this.meta.sessionId || 'pending',
        floor: this.meta.floor || 'open',
        isMember: () => true,
      });
      for (const ws of state.getWebSockets()) {
        const a = ws.deserializeAttachment();
        if (!a?.participantId || a.retired || a.sessionId !== this.meta.sessionId) continue;
        this.sockets.set(a.participantId, ws);
        if (a.joined !== true) continue; // Accepted, left and legacy-unmarked sockets are not room members.
        const restored = this.room.join({ participantId: a.participantId, sessionId: a.sessionId, role: a.role, trackId: a.trackId });
        // Restore a publication on any of the participant's live ledger sessions, exactly as the live instance allowed.
        const session = a.published && this.sfuSessions[a.published.sessionId];
        const live = a.published && (a.published.sessionId === this.mintedTracks[a.participantId] ||
          (session && session.participantId === a.participantId && session.departed !== true));
        if (restored.ok && live && typeof a.published.trackName === 'string' && a.published.trackName) {
          this.publishedTracks[a.participantId] = a.published;
        }
      }
      if (this.meta.floor && this.meta.floor !== 'open') this.room.setFloor(this.meta.floor);
      if (this.meta.holder) this.room.grantFloor(this.meta.holder);
    });
  }

  async fetch(request) {
    const url = new URL(request.url);

    // Worker-only internal ops: EXACT path + configured key (never a default). The Worker forwards external WS traffic
    // as a fresh GET upgrade to the /ws URL, so this path is unreachable by any client request.
    if (request.method === 'POST' && url.pathname === INTERNAL_OP_PATH) {
      const key = this.env.INTERNAL_BIND_KEY;
      if (!key || !ctEqual(request.headers.get('x-live-call-internal'), key)) return json({ ok: false }, 403);
      return this.handleInternal((await request.json().catch(() => ({}))) || {});
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

    const prior = this.sockets.get(participantId);
    if (prior) {
      // A closing socket can still have queued events. Persist retirement before replacing it.
      prior.serializeAttachment({ ...prior.deserializeAttachment(), joined: false, retired: true });
      this.room.leave(participantId);
      delete this.publishedTracks[participantId];
      await this.persistRoomMeta();
      try {
        prior.close(1012, 'reconnected');
      } catch {
        /* already gone */
      }
    }

    const { 0: client, 1: server } = new WebSocketPair();
    this.state.acceptWebSocket(server, [participantId]);
    server.serializeAttachment({ participantId, sessionId, role, joined: false });
    this.sockets.set(participantId, server);
    const dropped = await this.sweepIdle();
    await this.ensureAlarm();
    // Only after the replacement is registered (a retired socket can no longer act while the SFU is awaited): a kicked
    // or swept participant is no member, so its pulls and every pull of its track lose permission.
    if (prior || dropped.length) {
      this.broadcast(); // the kicked/swept participant drops out of everyone's directives, then returns on re-join
      await this.revokeStale();
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  async handleInternal(b) {
    const pid = typeof b.participantId === 'string' ? b.participantId : '';
    if (!pid) return json({ ok: false, reason: 'no-participant' }, 400);
    if (b.op === 'mint-reserve') {
      const count = this.mintCount[pid] || 0;
      if (count >= MINT_CAP) return json({ ok: false, reason: 'mint-cap' });
      this.mintCount[pid] = count + 1;
      await this.state.storage.put('mintCount', this.mintCount);
      return json({ ok: true });
    }
    if (b.op === 'bind') {
      if (typeof b.cfSessionId === 'string' && b.cfSessionId) {
        this.mintedTracks[pid] = b.cfSessionId;
        this.sfuSessions[b.cfSessionId] = { participantId: pid, departed: false, boundAt: Date.now(), closed: [] };
        await this.state.storage.put('mintedTracks', this.mintedTracks);
        await this.state.storage.put('sfuSessions', this.sfuSessions);
      }
      return json({ ok: true });
    }
    if (b.op === 'reconcile') {
      // The Worker calls this after every pull it dispatched: a floor change or leave that landed while the pull was in
      // flight cannot leave that pull open, because the decision is taken against the room state now. It names the
      // session it dispatched on, and the session is re-added if a pass dropped it meanwhile.
      const sid = typeof b.cfSessionId === 'string' ? b.cfSessionId : '';
      if (sid && !this.sfuSessions[sid]) {
        this.sfuSessions[sid] = { participantId: pid, departed: !this.isMember(pid), boundAt: Date.now(), closed: [] };
        await this.state.storage.put('sfuSessions', this.sfuSessions);
      }
      const { pending } = await this.revokeStale();
      return json({ ok: pending === 0, pending });
    }
    if (b.op === 'sfu-authz') {
      const owns = Boolean(this.mintedTracks[pid]) && this.mintedTracks[pid] === b.sessionId;
      const permitted = this.permittedPulls(pid);
      // Session-only legacy requests cannot establish which track is permitted.
      const remoteOk = !Object.hasOwn(b, 'remoteSessionIds') && Array.isArray(b.remoteTracks) && b.remoteTracks.every((track) =>
        track && typeof track.sessionId === 'string' && typeof track.trackName === 'string' &&
        permitted.some((published) => published.sessionId === track.sessionId && published.trackName === track.trackName));
      const ok = owns && remoteOk;
      if (ok && b.remoteTracks.length && this.sfuSessions[b.sessionId]) {
        this.sfuSessions[b.sessionId].pullPendingUntil = Date.now() + PULL_GRACE_MS;
        await this.state.storage.put('sfuSessions', this.sfuSessions);
      }
      return json({ ok });
    }
    return json({ ok: false, reason: 'unknown-op' }, 400);
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
    if (this.sockets.get(att.participantId) !== ws) return; // Replaced sockets cannot mutate the current membership.

    if (msg.type === 'join') {
      msg.participantId = att.participantId; // anti-spoof
      msg.sessionId = att.sessionId;
      msg.role = att.role; // the roster shows the gateway-bound role, never a self-declared one
    } else if (msg.type === 'leave' || msg.type === 'touch') {
      msg.participantId = att.participantId;
    } else if (FLOOR_OPS.has(msg.type) && !FLOOR_ROLES.has(att.role)) {
      return ws.send(JSON.stringify({ type: 'ack', op: msg.type, ok: false, reason: 'forbidden-role', state: this.room.state() }));
    }

    const res = handleSignal(this.room, msg);
    if (msg.type === 'join' && res.ok) {
      if (typeof msg.cfSessionId === 'string' && msg.cfSessionId && typeof msg.cfTrackName === 'string' &&
          msg.cfTrackName && this.mintedTracks[att.participantId] === msg.cfSessionId) {
        this.publishedTracks[att.participantId] = { sessionId: msg.cfSessionId, trackName: msg.cfTrackName };
      }
      const { published: _oldPublished, trackId: _oldTrackId, ...identity } = att;
      const published = this.publishedTracks[att.participantId];
      ws.serializeAttachment({ ...identity, joined: true, trackId: msg.trackId || att.trackId, ...(published ? { published } : {}) });
    }
    if (msg.type === 'leave') await this.forget(att.participantId, { keepSocket: true });
    if ((FLOOR_OPS.has(msg.type) && res.state) || (msg.type === 'join' && res.ok)) await this.persistRoomMeta();
    ws.send(JSON.stringify({ type: 'ack', op: msg.type, ok: res.ok, reason: res.reason, state: res.state }));
    this.broadcast();
    // Directives only ASK clients to drop pulls; the server closes them regardless of what a client does. Only a leave or
    // an applied floor change can narrow a permission (a join only adds), so nothing else costs an SFU pass.
    if (msg.type === 'leave' || (res.ok && FLOOR_OPS.has(msg.type))) await this.revokeStale();
  }

  async webSocketClose(ws) {
    const att = ws.deserializeAttachment() || {};
    if (!att.participantId || att.retired) return;
    if (this.sockets.get(att.participantId) === ws || !this.sockets.has(att.participantId)) {
      this.room.leave(att.participantId);
      await this.forget(att.participantId);
      this.broadcast();
      await this.revokeStale();
    }
  }

  async webSocketError(ws) {
    return this.webSocketClose(ws);
  }

  async forget(participantId, { keepSocket = false } = {}) {
    // NB: mintCount is NOT reset here. It is a durable per-participant lifetime count — resetting it on leave/close
    // would let a viewer mint, leave, and re-mint without bound (the CF sessions are not closed server-side).
    const ws = this.sockets.get(participantId);
    if (ws) {
      const { published: _published, trackId: _trackId, ...identity } = ws.deserializeAttachment() || {};
      ws.serializeAttachment({ ...identity, joined: false });
    }
    if (!keepSocket) this.sockets.delete(participantId);
    delete this.publishedTracks[participantId];
    delete this.mintedTracks[participantId];
    // Its minted sessions stay in the ledger, marked departed, until the SFU confirms nothing on them is active.
    for (const entry of Object.values(this.sfuSessions)) if (entry.participantId === participantId) entry.departed = true;
    await this.state.storage.put('mintedTracks', this.mintedTracks);
    await this.state.storage.put('sfuSessions', this.sfuSessions);
    await this.persistRoomMeta();
  }

  isMember(participantId) {
    return this.room.roster().some((p) => p.id === participantId);
  }

  // The exact pulls the floor allows this participant now: [] unless it is a joined member hearing a published track.
  permittedPulls(participantId) {
    return (this.room.subscriptions()[participantId] || []).map((id) => this.publishedTracks[id]).filter(Boolean);
  }

  // At most one pass runs and one waits; a waiting pass reads the room state when it starts, so callers that arrive
  // during a pass are covered by the next one instead of each starting their own.
  revokeStale() {
    if (this.revokeQueued) return this.revokeQueued;
    const next = (this.revokeRunning || Promise.resolve()).catch(() => {}).then(async () => {
      if (this.revokeQueued === next) this.revokeQueued = null;
      this.revokeRunning = next;
      try {
        return await this.revokeOnce();
      } finally {
        if (this.revokeRunning === next) this.revokeRunning = null;
      }
    });
    this.revokeQueued = next;
    return next;
  }

  async revokeOnce() {
    const now = Date.now();
    for (const entry of Object.values(this.sfuSessions)) {
      if (!entry.departed && !this.sockets.has(entry.participantId) && !this.isMember(entry.participantId) &&
          now - (entry.boundAt || 0) > ORPHAN_MS) entry.departed = true;
    }
    const entries = Object.entries(this.sfuSessions);
    if (!entries.length) return { pending: 0 };
    let pending = 0;
    if (!this.sfu) {
      pending = entries.length; // cannot reach the SFU: nothing is assumed closed
    } else {
      const results = await mapLimit(entries, SFU_PARALLEL, ([cfSessionId, entry]) => revokeSession(this.sfu, cfSessionId, {
        departed: entry.departed === true,
        permittedFor: () => this.permittedPulls(entry.participantId),
        closed: entry.closed || [],
      }).catch(() => ({ ok: false, closed: [], drained: false })));
      results.forEach((r, i) => {
        const [cfSessionId, entry] = entries[i];
        if (!r.ok) pending += 1;
        if (r.closed.length) entry.closed = [...new Set([...(entry.closed || []), ...r.closed])];
        if (!r.drained) return;
        // Never drop a session an authorized pull may still be landing on: no later pass would ever see that pull.
        if (entry.pullPendingUntil > Date.now()) pending += 1;
        else if (this.sfuSessions[cfSessionId] === entry) delete this.sfuSessions[cfSessionId];
      });
      await this.state.storage.put('sfuSessions', this.sfuSessions);
    }
    this.revokeFailures = pending ? (this.revokeFailures || 0) + 1 : 0;
    await this.state.storage.put('revokeFailures', this.revokeFailures);
    if (pending) await this.scheduleAlarm(this.retryDelay());
    return { pending };
  }

  // Fast retries first; an SFU that stays unreachable falls back to the sweep cadence instead of a 2 s alarm forever.
  retryDelay() {
    return (this.revokeFailures || 0) <= REVOKE_FAST_RETRIES ? REVOKE_RETRY_MS : SWEEP_INTERVAL_MS;
  }

  // Never postpone an alarm that is already due sooner.
  async scheduleAlarm(delayMs) {
    const due = Date.now() + delayMs;
    const current = await this.state.storage.getAlarm();
    if (current === null || current > due) await this.state.storage.setAlarm(due);
  }

  broadcast() {
    const { directives } = buildFanout(this.room, this.publishedTracks);
    for (const ws of this.state.getWebSockets()) {
      const att = ws.deserializeAttachment() || {};
      if (att.joined !== true || att.retired || this.sockets.get(att.participantId) !== ws) continue;
      const d = directives[att.participantId];
      if (!d) continue;
      try {
        ws.send(JSON.stringify(d));
      } catch {
        /* a closing socket is swept by the alarm */
      }
    }
  }

  async ensureAlarm() {
    if ((await this.state.storage.getAlarm()) === null) await this.state.storage.setAlarm(Date.now() + SWEEP_INTERVAL_MS);
  }

  async sweepIdle() {
    const dropped = this.room.sweep();
    for (const id of dropped) {
      const ws = this.sockets.get(id);
      await this.forget(id);
      if (ws) {
        try {
          ws.close(1000, 'idle-timeout');
        } catch {
          /* already gone */
        }
      }
    }
    return dropped;
  }

  async alarm() {
    const dropped = await this.sweepIdle();
    if (dropped.length) this.broadcast();
    const { pending } = await this.revokeStale();
    // Set explicitly: inside the handler the firing alarm can still read as set, so scheduleAlarm could skip it.
    const live = this.state.getWebSockets().length > 0 || Object.keys(this.sfuSessions).length > 0;
    if (pending || live) await this.state.storage.setAlarm(Date.now() + (pending ? this.retryDelay() : SWEEP_INTERVAL_MS));
  }

  async persistMeta() {
    await this.state.storage.put('meta', this.meta);
  }

  async persistRoomMeta() {
    const { floor, holder } = this.room.state();
    this.meta.floor = floor;
    this.meta.holder = holder;
    await this.persistMeta();
  }
}
