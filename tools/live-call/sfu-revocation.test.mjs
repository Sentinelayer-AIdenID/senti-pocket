import test from 'node:test';
import assert from 'node:assert/strict';
import { staleMids, revokeSession, trackKey } from './sfu-revocation.mjs';

const remote = (mid, sessionId, trackName = 'mic', status = 'active') => ({ location: 'remote', mid, sessionId, trackName, status });
const local = (mid, trackName = 'mic', status = 'active') => ({ location: 'local', mid, trackName, status });
const mids = (r) => r.targets.map((t) => t.mid);

test('a live participant loses only the pulls the floor no longer permits; its own publication stays', () => {
  const tracks = [local('0'), remote('1', 'SA'), remote('2', 'SC'), remote('3', 'SD', 'mic', 'inactive')];
  const r = staleMids({ departed: false, tracks, permitted: [{ sessionId: 'SA', trackName: 'mic' }] });
  // An inactive stale pull is still closed: CF's "inactive" also means "unavailable", which can resume.
  assert.deepEqual(mids(r), ['2', '3']);
  assert.equal(r.unclosable, 0);
});

test('a track already confirmed closed is not closed again, keyed by track identity rather than mid alone', () => {
  const tracks = [remote('2', 'SC', 'mic', 'inactive'), remote('2', 'SD')]; // mid 2 reused for a new stale pull
  const r = staleMids({ departed: false, tracks, permitted: [], closed: [trackKey(tracks[0])] });
  assert.deepEqual(r.targets, [{ mid: '2', key: trackKey(tracks[1]) }]);
});

test('permission is the exact (session, track) pair, not the session alone', () => {
  assert.deepEqual(mids(staleMids({ departed: false, tracks: [remote('1', 'SA', 'screen')], permitted: [{ sessionId: 'SA', trackName: 'mic' }] })), ['1']);
});

test('a departed participant has every track closed, local and remote, whatever its listed status', () => {
  const r = staleMids({ departed: true, tracks: [local('0'), remote('1', 'SA'), remote('2', 'SC', 'mic', 'inactive')], permitted: [{ sessionId: 'SA', trackName: 'mic' }] });
  assert.deepEqual(mids(r), ['0', '1', '2']);
});

test('a stale track without a mid is reported, never silently treated as closed', () => {
  const r = staleMids({ departed: false, tracks: [{ location: 'remote', sessionId: 'SC', trackName: 'mic', status: 'active' }], permitted: [] });
  assert.deepEqual(r.targets, []);
  assert.equal(r.unclosable, 1);
});

function sfuWith(tracks, closeResult) {
  const calls = [];
  return {
    calls,
    async getSession(id) { calls.push(['get', id]); return { tracks }; },
    async closeTracks(id, body) { calls.push(['close', id, body]); return closeResult(body); },
  };
}

test('the decision uses the floor as it is after the SFU read, not when the pass started', async () => {
  let permitted = [{ sessionId: 'SC', trackName: 'mic' }];
  const pull = remote('2', 'SC');
  const sfu = sfuWith([pull], (body) => ({ tracks: body.tracks.map(({ mid }) => ({ mid })) }));
  const read = sfu.getSession;
  sfu.getSession = async (id) => { const state = await read(id); permitted = []; return state; }; // floor moves mid-read
  const res = await revokeSession(sfu, 'SB', { departed: false, permittedFor: () => permitted });
  assert.deepEqual(res.closed, [trackKey(pull)]);
  assert.deepEqual(sfu.calls[1], ['close', 'SB', { tracks: [{ mid: '2' }], force: true }]); // forced: no SDP exchange
});

test('"already closed" counts as closed; a backend error or a missing per-track result does not', async () => {
  const tracks = [remote('1', 'SA'), remote('2', 'SC'), remote('3', 'SD')];
  const sfu = sfuWith(tracks, () => ({ tracks: [{ mid: '1', errorCode: 'close_track_error' }, { mid: '2', errorCode: 'internal_error' }] }));
  const res = await revokeSession(sfu, 'SB', { departed: false, permittedFor: () => [] });
  assert.equal(res.ok, false);
  assert.deepEqual(res.closed, [trackKey(tracks[0])]); // mid 3 had no result: not assumed closed
});

test('a departed session is drained only when everything on it is confirmed closed; a failed close keeps it', async () => {
  const tracks = [local('0'), remote('1', 'SA', 'mic', 'inactive')];
  const failing = sfuWith(tracks, () => ({ tracks: [{ mid: '0' }, { mid: '1', errorCode: 'internal_error' }] }));
  const first = await revokeSession(failing, 'SB', { departed: true, permittedFor: () => [] });
  assert.equal(first.drained, false);
  const quiet = sfuWith(tracks, () => assert.fail('nothing left to close'));
  const second = await revokeSession(quiet, 'SB', { departed: true, permittedFor: () => [], closed: tracks.map(trackKey) });
  assert.deepEqual(second, { ok: true, closed: [], drained: true });
});

test('an SFU read error is a retry; a session the SFU no longer knows (404) is drained', async () => {
  const erroring = { async getSession() { return { errorCode: 'internal_error' }; }, async closeTracks() { throw new Error('unreachable'); } };
  assert.deepEqual(await revokeSession(erroring, 'SB', { departed: true, permittedFor: () => [] }), { ok: false, closed: [], drained: false });
  const throwing = { async getSession() { throw new Error('cf-realtime-503'); } };
  await assert.rejects(revokeSession(throwing, 'SB', { departed: true, permittedFor: () => [] }), /503/);
  const gone = { async getSession() { throw new Error('cf-realtime-404'); } };
  assert.deepEqual(await revokeSession(gone, 'SB', { departed: false, permittedFor: () => [] }), { ok: true, closed: [], drained: true });
});
