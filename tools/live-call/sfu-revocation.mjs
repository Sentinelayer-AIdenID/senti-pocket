// tools/live-call/sfu-revocation.mjs
//
// Server-side revocation of SFU media for the live-call DO (VOICE-08). The floor check at pull time only gates NEW
// pulls; this module closes pulls that a later floor change or leave no longer permits. It reads the SFU's own
// session state (GET /sessions/:id — the ground truth, whatever path created a track) instead of trusting a client or
// a locally recorded mid, then force-closes (no SDP exchange) every stale track. Pure decision + injected SFU client.

/**
 * Which track mids on one minted session must be closed now.
 * @param {object} args
 * @param {boolean} args.departed - the owning participant left / was swept / was forgotten: close EVERYTHING it has.
 * @param {Array} args.tracks - GET /sessions/:id `tracks` (location, mid, sessionId, trackName, status).
 * @param {Array<{sessionId:string, trackName:string}>} args.permitted - pulls the floor allows for the owner right now
 *   ([] when the owner is not a joined member).
 * @returns {{ mids: string[], unclosable: number }} unclosable = active tracks with no usable mid (cannot be targeted).
 */
export function staleMids({ departed, tracks, permitted }) {
  const mids = [];
  let unclosable = 0;
  for (const t of Array.isArray(tracks) ? tracks : []) {
    if (!t || typeof t !== 'object' || t.status === 'inactive') continue;
    const allowed = !departed && t.location === 'remote' ? permitted.some((p) => p.sessionId === t.sessionId && p.trackName === t.trackName) : false;
    // A live participant's own publication (location local) is never revoked here; a departed one's always is.
    if (allowed || (!departed && t.location !== 'remote')) continue;
    if (typeof t.mid === 'string' && t.mid) mids.push(t.mid);
    else unclosable += 1;
  }
  return { mids, unclosable };
}

// 'close_track_error' is the SFU's "doesn't exist or was already closed" — the desired end state, not a failure.
const closed = (result) => !result?.errorCode || result.errorCode === 'close_track_error';

/**
 * Reconcile one minted session against the floor. `permittedFor` is called AFTER the SFU read returns, so the decision
 * uses the room state at decision time, not the state when the pass started.
 * @returns {Promise<{ ok: boolean, closed: string[], drained: boolean }>} ok=false means retry; drained=true means a
 *   departed session has nothing active left (its ledger entry can be dropped).
 */
export async function revokeSession(sfu, cfSessionId, { departed, permittedFor }) {
  const state = await sfu.getSession(cfSessionId);
  if (state?.errorCode) return { ok: false, closed: [], drained: false };
  const { mids, unclosable } = staleMids({ departed, tracks: state?.tracks, permitted: departed ? [] : permittedFor() });
  if (!mids.length) return { ok: unclosable === 0, closed: [], drained: departed && unclosable === 0 };
  const res = await sfu.closeTracks(cfSessionId, { tracks: mids.map((mid) => ({ mid })), force: true });
  const results = new Map((Array.isArray(res?.tracks) ? res.tracks : []).map((r) => [r?.mid, r]));
  // A mid with no per-track result is NOT assumed closed (a request-level failure can follow partial closes).
  const done = mids.filter((mid) => results.has(mid) && closed(results.get(mid)));
  const ok = done.length === mids.length && unclosable === 0;
  return { ok, closed: done, drained: departed && ok };
}
