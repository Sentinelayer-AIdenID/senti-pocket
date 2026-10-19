# live-call transport

Server side of multi-party live voice (PHONE05). Turns a Senti session into a call room:
members join over a WebSocket signaling channel, the floor policy authorizes **new remote-track pulls**,
and each client is told which remote tracks to subscribe to on the Cloudflare Realtime SFU.

## Layers

| File | Role | Verified by |
| --- | --- | --- |
| `call-room.mjs` | Membership + capacity + idle sweep + floor (`open` / `round-robin` / `moderated`) + who-hears-whom | unit tests |
| `signaling.mjs` | Typed message → CallRoom op, returns fresh subscriptions + state | unit tests |
| `cf-realtime-sfu.mjs` | Thin CF Realtime HTTP adapter (Bearer App Secret, SDP passed through) + `remoteTracksForListener` | unit tests |
| `call-fanout.mjs` | Per-listener subscribe directives (subscriptions × published tracks) | unit tests |
| `call-do.mjs` | Durable Object: hibernatable WS, role-gated floor, mint-bound tracks, reconnect-kick, sweep, rebuild | unit tests (mocked CF runtime) |
| `sfu-revocation.mjs` | Server-side close of stale pulls: SFU session state → stale mids → forced `tracks/close` | unit tests (fake SFU state) |
| `worker.mjs` | Edge router: fail-closed (session,room) auth, host-pin, token-strip, DO routing, SFU mint + bind | unit tests (helpers) |
| `join-call.mjs` | In-process demo of floor routing (no network) | `node join-call.mjs demo` |

The decision logic is pure and unit-tested with no network. The DO's orchestration (identity anti-spoof, floor-role
gate, mint-binding, reconnect, sweep, hibernation rebuild) is unit-tested against a mocked CF runtime, and the
Worker's auth/forward helpers are unit-tested directly. The **live WebSocket upgrade + real CF Realtime negotiation**
still only run under deploy / miniflare — do not read the green unit suite as proof the end-to-end socket path works.

## Signaling protocol (client ⇄ DO over the WS)

Client → DO (JSON): `{ type, ... }` where `type` ∈
`join | leave | touch | set-floor | grant-floor | advance-floor | roster`.
On `join`, a client that has already negotiated its publish with the SFU includes
`cfSessionId` + `cfTrackName` — accepted **only if they match a session the Worker minted for that
participant** (a client cannot claim another's CF session). `participantId` / `sessionId` on
`join`/`leave`/`touch` are **ignored and overwritten** with the identity bound to the socket at
accept time (anti-spoof). `grant-floor`'s `participantId` is the grantee. **Floor ops**
(`set-floor` / `grant-floor` / `advance-floor`) are privileged — **owner/admin only**, by the
gateway role carried in the socket; anyone else gets `ack ok:false reason:'forbidden-role'`. A
reconnecting participant **kicks its own stale socket**; messages over 16 KiB are rejected.

An accepted socket is not a joined member. Only a successful `join` persists `joined:true` in its
hibernation attachment. `leave` clears that marker, publication and minted-session binding before its
acknowledgement; the healthy socket can explicitly join again (a new publication needs a newly bound
session, still subject to the lifetime mint cap). Constructor rebuild restores only explicitly joined
sockets and mint-matching publications. Legacy attachments without the marker must send `join` again.
Replaced sockets are retired and cannot alter their replacement's membership.

DO → client (JSON):
- `{ type:'ack', op, ok, reason?, state }` — the result of the sender's own op.
- `{ type:'directives', state, subscriptions, remoteTracks }` — broadcast to every member after
  any change; `remoteTracks` is the exact CF `tracks/new` subscribe body for that listener.

## Authorization (mirrors the gateway — not a reinvention)

The Pocket gateway holds **no signing key**: it authorizes by forwarding the caller's own Senti bearer to the
SentinelLayer API and trusting the returned role (`senti-target-membership.mjs`). So this Worker mints nothing — it
forwards the **client's own bearer** to a configured gateway authorize endpoint, which returns a member role + the
participant id the **gateway** bound to that bearer for the **(session, room)** pair (the caller never chooses its own
id or room — those shapes are the confused-deputy / room-squatting bugs). The DO is keyed by
`${encode(session)}::${encode(room)}`, so one session can't reach (or collide into) another's room. Fail-closed:
`GATEWAY_AUTHORIZE_URL` or `GATEWAY_HOST` unset, or the URL host ≠ `GATEWAY_HOST`, and every `/call/*` route 403s; the
authorize fetch is `redirect:'manual'` + 3 s timeout, and the gateway must echo the (session, room) it authorized.
The WS forward is **GET-only** and a **fresh** request — no client header or body (the bearer, any
`x-live-call-internal`, any POST body) reaches the DO. Every SFU op is authorized against the DO, which owns the
per-participant minted sessions: `/sfu/session` is mint-capped, and `/sfu/tracks` + `/sfu/renegotiate` accept only
a sessionId minted for that participant. Each new remote pull must match an exact published session/track pair
in that listener's current floor subscriptions. Malformed track coordinates and unknown locations are rejected
before SFU dispatch; local publication on the owned session remains possible before `join`. Internal authorization
requires `remoteTracks` coordinate pairs; legacy session-only lists are refused. The Worker↔DO internal ops live at an **exact path** gated by a **required**
`INTERNAL_BIND_KEY` (no default), unreachable by any client request.

The floor check gates every new pull, and revocation is **server-side** (`sfu-revocation.mjs`): directives only ask
clients to drop pulls, so the DO does not rely on them. It keeps a durable ledger of every SFU session it minted. After
any floor or membership change (set/grant/advance floor, leave, socket close, reconnect kick, idle sweep), after every
pull the Worker dispatches, and on the sweep alarm, it reads each session's SFU state (`GET /sessions/:id`, which
lists every track whatever path created it) and force-closes (`tracks/close` with `force: true`, no SDP exchange)
every pull the floor no longer permits, plus every track of a departed participant. Permission is the exact published
(session, track) pair, and a pull may not reuse a transceiver (`mid` / `bidirectionalMediaStream` are refused), so a
revoked pull never takes the puller's own publication with it. A track is finished only when its close is confirmed per
track ("already closed" included; an `inactive` listing alone is not proof, since it can also mean unavailable).
Failures retry on a 2 s alarm, backing off to the 30 s sweep after five attempts (the count survives hibernation); DO
SFU calls are bounded at 3 s and run at most 4 at a time. An authorized pull holds its session in the ledger for 30 s
(the Worker bounds its own SFU calls at 10 s) and the post-dispatch reconcile names that session, so a leave that lands
while a pull is in flight cannot strand it. A session minted by someone who never joins is drained after the 5 min idle
window. A pull created between room changes is closed by the next pass, at most one sweep interval later. This is
proven against a fake SFU that models session track state (`call-do-revocation.test.mjs`, including the adversarial
review's probes); it has not yet run against the live CF Realtime API.

The authorize endpoint is the Pocket gateway's `POST /call/authorize` (`services/pocket-gateway/API.md`): it resolves the
caller's membership role in the session under the caller's own bearer and returns the authenticated account as the
participant id. Set `GATEWAY_AUTHORIZE_URL=https://<gateway api domain>/call/authorize` and `GATEWAY_HOST=<gateway api
domain>`. Until both are set (and the gateway route is deployed), every `/call/*` route 403s — intentionally. One
participant per account: a second device or agent on the same account replaces the first. The authorize fetch allows
14 s because the gateway checks the bearer (up to 5 s) and then membership (up to 3 s), uncached, after a cold start's
secret load (up to ~3.75 s).

Routes: `GET /call/:room/ws` (WS signaling), `POST /call/:room/sfu/session` (mint — also binds the minted CF session
to the participant inside the DO), `POST /call/:room/sfu/tracks`, `POST /call/:room/sfu/renegotiate`, `GET /health`.

## Deploy (needs CF Realtime app + wrangler; co-set up with warden)

```sh
cd tools/live-call
# one-time secrets (NEVER committed):
wrangler secret put CF_REALTIME_APP_SECRET   # CF Realtime App Secret (stays server-side)
wrangler secret put INTERNAL_BIND_KEY        # Worker->DO minted-session bind key (defense-in-depth)
# set CF_REALTIME_APP_ID + GATEWAY_AUTHORIZE_URL + GATEWAY_HOST in wrangler.toml [vars], then:
wrangler deploy
```
