import test from 'node:test';
import assert from 'node:assert/strict';

// --- minimal Cloudflare Durable Object runtime mocks (no miniflare) ---
function makeWs() {
  let attach;
  const sent = [];
  return {
    serializeAttachment(v) { attach = v; },
    deserializeAttachment() { return attach; },
    send(m) { sent.push(JSON.parse(m)); },
    close() { this.closed = true; },
    _sent: sent,
    get last() { return sent[sent.length - 1]; },
    received(type) { return sent.filter((e) => e.type === type); },
  };
}

function makeState() {
  const store = new Map();
  const wss = [];
  let alarm = null;
  let ready = Promise.resolve();
  return {
    storage: {
      async get(k) { return store.get(k); },
      async put(k, v) { store.set(k, v); },
      async getAlarm() { return alarm; },
      async setAlarm(t) { alarm = t; },
    },
    getWebSockets() { return wss.filter((w) => !w.closed); },
    acceptWebSocket(ws) { wss.push(ws); },
    blockConcurrencyWhile(fn) { ready = (async () => fn())(); return ready; },
    get ready() { return ready; },
  };
}

function mkReq(url, { method = 'GET', upgrade = false, internal = null, json = null } = {}) {
  const h = new Map();
  if (upgrade) h.set('upgrade', 'websocket');
  if (internal != null) h.set('x-live-call-internal', internal);
  return {
    url,
    method,
    headers: { get: (k) => (h.has(k.toLowerCase()) ? h.get(k.toLowerCase()) : null) },
    async json() { return json; },
  };
}

globalThis.WebSocketPair = function () { return { 0: {}, 1: makeWs() }; };
globalThis.Response = class { constructor(body, init = {}) { this.body = body; this.status = init.status ?? 200; this.webSocket = init.webSocket; } };

const { CallRoomDO } = await import('./call-do.mjs');

async function newDO(env = {}) {
  const state = makeState();
  const doo = new CallRoomDO(state, { INTERNAL_BIND_KEY: 'k', ...env });
  await state.ready;
  return doo;
}
async function mint(doo, participantId, cfSessionId) {
  await doo.fetch(mkReq('https://do/bind', { method: 'POST', internal: 'k', json: { participantId, cfSessionId } }));
}
async function connect(doo, { p, session = 'S', role = 'viewer', room = 'R' }) {
  await doo.fetch(mkReq(`https://do/call/${room}/ws?participant=${p}&session=${session}&role=${role}&room=${room}`, { upgrade: true }));
  return doo.sockets.get(p);
}

test('identity is the attachment, never the body: a spoofed participantId in a join is ignored', async () => {
  const doo = await newDO();
  await mint(doo, 'alice', 'SA');
  const ws = await connect(doo, { p: 'alice' });
  await doo.webSocketMessage(ws, JSON.stringify({ type: 'join', participantId: 'bob', cfSessionId: 'SA', cfTrackName: 'mic' }));
  const ids = doo.room.roster().map((r) => r.id);
  assert.deepEqual(ids, ['alice']); // NOT 'bob' — removing the participantId overwrite makes this fail
  assert.ok(doo.publishedTracks.alice);
  assert.equal(doo.publishedTracks.bob, undefined);
});

test('floor control is privileged: a viewer cannot change the floor; an owner can', async () => {
  const doo = await newDO();
  const viewer = await connect(doo, { p: 'v', role: 'viewer' });
  await doo.webSocketMessage(viewer, JSON.stringify({ type: 'set-floor', floor: 'moderated' }));
  assert.equal(viewer.last.ok, false);
  assert.equal(viewer.last.reason, 'forbidden-role'); // removing the role gate makes this fail
  assert.equal(doo.room.state().floor, 'open');

  const owner = await connect(doo, { p: 'o', role: 'owner' });
  await doo.webSocketMessage(owner, JSON.stringify({ type: 'set-floor', floor: 'moderated' }));
  assert.equal(doo.room.state().floor, 'moderated');
});

test('published CF coords are accepted only if the Worker minted that session for the participant', async () => {
  const doo = await newDO();
  const ws = await connect(doo, { p: 'eve' });
  // eve was never minted a session -> an unminted claim is rejected
  await doo.webSocketMessage(ws, JSON.stringify({ type: 'join', cfSessionId: 'SX', cfTrackName: 'mic' }));
  assert.equal(doo.publishedTracks.eve, undefined); // removing the mint check makes this fail
  // now the Worker mints SE for eve; the matching claim is accepted
  await mint(doo, 'eve', 'SE');
  await doo.webSocketMessage(ws, JSON.stringify({ type: 'join', cfSessionId: 'SE', cfTrackName: 'mic' }));
  assert.deepEqual(doo.publishedTracks.eve, { sessionId: 'SE', trackName: 'mic' });
});

test('fan-out: two published members each receive the other as a remote track', async () => {
  const doo = await newDO();
  await mint(doo, 'a', 'SA');
  await mint(doo, 'b', 'SB');
  const a = await connect(doo, { p: 'a' });
  const b = await connect(doo, { p: 'b' });
  await doo.webSocketMessage(a, JSON.stringify({ type: 'join', cfSessionId: 'SA', cfTrackName: 'mic' }));
  await doo.webSocketMessage(b, JSON.stringify({ type: 'join', cfSessionId: 'SB', cfTrackName: 'mic' }));
  const aDir = a.received('directives').pop();
  const bDir = b.received('directives').pop();
  assert.deepEqual(aDir.remoteTracks, [{ location: 'remote', sessionId: 'SB', trackName: 'mic' }]);
  assert.deepEqual(bDir.remoteTracks, [{ location: 'remote', sessionId: 'SA', trackName: 'mic' }]);
});

test('reconnect kicks the participant\'s own stale socket', async () => {
  const doo = await newDO();
  const first = await connect(doo, { p: 'x' });
  const second = await connect(doo, { p: 'x' });
  assert.equal(first.closed, true);
  assert.equal(doo.sockets.get('x'), second);
});

test('oversized and malformed messages are rejected without mutating the room', async () => {
  const doo = await newDO();
  const ws = await connect(doo, { p: 'a' });
  await doo.webSocketMessage(ws, 'x'.repeat(17000));
  assert.equal(ws.last.reason, 'message-too-large');
  await doo.webSocketMessage(ws, '{not json');
  assert.equal(ws.last.reason, 'bad-json');
});

test('leave forgets the participant and clears its minted + published state', async () => {
  const doo = await newDO();
  await mint(doo, 'a', 'SA');
  const ws = await connect(doo, { p: 'a' });
  await doo.webSocketMessage(ws, JSON.stringify({ type: 'join', cfSessionId: 'SA', cfTrackName: 'mic' }));
  await doo.webSocketMessage(ws, JSON.stringify({ type: 'leave' }));
  assert.equal(doo.room.state().size, 0);
  assert.equal(doo.publishedTracks.a, undefined);
  assert.equal(doo.mintedTracks.a, undefined);
});

test('hibernation rebuild restores membership from the surviving sockets', async () => {
  // First DO instance: one member joins, then the instance is "evicted".
  const state = makeState();
  const doo1 = new CallRoomDO(state, { INTERNAL_BIND_KEY: 'k' });
  await state.ready;
  await doo1.fetch(mkReq('https://do/call/R/ws?participant=a&session=S&role=owner&room=R', { upgrade: true }));
  // New instance over the SAME state (same storage + surviving sockets) rebuilds the room.
  const doo2 = new CallRoomDO(state, { INTERNAL_BIND_KEY: 'k' });
  await state.ready;
  assert.equal(doo2.meta.sessionId, 'S');
  assert.deepEqual(doo2.room.roster().map((r) => r.id), ['a']);
});
