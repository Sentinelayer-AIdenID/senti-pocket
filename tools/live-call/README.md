# live-call transport

Server side of multi-party live voice (PHONE05). Turns a Senti session into a call room:
members join over a WebSocket signaling channel, the room decides **who hears whom** by a
floor policy, and each client is told exactly which remote tracks to subscribe to on the
Cloudflare Realtime SFU.

## Layers

| File | Role | Verified by |
| --- | --- | --- |
| `call-room.mjs` | Membership + capacity + idle sweep + floor (`open` / `round-robin` / `moderated`) + who-hears-whom | unit tests |
| `signaling.mjs` | Typed message → CallRoom op, returns fresh subscriptions + state | unit tests |
| `cf-realtime-sfu.mjs` | Thin CF Realtime HTTP adapter (Bearer App Secret, SDP passed through) + `remoteTracksForListener` | unit tests |
| `call-fanout.mjs` | Per-listener subscribe directives (subscriptions × published tracks) | unit tests |
| `call-do.mjs` | Durable Object shell: hibernatable WS, alarm sweep, broadcast, hibernation rebuild | deploy / miniflare |
| `worker.mjs` | Edge router: fail-closed membership gate, DO routing, SFU session minting | deploy / miniflare |
| `join-call.mjs` | In-process demo of floor routing (no network) | `node join-call.mjs demo` |

The decision logic is pure and unit-tested with no network. The DO + Worker are the CF-runtime
shell and are exercised by deploy / miniflare, **not** by the node unit tests — do not read the
green unit suite as proof the deployed path works end to end.

## Signaling protocol (client ⇄ DO over the WS)

Client → DO (JSON): `{ type, ... }` where `type` ∈
`join | leave | touch | set-floor | grant-floor | advance-floor | roster`.
On `join`, a client that has already negotiated its publish with the SFU includes
`cfSessionId` + `cfTrackName` so others can subscribe to it; `participantId` / `sessionId`
on `join`/`leave`/`touch` are **ignored and overwritten** with the identity bound to the
socket at accept time (anti-spoof). `grant-floor`'s `participantId` is the grantee.

DO → client (JSON):
- `{ type:'ack', op, ok, reason?, state }` — the result of the sender's own op.
- `{ type:'directives', state, subscriptions, remoteTracks }` — broadcast to every member after
  any change; `remoteTracks` is the exact CF `tracks/new` subscribe body for that listener.

## Authorization (mirrors the gateway — not a reinvention)

The Pocket gateway holds **no signing key**: it authorizes by forwarding the caller's own Senti bearer to the
SentinelLayer API and trusting the returned role (`senti-target-membership.mjs`). So this Worker mints nothing — it
forwards the **client's own bearer** to a configured gateway authorize endpoint and trusts only a member role + the
participant id the **gateway** bound to that bearer (the caller never chooses its own id — that shape is the
confused-deputy bug). Fail-closed: with `GATEWAY_AUTHORIZE_URL` unset, every `/call/*` route 403s.

The exact authorize endpoint is being **co-designed with warden** (gateway owns `/dial` + the resolver; a store-backed
one-time join grant via the existing `dialSignalStore` is one candidate). Until it's wired, deploy stands up the
transport but admits no one — intentionally.

## Deploy (needs CF Realtime app + wrangler; co-set up with warden)

```sh
cd tools/live-call
# one-time secret (NEVER committed):
wrangler secret put CF_REALTIME_APP_SECRET   # CF Realtime App Secret (stays server-side)
# set CF_REALTIME_APP_ID + GATEWAY_AUTHORIZE_URL in wrangler.toml [vars], then:
wrangler deploy
```
