import Foundation
import PocketContracts
import XCTest
@testable import SentiPocketApp

private let questionID = "b01fc928-bd8e-48fc-9f23-c8f1b28a2c90"
private let questionCallID = "a63a9d6c-674f-4a3c-b115-9fc47a1a3439"
private let questionAnswerID = "0d312baa-b7b8-4e4d-b111-e069a059b1ea"
private let questionRoomID = "5b08ade7-c680-4fc9-8c63-af343072d476"
private let questionNow = Date(timeIntervalSince1970: 1_799_020_800) // Frozen before the fixture's expiry.

private func questionJSON(_ changes: [String: Any] = [:]) throws -> JSONValue {
    var body: [String: Any] = [
        "questionId": questionID, "sessionId": questionRoomID, "targetSequenceId": 91,
        "targetActionId": NSNull(), "text": "Should we ship?", "status": "called",
        "choices": [["id": "ship", "label": "Ship it"], ["id": "wait", "label": "Wait"]],
        "expiresAt": "2030-01-01T00:00:00+00:00", "callId": questionCallID,
        "answerActionId": NSNull(), "ringAllowed": true,
    ]
    changes.forEach { body[$0.key] = $0.value }
    return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: body))
}

private func question(_ changes: [String: Any] = [:]) throws -> RoomQuestion {
    try XCTUnwrap(RoomQuestion(json: questionJSON(changes)))
}

private actor QuestionsStub: RoomQuestionsAPI {
    var read: RoomQuestion
    let answered: RoomQuestion
    var writes: [RoomQuestionAnswer] = []
    var failures: [RoomCallsClient.Failure]
    var holdRead = false
    var holdAnswer = false
    var readWaiter: CheckedContinuation<Void, Never>?
    var answerWaiter: CheckedContinuation<Void, Never>?

    init(read: RoomQuestion, answered: RoomQuestion, failures: [RoomCallsClient.Failure] = []) {
        self.read = read
        self.answered = answered
        self.failures = failures
    }

    func question(sessionId: String, questionId: String) async throws -> RoomQuestion {
        if holdRead { await withCheckedContinuation { readWaiter = $0 } }
        return read
    }

    func answer(_ answer: RoomQuestionAnswer, question: RoomQuestion) async throws -> RoomQuestion {
        writes.append(answer)
        if holdAnswer { await withCheckedContinuation { answerWaiter = $0 } }
        if !failures.isEmpty { throw failures.removeFirst() }
        return answered
    }

    func setHold(read: Bool = false, answer: Bool = false) { holdRead = read; holdAnswer = answer }
    func releaseRead() { holdRead = false; readWaiter?.resume(); readWaiter = nil }
    func releaseAnswer() { holdAnswer = false; answerWaiter?.resume(); answerWaiter = nil }
    var isReading: Bool { readWaiter != nil }
    var isPosting: Bool { answerWaiter != nil }
}

@MainActor
private final class QuestionListener: VoiceListening {
    var partial: (@MainActor (String) -> Void)?
    var words = ""
    var starts = 0
    var cancels = 0
    var failure: Error?
    func start(partial: @escaping @MainActor (String) -> Void) async throws {
        starts += 1
        if let failure { throw failure }
        self.partial = partial
    }
    func say(_ text: String) { words = text; partial?(text) }
    func stop() async -> String { partial = nil; return words }
    func cancel() { cancels += 1; partial = nil }
}

@MainActor
private final class QuestionSpeaker: VoiceSpeaking {
    var spoken: [String] = []
    var finished: (@MainActor () -> Void)?
    func speak(_ markdown: String, as speaker: String, finished: @escaping @MainActor () -> Void) {
        spoken.append(markdown)
        self.finished = finished
    }
    func stop() { finished = nil }
    func finish() { let done = finished; finished = nil; done?() }
}

@MainActor
private final class QuestionAudio: VoiceRoomAudioSession {
    var active = false
    func activate() throws { active = true }
    func deactivate() { active = false }
}

@MainActor
final class QuestionCallsTests: XCTestCase {
    private func until(_ message: String, _ condition: () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out: \(message)")
    }

    private func stub(read: RoomQuestion? = nil, failures: [RoomCallsClient.Failure] = []) throws -> QuestionsStub {
        try QuestionsStub(read: read ?? question(),
                          answered: question(["status": "answered", "answerActionId": questionAnswerID]), failures: failures)
    }

    func test_question_payload_refuses_unbounded_ambiguous_and_wrong_target_data() throws {
        for changes: [String: Any] in [
            ["questionId": "../escape"], ["sessionId": "room/path"], ["targetSequenceId": 0],
            ["targetActionId": "not-a-uuid"], ["callId": "not-a-uuid"], ["status": "other"],
            ["expiresAt": "not-a-date"], ["text": ""], ["text": String(repeating: "x", count: 4_001)],
            ["choices": [["id": "only", "label": "Only"]]],
            ["choices": [["id": "x", "label": "First"], ["id": "x", "label": "Second"]]],
            ["choices": [["id": "x", "label": "First\nline"], ["id": "y", "label": "Second"]]],
        ] {
            XCTAssertNil(RoomQuestion(json: try questionJSON(changes)), "\(changes.keys)")
        }
        XCTAssertNotNil(RoomQuestion(json: try questionJSON(["choices": []])))
        XCTAssertNotNil(RoomQuestion(json: try questionJSON(["status": "cancelled", "text": "", "choices": []])))
    }

    func test_question_ring_requires_explicit_permission_same_call_and_live_question() throws {
        let bell = RoomCallDoorbell(callId: questionCallID, sessionId: questionRoomID, callerName: "Senti")
        func details(_ value: JSONValue) -> RoomCallDetails? {
            RoomCallDetails(json: .object([
                "callId": .string(questionCallID), "sessionId": .string(questionRoomID),
                "callerActorId": .string("warden"), "status": .string("ringing"), "question": value,
            ]))
        }
        XCTAssertTrue(try XCTUnwrap(details(questionJSON())).isLiveRing(of: bell, at: questionNow))
        for changes: [String: Any] in [["ringAllowed": false], ["status": "answered"],
                                      ["expiresAt": "2020-01-01T00:00:00Z"]] {
            XCTAssertFalse(try XCTUnwrap(details(questionJSON(changes))).isLiveRing(of: bell, at: questionNow))
        }
        XCTAssertNil(details(.null), "a present malformed question never becomes an ordinary call")
        XCTAssertNil(try details(questionJSON(["sessionId": "another-room"])))
        XCTAssertNil(try details(questionJSON(["callId": questionAnswerID])))
        XCTAssertNil(try details(questionJSON(["ringAllowed": NSNull()])))
        let ordinary = RoomCallDetails(callId: questionCallID, sessionId: questionRoomID, callerActorId: "warden",
                                       callerName: "warden", reason: nil, status: "ringing", ringExpiresAt: nil)
        XCTAssertTrue(ordinary.isLiveRing(of: bell, at: questionNow))
    }

    func test_speech_is_exact_number_or_unique_label_otherwise_unmodified_human_text() throws {
        let q = try question()
        XCTAssertEqual(q.answer(from: "Option one."), .choice("ship"))
        XCTAssertEqual(q.answer(from: "Wait"), .choice("wait"))
        XCTAssertEqual(q.answer(from: "Ship tomorrow, please."), .voice("Ship tomorrow, please."))
        let ambiguous = try question(["choices": [["id": "a", "label": "Same"], ["id": "b", "label": "Same"]]])
        XCTAssertEqual(ambiguous.answer(from: "Same"), .voice("Same"))
        XCTAssertFalse(q.canAnswer(at: q.expiresAt), "the exact expiry boundary refuses")
    }

    func test_read_aloud_uses_fresh_question_and_choices_then_voice_posts_under_it() async throws {
        let api = try stub()
        let listener = QuestionListener(), speaker = QuestionSpeaker(), audio = QuestionAudio()
        var ended = 0
        let call = try QuestionCallCoordinator(question: question(), api: api, listener: listener, speaker: speaker,
                                              audio: audio, now: { questionNow }, onEnded: { ended += 1 })
        XCTAssertNil(call.question, "cached call data is not displayed before a fresh source read")
        await call.begin()
        XCTAssertEqual(call.phase, .speaking)
        XCTAssertTrue(speaker.spoken[0].contains("Should we ship?"))
        XCTAssertTrue(speaker.spoken[0].contains("Option 1: Ship it."))
        XCTAssertTrue(speaker.spoken[0].contains("Option 2: Wait."))
        XCTAssertEqual(listener.starts, 0, "the microphone does not hear the question")
        speaker.finish()
        await until("listening after readout") { call.phase == .listening }
        listener.say("Ship tomorrow.")
        await call.finishSpeaking()
        let writes = await api.writes
        XCTAssertEqual(writes, [.voice("Ship tomorrow.")])
        XCTAssertEqual(call.phase, .answered)
        XCTAssertTrue(audio.active)
        speaker.finish()
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(call.phase, .ended)
        XCTAssertFalse(audio.active)
    }

    func test_tap_and_voice_race_only_posts_one_answer_and_ignores_hangup_completion() async throws {
        let api = try stub()
        await api.setHold(answer: true)
        let call = try QuestionCallCoordinator(question: question(), api: api, listener: QuestionListener(),
                                              speaker: QuestionSpeaker(), audio: QuestionAudio(), now: { questionNow }, onEnded: {})
        await call.begin()
        let first = Task { await call.choose("ship") }
        await until("answer in flight") { await api.isPosting }
        await call.choose("wait")
        await call.finishSpeaking()
        call.hangUp()
        await api.releaseAnswer()
        await first.value
        let writes = await api.writes
        XCTAssertEqual(writes, [.choice("ship")])
        XCTAssertEqual(call.phase, .ended, "a late success never restarts speech or the call")
    }

    func test_lost_answer_response_keeps_same_retry_and_never_claims_success_early() async throws {
        let api = try stub(failures: [.unreachable])
        let speaker = QuestionSpeaker()
        let call = try QuestionCallCoordinator(question: question(), api: api, listener: QuestionListener(),
                                              speaker: speaker, audio: QuestionAudio(), now: { questionNow }, onEnded: {})
        await call.begin()
        await call.choose("ship")
        XCTAssertEqual(call.phase, .retry)
        XCTAssertFalse(speaker.spoken.contains("Your answer is posted under the question."))
        await call.choose("wait")
        await call.retry()
        let writes = await api.writes
        XCTAssertEqual(writes, [.choice("ship"), .choice("ship")])
        XCTAssertEqual(call.phase, .answered)
    }

    func test_cancelled_edited_and_expired_sources_never_read_or_post() async throws {
        for changes: [String: Any] in [["status": "cancelled", "text": "", "choices": []],
                                      ["text": "Changed source"], ["expiresAt": "2020-01-01T00:00:00Z"],
                                      ["status": "answered", "answerActionId": questionAnswerID]] {
            let api = try stub(read: question(changes))
            let speaker = QuestionSpeaker(), audio = QuestionAudio()
            var ended = 0
            let call = try QuestionCallCoordinator(question: question(), api: api, listener: QuestionListener(),
                                                  speaker: speaker, audio: audio, now: { questionNow }, onEnded: { ended += 1 })
            await call.begin()
            await call.choose("ship")
            let writes = await api.writes
            XCTAssertEqual(ended, 1)
            XCTAssertTrue(speaker.spoken.isEmpty)
            XCTAssertTrue(writes.isEmpty)
            XCTAssertNil(call.question)
            XCTAssertFalse(audio.active)
        }
    }

    func test_hangup_while_reading_cannot_reopen_question() async throws {
        let api = try stub()
        await api.setHold(read: true)
        let speaker = QuestionSpeaker(), audio = QuestionAudio()
        let call = try QuestionCallCoordinator(question: question(), api: api, listener: QuestionListener(),
                                              speaker: speaker, audio: audio, now: { questionNow }, onEnded: {})
        let start = Task { await call.begin() }
        await until("read in flight") { await api.isReading }
        call.hangUp()
        await api.releaseRead()
        await start.value
        XCTAssertEqual(call.phase, .ended)
        XCTAssertTrue(speaker.spoken.isEmpty)
        XCTAssertFalse(audio.active)
    }

    func test_mute_discards_partial_voice_but_keeps_choices_available() async throws {
        let api = try stub()
        let listener = QuestionListener()
        let call = try QuestionCallCoordinator(question: question(), api: api, listener: listener,
                                              speaker: QuestionSpeaker(), audio: QuestionAudio(), now: { questionNow }, onEnded: {})
        await call.begin()
        await call.listen()
        listener.say("Do not post this partial")
        call.callScreenMuted(true)
        await call.finishSpeaking()
        XCTAssertEqual(call.partial, "")
        XCTAssertEqual(call.phase, .ready)
        await call.choose("wait")
        let writes = await api.writes
        XCTAssertEqual(writes, [.choice("wait")])
    }

    func test_refused_or_conflicting_answer_ends_without_retrying_or_claiming_success() async throws {
        for status in [401, 403, 404, 409, 410, 422] {
            let api = try stub(failures: [.refused(status)])
            let speaker = QuestionSpeaker()
            var notices: [String] = []
            let call = try QuestionCallCoordinator(question: question(), api: api, listener: QuestionListener(),
                                                  speaker: speaker, audio: QuestionAudio(), now: { questionNow },
                                                  onEnded: {}, onNotice: { notices.append($0) })
            await call.begin()
            await call.choose("ship")
            await call.retry()
            let writes = await api.writes
            XCTAssertEqual(writes.count, 1)
            XCTAssertEqual(call.phase, .ended)
            XCTAssertEqual(notices.count, 1)
            XCTAssertFalse(speaker.spoken.contains("Your answer is posted under the question."))
        }
    }
}
