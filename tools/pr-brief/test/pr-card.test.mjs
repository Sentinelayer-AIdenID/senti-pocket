import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { buildPrObservation } from '../src/pr-observation.mjs';
import { buildPrCard, CARD_STATES } from '../src/pr-card.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const fx = (n) => JSON.parse(readFileSync(join(here, 'fixtures', `pr-${n}.json`), 'utf8'));
const obs = (n) => buildPrObservation(fx(n), { checkedAt: '2026-10-12T00:00:00Z' });

// Craft a synthetic observation via the real pipeline.
function synthetic({ draft = false, checkRuns = [{ name: 'ci', status: 'completed', conclusion: 'success', app: 'gh' }], reviews = [] } = {}) {
  return buildPrObservation({
    repoId: 'x/y',
    pull: { number: 42, state: 'open', draft, title: 'Do a thing', user: { login: 'dev' }, head: {}, base: {}, html_url: 'https://e/42', additions: 3, deletions: 1, changed_files: 1, commits: 1 },
    commits: [{ sha: 'a', author: { login: 'dev' }, commit: { author: { name: 'Dev' }, message: 'do thing' } }],
    reviews,
    checkRuns,
  });
}

test('#154 merged, no deployment evidence -> Waiting on deployment (merged != available)', () => {
  const c = buildPrCard(obs(154));
  assert.equal(c.state, CARD_STATES.DEPLOY);
  assert.equal(c.responsibleOwner, 'deployment');
  assert.equal(c.nextAction.button, 'Open PR');
  assert.equal(c.whoWorkedOnIt.author, 'mrrCarter');
  assert.equal(c.measures.sourceCoverage.deploymentEvidence, 'unknown');
});

test('#154 merged + deployment proven -> Available', () => {
  const c = buildPrCard(obs(154), { deployment: { deployed: true } });
  assert.equal(c.state, CARD_STATES.AVAILABLE);
  assert.equal(c.responsibleOwner, null);
});

test('#158 draft -> Waiting on implementation, owner = author', () => {
  const c = buildPrCard(obs(158));
  assert.equal(c.state, CARD_STATES.IMPL);
  assert.equal(c.responsibleOwner, 'mrrCarter');
});

test('open + green + no approval -> Waiting on review, button = Review on GitHub', () => {
  const c = buildPrCard(synthetic());
  assert.equal(c.state, CARD_STATES.REVIEW);
  assert.equal(c.nextAction.button, 'Review on GitHub');
});

test('open + green + approved -> Needs you; next action does NOT imply a merge happened', () => {
  const c = buildPrCard(synthetic({ reviews: [{ user: { login: 'rev' }, state: 'APPROVED', submitted_at: '2026-01-01' }] }));
  assert.equal(c.state, CARD_STATES.NEEDS_YOU);
  assert.equal(c.responsibleOwner, 'the session owner');
  assert.match(c.nextAction.text, /does not merge it for you/);
  assert.equal(c.nextAction.button, 'Open PR'); // never a "Merge" button
});

test('open + failing checks -> Waiting on implementation', () => {
  const c = buildPrCard(synthetic({ checkRuns: [{ name: 'ci', status: 'completed', conclusion: 'failure', app: 'gh' }] }));
  assert.equal(c.state, CARD_STATES.IMPL);
});

test('two measures stay DISTINCT — never one blended percentage', () => {
  const c = buildPrCard(obs(154));
  assert.ok(c.measures.verifiedAcceptance, 'has verified-acceptance measure');
  assert.ok(c.measures.sourceCoverage, 'has source-coverage measure');
  const flat = JSON.stringify(c.measures);
  assert.doesNotMatch(flat, /"(percent|pct|readinessScore|completeness)"/i, 'no single blended readiness %');
});

test('shared-account reviews surface the independence note on the card', () => {
  const c = buildPrCard(synthetic({ reviews: [
    { user: { login: 'bot' }, state: 'APPROVED', submitted_at: '2026-01-01' },
    { user: { login: 'bot' }, state: 'APPROVED', submitted_at: '2026-01-02' },
  ] }));
  assert.match(c.whoWorkedOnIt.independenceNote, /not independent verification/i);
});

test('unavailable observation -> card passthrough, no fabricated state', () => {
  const c = buildPrCard({ available: false, reason: 'source-error' });
  assert.equal(c.available, false);
  assert.equal(c.state, undefined);
});

test('button text is ALWAYS Open PR or Review on GitHub (never implies a merge) across states', () => {
  const cards = [
    buildPrCard(obs(154)),
    buildPrCard(obs(158)),
    buildPrCard(synthetic()),
    buildPrCard(synthetic({ reviews: [{ user: { login: 'r' }, state: 'APPROVED', submitted_at: '2026-01-01' }] })),
  ];
  for (const c of cards) assert.ok(['Open PR', 'Review on GitHub'].includes(c.nextAction.button), `button=${c.nextAction.button}`);
});
