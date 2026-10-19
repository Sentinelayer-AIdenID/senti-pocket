import test from 'node:test';
import assert from 'node:assert/strict';
import { CallRoomDO, INTERNAL_OP_PATH } from './call-do.mjs';
import worker from './worker.mjs';

// Inert CF runtime doubles: storage and attachments clone values like durable serialization.
function makeWs() {
  let attachment;
  return {
    sent: [], closed: false,
    serializeAttachment(value) { attachment = structuredClone(value); },
    deserializeAttachment() { return structuredClone(attachment); },
    send(value) { this.sent.push(JSON.parse(value)); },
    close() { this.closed = true; },
    get last() { return this.sent.at(-1); },
    received(type) { return this.sent.filter((message) => message.type === type); },
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
const KEY = 'synthetic-bind-key';
async function fresh() {
  const state = makeState();
  const room = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY });
  await state.ready;
  return { state, room };
}
async function internal(room, op, payload) {
  return room.fetch(new Request(`https://do${INTERNAL_OP_PATH}`, {
    method: 'POST', headers: { 'x-live-call-internal': KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ op, ...payload }),
  }));
}
async function connect(room, id, role = 'viewer') {
  await room.fetch(new Request(`https://do/call/R/ws?participant=${id}&session=S&room=R&role=${role}`, { headers: { Upgrade: 'websocket' } }));
  return room.sockets.get(id);
}
async function join(room, id, role = 'viewer') {
  await internal(room, 'bind', { participantId: id, cfSessionId: `S${id}` });
  const ws = await connect(room, id, role);
  await room.webSocketMessage(ws, JSON.stringify({ type: 'join', cfSessionId: `S${id}`, cfTrackName: 'mic' }));
  return ws;
}
async function prepared() {
  const { state, room } = await fresh();
  const alice = await join(room, 'alice', 'owner');
  await join(room, 'bob');
  await join(room, 'carol');
  return { state, room, alice };
}
async function pull(room, tracks, { id = 'bob', sessionId = `S${id}` } = {}) {
  const calls = [];
  const savedFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    if (String(url) === 'https://gateway.example/authorize') {
      return { ok: true, json: async () => ({ sessionId: 'S', roomId: 'R', participantId: id, role: 'viewer' }) };
    }
    calls.push({ url: String(url), body: JSON.parse(options.body) });
    return { ok: true, json: async () => ({ synthetic: true }) };
  };
  try {
    const response = await worker.fetch(new Request('https://worker.example/call/R/sfu/tracks?session=S', {
      method: 'POST', headers: { authorization: 'Bearer synthetic-user', 'content-type': 'application/json' },
      body: JSON.stringify({ sessionId, tracks }),
    }), {
      GATEWAY_AUTHORIZE_URL: 'https://gateway.example/authorize', GATEWAY_HOST: 'gateway.example',
      INTERNAL_BIND_KEY: KEY, CF_REALTIME_APP_ID: 'synthetic-app', CF_REALTIME_APP_SECRET: 'synthetic-inert-secret',
      CALL_ROOM: { idFromName(name) { assert.equal(name, 'S::R'); return name; }, get() { return { fetch: (request) => room.fetch(request) }; } },
    });
    return { response, calls };
  } finally { globalThis.fetch = savedFetch; }
}
const remote = (id, trackName = 'mic') => ({ location: 'remote', sessionId: `S${id}`, trackName });

test('actual Worker refuses moderated non-holder pulls and mixed batches before any SFU dispatch', async () => {
  const { room, alice } = await prepared();
  await room.webSocketMessage(alice, JSON.stringify({ type: 'set-floor', floor: 'moderated' }));
  await room.webSocketMessage(alice, JSON.stringify({ type: 'grant-floor', participantId: 'alice' }));
  assert.deepEqual(room.room.subscriptions().bob, ['alice']);
  for (const tracks of [[remote('carol')], [remote('alice'), remote('carol')]]) {
    const { response, calls } = await pull(room, tracks);
    assert.equal(response.status, 403);
    assert.deepEqual(calls, []);
  }
});
test('actual Worker preserves open/holder pulls but rejects other tracks in an allowed session', async () => {
  const { room, alice } = await prepared();
  const open = await pull(room, [remote('carol')]);
  assert.equal(open.response.status, 200);
  assert.deepEqual(open.calls[0].body.tracks, [remote('carol')]);
  await room.webSocketMessage(alice, JSON.stringify({ type: 'set-floor', floor: 'moderated' }));
  const holder = await pull(room, [remote('alice')]);
  assert.equal(holder.response.status, 200);
  assert.deepEqual(holder.calls[0].body.tracks, [remote('alice')]);
  const wrongTrack = await pull(room, [remote('alice', 'private-camera')]);
  assert.equal(wrongTrack.response.status, 403);
  assert.deepEqual(wrongTrack.calls, []);
});
test('actual Worker rejects malformed remote coordinates/locations without filtering them away', async () => {
  const { room } = await prepared();
  for (const track of [null, { sessionId: 'Salice', trackName: 'mic' }, { location: 'elsewhere', sessionId: 'Salice', trackName: 'mic' }, { location: 'remote', trackName: 'mic' }, { location: 'remote', sessionId: 'Salice' }]) {
    const { response, calls } = await pull(room, [remote('alice'), track]);
    assert.equal(response.status, 400);
    assert.deepEqual(calls, []);
  }
});
test('owned local publication before join remains possible; legacy session-only pulls fail closed', async () => {
  const { room } = await fresh();
  await internal(room, 'bind', { participantId: 'bob', cfSessionId: 'Sbob' });
  const local = { location: 'local', mid: '0', trackName: 'mic' };
  const result = await pull(room, [local]);
  assert.equal(result.response.status, 200);
  assert.deepEqual(result.calls[0].body.tracks, [local]);
  const legacy = await internal(room, 'sfu-authz', { participantId: 'bob', sessionId: 'Sbob', remoteSessionIds: [] });
  assert.equal((await legacy.json()).ok, false);
});
test('explicit leave stays left across constructor rebuild, with no restored publication', async () => {
  const { state, room } = await fresh();
  const ws = await join(room, 'alice');
  await room.webSocketMessage(ws, JSON.stringify({ type: 'leave' }));
  assert.equal(ws.deserializeAttachment().joined, false);
  assert.equal(ws.deserializeAttachment().published, undefined);
  assert.deepEqual(room.room.roster(), []);
  const rebuilt = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY });
  await state.ready;
  assert.deepEqual(rebuilt.room.roster(), []);
  assert.deepEqual(rebuilt.publishedTracks, {});
  assert.deepEqual(rebuilt.mintedTracks, {});
});
test('left socket can explicitly rejoin and retain only its new publication after rebuild', async () => {
  const { state, room } = await fresh();
  const ws = await join(room, 'alice');
  await room.webSocketMessage(ws, JSON.stringify({ type: 'leave' }));
  assert.equal(room.sockets.get('alice'), ws);
  await internal(room, 'bind', { participantId: 'alice', cfSessionId: 'Salice-new' });
  await room.webSocketMessage(ws, JSON.stringify({ type: 'join', cfSessionId: 'Salice-new', cfTrackName: 'new-mic' }));
  assert.equal(ws.deserializeAttachment().joined, true);
  const rebuilt = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY });
  await state.ready;
  assert.deepEqual(rebuilt.room.roster().map((p) => p.id), ['alice']);
  assert.deepEqual(rebuilt.publishedTracks.alice, { sessionId: 'Salice-new', trackName: 'new-mic' });
});
test('accepted but unjoined and legacy unmarked sockets do not become members on rebuild', async () => {
  const { state, room } = await fresh();
  const ws = await connect(room, 'alice');
  const rebuilt = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY });
  await state.ready;
  assert.deepEqual(rebuilt.room.roster(), []);
  ws.serializeAttachment({ participantId: 'alice', sessionId: 'S', role: 'viewer', published: { sessionId: 'stale', trackName: 'mic' } });
  const legacy = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY });
  await state.ready;
  assert.deepEqual(legacy.room.roster(), []);
  assert.deepEqual(legacy.publishedTracks, {});
});
test('a replaced socket cannot reclaim or clear the current socket membership', async () => {
  const { state, room } = await fresh();
  const old = await join(room, 'alice');
  const current = await connect(room, 'alice');
  await room.webSocketMessage(current, JSON.stringify({ type: 'join', cfSessionId: 'Salice', cfTrackName: 'mic' }));
  await room.webSocketMessage(old, JSON.stringify({ type: 'leave' }));
  await room.webSocketMessage(old, JSON.stringify({ type: 'join', cfSessionId: 'Salice', cfTrackName: 'stale' }));
  assert.equal(room.sockets.get('alice'), current);
  assert.deepEqual(room.room.roster().map((p) => p.id), ['alice']);
  assert.deepEqual(room.publishedTracks.alice, { sessionId: 'Salice', trackName: 'mic' });
  const rebuilt = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY });
  await state.ready;
  assert.deepEqual(rebuilt.room.roster().map((p) => p.id), ['alice']);
  assert.deepEqual(rebuilt.publishedTracks.alice, { sessionId: 'Salice', trackName: 'mic' });
});

test('reconnect membership changes preserve the resulting floor holder through rebuild', async () => {
  const { state, room, alice } = await prepared();
  await room.webSocketMessage(alice, JSON.stringify({ type: 'set-floor', floor: 'moderated' }));
  assert.equal(room.room.state().holder, 'alice');
  const replacement = await connect(room, 'alice');
  await room.webSocketMessage(replacement, JSON.stringify({ type: 'join', cfSessionId: 'Salice', cfTrackName: 'mic' }));
  const holder = room.room.state().holder;
  assert.equal(holder, 'bob');
  const rebuilt = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY });
  await state.ready;
  assert.equal(rebuilt.room.state().holder, holder);
  assert.deepEqual(rebuilt.room.subscriptions(), room.room.subscriptions());
  // Model a closing retired socket still present in the runtime connection census.
  alice.closed = false;
  alice.sent.length = 0;
  rebuilt.broadcast();
  assert.deepEqual(alice.sent, []);
});
