import test from 'node:test';
import assert from 'node:assert/strict';
import { buildPrObservation } from '../src/pr-observation.mjs';
import { buildPrCard, CARD_STATES } from '../src/pr-card.mjs';
import { cardToSpokenBrief } from '../src/pr-spoken-brief.mjs';

const HEAD = '0123456789abcdef0123456789abcdef01234567';
const approved = { user: { login: 'reviewer' }, state: 'APPROVED', submitted_at: '2026-10-18T00:00:00Z', commit_id: HEAD };
const green = { name: 'ci', status: 'completed', conclusion: 'success', app: 'legacy-ci' };
function pipeline({ pull = {}, reviews = [approved], checkRuns = [green], deployment = null } = {}) {
  const observation = buildPrObservation({
    repoId: 'example/project',
    pull: { number: 164, state: 'closed', merged: false, draft: false, title: 'Terminal PR', html_url: 'https://github.com/example/project/pull/164', user: { login: 'author' }, head: { sha: HEAD }, base: {}, ...pull },
    reviews, commits: [], checkRuns,
  }, { checkedAt: '2026-10-19T00:00:00Z' });
  const card = buildPrCard(observation, { deployment });
  return { observation, card, spoken: cardToSpokenBrief(card) };
}
for (const [label, options] of [
  ['approved and green', {}],
  ['unapproved', { reviews: [{ ...approved, state: 'COMMENTED' }] }],
  ['draft', { pull: { draft: true } }],
  ['failed checks and requested changes', { reviews: [{ ...approved, state: 'CHANGES_REQUESTED' }], checkRuns: [{ ...green, conclusion: 'failure' }] }],
]) {
  test(`closed/unmerged ${label}: observation → card → spoken is terminal and view-only`, () => {
    const { observation, card, spoken } = pipeline(options);
    assert.equal(observation.state, 'closed');
    assert.equal(observation.merged, false);
    assert.equal(card.state, 'Closed');
    assert.equal(card.state, CARD_STATES.CLOSED);
    assert.equal(card.responsibleOwner, null);
    assert.equal(card.nextAction.button, 'Open PR');
    assert.equal(card.nextAction.url, observation.url);
    assert.match(card.nextAction.text, /closed without merg/i);
    assert.equal(card.measures.verifiedAcceptance.requirementsVerified, false);
    assert.match(spoken.text, /status is: Closed/);
    assert.match(spoken.text, /closed without merg/i);
    assert.doesNotMatch(card.nextAction.text, /decide whether to merge|re-request review|Review on GitHub|finish the implementation|requirements appear met/i);
    assert.doesNotMatch(spoken.text, /not yet approved|change requests? outstanding|requirements appear met/i);
  });
}
test('merged+closed keeps deployment-pending precedence and does not become unmerged', () => {
  const { card, spoken } = pipeline({ pull: { merged: true, merged_at: '2026-10-18T01:00:00Z' } });
  assert.equal(card.state, CARD_STATES.DEPLOY);
  assert.equal(card.nextAction.text, 'Confirm deployment of the merged change.');
  assert.match(spoken.text, /Waiting on deployment/);
  assert.doesNotMatch(spoken.text, /closed without merg/i);
});
test('merged+closed with supplied deployment evidence retains Available precedence', () => {
  const { card, spoken } = pipeline({ pull: { merged: true }, deployment: { deployed: true } });
  assert.equal(card.state, CARD_STATES.AVAILABLE);
  assert.match(spoken.text, /Available/);
  assert.doesNotMatch(spoken.text, /closed without merg/i);
});
test('raw GitHub app object survives observation and card source coverage as its slug', () => {
  const { observation, card } = pipeline({ pull: { state: 'open' }, checkRuns: [{ ...green, app: { id: 15368, slug: 'github-actions', name: 'GitHub Actions' } }] });
  assert.deepEqual(observation.checks.producers, ['github-actions']);
  assert.deepEqual(card.measures.sourceCoverage.checkProducers, ['github-actions']);
  assert.equal(card.measures.verifiedAcceptance.requirementsVerified, true);
});
test('producer normalization retains legacy strings, stable id fallback and unknown uncertainty', () => {
  const { observation, card } = pipeline({ checkRuns: [
    { ...green, app: 'legacy-ci' }, { ...green, app: { id: 15368, slug: '', name: 'Mutable display name' } },
    { ...green, app: { id: 15368 } }, { ...green, app: null }, { ...green, app: {} },
    { ...green, app: { name: 'No stable identifier' } }, { ...green, app: { id: false } },
  ] });
  assert.deepEqual(observation.checks.producers, ['legacy-ci', 'github-app:15368']);
  assert.deepEqual(card.measures.sourceCoverage.checkProducers, observation.checks.producers);
  assert.equal(observation.checks.total, 7);
  const unknown = pipeline({ checkRuns: [{ ...green, app: {} }] });
  assert.deepEqual(unknown.observation.checks.producers, []);
  assert.deepEqual(unknown.card.measures.sourceCoverage.checkProducers, []);
});
