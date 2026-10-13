// tools/pr-brief/src/pr-observation.mjs
//
// Pure, deterministic normalization of GitHub PR facts into a typed PR-observation record.
// No network, no model, no authority — a notification/voice layer may READ this record; it
// grants no action, call, merge or write. This is the factual substrate the card + spoken
// brief are derived from.
//
// Spec guards honored (Jev commitment-recovery spec) + warden P1 packet for #164:
//  - Typed id `github:<repoId>:pr:<n>`; a bare number is never a resolvable PR.
//  - "Who worked on it" = PR author + commit authors + reviewers.
//  - Approval semantics (P1): an APPROVED review counts as a CURRENT valid approval only when it
//    is on the current head SHA (a stale-head +1 does NOT carry), is NOT the author's own review
//    (shared-account self-approval), and is NOT a bot. Approvals on a prior head are reported as
//    `staleApprovals`, never as current.
//  - Provenance (P1): commits authored by a noreply address or carrying a `Co-Authored-By: …noreply…`
//    trailer are AI/automation-attributed through a human account — surfaced, not counted as solely
//    human work.
//  - Never advance a completion state from a missing/partial/errored source.

const str = (v) => (typeof v === 'string' ? v : '');
const lc = (v) => str(v).toLowerCase();
const int = (v) => (Number.isFinite(v) ? v : null);
// An automation/bot login, not an independent human reviewer.
const isBot = (login) => /\[bot\]$/i.test(str(login)) || /^(github-actions|dependabot|renovate)(\[bot\])?$/i.test(str(login));
// Email / trailer marking AI or noreply authorship routed through a human's account.
const NOREPLY_RE = /noreply@anthropic\.com|users\.noreply\.github\.com|noreply@github\.com/i;

/**
 * @param {object} input - composite of raw GitHub shapes:
 *   { repoId, pull, reviews[], commits[], checkRuns[] } (see test/fixtures/pr-*.json).
 *   reviews[] should carry `commit_id` (GitHub includes it); the CLI fetch paginates all three
 *   arrays so this receives the COMPLETE set, not page 1.
 * @param {object} [opts] - { checkedAt } observation timestamp.
 * @returns typed PR-observation record, or { available:false, reason } when the source is
 *   missing/partial/errored (completion state is NOT fabricated in that case).
 */
export function buildPrObservation(input, { checkedAt = new Date().toISOString() } = {}) {
  const repoId = str(input?.repoId);
  const pull = input?.pull;
  if (!repoId || !pull || pull._error || !Number.isInteger(pull.number)) {
    return {
      available: false,
      reason: !repoId ? 'missing-repo' : pull?._error ? 'source-error' : 'missing-pull',
      repoId: repoId || null,
      checkedAt,
    };
  }

  const number = pull.number;
  const id = `github:${repoId}:pr:${number}`; // typed name; never a bare number

  // --- Observed state (facts only) ---
  const state = lc(pull.state) === 'closed' ? 'closed' : 'open';
  const draft = pull.draft === true;
  const merged = pull.merged === true || Boolean(pull.merged_at);
  const mergedAt = merged ? str(pull.merged_at) || null : null;
  const mergeCommitSha = merged ? str(pull.merge_commit_sha) || null : null;

  // --- Who authored / worked on it ---
  const author = {
    login: str(pull.user?.login) || null,
    association: str(pull.author_association) || null,
  };

  const commits = Array.isArray(input.commits) ? input.commits : [];
  const commitAuthorMap = new Map();
  let aiCoAuthoredCommits = 0; // provenance: commits AI/noreply co-authored through a human account
  for (const c of commits) {
    const login = str(c?.author?.login);
    const name = str(c?.commit?.author?.name);
    const email = lc(c?.commit?.author?.email);
    const message = str(c?.commit?.message);
    const noreply = NOREPLY_RE.test(email) || /co-authored-by:[^\n]*noreply/i.test(message);
    if (noreply) aiCoAuthoredCommits += 1;
    const key = login ? `login:${login.toLowerCase()}` : email ? `email:${email}` : name ? `name:${name.toLowerCase()}` : null;
    if (!key) continue;
    if (!commitAuthorMap.has(key)) commitAuthorMap.set(key, { login: login || null, name: name || null, commits: 0, noreply: false });
    const row = commitAuthorMap.get(key);
    row.commits += 1;
    if (noreply) row.noreply = true;
  }
  const commitAuthors = [...commitAuthorMap.values()];
  const commitSubjects = commits.map((c) => str(c?.commit?.message).split('\n')[0]).filter(Boolean).slice(0, 24);

  // --- Reviews: head-valid approvals only (stale-head + self-approval + bot guards) ---
  const headSha = str(pull.head?.sha);
  const authorLogin = lc(pull.user?.login);
  const reviews = Array.isArray(input.reviews) ? input.reviews : [];
  const reviewerMap = new Map();
  for (const r of reviews) {
    const login = str(r?.user?.login);
    if (!login) continue;
    const row = {
      login,
      state: str(r.state).toUpperCase(),
      submittedAt: str(r.submitted_at) || null,
      association: str(r.author_association) || null,
      commitId: str(r.commit_id) || null,
      onHead: headSha ? str(r.commit_id) === headSha : false,
    };
    const prev = reviewerMap.get(login.toLowerCase());
    if (!prev || (row.submittedAt || '') >= (prev.submittedAt || '')) reviewerMap.set(login.toLowerCase(), row);
  }
  const reviewers = [...reviewerMap.values()];
  // A CURRENT valid approval: APPROVED, on the current head (stale +1 doesn't carry), not the
  // author's own review (shared-account self-approval), not a bot.
  const validApprovals = reviewers.filter((r) => r.state === 'APPROVED' && r.onHead && lc(r.login) !== authorLogin && !isBot(r.login));
  const staleApprovals = reviewers.filter((r) => r.state === 'APPROVED' && !r.onHead).length;
  const approvalCount = validApprovals.length;
  const distinctReviewerLogins = reviewerMap.size;
  const independentReviewerLogins = new Set(validApprovals.map((r) => lc(r.login))).size;
  // Reviews exist but fewer than two INDEPENDENT on-head approvals → not independent verification.
  const sharedAccountWarning = reviews.length >= 2 && independentReviewerLogins < 2;

  // --- Checks: producers + conclusions (observed, never inferred green) ---
  const checkRuns = Array.isArray(input.checkRuns) ? input.checkRuns : [];
  const byConclusion = {};
  const producers = new Set();
  let pending = 0;
  for (const cr of checkRuns) {
    if (str(cr.app)) producers.add(str(cr.app));
    const status = lc(cr.status);
    if (status && status !== 'completed') {
      pending += 1;
      continue;
    }
    const concl = lc(cr.conclusion) || 'unknown';
    byConclusion[concl] = (byConclusion[concl] || 0) + 1;
  }
  const hasFailures = (byConclusion.failure || 0) + (byConclusion.timed_out || 0) + (byConclusion.cancelled || 0) + (byConclusion.action_required || 0) > 0;
  const checks = { total: checkRuns.length, byConclusion, pending, producers: [...producers], hasFailures };

  return {
    available: true,
    id,
    repoId,
    number,
    title: str(pull.title),
    url: str(pull.html_url) || null,
    change: {
      additions: int(pull.additions),
      deletions: int(pull.deletions),
      changedFiles: int(pull.changed_files),
      commitCount: Number.isInteger(pull.commits) ? pull.commits : commits.length,
    },
    commitSubjects,
    head: { sha: str(pull.head?.sha) || null, ref: str(pull.head?.ref) || null },
    base: { sha: str(pull.base?.sha) || null, ref: str(pull.base?.ref) || null },
    state,
    draft,
    merged,
    mergedAt,
    mergeCommitSha,
    author,
    commitAuthors,
    provenance: {
      aiCoAuthoredCommits,
      note: aiCoAuthoredCommits > 0 ? 'Some commits are AI/noreply co-authored through a shared account — not solely human-authored.' : null,
    },
    reviewers,
    approvalCount, // head-valid, non-self, non-bot approvals only
    staleApprovals, // approvals on a prior head — reported, never counted as current
    reviewIndependence: {
      distinctReviewerLogins,
      independentReviewerLogins,
      staleApprovals,
      sharedAccountWarning,
      note: sharedAccountWarning
        ? 'Fewer than two independent on-head approvals — reviews from a single, self, or bot account are not independent verification.'
        : null,
    },
    checks,
    checkedAt,
  };
}
