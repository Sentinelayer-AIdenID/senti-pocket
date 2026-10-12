// tools/pr-brief/src/pr-observation.mjs
//
// Pure, deterministic normalization of GitHub PR facts into a typed PR-observation record.
// No network, no model, no authority — a notification/voice layer may READ this record; it
// grants no action, call, merge or write. This is the factual substrate the card + spoken
// brief are derived from.
//
// Spec guards honored (Jev commitment-recovery spec):
//  - Typed id `github:<repoId>:pr:<n>`. A bare number is never a resolvable PR, and a GitHub
//    PR id must never be confused with a Senti room event id.
//  - "Who worked on it" = PR author + commit authors + reviewers. Agent names posting through
//    ONE shared GitHub account are NOT independently authenticated reviewers
//    (`reviewIndependence.sharedAccountWarning`).
//  - Never advance an apparent completion state from a missing / partial / errored source:
//    an unavailable pull returns `{ available: false }` with no fabricated merged/state.

const str = (v) => (typeof v === 'string' ? v : '');
const lc = (v) => str(v).toLowerCase();
const int = (v) => (Number.isFinite(v) ? v : null);

/**
 * @param {object} input - composite of raw GitHub shapes:
 *   { repoId, pull, reviews[], commits[], checkRuns[] } (see test/fixtures/pr-*.json).
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
  for (const c of commits) {
    const login = str(c?.author?.login);
    const name = str(c?.commit?.author?.name);
    const email = lc(c?.commit?.author?.email);
    const key = login ? `login:${login.toLowerCase()}` : email ? `email:${email}` : name ? `name:${name.toLowerCase()}` : null;
    if (!key) continue;
    if (!commitAuthorMap.has(key)) commitAuthorMap.set(key, { login: login || null, name: name || null, commits: 0 });
    commitAuthorMap.get(key).commits += 1;
  }
  const commitAuthors = [...commitAuthorMap.values()];
  const commitSubjects = commits.map((c) => str(c?.commit?.message).split('\n')[0]).filter(Boolean).slice(0, 24);

  // --- Reviews + the shared-account independence guard ---
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
    };
    const prev = reviewerMap.get(login.toLowerCase());
    if (!prev || (row.submittedAt || '') >= (prev.submittedAt || '')) reviewerMap.set(login.toLowerCase(), row);
  }
  const reviewers = [...reviewerMap.values()];
  const approvalCount = reviewers.filter((r) => r.state === 'APPROVED').length;
  const distinctReviewerLogins = reviewerMap.size;
  // Reviews exist but come from fewer than two distinct accounts → not independent verification.
  const sharedAccountWarning = reviews.length >= 2 && distinctReviewerLogins < 2;

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
    reviewers,
    approvalCount,
    reviewIndependence: {
      distinctReviewerLogins,
      sharedAccountWarning,
      note: sharedAccountWarning ? 'Multiple reviews from a single GitHub account are not independent verification.' : null,
    },
    checks,
    checkedAt,
  };
}
