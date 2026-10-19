import test from 'node:test';
import assert from 'node:assert/strict';
import { CallRoomDO, INTERNAL_OP_PATH, REVOKE_RETRY_MS, PULL_GRACE_MS, PULL_RECHECK_MS } from './call-do.mjs';
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
    calls: [], failCloses: 0, failGets: false,
    publish(id) { add(id, { location: 'local', trackName: 'mic' }); },
    pull(listener, publisher) { add(listener, { location: 'remote', sessionId: publisher, trackName: 'mic' }); },
    publishOn(id, trackName) { add(id, { location: 'local', trackName }); },
    pullWithMid(listener, publisher, m) {
      if (!sessions.has(listener)) sessions.set(listener, []);
      sessions.get(listener).push({ mid: m, status: 'active', location: 'remote', sessionId: publisher, trackName: 'mic' });
    },
    midOf(listener, publisher) { return (sessions.get(listener) || []).find((t) => t.sessionId === publisher).mid; },
    active(id) {
      return (sessions.get(id) || []).filter((t) => t.status === 'active')
        .map((t) => (t.location === 'remote' ? `hears:${t.sessionId}` : 'publishes')).sort();
    },
    async getSession(id) {
      this.calls.push(['get', id]);
      if (this.failGets) throw new Error('cf-realtime-503');
      return { tracks: structuredClone(sessions.get(id) || []) };
    },
    async closeTracks(id, body) {
      this.calls.push(['close', id, structuredClone(body)]);
      assert.equal(body.force, true);
      if (this.failCloses > 0) { this.failCloses -= 1; return { tracks: body.tracks.map(({ mid: m }) => ({ mid: m, errorCode: 'internal_error' })) }; }
      return { tracks: body.tracks.map(({ mid: m }) => {
        const hits = (sessions.get(id) || []).filter((x) => x.mid === m && x.status === 'active');
        if (!hits.length) return { mid: m, errorCode: 'close_track_error' };
        hits.forEach((t) => { t.status = 'inactive'; });
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

// Drive the actual Worker's sfu/tracks pull; `duringDispatch` runs while the CF tracks/new call is in flight.
async function workerPull(room, { id, sessionId, tracks, duringDispatch = async () => {}, signals = [], extra = {} }) {
  const savedFetch = globalThis.fetch;
  const dispatched = [];
  globalThis.fetch = async (url, options) => {
    if (String(url) === 'https://gateway.example/authorize') {
      return { ok: true, json: async () => ({ sessionId: 'S', roomId: 'R', participantId: id, role: 'viewer' }) };
    }
    signals.push(options.signal);
    dispatched.push(JSON.parse(options.body));
    await duringDispatch();
    return { ok: true, json: async () => ({ tracks: [] }) };
  };
  try {
    const response = await worker.fetch(new Request('https://worker.example/call/R/sfu/tracks?session=S', {
      method: 'POST', headers: { authorization: 'Bearer synthetic-user', 'content-type': 'application/json' },
      body: JSON.stringify({ sessionId, tracks, ...extra }),
    }), {
      GATEWAY_AUTHORIZE_URL: 'https://gateway.example/authorize', GATEWAY_HOST: 'gateway.example',
      INTERNAL_BIND_KEY: KEY, CF_REALTIME_APP_ID: 'synthetic-app', CF_REALTIME_APP_SECRET: 'synthetic-inert-secret',
      CALL_ROOM: { idFromName(name) { return name; }, get() { return { fetch: (request) => room.fetch(request) }; } },
    });
    return { response, dispatched };
  } finally { globalThis.fetch = savedFetch; }
}
const carolTrack = [{ location: 'remote', sessionId: 'Scarol', trackName: 'mic' }];

// Regressions from the adversarial review (ADV-n / PROP-n) of #167.
test('ADV-1: a leave while a pull is in flight cannot strand the landed pull (leave and socket close)', async () => {
  for (const departure of ['leave', 'close']) {
    const { room, sfu, ws } = await callInProgress();
    await internal(room, 'bind', { participantId: 'bob', cfSessionId: 'Sbob2' }); // a fresh, empty pull session
    const { response } = await workerPull(room, {
      id: 'bob', sessionId: 'Sbob2', tracks: carolTrack,
      duringDispatch: async () => {
        if (departure === 'leave') await say(room, ws.bob, { type: 'leave' });
        else { ws.bob.closed = true; await room.webSocketClose(ws.bob); }
        sfu.pull('Sbob2', 'Scarol'); // the read during the leave saw Sbob2 empty; then the pull lands
      },
    });
    assert.equal(response.status, 200);
    assert.deepEqual(sfu.active('Sbob2'), [], `${departure}: the departed participant still hears carol`);
  }
});

test('ADV-1: even if the Worker never reports back, the grace window keeps the session and the alarm closes the pull', async () => {
  const { room, sfu, ws } = await callInProgress();
  await internal(room, 'bind', { participantId: 'bob', cfSessionId: 'Sbob2' });
  const authz = await (await internal(room, 'sfu-authz', { participantId: 'bob', sessionId: 'Sbob2', remoteTracks: carolTrack })).json();
  assert.equal(authz.ok, true);
  await say(room, ws.bob, { type: 'leave' });
  assert.ok(room.sfuSessions.Sbob2, 'an authorized pull may still land: the session stays in the ledger');
  sfu.pull('Sbob2', 'Scarol'); // lands; no reconcile follows (the Worker died)
  await room.alarm();
  assert.deepEqual(sfu.active('Sbob2'), []);
  room.sfuSessions.Sbob2.pullPendingUntil = Date.now() - 1; // the grace window has passed
  await room.alarm();
  assert.equal(room.sfuSessions.Sbob2, undefined, 'dropped only after the grace window');
  assert.ok(PULL_GRACE_MS >= 30000);
});

test('ADV-2: a pull may not reuse a transceiver (mid / bidirectional), so revoking it can never stop the puller\'s own mic', async () => {
  const { room } = await callInProgress();
  for (const extra of [{ mid: '#mic' }, { mid: '4' }, { bidirectionalMediaStream: true }]) {
    const { response, dispatched } = await workerPull(room, { id: 'bob', sessionId: 'Sbob', tracks: [{ ...carolTrack[0], ...extra }] });
    assert.equal(response.status, 400, JSON.stringify(extra));
    assert.deepEqual(dispatched, [], 'refused before any SFU dispatch');
  }
});

test('ADV-3: after a hibernation rebuild, a member publishing on an earlier session is still heard', async () => {
  const state = makeState();
  const room = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY });
  await state.ready;
  const sfu = fakeSfu();
  room.sfu = sfu;
  await join(room, sfu, 'alice', 'owner'); // publishes on Salice
  await join(room, sfu, 'bob');
  await internal(room, 'bind', { participantId: 'alice', cfSessionId: 'Salice-pull' }); // a second session for pulls
  sfu.pull('Sbob', 'Salice');
  const rebuilt = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY }); // hibernation wake
  await state.ready;
  rebuilt.sfu = sfu;
  assert.deepEqual(rebuilt.publishedTracks.alice, { sessionId: 'Salice', trackName: 'mic' });
  await rebuilt.alarm();
  assert.deepEqual(sfu.active('Sbob'), ['hears:Salice', 'publishes']);
});

test('ADV-4: messages that cannot narrow a permission cost no SFU pass', async () => {
  const { room, sfu, ws } = await callInProgress();
  sfu.calls.length = 0;
  for (const type of ['touch', 'roster', 'zzz', 'join']) for (let i = 0; i < 5; i += 1) await say(room, ws.bob, { type });
  await say(room, ws.bob, { type: 'set-floor', floor: 'moderated' }); // forbidden for a viewer: nothing changed
  assert.equal(sfu.calls.length, 0);
});

test('ADV-5: a session minted by someone who never joined is drained after the idle window, and an empty room stops its alarm', async () => {
  const state = makeState();
  const room = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY });
  await state.ready;
  const sfu = fakeSfu();
  room.sfu = sfu;
  await internal(room, 'bind', { participantId: 'mallory', cfSessionId: 'Smallory' }); // HTTP mint only, no socket
  const alice = await join(room, sfu, 'alice', 'owner');
  alice.closed = true;
  await room.webSocketClose(alice);
  await room.alarm();
  assert.ok(room.sfuSessions.Smallory, 'within the idle window it is kept');
  room.sfuSessions.Smallory.boundAt -= 300001;
  await state.storage.setAlarm(null);
  await room.alarm();
  assert.deepEqual(Object.keys(room.sfuSessions), []);
  assert.equal(await state.storage.getAlarm(), null);
});

test('ADV-6: the retry backoff survives a hibernation rebuild', async () => {
  const { state, room, sfu } = await callInProgress();
  sfu.failGets = true;
  const delays = [];
  for (let i = 0; i < 7; i += 1) { const t = Date.now(); await room.alarm(); delays.push(Math.round(((await state.storage.getAlarm()) - t) / 1000)); }
  assert.deepEqual(delays, [2, 2, 2, 2, 2, 30, 30]);
  const rebuilt = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY });
  await state.ready;
  rebuilt.sfu = sfu;
  const t = Date.now();
  await rebuilt.alarm();
  assert.equal(Math.round(((await state.storage.getAlarm()) - t) / 1000), 30);
});

test('ADV-9: a reconnect kick tells everyone the participant dropped, and the re-join tells them it is back', async () => {
  const { room, sfu, ws } = await callInProgress();
  const heard = (msg) => msg.remoteTracks.map((t) => t.sessionId).sort();
  const n = ws.bob.sent.length;
  const carol2 = await room.fetch(new Request('https://do/call/R/ws?participant=carol&session=S&room=R&role=viewer', { headers: { Upgrade: 'websocket' } }))
    .then(() => room.sockets.get('carol'));
  const duringKick = ws.bob.sent.slice(n).filter((m) => m.type === 'directives');
  assert.deepEqual(heard(duringKick.at(-1)), ['Salice'], 'bob is told carol dropped');
  assert.deepEqual(sfu.active('Sbob'), ['hears:Salice', 'publishes']);
  await say(room, carol2, { type: 'join', cfSessionId: 'Scarol', cfTrackName: 'mic' });
  assert.deepEqual(heard(ws.bob.sent.filter((m) => m.type === 'directives').at(-1)), ['Salice', 'Scarol'], 'and that she is back');
});

test('PROP-7: a floor change that lands while a pass is running is fully revoked when the floor op returns', async () => {
  const { room, sfu, ws } = await callInProgress();
  const read = sfu.getSession.bind(sfu);
  let release;
  const gate = new Promise((r) => { release = r; });
  let hold = true;
  sfu.getSession = async (id) => { const s = await read(id); if (hold && id === 'Scarol') await gate; return s; };
  const running = room.alarm(); // decides Salice/Sbob under the OPEN floor, then waits on Scarol's read
  await new Promise((r) => setTimeout(r, 10));
  hold = false;
  const op = say(room, ws.alice, { type: 'set-floor', floor: 'moderated' }); // arrives mid-pass
  await new Promise((r) => setTimeout(r, 10));
  release();
  await op; // the floor op's own await must cover its change
  assert.deepEqual(sfu.active('Sbob'), ['hears:Salice', 'publishes']);
  await running;
});

test('PROP-8: a departed session whose close FAILED stays in the ledger and is retried', async () => {
  const { room, sfu, ws } = await callInProgress();
  sfu.failCloses = 10;
  await say(room, ws.carol, { type: 'leave' });
  assert.ok(room.sfuSessions.Scarol, 'kept although its close failed');
  sfu.failCloses = 0;
  await room.alarm();
  assert.deepEqual(sfu.active('Scarol'), []);
  assert.equal(room.sfuSessions.Scarol, undefined);
});

test('ADV-1: a pull that outlives its grace window is still closed: the Worker\'s reconcile re-adds the dropped session', async () => {
  const { room, sfu, ws } = await callInProgress();
  await internal(room, 'bind', { participantId: 'bob', cfSessionId: 'Sbob2' });
  await workerPull(room, {
    id: 'bob', sessionId: 'Sbob2', tracks: carolTrack,
    duringDispatch: async () => {
      room.sfuSessions.Sbob2.pullPendingUntil = 0; // the dispatch outlived the grace window
      await say(room, ws.bob, { type: 'leave' }); // so this pass drops the empty, departed session
      assert.equal(room.sfuSessions.Sbob2, undefined);
      sfu.pull('Sbob2', 'Scarol');
    },
  });
  assert.deepEqual(sfu.active('Sbob2'), []);
});

const tick = () => new Promise((r) => setTimeout(r, 10));
function withClock(fn) {
  return async () => {
    const realNow = Date.now;
    const clock = { skew: 0 };
    Date.now = () => realNow() + clock.skew;
    try { await fn(clock); } finally { Date.now = realNow; }
  };
}

// Round-2 regressions (R2-n) of #167.
test('R2-1: grace is judged at READ time: a pass that outlives the window cannot drop a session read inside it', withClock(async (clock) => {
  const { room, sfu, ws } = await callInProgress();
  await internal(room, 'bind', { participantId: 'bob', cfSessionId: 'Sbob2' });
  assert.equal((await (await internal(room, 'sfu-authz', { participantId: 'bob', sessionId: 'Sbob2', remoteTracks: carolTrack })).json()).ok, true);
  const read = sfu.getSession.bind(sfu);
  let release; const gate = new Promise((r) => { release = r; });
  let hold = true;
  sfu.getSession = async (id) => { const st = await read(id); if (hold && id === 'Salice') await gate; return st; };
  const leave = say(room, ws.bob, { type: 'leave' }); // reads Sbob2 empty, then waits on a slow read
  await tick();
  sfu.pull('Sbob2', 'Scarol'); // the authorized pull lands after that read
  const rec = internal(room, 'reconcile', { participantId: 'bob', cfSessionId: 'Sbob2' });
  await tick();
  clock.skew = PULL_GRACE_MS + 1000; // the pass finishes after the grace window
  hold = false; release();
  await leave; await rec;
  await room.alarm();
  assert.deepEqual(sfu.active('Sbob2'), []);
}));

test('R2-2: an abandoned session is no longer the participant\'s: no publication, no pull authorization on it', async () => {
  const { room } = await callInProgress();
  await internal(room, 'bind', { participantId: 'dave', cfSessionId: 'Sdave' }); // HTTP mint, no socket
  room.sfuSessions.Sdave.boundAt -= 300001;
  await room.alarm();
  assert.equal(room.sfuSessions.Sdave, undefined);
  assert.equal(room.mintedTracks.dave, undefined, 'ownership dropped with the orphan');
  await room.fetch(new Request('https://do/call/R/ws?participant=dave&session=S&room=R&role=viewer', { headers: { Upgrade: 'websocket' } }));
  await say(room, room.sockets.get('dave'), { type: 'join', cfSessionId: 'Sdave', cfTrackName: 'mic' });
  assert.equal(room.publishedTracks.dave, undefined, 'no publication on the abandoned session');
  const { response, dispatched } = await workerPull(room, { id: 'dave', sessionId: 'Sdave', tracks: carolTrack });
  assert.equal(response.status, 403);
  assert.deepEqual(dispatched, []);
});

test('R2-2: sfu-authz refuses a session that is not a live ledger entry, even if still marked as minted', async () => {
  const { room } = await callInProgress();
  await internal(room, 'bind', { participantId: 'bob', cfSessionId: 'Sbob3' });
  room.sfuSessions.Sbob3.departed = true;
  const res = await (await internal(room, 'sfu-authz', { participantId: 'bob', sessionId: 'Sbob3', remoteTracks: carolTrack })).json();
  assert.equal(res.ok, false);
});

test('R2-2: a pull whose SFU call throws is still reconciled (finally), and the DO re-checks after the dispatch bound', async () => {
  const { state, room, sfu, ws } = await callInProgress();
  await internal(room, 'bind', { participantId: 'bob', cfSessionId: 'Sbob2' });
  const before = Date.now();
  const { response } = await workerPull(room, {
    id: 'bob', sessionId: 'Sbob2', tracks: carolTrack,
    duringDispatch: async () => { await say(room, ws.bob, { type: 'leave' }); sfu.pull('Sbob2', 'Scarol'); throw new Error('aborted'); },
  });
  assert.equal(response.status, 502);
  assert.deepEqual(sfu.active('Sbob2'), [], 'closed by the reconcile in finally');
  const due = await state.storage.getAlarm();
  assert.ok(due <= before + PULL_RECHECK_MS + 1000, 'a re-check is scheduled after the Worker dispatch bound');
  assert.ok(PULL_RECHECK_MS > 10000 && PULL_RECHECK_MS < PULL_GRACE_MS);
});

test('R2-3: a 404 on a live member\'s session keeps it in the ledger, so its pulls are still revoked later', async () => {
  const { room, sfu, ws } = await callInProgress();
  const read = sfu.getSession.bind(sfu);
  let once = true;
  sfu.getSession = async (id) => { if (once && id === 'Sbob') { once = false; throw new Error('cf-realtime-404'); } return read(id); };
  await room.alarm();
  assert.ok(room.sfuSessions.Sbob);
  await say(room, ws.alice, { type: 'set-floor', floor: 'moderated' });
  assert.deepEqual(sfu.active('Sbob'), ['hears:Salice', 'publishes']);
});

test('R2-4: a re-pull that reuses a confirmed-closed mid for the same track is closed again', async () => {
  const { room, sfu, ws } = await callInProgress();
  const m = sfu.midOf('Sbob', 'Scarol');
  await say(room, ws.alice, { type: 'set-floor', floor: 'moderated' });
  await say(room, ws.alice, { type: 'set-floor', floor: 'open' });
  sfu.pullWithMid('Sbob', 'Scarol', m); // permitted re-pull; the SFU recycles the transceiver
  await say(room, ws.alice, { type: 'set-floor', floor: 'moderated' });
  assert.deepEqual(sfu.active('Sbob'), ['hears:Salice', 'publishes']);
});

test('R2-5: the SFU only receives a body rebuilt from validated fields; unknown or case-variant keys are refused', async () => {
  const { room } = await callInProgress();
  for (const tracks of [
    [{ ...carolTrack[0], Mid: '#mic' }],
    [{ location: 'local', Location: 'remote', sessionId: 'Sx-other-room', trackName: 'mic' }],
    [{ location: 'local', trackName: 'mic', sessionId: 'Sx' }], // a local track carrying a session id
    [{ ...carolTrack[0], kind: 'screen' }],
  ]) {
    const { response, dispatched } = await workerPull(room, { id: 'bob', sessionId: 'Sbob', tracks });
    assert.equal(response.status, 400, JSON.stringify(tracks));
    assert.deepEqual(dispatched, []);
  }
  const ok = await workerPull(room, { id: 'bob', sessionId: 'Sbob', tracks: [{ ...carolTrack[0], kind: 'audio' }] });
  assert.equal(ok.response.status, 200);
  assert.deepEqual(ok.dispatched, [{ tracks: [{ location: 'remote', sessionId: 'Scarol', trackName: 'mic', kind: 'audio' }] }]);
});

// Properties the round-2 review showed no test guarded.
test('the DO reads at most 4 sessions at a time', async () => {
  const { room, sfu } = await callInProgress();
  for (let i = 0; i < 9; i += 1) await internal(room, 'bind', { participantId: 'alice', cfSessionId: `Sx${i}` });
  const read = sfu.getSession.bind(sfu);
  let inFlight = 0; let peak = 0;
  sfu.getSession = async (id) => { inFlight += 1; peak = Math.max(peak, inFlight); await tick(); inFlight -= 1; return read(id); };
  await room.alarm();
  assert.ok(peak > 1 && peak <= 4, `peak ${peak}`);
});

test('SFU calls are bounded: the DO and the Worker both pass an abort signal', async () => {
  const state = makeState();
  const savedFetch = globalThis.fetch;
  const seen = [];
  globalThis.fetch = async (url, options) => { seen.push(options.signal); return { ok: true, json: async () => ({ tracks: [] }) }; };
  try {
    const room = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY, CF_REALTIME_APP_ID: 'app', CF_REALTIME_APP_SECRET: 'inert' });
    await state.ready;
    await internal(room, 'bind', { participantId: 'a', cfSessionId: 'Sa' });
    await room.alarm();
  } finally { globalThis.fetch = savedFetch; }
  assert.ok(seen.length > 0 && seen.every((s) => s instanceof AbortSignal), 'DO SFU reads carry a timeout signal');
  const { room } = await callInProgress();
  const signals = [];
  await workerPull(room, { id: 'bob', sessionId: 'Sbob', tracks: carolTrack, signals });
  assert.ok(signals.length === 1 && signals[0] instanceof AbortSignal, 'the Worker dispatch carries a timeout signal');
});

test('a floor op that did not apply costs no SFU pass', async () => {
  const { room, sfu, ws } = await callInProgress();
  sfu.calls.length = 0;
  await say(room, ws.alice, { type: 'grant-floor', participantId: 'nobody' }); // open floor: refused
  assert.equal(sfu.calls.length, 0);
});

test('grace and confirmed closes survive a hibernation rebuild', async () => {
  const { state, room, sfu, ws } = await callInProgress();
  await internal(room, 'bind', { participantId: 'bob', cfSessionId: 'Sbob2' });
  await internal(room, 'sfu-authz', { participantId: 'bob', sessionId: 'Sbob2', remoteTracks: carolTrack });
  await say(room, ws.alice, { type: 'set-floor', floor: 'moderated' }); // closes bob's pull of carol on Sbob
  const rebuilt = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY });
  await state.ready;
  rebuilt.sfu = sfu;
  assert.ok(rebuilt.sfuSessions.Sbob2.pullPendingUntil > Date.now());
  assert.ok(rebuilt.sfuSessions.Sbob.closed.length > 0);
  sfu.calls.length = 0;
  await rebuilt.alarm();
  assert.equal(sfu.calls.filter((c) => c[0] === 'close' && c[1] === 'Sbob').length, 0, 'no second close of a confirmed-closed track');
});

test('a re-added session of someone who left is closed entirely, publication included', async () => {
  const { room, sfu, ws } = await callInProgress();
  await internal(room, 'bind', { participantId: 'bob', cfSessionId: 'Sbob2' });
  await workerPull(room, {
    id: 'bob', sessionId: 'Sbob2', tracks: carolTrack,
    duringDispatch: async () => {
      room.sfuSessions.Sbob2.pullPendingUntil = 0;
      await say(room, ws.bob, { type: 'leave' });
      sfu.publishOn('Sbob2', 'cam');
      sfu.pull('Sbob2', 'Scarol');
    },
  });
  assert.deepEqual(sfu.active('Sbob2'), []);
});

test('the orphan rule spares a participant whose socket is open but who has not joined yet', async () => {
  const { room, sfu } = await callInProgress();
  await internal(room, 'bind', { participantId: 'erin', cfSessionId: 'Serin' });
  sfu.publishOn('Serin', 'mic');
  await room.fetch(new Request('https://do/call/R/ws?participant=erin&session=S&room=R&role=viewer', { headers: { Upgrade: 'websocket' } }));
  room.sfuSessions.Serin.boundAt -= 300001;
  await room.alarm();
  assert.equal(room.sfuSessions.Serin.departed, false);
  assert.deepEqual(sfu.active('Serin'), ['publishes']);
});

test('the post-dispatch reconcile reads only the session it dispatched on', async () => {
  const { room, sfu } = await callInProgress();
  sfu.calls.length = 0;
  await internal(room, 'reconcile', { participantId: 'bob', cfSessionId: 'Sbob' });
  assert.deepEqual(sfu.calls.filter((c) => c[0] === 'get').map((c) => c[1]), ['Sbob']);
});

test('an authorized pull\'s grace is persisted by the authorization itself (eviction right after it keeps the session)', async () => {
  const { state, room } = await callInProgress();
  await internal(room, 'bind', { participantId: 'bob', cfSessionId: 'Sbob2' });
  await internal(room, 'sfu-authz', { participantId: 'bob', sessionId: 'Sbob2', remoteTracks: carolTrack });
  const rebuilt = new CallRoomDO(state, { INTERNAL_BIND_KEY: KEY }); // evicted before anything else wrote storage
  await state.ready;
  assert.ok(rebuilt.sfuSessions.Sbob2.pullPendingUntil > Date.now());
});

// Properties the independent review (opus-proof) found unpinned at 55a4b968.
test('read-time grace holds even with no reconcile: a pass that outlives the window keeps a session it read inside it', withClock(async (clock) => {
  const { room, sfu, ws } = await callInProgress();
  await internal(room, 'bind', { participantId: 'bob', cfSessionId: 'Sbob2' });
  await internal(room, 'sfu-authz', { participantId: 'bob', sessionId: 'Sbob2', remoteTracks: carolTrack });
  const read = sfu.getSession.bind(sfu);
  let release; const gate = new Promise((r) => { release = r; });
  let hold = true;
  sfu.getSession = async (id) => { const st = await read(id); if (hold && id === 'Salice') await gate; return st; };
  const leave = say(room, ws.bob, { type: 'leave' }); // reads Sbob2 empty, waits on a slow read of Salice
  await tick();
  sfu.pull('Sbob2', 'Scarol'); // lands after that read; the Worker never reports back
  clock.skew = PULL_GRACE_MS + 1000;
  hold = false; release();
  await leave;
  assert.ok(room.sfuSessions.Sbob2, 'kept: it was read inside its grace window');
  await room.alarm();
  assert.deepEqual(sfu.active('Sbob2'), []);
}));

test('a pass never deletes or mutates an entry re-bound under the same session while it was reading', async () => {
  const { room, sfu } = await callInProgress();
  await internal(room, 'bind', { participantId: 'bob', cfSessionId: 'Sbob2' });
  room.sfuSessions.Sbob2.departed = true; // empty and departed: this pass will decide "drained"
  const read = sfu.getSession.bind(sfu);
  let release; const gate = new Promise((r) => { release = r; });
  sfu.getSession = async (id) => { const st = await read(id); if (id === 'Sbob2') await gate; return st; };
  const pass = room.alarm();
  await tick();
  const replacement = { participantId: 'bob', departed: true, boundAt: Date.now(), closed: [], pullPendingUntil: Date.now() + 60000 };
  room.sfuSessions.Sbob2 = replacement; // e.g. a reconcile re-add while the pass was reading
  release();
  await pass;
  assert.equal(room.sfuSessions.Sbob2, replacement);
});

test('permission is decided against the floor as it is AFTER the SFU read (no queued pass to rescue it)', async () => {
  const { room, sfu } = await callInProgress();
  const read = sfu.getSession.bind(sfu);
  sfu.getSession = async (id) => {
    const st = await read(id);
    if (id === 'Sbob') room.room.setFloor('moderated'); // floor moves during the read, with no message and no new pass
    return st;
  };
  await room.alarm();
  assert.deepEqual(sfu.active('Sbob'), ['hears:Salice', 'publishes']);
});

test('extra keys in a sessionDescription, and a bidirectional publication, are refused (not dropped)', async () => {
  const { room } = await callInProgress();
  const sd = await workerPull(room, { id: 'bob', sessionId: 'Sbob', tracks: carolTrack, extra: { sessionDescription: { type: 'offer', sdp: 'v=0', Type: 'answer' } } });
  assert.equal(sd.response.status, 400);
  assert.deepEqual(sd.dispatched, []);
  const bidi = await workerPull(room, { id: 'bob', sessionId: 'Sbob', tracks: [{ location: 'local', trackName: 'mic', bidirectionalMediaStream: true }] });
  assert.equal(bidi.response.status, 400);
  assert.deepEqual(bidi.dispatched, []);
});
