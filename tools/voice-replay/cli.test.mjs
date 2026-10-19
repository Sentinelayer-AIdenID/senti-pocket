import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createTypeSafeRouter } from './typesafe.mjs';
import { replay } from './replay.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(directory, 'local', 'tests-' + randomUUID());
fs.mkdirSync(root, { recursive: true });
const run = (args, extraEnv = {}) => spawnSync(process.execPath, [path.join(directory, 'cli.mjs'), ...args],
  { encoding: 'utf8', timeout: 10000, env: { ...process.env, TYPESAFE_API_KEY: '', ...extraEnv } });
const fixture = JSON.parse(fs.readFileSync(path.join(directory, 'synthetic.json')));

test('CLI synthetic report and records are usable without any provider credential', () => {
  const out = path.join(root, 'synthetic'), result = run(['--out', out]);
  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.equal(report.mode, 'synthetic'); assert.equal(report.provider_calls, 0);
  assert.equal(report.evidence.ticket_complete, false);
  const { stable_pick_with_latency_ms_total: baselineLatency, ...baseline } = report.partitions.development.baseline;
  const { stable_pick_with_latency_ms_total: signalLatency, ...signal } = report.partitions.development.signal;
  assert.deepEqual(baseline, signal, 'deterministic fixture intentionally mirrors baseline choices');
  assert.ok(signalLatency >= baselineLatency, 'measured local router overhead remains distinct from baseline');
  for (const file of ['report.json', 'last-named-record.json', 'signal-record.json']) assert.ok(fs.existsSync(path.join(out, file)));
  assert.ok(!result.stdout.includes(fixture.sessions[0].turns[0].text));
  assert.equal(run(['--out', out]).status, 1, 'must not overwrite a run directory');
});
test('live preparation freezes corpus/split/config without a key or provider call; drift fails closed', () => {
  const frozen = path.join(root, 'freeze.json');
  const prepared = run(['--live', '--prepare', '--freeze', frozen, '--split', 'holdout']);
  assert.equal(prepared.status, 0, prepared.stderr); assert.equal(JSON.parse(prepared.stdout).provider_calls, 0);
  const modified = run(['--live', '--freeze', frozen, '--split', 'holdout', '--confidence-ppm', '700000', '--out', path.join(root, 'drift')]);
  assert.equal(modified.status, 1); assert.ok(!fs.existsSync(path.join(root, 'drift')));
  assert.equal(run(['--live', '--freeze', frozen, '--split', 'holdout']).status, 1, 'no key fails before dispatch');
});
test('recorded datasets require their actual source file hash before running', () => {
  const data = structuredClone(fixture); data.sessions[0].source_kind = 'recorded';
  const input = path.join(root, 'recorded.private.json'); fs.writeFileSync(input, JSON.stringify(data));
  assert.equal(run(['--input', input, '--out', path.join(root, 'unverified')]).status, 1);
  assert.ok(!fs.existsSync(path.join(root, 'unverified')));
});
test('holdout freeze is single-use before any dispatch, including a zero-call run', () => {
  const frozen = path.join(root, 'holdout-once.json');
  const args = ['--live', '--freeze', frozen, '--split', 'holdout', '--max-calls', '0'];
  assert.equal(run([...args, '--prepare']).status, 0);
  const first = run([...args, '--out', path.join(root, 'holdout-first')], { TYPESAFE_API_KEY: 'inert-no-dispatch' });
  assert.equal(first.status, 0, first.stderr); assert.equal(JSON.parse(first.stdout).provider_calls, 0);
  const result = JSON.parse(first.stdout), freeze = JSON.parse(fs.readFileSync(frozen));
  assert.equal(result.evaluation_binding.full_corpus_hash, freeze.corpus_hash);
  assert.equal(result.evidence.freeze_artifact_bound, true);
  const record = JSON.parse(fs.readFileSync(path.join(root, 'holdout-first', 'signal-record.json')));
  assert.deepEqual(record.events[0].payload.manifest.evaluation_binding, result.evaluation_binding);
  assert.ok(fs.existsSync(frozen + '.consumed'));
  assert.equal(run([...args, '--out', path.join(root, 'holdout-reuse')], { TYPESAFE_API_KEY: 'inert-no-dispatch' }).status, 1);
});
test('bounded typed adapter integrates with the signed replay and accurate dispatch count', async () => {
  let wireCalls = 0;
  const router = createTypeSafeRouter({ apiKey: 'inert-test-credential', fetchImpl: async (_url, request) => {
    wireCalls++;
    const body = JSON.parse(request.body), ids = Object.keys(body.questions.route.criteria), choice = 'cedar';
    return new Response(JSON.stringify({ model: body.model, answers: { route: { type: 'choice', choice, confidence: 1,
      probabilities: Object.fromEntries(ids.map((id) => [id, Number(id === choice)])) } }, usage: { input_tokens: 11, output_tokens: 0 } }));
  } });
  const result = await replay({ ...fixture, sessions: fixture.sessions.slice(0, 1) }, { router,
    config: { mode: 'typesafe-live', charsPerPartial: 8000, maxCalls: 1 } });
  assert.equal(wireCalls, 1); assert.equal(result.report.provider_calls, 1);
  assert.equal(result.report.dispatch_count_complete, true); assert.equal(result.report.usage.known_input_tokens, 11);
  assert.ok(!JSON.stringify(result).includes('inert-test-credential'));
});
test('outer timeout preserves dispatch count even when the adapter result has not returned', async () => {
  let count = 0;
  const router = () => { count++; return new Promise(() => {}); };
  router.getDispatchCount = () => count;
  const result = await replay({ ...fixture, sessions: fixture.sessions.slice(0, 1) }, { router,
    config: { mode: 'typesafe-live', charsPerPartial: 8000, maxCalls: 1, deadlineMs: 10 } });
  assert.equal(result.report.provider_calls, 1); assert.equal(result.report.usage.input_tokens, null);
});
