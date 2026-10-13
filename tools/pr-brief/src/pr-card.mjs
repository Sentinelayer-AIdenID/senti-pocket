// tools/pr-brief/src/pr-card.mjs
//
// Deterministic PR-observation -> non-developer "card" (the recovery-inbox / PR-brief render model).
// Pure: no network, no model, no authority. Turns the factual PR-observation record (pr-observation.mjs)
// into: what the PR does, WHO worked on it, a single state chip, the one responsible owner, one next action,
// and two distinct measures. A voice/notification layer reads this card; it grants nothing.
//
// Spec contract (Jev commitment-recovery spec, "non-developer ticket UX"):
//  - State chip ∈ { 'Needs you', 'Waiting on implementation', 'Waiting on review', 'Waiting on deployment', 'Available' }.
//  - Button text is 'Open PR' / 'Review on GitHub' — it MUST NOT imply a merge happened.
//  - Keep TWO distinct measures: verified-acceptance-evidence vs source-coverage. Never collapse to one %.
//  - merged != deployed != available: without deployment evidence a merged PR is 'Waiting on deployment', not 'Available'.
//  - Agent names over one shared GitHub account are NOT independent reviewers (carried from the observation).

const STATES = Object.freeze({
  NEEDS_YOU: 'Needs you',
  IMPL: 'Waiting on implementation',
  REVIEW: 'Waiting on review',
  DEPLOY: 'Waiting on deployment',
  AVAILABLE: 'Available',
});

/**
 * @param {object} observation - output of buildPrObservation (available:true).
 * @param {object} [opts]
 *   deployment: { deployed:boolean, evidence? } | null  (JEV09 territory; default null = unknown)
 *   omar: a normalized Omar review record (B3) | null    (adds a safety dimension to acceptance)
 * @returns a card, or { available:false } passthrough when the observation is unavailable.
 */
export function buildPrCard(observation, { deployment = null, omar = null } = {}) {
  if (!observation || observation.available !== true) {
    return { available: false, reason: observation?.reason || 'unavailable' };
  }
  const o = observation;

  // --- State chip + responsible owner (deterministic; observed facts only) ---
  let state;
  let responsibleOwner;
  if (o.merged) {
    if (deployment && deployment.deployed === true) { state = STATES.AVAILABLE; responsibleOwner = null; }
    else { state = STATES.DEPLOY; responsibleOwner = 'deployment'; } // merged is not deployed until proven
  } else if (o.draft) {
    state = STATES.IMPL; responsibleOwner = o.author.login || 'the author';
  } else if (o.checks.hasFailures) {
    state = STATES.IMPL; responsibleOwner = o.author.login || 'the author'; // red checks -> back to implementation
  } else if (o.checks.pending > 0) {
    state = STATES.REVIEW; responsibleOwner = 'checks in progress';
  } else if (o.approvalCount < 1) {
    state = STATES.REVIEW; responsibleOwner = 'a reviewer';
  } else {
    // ready, green, approved -> the owner must decide to merge. "Needs you", never auto-"Available".
    state = STATES.NEEDS_YOU; responsibleOwner = 'the session owner';
  }

  // --- One next action. Button text never implies a merge occurred. ---
  const nextAction = {
    text:
      state === STATES.IMPL ? (o.checks.hasFailures ? 'Fix the failing checks, then re-request review.' : 'Finish the implementation and mark ready.')
      : state === STATES.REVIEW ? 'Review on GitHub.'
      : state === STATES.NEEDS_YOU ? 'Decide whether to merge (requirements appear met — this does not merge it for you).'
      : state === STATES.DEPLOY ? 'Confirm deployment of the merged change.'
      : 'Nothing — the change is merged and deployed.',
    button: state === STATES.REVIEW ? 'Review on GitHub' : 'Open PR',
    url: o.url,
  };

  // --- "Who worked on it" (carries the independence guard) ---
  const whoWorkedOnIt = {
    author: o.author.login,
    commitAuthors: o.commitAuthors.map((c) => c.login || c.name).filter(Boolean),
    reviewers: o.reviewers.map((r) => ({ login: r.login, disposition: r.state, onHead: r.onHead })),
    independenceNote: o.reviewIndependence.sharedAccountWarning ? o.reviewIndependence.note : null,
    provenanceNote: (o.provenance && o.provenance.note) || null,
  };

  // --- "What it does" (bounded, factual; no model summary) ---
  const whatItDoes = {
    title: o.title,
    change: o.change,
    commitSubjects: o.commitSubjects.slice(0, 8),
  };

  // --- TWO distinct measures (never one blended %) ---
  const approvedWithoutChecks = o.approvalCount > 0 && o.checks.total === 0; // approval with zero observed checks != verified
  const verifiedAcceptance = {
    checks: { total: o.checks.total, byConclusion: o.checks.byConclusion, pending: o.checks.pending, hasFailures: o.checks.hasFailures },
    approvals: o.approvalCount, // head-valid, non-self, non-bot approvals only
    staleApprovals: o.staleApprovals || 0, // approvals on a prior head — reported, never counted as current
    independentReviewers: o.reviewIndependence.independentReviewerLogins,
    approvedWithoutChecks,
    omar: omar ? { state: omar.state, mergeAuthorized: omar.mergeAuthorized === true, findingCounts: omar.findingCounts || null } : null,
    unknowns: [
      ...(deployment == null ? ['deployment-status'] : []),
      ...(o.checks.total === 0 ? ['no-checks-observed'] : []),
      ...(approvedWithoutChecks ? ['approved-without-checks'] : []),
      ...((o.staleApprovals || 0) > 0 ? ['stale-head-approvals'] : []),
    ],
  };
  const sourceCoverage = {
    observedAt: o.checkedAt,
    reviewsObserved: o.reviewers.length,
    checksObserved: o.checks.total,
    checkProducers: o.checks.producers,
    deploymentEvidence: deployment == null ? 'unknown' : deployment.deployed ? 'deployed' : 'not-deployed',
  };

  return {
    available: true,
    id: o.id,
    number: o.number,
    url: o.url,
    state,
    responsibleOwner,
    nextAction,
    whatItDoes,
    whoWorkedOnIt,
    measures: { verifiedAcceptance, sourceCoverage },
  };
}

export { STATES as CARD_STATES };
