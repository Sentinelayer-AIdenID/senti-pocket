import test from 'node:test';
import assert from 'node:assert/strict';
import { CallRoomDO, INTERNAL_OP_PATH, REVOKE_RETRY_MS } from './call-do.mjs';
import worker from './worker.mjs';

// Inert CF runtime doubles (as in worker-floor-state.test.mjs) plus a fake SFU that keeps per-session track state the
// way GET /sessions/:id reports it, so each test asserts what is still FLOWING, not what the DO intended.
function makeWs() {
  let attachment;
  return {
    sent: [], closed: false,
    serializeAttachment(value) { attachment = structuredClone(value); },
    deserializeAttachment() { return structuredClone(attachment); },
    send(value) { this.sent.push(JSON.parse(value)); },
    close() { this.closed = true; },
  };
}
function makeState() {
  const storage = new Map();
  const sockets = [];
  let ready;
  let alarm = null;
  return {
    storage: {
      async get(key) { return structuredClone(storage.get(key)); },
      async put(key, value) { storage.set(key, structuredClone(value)); },
      async getAlarm() { return alarm; },
      async setAlarm(value) { alarm = value; },
    },
    acceptWebSocket(ws) { sockets.push(ws); },
    getWebSockets() { return sockets.filter((ws) => !ws.closed); },
    blockConcurrencyWhile(fn) { ready = Promise.resolve().then(fn); return ready; },
    get ready() { return ready; },
  };
}
globalThis.WebSocketPair = function () { return { 0: {}, 1: makeWs() }; };
globalThis.Response = class {
  constructor(body, init = {}) { this.body = body; this.status = init.status ?? 200; this.webSocket = init.webSocket; }
  async json() { return JSON.parse(this.body); }
};

function fakeSfu() {
  const sessions = new Map();
  let mid = 0;
  const add = (id, track) => { if (!sessions.has(id)) sessions.set(id, []); sessions.get(id).push({ mid: String(mid++), status: 'active', ...track }); };
  return {
    calls: [], failCloses: 0,
    publish(id) { add(id, { location: 'local', trackName: 'mic' }); },
    pull(listener, publisher) { add(listener, { location: 'remote', sessionId: publisher, trackName: 'mic' }); },
    active(id) {
      return (sessions.get(id) || []).filter((t) => t.status === 'active')
        .map((t) => (t.location === 'remote' ? `hears:${t.sessionId}` : 'publishes')).sort();
    },
    async getSession(id) { this.calls.push(['get', id]); return { tracks: structuredClone(sessions.get(id) || []) }; },
    async closeTracks(id, body) {
      this.calls.push(['close', id, structuredClone(body)]);
      assert.equal(body.force, true);
      if (this.failCloses > 0) { this.failCloses -= 1; return { tracks: body.tracks.map(({ mid: m }) => ({ mid: m, errorCode: 'internal_error' })) }; }
      return { tracks: body.tracks.map(({ mid: m }) => {
        const t = (sessions.get(id) || []).find((x) => x.mid === m && x.status === 'active');
        if (!t) return { mid: m, errorCode: 'close_track_error' };
        t.status = 'inactive';
        return { mid: m };
      }) };
    },
  };
}

const KEY = 'synthetic-bind-key';
const say = (room, ws, msg) => room.webSocketMessage(ws, JSON.stringify(msg));
async function internal(room, op, payload) {
  return room.fetch(new Request(`https://do${INTERNAL_OP_PATH}`, {
    method: 'POST', headers: { 'x-live-call-internal': KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ op, ...payload }),
  }));
}
async function join(room, sfu, id, role = 'viewer') {
  await internal(room, 'bind', { participantId: id, cfSessionId: `S${id}` });
  await room.fetch(new Request(`https://do/call/R/ws?participant=${id}&session=S&room=R&role=${role}`, { headers: { Upgrade: 'websocket' } }));
  const ws = room.sockets.get(id);
  sfu.publish(`S${id}`);
  await say(room, ws, { type: 'join', cfSessionId: `S${id}`, cfTrackName: 'mic' });
  return ws;
}
// Open floor, three published members, and everyone already pulling everyone else (as the open floor permits).
async function callInProgress() {
  const state = makeState();
  const room = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY });
  await state.ready;
  const sfu = fakeSfu();
  room.sfu = sfu;
  const ws = {};
  for (const [id, role] of [['alice', 'owner'], ['bob', 'viewer'], ['carol', 'viewer']]) ws[id] = await join(room, sfu, id, role);
  for (const listener of ['alice', 'bob', 'carol']) {
    for (const publisher of ['alice', 'bob', 'carol']) if (publisher !== listener) sfu.pull(`S${listener}`, `S${publisher}`);
  }
  return { state, room, sfu, ws };
}

test('a floor change closes non-holder pulls server-side before the floor op completes', async () => {
  const { room, sfu, ws } = await callInProgress();
  await say(room, ws.alice, { type: 'set-floor', floor: 'moderated' }); // alice (first joiner) holds the floor
  assert.deepEqual(room.room.subscriptions(), { alice: [], bob: ['alice'], carol: ['alice'] });
  // Only the holder is heard, and nobody's own publication was touched. No client cooperation was involved.
  assert.deepEqual(sfu.active('Sbob'), ['hears:Salice', 'publishes']);
  assert.deepEqual(sfu.active('Scarol'), ['hears:Salice', 'publishes']);
  assert.deepEqual(sfu.active('Salice'), ['publishes']);
});

test('granting the floor to another member moves who is heard, server-side', async () => {
  const { room, sfu, ws } = await callInProgress();
  await say(room, ws.alice, { type: 'set-floor', floor: 'moderated' });
  sfu.pull('Sbob', 'Scarol'); // an out-of-band pull, as if a client ignored its directives
  await say(room, ws.alice, { type: 'grant-floor', participantId: 'carol' });
  // Bob now hears carol (the new holder) and no longer alice. Revocation only closes; it never adds a pull, so alice
  // (whose pulls closed while she held the floor) hears nothing until she pulls carol herself.
  assert.deepEqual(sfu.active('Sbob'), ['hears:Scarol', 'publishes']);
  assert.deepEqual(sfu.active('Salice'), ['publishes']);
  assert.deepEqual(sfu.active('Scarol'), ['publishes']); // the holder hears nobody under a moderated floor
});

test('a pull created between room changes is still closed by the next sweep alarm (the 30 s backstop)', async () => {
  const { room, sfu, ws } = await callInProgress();
  await say(room, ws.alice, { type: 'set-floor', floor: 'moderated' });
  sfu.pull('Sbob', 'Scarol'); // not permitted under alice's floor, and no room change follows
  await room.alarm();
  assert.deepEqual(sfu.active('Sbob'), ['hears:Salice', 'publishes']);
});

test('leave closes everything on the leaver\'s session and every pull of its track, then drains its ledger entry', async () => {
  const { room, sfu, ws } = await callInProgress();
  await say(room, ws.carol, { type: 'leave' });
  assert.deepEqual(sfu.active('Scarol'), []);
  assert.deepEqual(sfu.active('Sbob'), ['hears:Salice', 'publishes']);
  assert.deepEqual(sfu.active('Salice'), ['hears:Sbob', 'publishes']);
  assert.equal(room.sfuSessions.Scarol, undefined);
  assert.deepEqual(Object.keys(room.sfuSessions).sort(), ['Salice', 'Sbob']);
});

test('a dropped socket is revoked the same way as an explicit leave', async () => {
  const { room, sfu, ws } = await callInProgress();
  ws.bob.closed = true;
  await room.webSocketClose(ws.bob);
  assert.deepEqual(sfu.active('Sbob'), []);
  assert.deepEqual(sfu.active('Salice'), ['hears:Scarol', 'publishes']);
});

test('a reconnect kicks the old socket out of the room: its pulls and every pull of its track are closed', async () => {
  const { room, sfu } = await callInProgress();
  await room.fetch(new Request('https://do/call/R/ws?participant=carol&session=S&room=R&role=viewer', { headers: { Upgrade: 'websocket' } }));
  assert.deepEqual(sfu.active('Scarol'), ['publishes']); // not departed: carol may re-join with the same session
  assert.deepEqual(sfu.active('Sbob'), ['hears:Salice', 'publishes']);
  assert.deepEqual(sfu.active('Salice'), ['hears:Sbob', 'publishes']);
});

test('a failed close is never assumed closed: it is retried on the short alarm until the SFU confirms', async () => {
  const { state, room, sfu, ws } = await callInProgress();
  sfu.failCloses = 1;
  const before = Date.now();
  await say(room, ws.alice, { type: 'set-floor', floor: 'moderated' });
  const stale = ['Salice', 'Sbob', 'Scarol'].filter((id) => sfu.active(id).some((t) => t !== 'publishes' && t !== 'hears:Salice'));
  assert.equal(stale.length, 1); // exactly the session whose close failed still flows
  const due = await state.storage.getAlarm();
  assert.ok(due <= before + REVOKE_RETRY_MS + 1000, 'retry is scheduled on the short alarm, not the 30 s sweep');
  await room.alarm();
  for (const id of ['Sbob', 'Scarol']) assert.deepEqual(sfu.active(id), ['hears:Salice', 'publishes']);
  assert.deepEqual(sfu.active('Salice'), ['publishes']);
});

test('a pull that lands after the floor moved is closed by the Worker\'s post-dispatch reconcile', async () => {
  const { room, sfu, ws } = await callInProgress();
  // Bob has nothing yet on a fresh session; he asks for carol's track while the floor is still open (permitted).
  await internal(room, 'bind', { participantId: 'bob', cfSessionId: 'Sbob2' });
  const savedFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    if (String(url) === 'https://gateway.example/authorize') {
      return { ok: true, json: async () => ({ sessionId: 'S', roomId: 'R', participantId: 'bob', role: 'viewer' }) };
    }
    // While the pull is in flight the owner moderates the floor; that pass sees no pull yet. Then the pull lands.
    await say(room, ws.alice, { type: 'set-floor', floor: 'moderated' });
    sfu.pull('Sbob2', 'Scarol');
    return { ok: true, json: async () => ({ tracks: [{ mid: 'x', sessionId: 'Scarol', trackName: 'mic' }] }) };
  };
  try {
    const response = await worker.fetch(new Request('https://worker.example/call/R/sfu/tracks?session=S', {
      method: 'POST', headers: { authorization: 'Bearer synthetic-user', 'content-type': 'application/json' },
      body: JSON.stringify({ sessionId: 'Sbob2', tracks: [{ location: 'remote', sessionId: 'Scarol', trackName: 'mic' }] }),
    }), {
      GATEWAY_AUTHORIZE_URL: 'https://gateway.example/authorize', GATEWAY_HOST: 'gateway.example',
      INTERNAL_BIND_KEY: KEY, CF_REALTIME_APP_ID: 'synthetic-app', CF_REALTIME_APP_SECRET: 'synthetic-inert-secret',
      CALL_ROOM: { idFromName(name) { return name; }, get() { return { fetch: (request) => room.fetch(request) }; } },
    });
    assert.equal(response.status, 200);
  } finally { globalThis.fetch = savedFetch; }
  assert.deepEqual(sfu.active('Sbob2'), []); // carol is no longer heard under alice's floor: closed server-side
});
