// tools/live-call/sfu-revocation.mjs
//
// Server-side revocation of SFU media for the live-call DO (VOICE-08). The floor check at pull time only gates NEW
// pulls; this module closes pulls that a later floor change or leave no longer permits. It reads the SFU's own
// session state (GET /sessions/:id — the ground truth, whatever path created a track) instead of trusting a client or
// a locally recorded mid, then force-closes (no SDP exchange) every stale track. Pure decision + injected SFU client.
//
// A track is finished only when a close for it is CONFIRMED (CF lists closed tracks as `inactive`, but `inactive` also
// means "unavailable", which can resume). Confirmed closes are remembered per session by track key, so each stale track
// is closed once, not on every pass.

/** Stable identity of one listed track; a mid alone can be reused for a different track. */
export const trackKey = (t) => [t.location, t.mid, t.sessionId || '', t.trackName || ''].join('|');

/**
 * Which tracks on one minted session must be closed now.
 * @param {object} args
 * @param {boolean} args.departed - the owning participant left / was swept / was forgotten: close EVERYTHING it has.
 * @param {Array} args.tracks - GET /sessions/:id `tracks` (location, mid, sessionId, trackName, status).
 * @param {Array<{sessionId:string, trackName:string}>} args.permitted - pulls the floor allows for the owner right now
 *   ([] when the owner is not a joined member).
 * @param {Iterable<string>} [args.closed] - track keys already confirmed closed on this session.
 * @returns {{ targets: Array<{mid:string, key:string}>, unclosable: number }} unclosable = stale tracks with no usable
 *   mid (cannot be targeted).
 */
export function staleMids({ departed, tracks, permitted, closed = [] }) {
  const done = new Set(closed);
  const targets = [];
  let unclosable = 0;
  for (const t of Array.isArray(tracks) ? tracks : []) {
    if (!t || typeof t !== 'object') continue;
    // A confirmed close is final unless the SFU lists that track as active again (a recycled mid re-pulling it).
    if (done.has(trackKey(t)) && t.status !== 'active') continue;
    const allowed = !departed && t.location === 'remote' ? permitted.some((p) => p.sessionId === t.sessionId && p.trackName === t.trackName) : false;
    // A live participant's own publication (location local) is never revoked here; a departed one's always is.
    if (allowed || (!departed && t.location !== 'remote')) continue;
    if (typeof t.mid === 'string' && t.mid) targets.push({ mid: t.mid, key: trackKey(t) });
    else unclosable += 1;
  }
  return { targets, unclosable };
}

// 'close_track_error' is the SFU's "doesn't exist or was already closed" — the desired end state, not a failure.
const closedResult = (result) => !result?.errorCode || result.errorCode === 'close_track_error';

/**
 * Reconcile one minted session against the floor. `permittedFor` is called AFTER the SFU read returns, so the decision
 * uses the room state at decision time, not the state when the pass started.
 * @returns {Promise<{ ok: boolean, closed: string[], drained: boolean }>} ok=false means retry; `closed` = track keys
 *   newly confirmed closed; drained=true means a departed session has nothing left that is not confirmed closed (the
 *   caller may drop it once no authorized pull can still be landing on it), or the SFU no longer knows the session.
 */
export async function revokeSession(sfu, cfSessionId, { departed, permittedFor, closed = [] }) {
  let state;
  try {
    state = await sfu.getSession(cfSessionId);
  } catch (error) {
    // The SFU no longer knows this session, so nothing on it can flow: a departed session is drained. A live member's
    // session stays in the ledger (a 404 could be transient), so its pulls are still revisited on every later pass.
    if (error?.message === 'cf-realtime-404') return { ok: true, closed: [], drained: departed === true };
    throw error;
  }
  if (state?.errorCode) return { ok: false, closed: [], drained: false };
  const { targets, unclosable } = staleMids({ departed, tracks: state?.tracks, permitted: departed ? [] : permittedFor(), closed });
  if (!targets.length) return { ok: unclosable === 0, closed: [], drained: departed && unclosable === 0 };
  const mids = [...new Set(targets.map((t) => t.mid))];
  const res = await sfu.closeTracks(cfSessionId, { tracks: mids.map((mid) => ({ mid })), force: true });
  const results = new Map((Array.isArray(res?.tracks) ? res.tracks : []).map((r) => [r?.mid, r]));
  // A mid with no per-track result is NOT assumed closed (a request-level failure can follow partial closes).
  const confirmed = new Set(mids.filter((mid) => results.has(mid) && closedResult(results.get(mid))));
  const newlyClosed = targets.filter((t) => confirmed.has(t.mid)).map((t) => t.key);
  const ok = confirmed.size === mids.length && unclosable === 0;
  return { ok, closed: newlyClosed, drained: departed && ok };
}
