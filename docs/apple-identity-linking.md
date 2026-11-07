# Link Apple to the signed-in account (SPEC E)

API dependency: [sentinelayer-api #1204](https://github.com/Sentinelayer-AIdenID/sentinelayer-api/pull/1204),
`docs/explicit-identity-linking.md`. This phone PR is separate from question calls and ordinary Apple sign-in.
The server feature defaults off. Migration 185 and production enablement remain held for the release owner's
independent security review and launch-window decision.

## User flow

Signed-in Settings → Account offers **Link Apple to this account** when the build supports Apple authorization
and `GET /api/v1/auth/identities` succeeds. Opening Settings only reads the three provider booleans. A feature-off
404 hides the row. A linked account shows **Apple linked**. It does not offer unlinking or account-data moves.

Only the person's explicit tap starts linking:

1. `POST /api/v1/auth/identities/apple/challenge` with `{}` and the current human bearer obtains `{state, nonce,
   expiresIn}`. State and nonce must be bounded opaque values; the lifetime may not exceed 300 seconds.
2. The existing native Apple proof sheet receives the server's state and the lowercase SHA-256 of its nonce,
   with no name or email scopes requested. The returned Apple credential must echo that same state.
3. `POST /api/v1/auth/identities/apple/complete` sends exactly `{state, identityToken, authorizationCode}` with
   the same starting bearer. The raw nonce is never included in completion. Apple token/code sizes match the API's
   16,384/4,096-byte client bounds.
4. Only `{provider: "apple", linked: true}` confirms the link. The response is never decoded as an AuthResponse,
   no principal is installed, and no session token is saved. The shared proof-sheet instance explicitly refuses
   any attempt to save a login token.

Apple's request state is returned unchanged in its credential, and its nonce is included in the identity proof:
[Apple state documentation](https://developer.apple.com/documentation/authenticationservices/asauthorizationopenidrequest/state)
and [Apple nonce documentation](https://developer.apple.com/documentation/authenticationservices/asauthorizationopenidrequest/nonce),
checked November 7, 2026. The server remains the cryptographic verifier and account/subject authority.

## Refusal and uncertainty

The client is bound to its starting Keychain bearer and compares it before and after every HTTP suspension and
after Apple's sheet. An account switch, sign-out, expiry, cancelled presentation or mismatched state cannot
complete under a new session. State/proof values live only in the in-memory attempt. Requests use the existing
ephemeral protected-read transport with no URL cache, cookies or credential storage. No credential, provider
subject, state, nonce or email is logged or persisted.

The model claims one attempt synchronously before starting asynchronous work, so repeated taps cannot create
competing challenges. A cancelled Apple sheet preserves the previous linked state. A 409 leaves the current
sign-in unchanged and requires a fresh read; a provider identity belonging elsewhere is not moved. A lost or
unreadable completion cannot claim success and cannot replay the spent challenge. **Read linked sign-ins** can
resolve an uncertain result; another attempt always needs a fresh challenge. If the app closes while completion
is in flight, the server may have committed the authorized link; the next read is authoritative.

This feature neither grants admin nor matches email nor merges accounts. The existing sign-in entry point and
token installation are unchanged. Legacy email-adoption retirement is a separate API review.

## Evidence and handoff

`AppleIdentityLinkTests` covers native request state/nonce/scopes, challenge bounds, explicit-only linking,
double taps, state substitution, account switch/expiry/cancellation during the Apple sheet, default-off behavior,
conflicts, lost-response readback and native cancellation. `AppleIdentityLinkClientTests` uses hermetic URLSession
requests to verify the exact routes/body/current bearer, absent raw nonce, unchanged token, receipt validation,
wrong-account/late responses, HTTP refusal and credential bounds. Existing `AppleSignInTests` still exercise
the ordinary login contract.

Local source-release preflight, Omar contract/forbidden-surface guards, Swift syntax parsing and whitespace checks
pass. The Linux workspace has no Swift/Xcode; hosted macOS app/Release builds and XCTest remain required exact-head
proof. Real Apple sheets, the deployed verifier and physical-device provisioning require the existing authorized
device handoff; no test here contacts Apple or links a real person's identity.

Source: [Main room](https://sentinelayer.com/dashboard/sessions/e9e8dc5e-8d57-4603-975f-09156e3b4473), SPEC E at
sequence 62879 (`e8b8584e-e6f7-45ac-9680-e2bc960bed31`), repeated at 62888
(`4ba0acab-7315-4d34-a064-026d38fd7769`); Warden design approval
`f9b60573-d64e-45f8-86e2-dd6f47510e96`. Warden and a distinct-role reviewer must sign off before merge. Disable the
server feature to hide/refuse linking; the phone change performs no migration, account merge, signing or deployment.
