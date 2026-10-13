import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { buildPrObservation } from '../src/pr-observation.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const fx = (n) => JSON.parse(readFileSync(join(here, 'fixtures', `pr-${n}.json`), 'utf8'));

const HEAD = 'HEADSHA1111111111111111111111111111111111';
function synth({ reviews = [], commits = [], checkRuns = [], user = { login: 'dev' } } = {}) {
  return buildPrObservation({
    repoId: 'x/y',
    pull: { number: 7, state: 'open', title: 'T', user, head: { sha: HEAD }, base: {}, changed_files: 1, commits: commits.length || 1 },
    reviews, commits, checkRuns,
  });
}
const review = (login, { state = 'APPROVED', commit = HEAD, at = '2026-01-01' } = {}) => ({ user: { login }, state, submitted_at: at, commit_id: commit });

test('#154 merged -> typed id, merged facts, author, checks', () => {
  const o = buildPrObservation(fx(154), { checkedAt: '2026-10-12T00:00:00Z' });
  assert.equal(o.available, true);
  assert.equal(o.id, 'github:mrrCarter/senti-pocket:pr:154');
  assert.equal(o.merged, true);
  assert.equal(o.author.login, 'mrrCarter');
  assert.ok(o.checks.total >= 1);
});

test('#158 draft -> draft true, not merged, open', () => {
  const o = buildPrObservation(fx(158));
  assert.equal(o.draft, true);
  assert.equal(o.merged, false);
  assert.equal(o.state, 'open');
});

test('missing/errored pull -> unavailable, NO fabricated completion', () => {
  const miss = buildPrObservation({ repoId: 'x/y', pull: { _error: '404' } });
  assert.equal(miss.available, false);
  assert.equal(miss.reason, 'source-error');
  assert.equal(miss.merged, undefined);
});

test('P1 stale-head: an APPROVED review NOT on the current head is not a current valid approval', () => {
  const o = synth({ reviews: [review('rev', { commit: 'OLDSHA' })] });
  assert.equal(o.approvalCount, 0, 'stale-head approval does not count');
  assert.equal(o.staleApprovals, 1);
  assert.equal(o.reviewIndependence.staleApprovals, 1);
});

test('P1 head approval counts (on current head)', () => {
  const o = synth({ reviews: [review('rev', { commit: HEAD })] });
  assert.equal(o.approvalCount, 1);
  assert.equal(o.staleApprovals, 0);
});

test('P1 self-approval: the PR author approving their own PR is excluded', () => {
  const o = synth({ user: { login: 'dev' }, reviews: [review('dev', { commit: HEAD })] });
  assert.equal(o.approvalCount, 0);
});

test('P1 bot approval excluded', () => {
  const o = synth({ reviews: [review('dependabot[bot]', { commit: HEAD })] });
  assert.equal(o.approvalCount, 0);
});

test('two distinct on-head human approvals are independent (no warning)', () => {
  const o = synth({ reviews: [review('a', { commit: HEAD }), review('b', { commit: HEAD })] });
  assert.equal(o.approvalCount, 2);
  assert.equal(o.reviewIndependence.independentReviewerLogins, 2);
  assert.equal(o.reviewIndependence.sharedAccountWarning, false);
});

test('shared-account: two reviews from one login -> not independent (warning)', () => {
  const o = synth({ reviews: [review('shared', { commit: HEAD, at: '2026-01-01' }), review('shared', { commit: HEAD, at: '2026-01-02' })] });
  assert.equal(o.reviewIndependence.independentReviewerLogins, 1);
  assert.equal(o.reviewIndependence.sharedAccountWarning, true);
  assert.match(o.reviewIndependence.note, /not independent verification/i);
});

test('P1 provenance: a noreply Co-Authored-By commit is surfaced', () => {
  const o = synth({ commits: [
    { author: { login: 'dev' }, commit: { author: { name: 'Dev', email: 'dev@x.com' }, message: 'do thing\n\nCo-Authored-By: Claude <noreply@anthropic.com>' } },
  ] });
  assert.equal(o.provenance.aiCoAuthoredCommits, 1);
  assert.match(o.provenance.note, /AI\/noreply co-authored/i);
});

test('P1 provenance: a noreply AUTHOR email is surfaced', () => {
  const o = synth({ commits: [
    { author: { login: null }, commit: { author: { name: 'bot', email: 'x@users.noreply.github.com' }, message: 'auto' } },
  ] });
  assert.equal(o.provenance.aiCoAuthoredCommits, 1);
});

test('checks: failures detected, pending counted', () => {
  const o = synth({ checkRuns: [
    { name: 'a', status: 'completed', conclusion: 'success' },
    { name: 'b', status: 'completed', conclusion: 'failure' },
    { name: 'c', status: 'in_progress', conclusion: null },
  ] });
  assert.equal(o.checks.total, 3);
  assert.equal(o.checks.hasFailures, true);
  assert.equal(o.checks.pending, 1);
});
