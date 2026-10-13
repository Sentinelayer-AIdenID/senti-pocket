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

## Deploy (needs CF account + wrangler; flag Carter for access)

```sh
cd tools/live-call
# one-time secrets (NEVER committed):
wrangler secret put CF_REALTIME_APP_SECRET   # CF Realtime App Secret
wrangler secret put GATEWAY_TOKEN            # bearer for the gateway membership check
# set CF_REALTIME_APP_ID + GATEWAY_URL in wrangler.toml [vars], then:
wrangler deploy
```

Membership is fail-closed: with `GATEWAY_URL`/`GATEWAY_TOKEN` unset, every call/SFU route 403s.
