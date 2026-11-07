# Owner question calls (SPEC G)

API dependency: [sentinelayer-api #1201](https://github.com/Sentinelayer-AIdenID/sentinelayer-api/pull/1201).
The API PR precedes this phone change. **Merge and migration 184 remain held until after HN.**

Source: [Main room](https://sentinelayer.com/dashboard/sessions/e9e8dc5e-8d57-4603-975f-09156e3b4473),
original SPEC G at sequence 62879, repeated at 62888; Warden safeguard approval
`b68708be-8283-42df-b99f-60e2ed655c52`, later admission/opt-out decision `3930c56c`.

## What the phone does

The existing CallKit/VoIP doorbell stays `{callId, sessionId, callerName}`. Its authenticated call read can now contain
`question`, including the exact source, text, choices, expiry, question/call IDs and `ringAllowed`. A malformed,
wrong-room/wrong-call, expired, cancelled, answered or refused question never becomes an ordinary agent call.
The normal call path is unchanged for calls without a question.

After the server accepts the call answer and CallKit supplies audio, Pocket reads the question again using the
person's session. The original source and choices must still match. This protects the gap between the incoming
call read and opening the question screen. Invalid sources close the call with a room notice and no speech/write.

The existing on-device `AgentVoiceSpeaker`, `OnDeviceVoiceListener`, `CallKitVoiceRoomAudioSession` and
`VoiceCallWindow` provide the call. The phone reads the question and numbered choices without the ordinary chat
readout's URL/code substitutions, so distinct URLs and command choices retain their content, then listens. A pause of
1.8 seconds after the recognizer's last changed words, or tapping **Send spoken answer**, submits one answer.
A complete, unambiguous choice label or numbered option selects that choice; other speech stays the person's
transcript. Microphone denial leaves choices available. The call screen's mute stops and discards a partial
answer, including while the recognizer is finishing its final transcript. Hanging up stops speech/listening immediately
and ignores late responses. Once the answer has been sent, mute cannot withdraw that request.

Tap sends `{"choiceId":"ship"}`; free speech sends `{"text":"Tomorrow.","inputKind":"voice"}` to
`POST /api/v1/sessions/{roomId}/questions/{questionId}/answer`. Only the server selects the authenticated human
sender and exact thread. This path does not call the generic voice model, post an agent message, or create a
separate voice-room transcript. The reply appears in the original question's thread through normal room updates.

An accepted answer must return the same question/source plus `status: "answered"` and `answerActionId` before
the phone says it posted. A lost/unreadable response retains the exact answer and offers **Retry the same answer**.
The API's same-answer idempotency returns one existing reply. Other choices are disabled while that result is
uncertain. Authentication, missing question, conflict and validation refusals close the call without claiming success.
An acknowledged duplicate with a now-cancelled/expired, redacted source also closes the call; it cannot keep the old
question visible in a retry loop.
An in-flight write can still reach the server after hang-up; the original thread is the authoritative record.

## Owner setting and authority

Signed-in Settings includes **Call me about unanswered questions**, backed only by
`GET/PUT /api/v1/me/question-call-preferences`. It starts false and cannot be changed until the server has been
read. It makes no optimistic success claim after an uncertain save. Each call/settings client is bound to its
starting credential; sign-out/account changes refuse retained writes and late responses. Protected reads use an
ephemeral URL session with no cache, cookies or credential storage.

The server enforces who may register a question, owner-only calls/answers, the default-off opt-in, the 30-minute
timer, one call per question, one call per 30 minutes across rooms, the ten-open-question cap, 24-hour expiry and
the person's existing calendar quiet hours. Quiet hours defer pending questions; opt-out/revocation/source changes
cancel them. Pocket does not invent a recipient, timer or additional retry call. Feature-off/missing API responses
do not enable the setting or ring a question.

## Proof and rollout limits

`QuestionCallsTests` covers bounded/malformed envelopes; explicit ring permission; call/room binding; fresh-source
refusal; numbered/ambiguous speech; spoken question and choices; actual answer acknowledgement; tap/voice races;
lost-response retry; cancellation during reads/writes; mute; and denied/conflicting answers.
`QuestionCallsClientTests` exercises real URLSession requests with a hermetic URLProtocol: endpoint/body/bearer
binding, receipts, default-off preference, account switches before/during a request, invalid inputs and uncertain
preference saves. Existing ordinary-call tests still run in the hosted app suite.

The Linux authoring workspace has no Swift/Xcode. Source release preflight and Swift syntax parsing run locally;
the existing macOS `Hosted app build and tests` workflow is required for the app's real compile and XCTest proof.
That CI also builds the unsigned Release device closure. No claim of physical-device APNs delivery, locked-phone
audio, signing, installation or a real phone call is made by these tests. Those remain the existing device handoff
checks in `MAC_VERIFY.md` after the API rollout is authorized. No test rings a real phone.

Rollback: keep the API feature flag off (and retain server history). Ordinary calls still use their old path. This
phone change introduces no device registration, signing, provisioning, push-payload expansion or persistent answer
storage. Warden and a distinct-role reviewer must approve the handoff before merge.
