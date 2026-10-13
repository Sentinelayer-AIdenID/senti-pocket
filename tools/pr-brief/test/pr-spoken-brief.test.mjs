import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { buildPrObservation } from '../src/pr-observation.mjs';
import { buildPrCard } from '../src/pr-card.mjs';
import { cardToSpokenBrief } from '../src/pr-spoken-brief.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const fx = (n) => JSON.parse(readFileSync(join(here, 'fixtures', `pr-${n}.json`), 'utf8'));
const brief = (n, opts) => cardToSpokenBrief(buildPrCard(buildPrObservation(fx(n), { checkedAt: '2026-10-12T00:00:00Z' }), opts));

test('#154 brief: identifies PR, what it does, who, state, next — grounded, bounded segments', () => {
  const b = brief(154);
  assert.match(b.text, /Pull request 154/);
  assert.match(b.text, /Opened by mrrCarter/);
  assert.match(b.text, /Waiting on deployment/); // merged != available without deploy evidence
  assert.ok(b.segments.find((s) => s.kind === 'next'));
  assert.equal(b.segments[0].kind, 'identify');
});

test('#158 draft brief: says Waiting on implementation; never falsely claims merged/deployed', () => {
  const b = brief(158);
  assert.match(b.text, /Waiting on implementation/);
  assert.doesNotMatch(b.text, /\bmerged\b|\bdeployed\b|\bAvailable\b/i);
});

test('#154 + deployment proven -> brief says Available', () => {
  const b = brief(154, { deployment: { deployed: true } });
  assert.match(b.text, /Available/);
});

test('shared-account reviews surface the independence caveat in the spoken who-line', () => {
  const o = buildPrObservation({
    repoId: 'x/y', pull: { number: 9, state: 'open', title: 'T', user: { login: 'dev' }, head: {}, base: {}, changed_files: 1, commits: 1 },
    reviews: [
      { user: { login: 'bot' }, state: 'APPROVED', submitted_at: '2026-01-01' },
      { user: { login: 'bot' }, state: 'APPROVED', submitted_at: '2026-01-02' },
    ],
  });
  const b = cardToSpokenBrief(buildPrCard(o));
  const who = b.segments.find((s) => s.kind === 'who');
  assert.match(who.text, /not independent verification/i);
});

test('unreadable card -> honest failure line, not a fabricated brief', () => {
  const b = cardToSpokenBrief({ available: false });
  assert.match(b.text, /could not be read/);
  assert.equal(b.segments[0].kind, 'error');
});
