import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { createTypeSafeJevAssessor } from '../src/jev-assessor.mjs';
import { createAssessedReasoningBackend } from '../src/assessed-reasoning.mjs';
import { signBundle } from '../src/bundle.mjs';

const ctx = {
  evidence: [
    { id: 'e1', sequence: 10, agentId: 'a', snippet: 'deploy succeeded at 10:00' },
    { id: 'e2', sequence: 11, agentId: 'b', snippet: 'all tests passed' },
  ],
};
const candidate = [
  { text: 'The deploy succeeded.', evidenceIds: ['e1'] },
  { text: 'All tests passed.', evidenceIds: ['e2'] },
];

function stubFetch(nouls, { ok = true, status = 200, capture } = {}) {
  return async (url, opts) => {
    if (capture) { capture.url = url; capture.opts = opts; capture.body = JSON.parse(opts.body); }
    const answers = {};
    for (const k of Object.keys(nouls)) answers[k] = { type: 'noul', noul: nouls[k] };
    return { ok, status, json: async () => ({ model: 'jev-1.13.0', answers, usage: { input_tokens: 1, output_tokens: 1 } }) };
  };
}

test('maps noul -> supported/unsupported; echoes hashes; one verdict per segment', async () => {
  const assess = createTypeSafeJevAssessor({ apiKey: 'k', fetchImpl: stubFetch({ seg0: 0.95, seg1: 0.1 }) });
  const r = await assess({ context: ctx, candidate, contextHash: 'CH', candidateHash: 'DH' });
  assert.equal(r.contextHash, 'CH');
  assert.equal(r.candidateHash, 'DH');
  assert.equal(r.verdicts.length, 2);
  assert.deepEqual(r.verdicts[0], { index: 0, support: 'supported', supportScore: 0.95 });
  assert.deepEqual(r.verdicts[1], { index: 1, support: 'unsupported', supportScore: 0.1 });
});

test('mid-probability -> inconclusive (never rewritten to 1.0)', async () => {
  const assess = createTypeSafeJevAssessor({ apiKey: 'k', fetchImpl: stubFetch({ seg0: 0.5, seg1: 0.5 }) });
  const r = await assess({ context: ctx, candidate, contextHash: 'C', candidateHash: 'D' });
  assert.equal(r.verdicts[0].support, 'inconclusive');
  assert.equal(r.verdicts[0].supportScore, 0.5);
});

test('request is well-formed: endpoint, Bearer, PINNED model, one noul per segment, bounded state', async () => {
  const cap = {};
  const assess = createTypeSafeJevAssessor({ apiKey: 'secret', fetchImpl: stubFetch({ seg0: 0.9, seg1: 0.9 }, { capture: cap }) });
  await assess({ context: ctx, candidate, contextHash: 'C', candidateHash: 'D' });
  assert.equal(cap.url, 'https://api.typesafe.ai/v1/systemone');
  assert.equal(cap.opts.headers.authorization, 'Bearer secret');
  assert.equal(cap.opts.headers['content-type'], 'application/json');
  assert.equal(cap.body.model, 'jev-1.13.0'); // pinned, never jev-latest
  assert.equal(Object.keys(cap.body.questions).length, 2);
  assert.equal(cap.body.questions.seg0.type, 'noul');
  assert.equal(cap.body.state.statements.length, 2);
  assert.equal(cap.body.state.evidence.length, 2);
  assert.deepEqual(cap.body.questions.seg0.instructions.citedEvidenceIds, ['e1']);
});

test('fail-closed: no API key -> throws (seam will mark unavailable)', async () => {
  const assess = createTypeSafeJevAssessor({ apiKey: '', fetchImpl: stubFetch({}) });
  await assert.rejects(() => assess({ context: ctx, candidate, contextHash: 'C', candidateHash: 'D' }), /missing-typesafe-api-key/);
});

test('HTTP error -> throws jev-http-<status> (seam marks unavailable, returns no prose)', async () => {
  const assess = createTypeSafeJevAssessor({ apiKey: 'k', fetchImpl: stubFetch({}, { ok: false, status: 503 }) });
  await assert.rejects(() => assess({ context: ctx, candidate, contextHash: 'C', candidateHash: 'D' }), /jev-http-503/);
});

test('missing answer for a required segment -> inconclusive at 0 (seam rejects)', async () => {
  const assess = createTypeSafeJevAssessor({ apiKey: 'k', fetchImpl: stubFetch({ seg0: 0.95 }) }); // seg1 unanswered
  const r = await assess({ context: ctx, candidate, contextHash: 'C', candidateHash: 'D' });
  assert.equal(r.verdicts[0].support, 'supported');
  assert.deepEqual(r.verdicts[1], { index: 1, support: 'inconclusive', supportScore: 0 });
});

test('honors AbortSignal (passed through to fetch)', async () => {
  const cap = {};
  const assess = createTypeSafeJevAssessor({ apiKey: 'k', fetchImpl: stubFetch({ seg0: 0.9, seg1: 0.9 }, { capture: cap }) });
  const ac = new AbortController();
  await assess({ context: ctx, candidate, contextHash: 'C', candidateHash: 'D', signal: ac.signal });
  assert.equal(cap.opts.signal, ac.signal);
});

// --- End-to-end: the live-shaped adapter plugged into the real assessed-reasoning seam ---
const key = generateKeyPairSync('ed25519').privateKey;
const signed = (over = {}) => signBundle({
  sessionId: 'sid-a', checkpointId: 'cp-1', contractsVersion: '0.1.8', sequenceStart: 1, sequenceEnd: 2,
  createdAt: '2026-10-12T12:00:00Z', signingKeyId: 'fixture-key',
  summary: { checkpointId: 'cp-1', headline: 'Source reports', perAgent: [], risks: [], blockers: [] },
  evidence: [
    { id: 'ev-1', sequence: 1, snippet: 'Agent reports PR opened; deployment is blocked.' },
    { id: 'ev-2', sequence: 2, snippet: 'Owner approval is still required.' },
  ].map((e) => ({ ...e, sessionId: 'sid-a', agentId: 'agent-1', ts: '2026-10-12T12:00:00Z' })),
  ...over,
}, key);
const e2eInput = { bundle: signed(), question: 'What needs my approval?', groundedEvidenceIds: ['ev-1', 'ev-2'] };
const groundedBrief = async () => ({ segments: [{ text: 'Owner approval is still required.', evidenceIds: ['ev-2'] }] });

test('E2E: a grounded brief + high noul from the live-shaped adapter is accepted (evaluated)', async () => {
  const backend = createAssessedReasoningBackend({
    brief: groundedBrief,
    assess: createTypeSafeJevAssessor({ apiKey: 'k', fetchImpl: stubFetch({ seg0: 0.95 }) }),
    requiredEvidenceFor: () => ['ev-2'],
  });
  const r = await backend.brief(e2eInput);
  assert.equal(r.assessment.status, 'evaluated');
  assert.equal(r.segments.length, 1);
  assert.equal(r.segments[0].text, 'Owner approval is still required.');
  assert.equal(r.assessment.coverage.requiredCovered, 1);
});

test('E2E: a low noul from the adapter makes the seam reject the brief (no prose returned)', async () => {
  const backend = createAssessedReasoningBackend({
    brief: groundedBrief,
    assess: createTypeSafeJevAssessor({ apiKey: 'k', fetchImpl: stubFetch({ seg0: 0.1 }) }),
  });
  const r = await backend.brief(e2eInput);
  assert.deepEqual(r.segments, []);
  assert.equal(r.assessment.status, 'inconclusive');
  assert.equal(r.assessment.reason, 'support-not-established');
});
