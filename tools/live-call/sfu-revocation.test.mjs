import test from 'node:test';
import assert from 'node:assert/strict';
import { staleMids, revokeSession } from './sfu-revocation.mjs';

const remote = (mid, sessionId, trackName = 'mic', status = 'active') => ({ location: 'remote', mid, sessionId, trackName, status });
const local = (mid, trackName = 'mic', status = 'active') => ({ location: 'local', mid, trackName, status });

test('a live participant loses only the pulls the floor no longer permits; its own publication stays', () => {
  const tracks = [local('0'), remote('1', 'SA'), remote('2', 'SC'), remote('3', 'SC', 'mic', 'inactive')];
  const { mids, unclosable } = staleMids({ departed: false, tracks, permitted: [{ sessionId: 'SA', trackName: 'mic' }] });
  assert.deepEqual(mids, ['2']); // SC is not permitted; an already inactive pull is not re-closed; local stays
  assert.equal(unclosable, 0);
});

test('permission is the exact (session, track) pair, not the session alone', () => {
  const { mids } = staleMids({ departed: false, tracks: [remote('1', 'SA', 'screen')], permitted: [{ sessionId: 'SA', trackName: 'mic' }] });
  assert.deepEqual(mids, ['1']);
});

test('a departed participant has every active track closed, local and remote', () => {
  const { mids } = staleMids({ departed: true, tracks: [local('0'), remote('1', 'SA')], permitted: [{ sessionId: 'SA', trackName: 'mic' }] });
  assert.deepEqual(mids, ['0', '1']);
});

test('an active stale track without a mid is reported, never silently treated as closed', () => {
  const { mids, unclosable } = staleMids({ departed: false, tracks: [{ location: 'remote', sessionId: 'SC', trackName: 'mic', status: 'active' }], permitted: [] });
  assert.deepEqual(mids, []);
  assert.equal(unclosable, 1);
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
  const sfu = sfuWith([remote('2', 'SC')], (body) => ({ tracks: body.tracks.map(({ mid }) => ({ mid })) }));
  const read = sfu.getSession;
  sfu.getSession = async (id) => { const state = await read(id); permitted = []; return state; }; // floor moves mid-read
  const res = await revokeSession(sfu, 'SB', { departed: false, permittedFor: () => permitted });
  assert.deepEqual(res.closed, ['2']);
  assert.deepEqual(sfu.calls[1], ['close', 'SB', { tracks: [{ mid: '2' }], force: true }]); // forced: no SDP exchange
});

test('"already closed" counts as closed; a backend error or a missing per-track result does not', async () => {
  const tracks = [remote('1', 'SA'), remote('2', 'SC'), remote('3', 'SD')];
  const sfu = sfuWith(tracks, () => ({ tracks: [{ mid: '1', errorCode: 'close_track_error' }, { mid: '2', errorCode: 'internal_error' }] }));
  const res = await revokeSession(sfu, 'SB', { departed: false, permittedFor: () => [] });
  assert.equal(res.ok, false);
  assert.deepEqual(res.closed, ['1']); // mid 3 had no result: not assumed closed
});

test('an SFU read error is a retry, and a departed session is drained only when nothing active is left', async () => {
  const failing = { async getSession() { return { errorCode: 'internal_error' } ; }, async closeTracks() { throw new Error('unreachable'); } };
  assert.deepEqual(await revokeSession(failing, 'SB', { departed: true, permittedFor: () => [] }), { ok: false, closed: [], drained: false });
  const quiet = sfuWith([local('0', 'mic', 'inactive')], () => assert.fail('nothing to close'));
  assert.deepEqual(await revokeSession(quiet, 'SB', { departed: true, permittedFor: () => [] }), { ok: true, closed: [], drained: true });
});
