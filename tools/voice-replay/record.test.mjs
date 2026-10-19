import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign } from 'node:crypto';
import { canonical, hash, DecisionLog, verifyDecisionDocument } from './record.mjs';

const manifest = { schema: 'voice-replay-v1', corpus_sha256: 'a'.repeat(64), config: { partial_ms: 250 } };
const clone = (value) => JSON.parse(JSON.stringify(value));
const log = (overrides = {}) => new DecisionLog({ runId: 'run-1', laneId: 'baseline', manifest, clock: () => 1792378800123, ...overrides });
function document() {
  const record = log();
  record.append('voice_decision', { session_id: 'room-1', input_sha256: 'b'.repeat(64), output_sha256: 'c'.repeat(64), choice: 'keep_listening', confidence_decimal: '0.75', latency_ms: 0 });
  return record.close();
}
// Sign malformed semantics correctly: signature checking alone must not accept these cases.
function resign(original, mutate, fixClosingHash = true) {
  const doc = clone(original);
  mutate(doc);
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  doc.record_public_key = Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url').toString('hex');
  let previous = '0'.repeat(64);
  for (const entry of doc.events) {
    entry.previous_hash = previous;
    if (fixClosingHash && entry.event === 'run_closed') entry.payload.final_hash = previous;
    const body = { ...entry };
    delete body.hash; delete body.signature;
    entry.hash = hash(body);
    entry.signature = sign(null, Buffer.from(entry.hash, 'hex'), privateKey).toString('base64');
    previous = entry.hash;
  }
  return doc;
}

test('canonical matches Python ASCII escaping, integer spelling and Unicode scalar key ordering', () => {
  assert.equal(canonical({ z: 2, a: 'café 🔥\n"\\' }), '{"a":"caf\\u00e9 \\ud83d\\udd25\\n\\"\\\\","z":2}');
  assert.equal(canonical({ '🔥': 2, '\ue000': 1, a: -0 }), '{"a":0,"\\ue000":1,"\\ud83d\\udd25":2}');
  assert.equal(canonical([true, false, null, -3]), '[true,false,null,-3]');
  assert.equal(hash({ b: 1, a: 2 }), hash({ a: 2, b: 1 }));
});
test('canonical rejects noninteger/opaque/cyclic/accessor/sparse JSON without invoking getters', () => {
  let called = false;
  const accessor = { get value() { called = true; return 1; } };
  const cyclic = {}; cyclic.self = cyclic;
  for (const value of [0.5, NaN, Infinity, -Infinity, Number.MAX_SAFE_INTEGER + 1, undefined, 1n, () => 0, Symbol('x'), new Date(), cyclic, accessor, [, 1]]) {
    assert.throws(() => canonical(value), /invalid integer JSON/);
  }
  assert.equal(called, false);
});
test('exact chain, integer UNIX seconds, closure and external expectations verify', () => {
  const doc = document();
  assert.deepEqual(Object.keys(doc).sort(), ['events', 'lane_id', 'record_public_key', 'run_id']);
  assert.equal(doc.events[0].timestamp, 1792378800);
  assert.equal(doc.events[0].previous_hash, '0'.repeat(64));
  assert.equal(doc.events[0].event, 'lane_identity_bound');
  assert.equal(doc.events[0].payload.agent_id, 'run-1:baseline');
  assert.equal(doc.events.at(-1).payload.event_count, 3);
  assert.equal(doc.events.at(-1).payload.final_hash, doc.events.at(-2).hash);
  for (let i = 0; i < doc.events.length; i += 1) {
    assert.equal(doc.events[i].sequence, i);
    assert.equal(Object.keys(doc.events[i]).length, 7);
  }
  const verdict = verifyDecisionDocument(doc, { expectedRunId: 'run-1', expectedLaneId: 'baseline', expectedManifestHash: hash(manifest) });
  assert.equal(verdict.ok, true);
  assert.equal(verdict.identityVerified, false);
  assert.equal(verdict.keyTrust, 'self-supplied-integrity-only');
});
test('inputs are copied, closed result is deeply immutable, and no key is serializable', () => {
  const config = clone(manifest), payload = { choice: 'agent-a', nested: { count: 1 } };
  const record = log({ manifest: config });
  record.append('voice_decision', payload);
  config.config.partial_ms = 1; payload.nested.count = 99;
  const doc = record.close();
  assert.equal(doc.events[0].payload.manifest.config.partial_ms, 250);
  assert.equal(doc.events[1].payload.nested.count, 1);
  assert.throws(() => { doc.events[1].payload.nested.count = 3; }, TypeError);
  assert.throws(() => doc.events.pop(), TypeError);
  assert.equal(JSON.stringify(record), '{}');
  assert.deepEqual(Object.getOwnPropertyNames(record), []);
  assert.equal(record.privateKey, undefined);
});
test('changed payload/hash/signature/key and reordered or truncated records fail', () => {
  const edits = [
    (d) => { d.events[1].payload.choice = 'agent-b'; },
    (d) => { d.events[1].hash = '0'.repeat(64); },
    (d) => { d.events[1].signature = 'A'.repeat(86) + '=='; },
    (d) => { d.record_public_key = '1'.repeat(64); },
    (d) => { [d.events[0], d.events[1]] = [d.events[1], d.events[0]]; },
    (d) => { d.events.pop(); }, (d) => { d.events.splice(1, 1); },
  ];
  for (const edit of edits) { const changed = clone(document()); edit(changed); assert.equal(verifyDecisionDocument(changed).ok, false); }
});
test('well-signed wrong sequence, early closure and duplicate identity still fail', () => {
  for (const mutate of [
    (d) => { d.events[1].sequence = 7; }, (d) => { d.events[1].event = 'run_closed'; },
    (d) => { d.events[1].event = 'lane_identity_bound'; },
  ]) assert.equal(verifyDecisionDocument(resign(document(), mutate)).ok, false);
});
test('well-signed incorrect closure count or final hash is rejected', () => {
  const count = resign(document(), (d) => { d.events.at(-1).payload.event_count = 99; });
  const final = resign(document(), (d) => { d.events.at(-1).payload.final_hash = 'f'.repeat(64); }, false);
  assert.equal(verifyDecisionDocument(count).reason, 'invalid_closure');
  assert.equal(verifyDecisionDocument(final).reason, 'invalid_closure');
});
test('outer swaps and well-signed run/lane/agent identity swaps fail', () => {
  for (const [key, value] of [['run_id', 'other-run'], ['lane_id', 'typed']]) {
    const changed = clone(document()); changed[key] = value;
    assert.equal(verifyDecisionDocument(changed).ok, false);
    assert.equal(verifyDecisionDocument(resign(document(), (d) => { d.events[0].payload[key] = value; })).reason, 'invalid_identity');
  }
  assert.equal(verifyDecisionDocument(resign(document(), (d) => { d.events[0].payload.agent_id = 'other-agent'; })).reason, 'invalid_identity');
  assert.equal(verifyDecisionDocument(document(), { expectedRunId: 'other-run' }).ok, false);
  assert.equal(verifyDecisionDocument(document(), { expectedLaneId: 'typed' }).ok, false);
});
test('manifest is hash-bound and external expectation rejects another valid self-signed manifest', () => {
  const changed = resign(document(), (d) => { d.events[0].payload.manifest.config.partial_ms = 1; });
  assert.equal(verifyDecisionDocument(changed).reason, 'invalid_manifest');
  const other = log({ manifest: { schema: 'different-config' } }).close();
  assert.equal(verifyDecisionDocument(other).ok, true);
  assert.equal(verifyDecisionDocument(other, { expectedManifestHash: hash(manifest) }).ok, false);
});
test('extra fields and malformed public key/base64 fail', () => {
  for (const mutate of [
    (d) => { d.extra = true; }, (d) => { d.events[1].extra = true; },
    (d) => { d.events[0].payload.extra = true; }, (d) => { d.events.at(-1).payload.extra = true; },
    (d) => { d.record_public_key = d.record_public_key.toUpperCase(); }, (d) => { d.record_public_key = 'bad'; },
    (d) => { d.events[1].signature = d.events[1].signature.slice(0, -2); },
  ]) { const changed = clone(document()); mutate(changed); assert.equal(verifyDecisionDocument(changed).ok, false); }
  assert.equal(verifyDecisionDocument(resign(document(), (d) => { d.events[0].payload.extra = true; })).reason, 'invalid_identity');
});
test('sensitive fields/recognized secrets are rejected without reflecting values', () => {
  const record = log();
  for (const payload of [
    { raw_prompt: 'synthetic prompt' }, { authorization: 'synthetic' }, { apiKey: 'synthetic' },
    { nested: { password: 'synthetic' } }, { key: 'synthetic' }, { note: 'Bearer synthetic-value' },
    { note: 'sk-syntheticnotreal123456' },
  ]) assert.throws(() => record.append('voice_decision', payload), /forbidden record payload/);
  assert.throws(() => log({ manifest: { secret: 'synthetic' } }), /forbidden record payload/);
  const verdict = verifyDecisionDocument(resign(document(), (d) => { d.events[1].payload.note = 'sk-syntheticnotreal123456'; }));
  assert.equal(verdict.ok, false);
  assert.doesNotMatch(verdict.reason, /sk-|synthetic/);
  assert.equal(record.close().events.length, 2);
});
test('only exact usage token fields accept nonnegative integers or null', () => {
  const record = log();
  record.append('usage_observed', { usage: { input_tokens: 0, output_tokens: null } });
  for (const value of [-1, 0.5, '3', true, {}, []]) assert.throws(() => record.append('usage_observed', { usage: { input_tokens: value } }));
  assert.throws(() => record.append('usage_observed', { total_tokens: 3 }), /forbidden/);
  assert.equal(verifyDecisionDocument(record.close()).ok, true);
});
test('reserved entries/closed append fail; close is idempotent without another signature', () => {
  const record = log();
  for (const event of ['run_closed', 'lane_identity_bound', '', 'not a code']) assert.throws(() => record.append(event, {}));
  const doc = record.close();
  assert.equal(record.close(), doc);
  assert.throws(() => record.append('voice_decision', {}), /closed/);
  assert.equal(doc.events.length, 2);
});
test('floats/nonfinite, invalid clocks and malformed documents fail closed', () => {
  for (const value of [0.3, Infinity, NaN]) {
    assert.throws(() => log().append('voice_decision', { value }), /invalid integer JSON/);
    const doc = clone(document()); doc.events[1].payload.value = value;
    assert.equal(verifyDecisionDocument(doc).ok, false);
  }
  for (const clock of [() => NaN, () => Infinity, () => '123']) assert.throws(() => log({ clock }), /invalid record clock/);
  for (const doc of [null, [], {}, { events: [] }]) assert.equal(verifyDecisionDocument(doc).ok, false);
});
