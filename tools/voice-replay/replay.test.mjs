import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { validateDataset, partials, lastNamed, routerInput } from './dataset.mjs';
import { replay } from './replay.mjs';
import { hash, verifyDecisionDocument } from './record.mjs';

const fixture = JSON.parse(fs.readFileSync(new URL('./synthetic.json', import.meta.url)));
function small() {
  const data = structuredClone(fixture); data.sessions = data.sessions.slice(0, 1);
  data.sessions[0].turns = [{ id: 'turn_one', source_key: 'dev:question', start_us: 100,
    text: 'Cedar, next.', context: [{ actor_id: 'atlas', text: 'Earlier context.', source_key: 'dev:prior', utc_us: 50 }],
    label: { target: 'cedar', basis: 'observed_first_reply', reply_source_key: 'dev:future_reply' } }];
  return data;
}
const answer = (choice, criteria, more = {}) => ({ ok: true, dispatched: false, model: 'jev-1.13.0', choice,
  effectiveConfidence: 1, probabilities: Object.fromEntries(Object.keys(criteria).map((id) => [id, Number(id === choice)])),
  usage: { input_tokens: 10, output_tokens: 0 }, ...more });
const options = { runId: 'test-run', recordClock: () => 1700000000000, config: { charsPerPartial: 8000 } };

test('prefix schedule preserves Unicode and includes the complete prefix once', () => {
  assert.deepEqual(partials('a😀bc', { charsPerPartial: 2, partialMs: 250 }), [
    { prefix: 'a😀', offset_ms: 250, final: false }, { prefix: 'a😀bc', offset_ms: 500, final: true },
  ]);
});
test('last named control uses exact boundaries and latest mention', () => {
  const agents = fixture.sessions[0].agents;
  assert.equal(lastNamed('Atlas asked Cedar. Rue, next.', agents), 'rue');
  assert.equal(lastNamed('Ced', agents), 'keep_listening');
  assert.equal(lastNamed('Atlassonian and cedarwood', agents), 'keep_listening');
  assert.equal(lastNamed('@CEDAR: next?', agents), 'cedar');
});
test('reject future context, reply leakage, alias ambiguity, duplicated holdout and source reuse', () => {
  for (const mutate of [
    (d) => { d.sessions[0].turns[0].context[0].utc_us = 100; },
    (d) => { d.sessions[0].turns[0].context[0].source_key = 'dev:future_reply'; },
    (d) => { d.sessions[0].agents[1].aliases.push('ATLAS'); },
    (d) => { delete d.sessions[0].session_id; },
    (d) => { delete d.sessions[0].agents[0].id; },
    (d) => { const s = structuredClone(d.sessions[0]); s.session_id = 'other'; s.split = 'holdout';
      s.source_sha256 = 'f'.repeat(64); s.turns[0].source_key = 'other:ask'; d.sessions.push(s); },
    (d) => { const s = structuredClone(d.sessions[0]); s.session_id = 'other'; d.sessions.push(s); },
  ]) { const data = small(); mutate(data); assert.throws(() => validateDataset(data), /invalid_dataset/); }
});
test('router state contains only current prefix, past context and available agents', async () => {
  const data = small(), seen = [];
  const result = await replay(data, { ...options, config: { charsPerPartial: 5 }, router: async (input) => {
    seen.push(structuredClone(input)); return answer('cedar', input.criteria);
  } });
  assert.equal(seen.length, 3);
  assert.equal(seen[0].state.partial_text, 'Cedar');
  assert.ok(!JSON.stringify(seen).includes('future_reply'));
  assert.ok(!JSON.stringify(seen[0]).includes('Cedar, next.'));
  assert.deepEqual(Object.keys(seen[0].state).sort(), ['available_agents', 'partial_text', 'prior_context']);
  assert.equal(result.report.evidence.ticket_complete, false);
  assert.equal(result.report.evidence.synthetic_only, true);
  assert.deepEqual(routerInput(data.sessions[0], data.sessions[0].turns[0], 'X').state.prior_context,
    [{ actor_id: 'atlas', content: 'Earlier context.' }]);
});
test('every result has a baseline, signed decisions bind config and records contain no transcript', async () => {
  const result = await replay(small(), { ...options, router: async ({ criteria }) => answer('cedar', criteria) });
  const report = result.report;
  assert.equal(report.partitions.development.baseline.correct_final, 1);
  assert.equal(report.partitions.development.signal.correct_final, 1);
  assert.equal(report.sessions[0].baseline.turns, report.sessions[0].signal.turns);
  const serialized = JSON.stringify(result);
  assert.ok(!serialized.includes('Cedar, next.')); assert.ok(!serialized.includes('Earlier context.'));
  assert.ok(!serialized.includes('dev:future_reply'));
  for (const [lane, record] of Object.entries(result.records)) {
    assert.equal(verifyDecisionDocument(record, { expectedRunId: 'test-run', expectedManifestHash: report.manifest_hash,
      expectedLaneId: lane === 'baseline' ? 'last_named' : 'signal' }).ok, true);
    assert.equal(record.events.filter((e) => e.event === 'routing_decision').length, 1);
    assert.equal(record.events.find((e) => e.event === 'evaluation_summary').payload.report_hash, hash(report));
    const changed = structuredClone(record); changed.events[1].payload.choice = 'atlas';
    assert.equal(verifyDecisionDocument(changed).ok, false);
    assert.equal(verifyDecisionDocument(record, { expectedManifestHash: 'a'.repeat(64) }).ok, false);
  }
});
test('invalid, unavailable, tie and low confidence routes fall back to baseline', async () => {
  const cases = [
    async () => { throw new Error('private-server-detail'); },
    async () => ({ ok: false }),
    async ({ criteria }) => answer('poison', criteria),
    async ({ criteria }) => answer('atlas', criteria, { effectiveConfidence: 0.2 }),
    async ({ criteria }) => answer('atlas', criteria, { probabilities: { ...Object.fromEntries(Object.keys(criteria).map((k) => [k, 0])), atlas: 0.5, cedar: 0.5 } }),
    async ({ criteria }) => answer('atlas', criteria, { model: 'jev-latest' }),
  ];
  for (const router of cases) {
    const result = await replay(small(), { ...options, router });
    const choice = result.records.signal.events.find((e) => e.event === 'routing_decision');
    assert.equal(choice.payload.choice, 'cedar'); assert.notEqual(choice.payload.reason, 'typed_choice');
    assert.ok(!JSON.stringify(result).includes('private-server-detail'));
  }
});
test('call cap prevents further invocations and reports unknown usage separately', async () => {
  let attempts = 0;
  const result = await replay(small(), { ...options, config: { charsPerPartial: 2, maxCalls: 1 }, router: async ({ criteria }) => {
    attempts++; return answer('atlas', criteria, { usage: null });
  } });
  assert.equal(attempts, 1); assert.equal(result.report.router_attempts, 1);
  assert.equal(result.report.reasons.call_cap, 5); assert.equal(result.report.usage.unknown_responses, 1);
  assert.equal(result.report.usage.input_tokens, null);
});
test('slow result and never-settling router cannot act beyond the deadline', async () => {
  for (const router of [() => new Promise(() => {}), async ({ criteria }) => {
    await new Promise((resolve) => setTimeout(resolve, 30)); return answer('atlas', criteria);
  }]) {
    const result = await replay(small(), { ...options, config: { charsPerPartial: 8000, deadlineMs: 10 }, router });
    const decision = result.records.signal.events.find((e) => e.event === 'routing_decision');
    assert.equal(decision.payload.choice, 'cedar'); assert.equal(decision.payload.reason, 'deadline');
  }
});
test('time-to-pick uses the earliest stable correct suffix, including wrong early activation', async () => {
  let index = 0;
  const result = await replay(small(), { ...options, config: { charsPerPartial: 3 }, clock: () => 1,
    router: async ({ criteria }) => answer(['cedar', 'atlas', 'cedar', 'cedar'][index++], criteria) });
  const score = result.report.partitions.development.signal;
  assert.equal(score.correct_final, 1); assert.equal(score.wrong_activations, 1);
  assert.equal(score.flips, 2); assert.equal(score.stable_correct_picks, 1);
  assert.equal(score.stable_pick_offset_ms_total, 750);
});
