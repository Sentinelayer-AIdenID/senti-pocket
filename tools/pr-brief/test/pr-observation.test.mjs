import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { buildPrObservation } from '../src/pr-observation.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const fx = (n) => JSON.parse(readFileSync(join(here, 'fixtures', `pr-${n}.json`), 'utf8'));

test('#154 merged -> typed id, merged facts, author, checks, commit authors', () => {
  const o = buildPrObservation(fx(154), { checkedAt: '2026-10-12T00:00:00Z' });
  assert.equal(o.available, true);
  assert.equal(o.id, 'github:mrrCarter/senti-pocket:pr:154');
  assert.equal(o.number, 154);
  assert.equal(o.merged, true);
  assert.equal(o.state, 'closed');
  assert.equal(o.author.login, 'mrrCarter');
  assert.ok(o.checks.total >= 1);
  assert.ok(o.commitAuthors.length >= 1);
  assert.equal(o.checkedAt, '2026-10-12T00:00:00Z');
});

test('#158 draft -> draft true, not merged, open', () => {
  const o = buildPrObservation(fx(158));
  assert.equal(o.available, true);
  assert.equal(o.draft, true);
  assert.equal(o.merged, false);
  assert.equal(o.state, 'open');
  assert.equal(o.mergedAt, null);
});

test('typed id is never a bare number; missing/errored pull -> unavailable, NO fabricated completion', () => {
  const miss = buildPrObservation({ repoId: 'x/y', pull: { _error: '404' } });
  assert.equal(miss.available, false);
  assert.equal(miss.reason, 'source-error');
  assert.equal(miss.merged, undefined); // nothing fabricated
  const noRepo = buildPrObservation({ pull: { number: 1 } });
  assert.equal(noRepo.available, false);
  assert.equal(noRepo.reason, 'missing-repo');
});

test('shared-account reviews are flagged as NOT independent verification', () => {
  const o = buildPrObservation({
    repoId: 'x/y', pull: { number: 1, state: 'open' },
    reviews: [
      { user: { login: 'shared' }, state: 'APPROVED', submitted_at: '2026-01-01' },
      { user: { login: 'shared' }, state: 'APPROVED', submitted_at: '2026-01-02' },
    ],
  });
  assert.equal(o.reviewIndependence.distinctReviewerLogins, 1);
  assert.equal(o.reviewIndependence.sharedAccountWarning, true);
  assert.match(o.reviewIndependence.note, /not independent verification/i);
  assert.equal(o.reviewers.length, 1); // latest-per-reviewer collapse
});

test('two distinct reviewers are independent (no warning)', () => {
  const o = buildPrObservation({
    repoId: 'x/y', pull: { number: 2, state: 'open' },
    reviews: [
      { user: { login: 'a' }, state: 'APPROVED', submitted_at: '2026-01-01' },
      { user: { login: 'b' }, state: 'APPROVED', submitted_at: '2026-01-02' },
    ],
  });
  assert.equal(o.reviewIndependence.distinctReviewerLogins, 2);
  assert.equal(o.reviewIndependence.sharedAccountWarning, false);
  assert.equal(o.approvalCount, 2);
});

test('checks: failures are detected, not inferred green', () => {
  const o = buildPrObservation({
    repoId: 'x/y', pull: { number: 3, state: 'open' },
    checkRuns: [
      { name: 'a', status: 'completed', conclusion: 'success' },
      { name: 'b', status: 'completed', conclusion: 'failure' },
      { name: 'c', status: 'in_progress', conclusion: null },
    ],
  });
  assert.equal(o.checks.total, 3);
  assert.equal(o.checks.hasFailures, true);
  assert.equal(o.checks.pending, 1);
  assert.equal(o.checks.byConclusion.success, 1);
});
