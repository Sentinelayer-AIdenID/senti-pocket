import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// The fast voice line (API #1062), on the phone: its events, and a call that hears it.
final class VoiceLineEventReaderTests: XCTestCase {
    func test_sentences_then_done_are_read_at_their_data_lines_and_an_error_ends_it() {
        var reader = VoiceLineEventReader()
        XCTAssertEqual(reader.read("event: sentence"), .none)
        XCTAssertEqual(reader.read("data: {\"text\": \"Build 15 is on TestFlight.\"}"),
                       .event(.sentence("Build 15 is on TestFlight.")))
        XCTAssertEqual(reader.read(""), .none)
        XCTAssertEqual(reader.read("event: sentence\r"), .none, "a carriage return is tolerated")
        XCTAssertEqual(reader.read("data: {\"text\": \"  \"}"), .none, "an empty sentence says nothing")
        XCTAssertEqual(reader.read("event: done"), .none)
        XCTAssertEqual(reader.read("data: {\"speaker\": \"pocket-forge (voice)\", \"chars\": 26}"),
                       .event(.done(speaker: "pocket-forge (voice)")))
        XCTAssertEqual(reader.read("data: {\"text\": \"stray\"}"), .none, "data without its event is ignored")
        XCTAssertEqual(reader.read("event: error"), .none)
        XCTAssertEqual(reader.read("data: {\"code\": \"voice_unavailable\"}"), .failed)
    }

    /// Who answers a turn, in the shape agreed for the server's turn routing (Carter, 11-05): `turn_assigned` before any
    /// sound, then `turn_started` and `turn_ended`, around the sentences. Fields this phone does not know are ignored.
    func test_the_turns_events_are_read_around_the_sentences() {
        let fixture = """
        event: turn_assigned
        data: {"turnId":"turn_7f3a","agentId":"review-agent","displayName":"Reviewer","model":"fast","route":{"why":"named"}}

        event: turn_started
        data: {"turnId":"turn_7f3a","at":"2026-11-05T07:54:03Z"}

        event: sentence
        data: {"text":"The release is live."}

        event: turn_ended
        data: {"turnId":"turn_7f3a","chars":20}

        event: done
        data: {"speaker":"review-agent (voice)","chars":20}
        """
        var reader = VoiceLineEventReader()
        let events = fixture.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> VoiceLineEvent? in
            if case .event(let event) = reader.read(String(line)) { return event }
            return nil
        }
        XCTAssertEqual(events, [
            .turnAssigned(VoiceTurnAssignment(turnId: "turn_7f3a", agentId: "review-agent", displayName: "Reviewer")),
            .turnStarted(turnId: "turn_7f3a"),
            .sentence("The release is live."),
            .turnEnded(turnId: "turn_7f3a"),
            .done(speaker: "review-agent (voice)")
        ])
    }

    /// The server's turn events are new: one this phone cannot read is skipped, never taken for an error that ends the
    /// answer, and an event it does not know says nothing.
    func test_turn_events_it_cannot_read_are_skipped_and_never_end_the_answer() {
        func read(_ event: String, _ data: String) -> VoiceLineEventReader.Parsed {
            var reader = VoiceLineEventReader()
            _ = reader.read("event: \(event)")
            return reader.read("data: \(data)")
        }
        XCTAssertEqual(read("turn_assigned", #"{"turnId":"t2","agentId":"build-agent"}"#),
                       .event(.turnAssigned(VoiceTurnAssignment(turnId: "t2", agentId: "build-agent",
                                                                displayName: "build-agent"))),
                       "no name: the agent's id is shown")
        XCTAssertEqual(read("turn_assigned", #"{"turnId":"t3","agentId":"review-agent","displayName":"  Review\nagent  "}"#),
                       .event(.turnAssigned(VoiceTurnAssignment(turnId: "t3", agentId: "review-agent",
                                                                displayName: "Review agent"))),
                       "a name is one line")
        let long = String(repeating: "w", count: 90)
        XCTAssertEqual(read("turn_assigned", "{\"turnId\":\"t4\",\"agentId\":\"a1\",\"displayName\":\"\(long)\"}"),
                       .event(.turnAssigned(VoiceTurnAssignment(turnId: "t4", agentId: "a1",
                                                                displayName: String(repeating: "w", count: 60)))),
                       "a name is cut to 60 characters")
        let unreadable: [(String, String)] = [
            ("no turn", #"{"agentId":"review-agent"}"#),
            ("no agent", #"{"turnId":"t5"}"#),
            ("an empty agent", #"{"turnId":"t5","agentId":""}"#),
            ("a number for a turn", #"{"turnId":5,"agentId":"review-agent"}"#),
            ("a turn with a space", #"{"turnId":"t 5","agentId":"review-agent"}"#),
            ("not JSON", "turn t5 to the reviewer")
        ]
        for (name, data) in unreadable {
            XCTAssertEqual(read("turn_assigned", data), .none, name)
        }
        XCTAssertEqual(read("turn_started", "{}"), .event(.turnStarted(turnId: nil)),
                       "a start without its turn is the current answer's")
        XCTAssertEqual(read("turn_ended", "not JSON"), .event(.turnEnded(turnId: nil)))
        XCTAssertEqual(read("turn_reassigned", #"{"turnId":"t6","agentId":"build-agent"}"#), .none,
                       "an event this phone does not know says nothing")

        // The answer goes on after a turn event that was skipped.
        var reader = VoiceLineEventReader()
        _ = reader.read("event: turn_assigned")
        XCTAssertEqual(reader.read("data: {}"), .none)
        _ = reader.read("event: sentence")
        XCTAssertEqual(reader.read(#"data: {"text":"Still here."}"#), .event(.sentence("Still here.")))
    }
}

private final class FakeVoiceLine: VoiceLining, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<[String], VoiceLineError>]
    private(set) var asks: [(agentId: String?, text: String, ringCallId: String?, history: [VoiceLineHistory])] = []

    init(_ answers: [Result<[String], VoiceLineError>]) { self.answers = answers }

    var askCount: Int { lock.withLock { asks.count } }

    func voiceLine(sessionId: String, agentId: String?, text: String, callId: String, ringCallId: String?,
                   history: [VoiceLineHistory]) -> AsyncThrowingStream<VoiceLineEvent, Error> {
        let answer: Result<[String], VoiceLineError> = lock.withLock {
            asks.append((agentId, text, ringCallId, history))
            return answers.isEmpty ? .failure(.failed) : answers.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch answer {
            case .success(let sentences):
                for sentence in sentences { continuation.yield(.sentence(sentence)) }
                continuation.yield(.done(speaker: (agentId ?? "room") + " (voice)"))
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}

/// A voice line the test drives event by event: each ask's stream stays open until the test finishes it.
private final class ScriptedVoiceLine: VoiceLining, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [AsyncThrowingStream<VoiceLineEvent, Error>.Continuation] = []
    var askCount: Int { lock.withLock { streams.count } }

    func voiceLine(sessionId: String, agentId: String?, text: String, callId: String, ringCallId: String?,
                   history: [VoiceLineHistory]) -> AsyncThrowingStream<VoiceLineEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { streams.append(continuation) }
        }
    }

    /// These events on the latest ask's stream.
    func send(_ events: VoiceLineEvent...) {
        let stream = lock.withLock { streams.last }
        for event in events { stream?.yield(event) }
    }

    /// The latest ask's stream ends.
    func finish() {
        lock.withLock { streams.last }?.finish()
    }
}

/// A voice line whose answer waits until the test lets it go, so an agent's post can come first.
private final class GatedVoiceLine: VoiceLining, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [AsyncThrowingStream<VoiceLineEvent, Error>.Continuation] = []
    var askCount: Int { lock.withLock { held.count } }

    func voiceLine(sessionId: String, agentId: String?, text: String, callId: String, ringCallId: String?,
                   history: [VoiceLineHistory]) -> AsyncThrowingStream<VoiceLineEvent, Error> {
        AsyncThrowingStream { continuation in self.lock.withLock { self.held.append(continuation) } }
    }

    /// Lets the `index`th ask (0 = the first) answer with `sentences`, or fail (with `error`, or a plain failure).
    func release(_ index: Int, _ sentences: [String], failing: Bool = false, error: VoiceLineError? = nil) {
        guard let continuation = lock.withLock({ index < held.count ? held[index] : nil }) else { return }
        if let error { continuation.finish(throwing: error); return }
        if failing { continuation.finish(throwing: VoiceLineError.failed); return }
        for sentence in sentences { continuation.yield(.sentence(sentence)) }
        continuation.yield(.done(speaker: "pocket-forge (voice)"))
        continuation.finish()
    }
}

/// A voice line the test steps through, ask by ask: a sentence, then (later) a failure or the end.
private final class SteppedVoiceLine: VoiceLining, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [AsyncThrowingStream<VoiceLineEvent, Error>.Continuation] = []
    var askCount: Int { lock.withLock { held.count } }

    func voiceLine(sessionId: String, agentId: String?, text: String, callId: String, ringCallId: String?,
                   history: [VoiceLineHistory]) -> AsyncThrowingStream<VoiceLineEvent, Error> {
        AsyncThrowingStream { continuation in self.lock.withLock { self.held.append(continuation) } }
    }

    private func ask(_ index: Int) -> AsyncThrowingStream<VoiceLineEvent, Error>.Continuation? {
        lock.withLock { index < held.count ? held[index] : nil }
    }

    func say(_ index: Int, _ sentence: String) { ask(index)?.yield(.sentence(sentence)) }
    func fail(_ index: Int) { ask(index)?.finish(throwing: VoiceLineError.failed) }
    func end(_ index: Int) {
        ask(index)?.yield(.done(speaker: "pocket-forge (voice)"))
        ask(index)?.finish()
    }
}

/// A voice line whose answers ignore cancellation, like a request already on the wire: an ask a newer turn cancelled
/// can still come back, late, with an error.
private final class LateVoiceLine: VoiceLining, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<VoiceLineEvent?, Error>?] = []
    private var asks = 0
    var askCount: Int { lock.withLock { asks } }

    func voiceLine(sessionId: String, agentId: String?, text: String, callId: String, ringCallId: String?,
                   history: [VoiceLineHistory]) -> AsyncThrowingStream<VoiceLineEvent, Error> {
        let index = lock.withLock { () -> Int in asks += 1; waiting.append(nil); return asks - 1 }
        var sent = 0
        return AsyncThrowingStream(unfolding: { [self] in
            sent += 1
            if sent > 2 { return nil }
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { waiting[index] = continuation }
            }
        })
    }

    private func take(_ index: Int) -> CheckedContinuation<VoiceLineEvent?, Error>? {
        lock.withLock { () -> CheckedContinuation<VoiceLineEvent?, Error>? in
            defer { if index < waiting.count { waiting[index] = nil } }
            return index < waiting.count ? waiting[index] : nil
        }
    }

    func fail(_ index: Int, _ error: VoiceLineError) { take(index)?.resume(throwing: error) }

    /// One sentence, then (on the stream's next pull) the end.
    func answer(_ index: Int, _ sentence: String) {
        take(index)?.resume(returning: .sentence(sentence))
        Task {
            for _ in 0..<200 {
                if let next = take(index) { next.resume(returning: nil); return }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }
}

private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@MainActor
private final class LineListener: VoiceListening {
    var partial: (@MainActor (String) -> Void)?
    var said = ""
    func start(partial: @escaping @MainActor (String) -> Void) async throws { said = ""; self.partial = partial }
    func say(_ text: String) { said = text; partial?(text) }
    func stop() async -> String { partial = nil; return said }
    func cancel() { partial = nil }
}

@MainActor
private final class LineSpeaker: VoiceSpeaking {
    var spoken: [(text: String, speaker: String)] = []
    var finished: (@MainActor () -> Void)?
    func speak(_ markdown: String, as speaker: String, finished: @escaping @MainActor () -> Void) {
        spoken.append((markdown, speaker))
        self.finished = finished
    }
    func finish() { let done = finished; finished = nil; done?() }
    func stop() { finished = nil }
}

@MainActor
private final class LineAudio: VoiceRoomAudioSession {
    func activate() throws {}
    func deactivate() {}
    var isSpeakerOn: Bool { true }
    func setSpeaker(_ on: Bool) throws {}
    func watchRoute(_ changed: @escaping @MainActor () -> Void) {}
}

private final class LinePoster: VoiceRoomPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _uploads: [String] = []
    var uploads: [String] { lock.withLock { _uploads } }
    func postCallStarted(sessionId: String, text: String, clientId: String) async throws {}
    func postVoiceTurn(sessionId: String, text: String, clientId: String) async throws {}
    func uploadTranscript(sessionId: String, filename: String, markdown: String, clientId: String) async throws -> VoiceTranscriptAttachment {
        lock.withLock { _uploads.append(markdown) }
        return VoiceTranscriptAttachment(attachmentId: "att-1", filename: filename, kind: "text", contentType: "text/markdown",
                                         sizeBytes: markdown.utf8.count, status: "ready")
    }
    func postCallEnded(sessionId: String, text: String, transcript: VoiceTranscriptAttachment?, clientId: String) async throws {}
}

/// Rings at once; an add waits until the test lets it go, then fails.
private final class SlowFailingAddPoster: VoiceRoomPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var released = false
    func release() { lock.withLock { released = true } }
    func postCallStarted(sessionId: String, text: String, clientId: String) async throws {
        let count = lock.withLock { () -> Int in starts += 1; return starts }
        guard count > 1 else { return }
        while !lock.withLock({ released }) { try? await Task.sleep(nanoseconds: 2_000_000) }
        throw URLError(.notConnectedToInternet)
    }
    func postVoiceTurn(sessionId: String, text: String, clientId: String) async throws {}
    func uploadTranscript(sessionId: String, filename: String, markdown: String, clientId: String) async throws -> VoiceTranscriptAttachment {
        VoiceTranscriptAttachment(attachmentId: "att-1", filename: filename, kind: "text", contentType: "text/markdown",
                                  sizeBytes: markdown.utf8.count, status: "ready")
    }
    func postCallEnded(sessionId: String, text: String, transcript: VoiceTranscriptAttachment?, clientId: String) async throws {}
}

/// The microphone's level on the test's clock, as the audio tap gives it: a level every 50 ms.
@MainActor
private struct LineMicrophone {
    static let step: TimeInterval = 0.05
    let room: VoiceRoomCoordinator
    let clock: ManualClock

    /// As loud as speech for `seconds`, ending on a loud level.
    func loud(for seconds: TimeInterval) {
        room.hear(level: 0.8)
        for _ in 0..<Int((seconds / Self.step).rounded()) {
            clock.advance(Self.step)
            room.hear(level: 0.8)
        }
    }

    /// Below speech for `seconds`.
    func quiet(for seconds: TimeInterval) {
        for _ in 0..<Int((seconds / Self.step).rounded()) {
            clock.advance(Self.step)
            room.hear(level: 0.1)
        }
    }
}

@MainActor
final class VoiceLineCallTests: XCTestCase {
    private func until(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    private func call(_ line: any VoiceLining, listener: LineListener, speaker: LineSpeaker, poster: LinePoster,
                      with agents: [String] = ["pocket-forge"], ringCallId: String? = nil, about: String? = nil,
                      now: @escaping @Sendable () -> Date = { Date() }) -> VoiceRoomCoordinator {
        let room = VoiceRoomCoordinator(sessionId: "room_line", with: agents, you: "mrrcarter",
                                        ownAuthorIds: ["human-mrrcarter"], listener: listener, speaker: speaker,
                                        audio: LineAudio(), poster: poster, voiceLine: line, ringCallId: ringCallId,
                                        about: about, now: now,
                                        sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) })
        room.send(.setHandsFree(false))
        return room
    }

    private func turn(_ room: VoiceRoomCoordinator, _ listener: LineListener, _ text: String) async {
        room.send(.toggleTalk)
        await until("listening") { listener.partial != nil }
        listener.say(text)
        room.send(.toggleTalk)
    }

    /// Each answer used to take 18 s. The voice line answers in its agent's voice, marked "(voice)".
    func test_a_turn_is_answered_by_the_voice_line_in_the_agents_voice_and_marked_as_the_voice_line() async {
        let line = FakeVoiceLine([.success(["Build 15 is on TestFlight.", "Calls ring first now."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin()
        await turn(room, listener, "What's new in the build?")
        await until("the first sentence is heard") { speaker.spoken.count == 1 }
        XCTAssertEqual(line.asks.first?.agentId, "pocket-forge")
        XCTAssertEqual(line.asks.first?.text, "What's new in the build?")
        XCTAssertNil(line.asks.first?.ringCallId, "a call you started is nobody's ring")
        XCTAssertEqual(speaker.spoken[0].speaker, "pocket-forge", "in the agent's own voice")
        XCTAssertEqual(room.state.speaker, "pocket-forge (voice)", "shown as the voice line")
        speaker.finish()
        await until("the second sentence") { speaker.spoken.count == 2 }
        speaker.finish()
        let quick = room.state.turns.filter { $0.speaker == "pocket-forge (voice)" }
        XCTAssertEqual(quick.map(\.text), ["Build 15 is on TestFlight. Calls ring first now."], "one answer in the transcript")
        XCTAssertNotNil(room.timings.percentile(.gap, 0.5), "the gap is measured to the voice line's first word")

        await room.hangUp()
        XCTAssertTrue(poster.uploads.first?.contains("Turns marked (voice) are the fast voice line") == true)
    }

    /// Who is answering (Carter, 11-05: you should see who is about to speak). The server assigns the turn before any
    /// sound; the call says "<name> is answering" from then until the answer ends, and the agent's face talks from the
    /// answer's first sound. Events for another turn change nothing.
    func test_the_call_shows_who_is_answering_from_the_assignment_until_the_answer_ends() async {
        let line = ScriptedVoiceLine()
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster, with: ["review-agent"])
        room.begin()
        await turn(room, listener, "What shipped tonight?")
        await until("asked") { line.askCount == 1 }
        XCTAssertNil(room.state.answeringLine)

        line.send(.turnAssigned(VoiceTurnAssignment(turnId: "t1", agentId: "review-agent", displayName: "Reviewer")))
        await until("assigned") { room.state.answering != nil }
        XCTAssertEqual(room.state.answeringLine, "Reviewer is answering", "named before any of the answer is heard")
        XCTAssertEqual(room.state.face, VoiceRoomFace(id: "review-agent", talks: false), "its face shows, still")
        XCTAssertTrue(speaker.spoken.isEmpty)

        line.send(.turnStarted(turnId: "another-turn"))
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(room.state.answering?.isSpeaking, false, "another turn's start is not this one's")
        line.send(.turnStarted(turnId: "t1"), .sentence("The release is live."))
        await until("heard") { speaker.spoken.count == 1 }
        XCTAssertEqual(room.state.face, VoiceRoomFace(id: "review-agent", talks: true), "its face talks with its voice")
        XCTAssertEqual(room.state.answeringLine, "Reviewer is answering")

        line.send(.turnEnded(turnId: "another-turn"))
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNotNil(room.state.answering, "another turn's end leaves this one")
        line.send(.turnEnded(turnId: "t1"))
        await until("ended") { room.state.answering == nil }
        XCTAssertNil(room.state.answeringLine)
        XCTAssertEqual(room.state.face, VoiceRoomFace(id: "review-agent", talks: true),
                       "still read aloud as the agent: its face stays while its words are said")
        speaker.finish()
        XCTAssertNil(room.state.face)
        await room.hangUp()
    }

    /// Nobody is left "answering" a turn that is gone: a new turn drops the last one's, and an answer whose stream ends
    /// without its `turn_ended` ends it too.
    func test_a_new_turn_or_an_answer_that_ends_without_its_end_clears_who_is_answering() async {
        let line = ScriptedVoiceLine()
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster, with: ["review-agent"])
        room.begin()
        await turn(room, listener, "First question?")
        await until("asked") { line.askCount == 1 }
        line.send(.turnAssigned(VoiceTurnAssignment(turnId: "t1", agentId: "review-agent", displayName: "Reviewer")))
        await until("assigned") { room.state.answering?.turnId == "t1" }

        await turn(room, listener, "Second question?")
        await until("asked again") { line.askCount == 2 }
        XCTAssertNil(room.state.answering, "the first turn's answer went with it")
        line.send(.turnAssigned(VoiceTurnAssignment(turnId: "t2", agentId: "review-agent", displayName: "Reviewer")))
        await until("assigned again") { room.state.answering?.turnId == "t2" }
        line.finish()
        await until("its stream ended") { room.state.answering == nil }
        await room.hangUp()
    }

    private func agentPost(_ id: String, _ text: String, in room: VoiceRoomCoordinator,
                           author: String = "pocket-forge") -> RoomMessage {
        let stamp = ISO8601DateFormatter().string(from: room.state.startedAt.addingTimeInterval(2))
        return RoomMessage(id: id, sequenceId: Int64(abs(id.hashValue % 100_000)) + 1, kind: .message, authorId: author,
                           authorName: author, isHuman: false, text: text, timestamp: stamp)
    }

    /// Carter heard every answer twice: the voice line spoke as the agent, then the agent's own post was read too.
    /// Now the voice line's answer is the one heard, and the agent's post is kept in the transcript, not read again.
    func test_when_the_voice_line_answered_the_turn_the_agents_post_is_kept_not_read_again() async {
        let line = FakeVoiceLine([.success(["Build 15 is on TestFlight."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin()
        await turn(room, listener, "What's new in the build?")
        await until("the voice line is heard") { speaker.spoken.count == 1 }
        speaker.finish()
        room.receive([agentPost("m1", "Build 15 is on TestFlight with the call fixes.", in: room)])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(speaker.spoken.map(\.text), ["Build 15 is on TestFlight."], "said once")
        XCTAssertEqual(room.state.turns.last?.text, "Build 15 is on TestFlight with the call fixes.", "kept in the transcript")
        XCTAssertEqual(room.state.turns.last?.isHeld, true)
        await room.hangUp()
        let transcript = poster.uploads.first ?? ""
        XCTAssertTrue(transcript.contains("not read: the voice line answered"), "the transcript says why it was not read")
        XCTAssertFalse(transcript.contains("another agent had the floor"))
    }

    /// The voice line owns the call's audio: an agent's post that comes first is kept as text, and the voice line's
    /// answer is the one heard.
    func test_an_agents_post_during_a_turn_is_kept_and_the_voice_line_is_heard() async {
        let line = GatedVoiceLine()
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin()
        await turn(room, listener, "What's new in the build?")
        await until("the voice line was asked") { line.askCount == 1 }
        room.receive([agentPost("m1", "Build 15 is out.", in: room)])
        line.release(0, ["Build 15 is on TestFlight."])
        await until("the voice line is heard") { speaker.spoken.count == 1 }
        XCTAssertEqual(speaker.spoken.map(\.text), ["Build 15 is on TestFlight."])
        speaker.finish()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(speaker.spoken.count, 1, "the post is not read")
        XCTAssertTrue(room.state.turns.contains { $0.text == "Build 15 is out." && $0.isHeld })
        await room.hangUp()
    }

    /// A slow post about turn A that lands during turn B never cancels or talks over B's answer.
    func test_a_late_post_about_an_earlier_turn_never_takes_the_newer_turns_voice() async {
        let line = GatedVoiceLine()
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin()
        await turn(room, listener, "Turn A?")
        await until("A asked") { line.askCount == 1 }
        line.release(0, ["Answer to A."])
        await until("A heard") { speaker.spoken.count == 1 }
        speaker.finish()
        await turn(room, listener, "Turn B?")
        await until("B asked") { line.askCount == 2 }
        room.receive([agentPost("late-a", "Late answer to A.", in: room)])
        line.release(1, ["Answer to B."])
        await until("B heard") { speaker.spoken.count == 2 }
        XCTAssertEqual(speaker.spoken.map(\.text), ["Answer to A.", "Answer to B."])
        speaker.finish()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(speaker.spoken.count, 2, "the late post is text only")
        XCTAssertTrue(room.state.turns.contains { $0.text == "Late answer to A." && $0.isHeld })
        await room.hangUp()
    }

    /// A turn whose voice line failed falls back to reading the agent's own answer, so the person still hears one.
    func test_when_the_voice_line_fails_for_a_turn_the_agents_post_is_read() async {
        let line = GatedVoiceLine()
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin()
        await turn(room, listener, "What's new?")
        await until("asked") { line.askCount == 1 }
        line.release(0, [], failing: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        room.receive([agentPost("m1", "Build 15 is out.", in: room)])
        await until("the agent is heard") { speaker.spoken.count == 1 }
        XCTAssertEqual(speaker.spoken.map(\.text), ["Build 15 is out."])
        await room.hangUp()
    }

    /// The agent's post can beat the voice line's failure (a slow network, a slow phone): it is held while the line may
    /// still answer, then read when the line fails, not left held and the turn silent.
    func test_an_agent_post_that_beats_the_voice_lines_failure_is_read_when_it_fails() async {
        for failing in [true, false] {
            let line = GatedVoiceLine()
            let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
            let room = call(line, listener: listener, speaker: speaker, poster: poster)
            room.begin()
            await turn(room, listener, "What's new?")
            await until("asked") { line.askCount == 1 }
            room.receive([agentPost("m1", "Build 15 is out.", in: room)])
            XCTAssertTrue(speaker.spoken.isEmpty, "held while the voice line may still answer")
            line.release(0, [], failing: failing)   // a failure, or an answer with no sentences
            await until("the agent is heard") { speaker.spoken.count == 1 }
            XCTAssertEqual(speaker.spoken.map(\.text), ["Build 15 is out."], "failing: \(failing)")
            XCTAssertEqual(room.state.turns.filter(\.isHeld).count, 0, "nothing left held")
            await room.hangUp()
        }
    }

    /// With two agents on the call the voice line used to answer every turn "as the room" while the agents waited.
    /// It now answers only as the agent a turn is for, and not at all when the turn is everyone's.
    func test_on_a_call_with_two_agents_the_voice_line_answers_only_as_the_agent_named() async {
        let line = FakeVoiceLine([.success(["Next up is the build."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster, with: ["claude-warden", "pocket-forge"])
        room.begin()
        room.receive([agentPost("h1", "Warden here.", in: room, author: "claude-warden"),
                      agentPost("h2", "Forge here.", in: room)])
        await until("both have said hello") { room.state.joined.count == 2 }
        speaker.finish()

        await turn(room, listener, "Who ships tonight?")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(line.askCount, 0, "a turn for everyone is not answered by the voice line")

        await turn(room, listener, "Forge, what's next?")
        await until("asked") { line.askCount == 1 }
        XCTAssertEqual(line.asks.first?.agentId, "pocket-forge")
        await until("heard") { speaker.spoken.contains { $0.text == "Next up is the build." } }
        XCTAssertEqual(speaker.spoken.first { $0.text == "Next up is the build." }?.speaker, "pocket-forge",
                       "in Forge's voice, never the room's")
        XCTAssertFalse(room.state.turns.contains { $0.speaker == "room (voice)" })
        await room.hangUp()
    }

    /// Review of the first cut: agents post well after the voice line. Forge's post for a turn the line answered as Forge
    /// comes during the next turn: it is kept (heard once already), and it does not take that turn's floor.
    func test_a_late_post_the_voice_line_already_answered_for_is_kept_and_takes_no_floor() async {
        let line = FakeVoiceLine([.success(["Next up is the build."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster, with: ["claude-warden", "pocket-forge"])
        room.begin()
        room.receive([agentPost("h1", "Warden here.", in: room, author: "claude-warden"),
                      agentPost("h2", "Forge here.", in: room)])
        await until("both have said hello") { room.state.joined.count == 2 }
        speaker.finish()

        await turn(room, listener, "Forge, what's next?")
        await until("the line answered as Forge") { speaker.spoken.contains { $0.text == "Next up is the build." } }
        speaker.finish()
        await turn(room, listener, "Who ships tonight?")
        try? await Task.sleep(nanoseconds: 30_000_000)
        room.receive([agentPost("f1", "Next up is the build, then QA.", in: room),
                      agentPost("w1", "I ship tonight.", in: room, author: "claude-warden")])
        await until("Warden is heard") { speaker.spoken.contains { $0.text == "I ship tonight." } }
        XCTAssertFalse(speaker.spoken.contains { $0.text == "Next up is the build, then QA." }, "heard once, from the line")
        XCTAssertTrue(room.state.turns.contains { $0.text == "Next up is the build, then QA." && $0.isHeld })
        await room.hangUp()
    }

    /// A call with two agents that have both said hello (the first one's hello is read, the second's kept).
    private func twoAgentCall(_ line: any VoiceLining, _ listener: LineListener, _ speaker: LineSpeaker,
                              _ poster: LinePoster) async -> VoiceRoomCoordinator {
        let room = call(line, listener: listener, speaker: speaker, poster: poster,
                        with: ["claude-warden", "pocket-forge"])
        room.begin()
        room.receive([agentPost("h1", "Warden here.", in: room, author: "claude-warden"),
                      agentPost("h2", "Forge here.", in: room)])
        await until("both have said hello") { room.state.joined.count == 2 }
        speaker.finish()
        return room
    }

    /// A meeting is everyone's: the voice line is never asked, and the agents' own answers are read.
    func test_a_meeting_never_asks_the_voice_line() async {
        let line = FakeVoiceLine([.success(["Hello room."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster, with: [])
        room.begin()
        await turn(room, listener, "Who ships tonight?")
        await until("turn kept") { room.state.turns.filter(\.isYou).count == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(line.askCount, 0, "a meeting does not ask the voice line")
        room.receive([agentPost("a1", "I do.", in: room, author: "review-agent")])
        await until("the agent is read") { speaker.spoken.contains { $0.text == "I do." } }
        XCTAssertFalse(room.state.turns.contains { $0.speaker.hasSuffix(VoiceRoomCoordinator.voiceSuffix) })
        await room.hangUp()
    }

    /// The line said a sentence as pocket-forge, the agent's own post came (the debt took it), then the line failed: an
    /// answer cut short is no answer, so the agent's post is read after all.
    func test_a_post_the_debt_took_is_read_when_the_line_then_fails() async {
        let line = SteppedVoiceLine()
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = await twoAgentCall(line, listener, speaker, poster)
        await turn(room, listener, "Forge, what's next?")
        await until("asked") { line.askCount == 1 }
        line.say(0, "Next up is")
        await until("first sentence heard") { speaker.spoken.contains { $0.text == "Next up is" } }
        speaker.finish()
        room.receive([agentPost("f1", "Next up is the build, then QA.", in: room)])
        XCTAssertTrue(room.state.answeredByLine.contains("msg:f1"), "taken by the debt while the line answers")
        line.fail(0)
        await until("the agent's post is read") {
            speaker.spoken.contains { $0.text == "Next up is the build, then QA." }
        }
        XCTAssertFalse(room.state.answeredByLine.contains("msg:f1"))
        await room.hangUp()
    }

    /// The line said a sentence as pocket-forge and failed before the agent posted: nothing is owed for that turn, so
    /// the agent's post, when it comes, is read.
    func test_when_the_line_fails_after_a_sentence_the_agents_post_is_read() async {
        let line = SteppedVoiceLine()
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = await twoAgentCall(line, listener, speaker, poster)
        await turn(room, listener, "Forge, what's next?")
        await until("asked") { line.askCount == 1 }
        line.say(0, "Next up is")
        await until("first sentence heard") { speaker.spoken.contains { $0.text == "Next up is" } }
        speaker.finish()
        line.fail(0)
        try? await Task.sleep(nanoseconds: 30_000_000)
        room.receive([agentPost("f1", "Next up is the build, then QA.", in: room)])
        await until("the agent's post is read") {
            speaker.spoken.contains { $0.text == "Next up is the build, then QA." }
        }
        await room.hangUp()
    }

    /// Two turns the line answered as pocket-forge owe two of its posts: both are kept when they come late, during an
    /// everyone-turn, and the other agent's answer to that turn, which comes first, is read (it owes nothing).
    func test_two_turns_the_line_answered_owe_two_posts() async {
        let line = FakeVoiceLine([.success(["Next up is the build."]), .success(["Then QA."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = await twoAgentCall(line, listener, speaker, poster)
        await turn(room, listener, "Forge, what's next?")
        await until("first heard") { speaker.spoken.contains { $0.text == "Next up is the build." } }
        speaker.finish()
        await turn(room, listener, "Forge, and after that?")
        await until("second heard") { speaker.spoken.contains { $0.text == "Then QA." } }
        speaker.finish()
        await turn(room, listener, "Who ships tonight?")
        await until("third turn kept") { room.state.turns.filter(\.isYou).count == 3 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        room.receive([agentPost("w3", "I ship tonight.", in: room, author: "claude-warden"),
                      agentPost("f1", "Next up is the build, as planned.", in: room),
                      agentPost("f2", "After that, QA.", in: room)])
        await until("the other agent is read") { speaker.spoken.contains { $0.text == "I ship tonight." } }
        let spoken = speaker.spoken.map(\.text)
        XCTAssertFalse(spoken.contains("Next up is the build, as planned."))
        XCTAssertFalse(spoken.contains("After that, QA."), "the line answered that turn already")
        XCTAssertTrue(room.state.answeredByLine.isSuperset(of: ["msg:f1", "msg:f2"]))
        await room.hangUp()
    }

    /// The agent's post for a turn came before the line's first sentence and was held for the line: the line owes
    /// nothing more for that turn, so the agent's answer to the next turn is read.
    func test_a_post_that_came_before_the_lines_answer_settles_the_turn() async {
        let line = GatedVoiceLine()
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = await twoAgentCall(line, listener, speaker, poster)
        await turn(room, listener, "Forge, what's next?")
        await until("asked") { line.askCount == 1 }
        room.receive([agentPost("f1", "Next up is the build.", in: room)])
        line.release(0, ["The build is next."])
        await until("line heard") { speaker.spoken.contains { $0.text == "The build is next." } }
        speaker.finish()
        XCTAssertFalse(speaker.spoken.contains { $0.text == "Next up is the build." }, "held for the line, not read")
        XCTAssertTrue(room.state.answeredByLine.contains("msg:f1"))
        await turn(room, listener, "Who ships tonight?")
        await until("second turn kept") { room.state.turns.filter(\.isYou).count == 2 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        room.receive([agentPost("f2", "I ship tonight.", in: room)])
        await until("its answer to the next turn is read") { speaker.spoken.contains { $0.text == "I ship tonight." } }
        await room.hangUp()
    }

    /// An add failed after a turn addressed the agent being added: the line spoke as that agent, so the call's other
    /// agent's post is read, not kept as answered by the line.
    func test_after_a_failed_add_only_the_agent_the_line_spoke_as_is_answered_by_it() async {
        let line = FakeVoiceLine([.success(["Welcome aboard."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = SlowFailingAddPoster()
        let room = VoiceRoomCoordinator(sessionId: "room_line", with: ["pocket-forge"], you: "mrrcarter",
                                        ownAuthorIds: ["human-mrrcarter"], listener: listener, speaker: speaker,
                                        audio: LineAudio(), poster: poster, voiceLine: line,
                                        sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) })
        room.send(.setHandsFree(false))
        room.begin(rings: false)
        room.receive([agentPost("h1", "Forge here.", in: room)])
        await until("hello") { speaker.spoken.count == 1 }
        speaker.finish()
        room.send(.add("claude-warden"))
        await turn(room, listener, "Warden, welcome to the call.")
        await until("line heard") { speaker.spoken.contains { $0.text == "Welcome aboard." } }
        XCTAssertEqual(line.asks.map(\.agentId), ["claude-warden"])
        speaker.finish()
        poster.release()
        await until("the add failed") { room.state.with == ["pocket-forge"] }
        room.receive([agentPost("f1", "Forge here, still on.", in: room)])
        await until("the other agent is read") { speaker.spoken.contains { $0.text == "Forge here, still on." } }
        XCTAssertFalse(room.state.answeredByLine.contains("msg:f1"))
        await room.hangUp()
    }

    /// The line owes an agent's post once per turn. A turn carried on is asked again as the same agent, and its second
    /// answer owes nothing more, whether the agent's post came before the carry-on or after it: the agent's answer to
    /// the next turn, everyone's, is read.
    func test_a_turn_carried_on_owes_the_agents_post_once() async {
        for postsBeforeCarryOn in [false, true] {
            let clock = ManualClock()
            let line = SteppedVoiceLine()
            let listener = LineListener(), speaker = LineSpeaker()
            let room = VoiceRoomCoordinator(sessionId: "room_line", with: ["claude-warden", "pocket-forge"],
                                            you: "mrrcarter", ownAuthorIds: ["human-mrrcarter"], listener: listener,
                                            speaker: speaker, audio: LineAudio(), poster: LinePoster(), voiceLine: line,
                                            now: { clock.now },
                                            sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) })
            let microphone = LineMicrophone(room: room, clock: clock)
            let label = "posts before the carry-on: \(postsBeforeCarryOn)"
            room.begin(rings: false)
            await until("listening") { listener.partial != nil }
            room.receive([agentPost("h1", "Warden here.", in: room, author: "claude-warden"),
                          agentPost("h2", "Forge here.", in: room)])
            await until("a hello is read") { speaker.spoken.count == 1 }
            speaker.finish()
            await until("listening again") { room.state.isListening && listener.partial != nil }

            microphone.loud(for: 0.4)
            listener.say("Forge, what's next?")
            microphone.quiet(for: VoiceRoomCoordinator.pauseAfterSentence + 0.1)
            await until("asked") { line.askCount == 1 }
            await until("still listening a moment") { room.state.isListening && listener.partial != nil }
            microphone.loud(for: 0.2)
            listener.say("And the tests?")
            line.say(0, "Next up is the build.")
            await until("the line answers as the agent") {
                room.state.turns.contains { $0.speaker == "pocket-forge" + VoiceRoomCoordinator.voiceSuffix }
            }
            if postsBeforeCarryOn { room.receive([agentPost("f1", "The build, then the tests.", in: room)]) }
            microphone.quiet(for: VoiceRoomCoordinator.pauseAfterSentence + 0.1)
            await until("asked again for the whole turn") { line.askCount == 2 }
            line.say(1, "The build, then the tests.")
            line.end(1)
            await until("its answer is heard") { speaker.spoken.contains { $0.text == "The build, then the tests." } }
            speaker.finish()
            if !postsBeforeCarryOn {
                room.receive([agentPost("f1", "The build, then the tests, as planned.", in: room)])
            }
            await until("listening for the next turn") { room.state.isListening && listener.partial != nil }

            microphone.loud(for: 0.4)
            listener.say("Who ships tonight?")
            microphone.quiet(for: VoiceRoomCoordinator.pauseAfterSentence + 0.1)
            await until("the next turn is kept") { room.state.turns.filter(\.isYou).count == 2 }
            XCTAssertEqual(line.askCount, 2, "\(label): everyone's turn is not asked")
            room.receive([agentPost("f3", "I ship tonight.", in: room)])
            await until("\(label): its answer to the next turn is read") {
                speaker.spoken.contains { $0.text == "I ship tonight." }
            }
            XCTAssertTrue(room.state.answeredByLine.contains("msg:f1"), label)
            await room.hangUp()
        }
    }

    /// An ask a newer turn cancelled can still come back with a typed error. It turns the line off or rests it, but it
    /// must not release the newer turn's held posts: that turn's own ask answers, and the post would be heard twice.
    func test_a_cancelled_asks_typed_error_never_releases_the_next_turns_held_post() async {
        let errors: [VoiceLineError] = [.unavailable, .notAllowed, .rateLimited(retryAfter: 1)]
        for error in errors {
            let line = LateVoiceLine()
            let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
            let room = call(line, listener: listener, speaker: speaker, poster: poster)
            room.begin()
            await turn(room, listener, "What's new?")
            await until("first ask") { line.askCount == 1 }
            await turn(room, listener, "And the build?")   // cancels the first ask
            await until("second ask") { line.askCount == 2 }
            room.receive([agentPost("m1", "Build 15 is out.", in: room)])
            line.fail(0, error)                             // the cancelled ask's error arrives late
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(speaker.spoken.isEmpty, "\(error): the newer turn's post stays held for its own ask")
            line.answer(1, "Build 15 shipped this morning.")
            await until("the second ask is heard") { speaker.spoken.count == 1 }
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(speaker.spoken.map(\.text), ["Build 15 shipped this morning."], "\(error): heard once")
            await room.hangUp()
        }
    }

    /// A turn sent while the line rests is never asked. If the rest ends before the agent's post comes, the post used
    /// to be held for an ask that was never made, and the turn went silent.
    func test_a_turn_sent_while_the_line_rests_reads_the_agents_post_after_the_rest_ends() async {
        let clock = ManualClock()
        let line = GatedVoiceLine()
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster, now: { clock.now })
        room.begin()
        await turn(room, listener, "What's new?")
        await until("asked") { line.askCount == 1 }
        line.release(0, [], error: .rateLimited(retryAfter: 30))
        try? await Task.sleep(nanoseconds: 30_000_000)
        await turn(room, listener, "And the build?")       // resting: not asked
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(line.askCount, 1, "not asked while resting")
        clock.advance(60)                                   // the rest is over before the post comes
        room.receive([agentPost("m2", "Build 15 is out.", in: room)])
        await until("the agent is heard") { speaker.spoken.count == 1 }
        XCTAssertEqual(speaker.spoken.map(\.text), ["Build 15 is out."])
        await room.hangUp()
    }

    /// A voice line that answered with no sentences said nothing, so the agent's post is read instead of silence.
    func test_a_voice_line_answer_with_no_sentences_falls_back_to_the_agents_post() async {
        let line = GatedVoiceLine()
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin()
        await turn(room, listener, "What's new?")
        await until("asked") { line.askCount == 1 }
        line.release(0, [])
        try? await Task.sleep(nanoseconds: 30_000_000)
        room.receive([agentPost("m1", "Build 15 is out.", in: room)])
        await until("the agent is heard") { speaker.spoken.count == 1 }
        XCTAssertEqual(speaker.spoken.map(\.text), ["Build 15 is out."])
        await room.hangUp()
    }

    /// Carter kept dialing busy agents and nobody answered. With the voice line on, the agent's fast voice picks up
    /// the ring in about 2 s as that agent; the agent's own hello, when it comes, is kept as text, not read again.
    func test_a_busy_agents_fast_voice_picks_up_the_ring_and_its_late_hello_is_kept_as_text() async {
        let line = FakeVoiceLine([])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin()
        for _ in 0..<250 where speaker.spoken.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(speaker.spoken.first?.text, "Hi, it's pocket-forge. Go ahead.")
        XCTAssertEqual(speaker.spoken.first?.speaker, "pocket-forge", "in the agent's own voice")
        XCTAssertFalse(room.state.isRinging)
        speaker.finish()
        room.receive([agentPost("hello", "Hi Carter, forge here.", in: room)])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(speaker.spoken.count, 1, "the agent's own hello is not read again")
        XCTAssertTrue(room.state.turns.contains { $0.text == "Hi Carter, forge here." && $0.isHeld })
        await room.hangUp()
    }

    /// An agent can call you with its reason and what it needs, and talk you through it. Answering an agent's call, the
    /// quick answers are asked with that call, whose reason and brief the server reads; the screen says what it is
    /// about until someone speaks.
    func test_answering_an_agents_call_asks_the_voice_line_with_that_call() async {
        let line = FakeVoiceLine([.success(["I need your yes on the release."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster,
                        ringCallId: "8c2f6c4e-2d7a-4a8e-9a43-0f1d2b3c4d5e", about: "The release needs your yes")
        XCTAssertEqual(room.state.about, "The release needs your yes")
        let blank = VoiceRoomCoordinator(sessionId: "r", with: ["a"], you: "me", ownAuthorIds: [], listener: LineListener(),
                                         speaker: LineSpeaker(), audio: LineAudio(), poster: LinePoster(), about: "   ")
        XCTAssertNil(blank.state.about, "a blank reason says nothing")
        room.begin(rings: false)
        await turn(room, listener, "What do you need?")
        await until("asked") { line.askCount == 1 }
        XCTAssertEqual(line.asks.first?.ringCallId, "8c2f6c4e-2d7a-4a8e-9a43-0f1d2b3c4d5e")
        await room.hangUp()
    }

    func test_without_a_voice_line_on_the_server_the_call_stops_asking() async {
        let line = FakeVoiceLine([.failure(.unavailable)])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin()
        await turn(room, listener, "Status?")
        await until("asked once") { line.askCount == 1 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await turn(room, listener, "Anything else?")
        await until("the second turn is kept") { room.state.turns.filter(\.isYou).count == 2 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(line.askCount, 1, "no more asks once the server says it has none")
        XCTAssertTrue(speaker.spoken.isEmpty)
        await room.hangUp()
    }
}

/// Answers with one sentence and keeps streaming until the call lets it go.
private final class StreamingVoiceLine: VoiceLining, @unchecked Sendable {
    private let lock = NSLock()
    private var _stopped = false
    var stopped: Bool { lock.withLock { _stopped } }

    func voiceLine(sessionId: String, agentId: String?, text: String, callId: String, ringCallId: String?,
                   history: [VoiceLineHistory]) -> AsyncThrowingStream<VoiceLineEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.sentence("The room is busy right now."))
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?._stopped = true } }
        }
    }
}

private final class EndPoster: VoiceRoomPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _endings: [String] = []
    var endings: [String] { lock.withLock { _endings } }
    func postCallStarted(sessionId: String, text: String, clientId: String) async throws {}
    func postVoiceTurn(sessionId: String, text: String, clientId: String) async throws {}
    func uploadTranscript(sessionId: String, filename: String, markdown: String, clientId: String) async throws -> VoiceTranscriptAttachment {
        VoiceTranscriptAttachment(attachmentId: "att-1", filename: filename, kind: "text", contentType: "text/markdown",
                                  sizeBytes: markdown.utf8.count, status: "ready")
    }
    func postCallEnded(sessionId: String, text: String, transcript: VoiceTranscriptAttachment?, clientId: String) async throws {
        lock.withLock { _endings.append(text) }
    }
}

/// Warden (#274): hang-up stops a quick answer still streaming, and a meeting's end never asks the voice line for a
/// summary.
@MainActor
final class VoiceLineHangUpTests: XCTestCase {
    func test_hanging_up_stops_the_stream_and_the_end_does_not_ask_the_voice_line_to_sum_up() async {
        let line = StreamingVoiceLine(), listener = LineListener(), speaker = LineSpeaker(), poster = EndPoster()
        // The voice line answers as the call's one agent (it never speaks for "the room" any more).
        let room = VoiceRoomCoordinator(sessionId: "room_call", with: ["pocket-forge"], you: "mrrcarter",
                                        ownAuthorIds: ["human-mrrcarter"], listener: listener, speaker: speaker,
                                        audio: LineAudio(), poster: poster, voiceLine: line,
                                        sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) })
        room.send(.setHandsFree(false))
        room.begin(rings: false)
        room.send(.toggleTalk)
        for _ in 0..<200 where listener.partial == nil { try? await Task.sleep(nanoseconds: 2_000_000) }
        listener.say("Who is working on the build?")
        room.send(.toggleTalk)
        for _ in 0..<400 where speaker.spoken.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(room.state.speaker, "pocket-forge (voice)")
        XCTAssertFalse(line.stopped)
        await room.hangUp()
        for _ in 0..<200 where !line.stopped { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(line.stopped, "the stream ends with the call")
        XCTAssertTrue(poster.endings.first?.contains("@pocket-forge") == true, "the end asks the agent itself")
        XCTAssertFalse(poster.endings.first?.contains("(voice)") == true, poster.endings.first ?? "")
    }
}

private final class FakeEndpointer: VoiceEndpointing, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: Result<Double, VoiceLineError>
    private var _asked: [String] = []
    var asked: [String] { lock.withLock { _asked } }

    init(_ answer: Result<Double, VoiceLineError>) { self.answer = answer }

    func finished(sessionId: String, text: String, callId: String) async throws -> Double {
        lock.withLock { _asked.append(text) }
        return try answer.get()
    }
}

private final class TurnPoster: VoiceRoomPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _turns: [String] = []
    var turns: [String] { lock.withLock { _turns } }
    func postCallStarted(sessionId: String, text: String, clientId: String) async throws {}
    func postVoiceTurn(sessionId: String, text: String, clientId: String) async throws { lock.withLock { _turns.append(text) } }
    func uploadTranscript(sessionId: String, filename: String, markdown: String, clientId: String) async throws -> VoiceTranscriptAttachment {
        VoiceTranscriptAttachment(attachmentId: "att-1", filename: filename, kind: "text", contentType: "text/markdown",
                                  sizeBytes: markdown.utf8.count, status: "ready")
    }
    func postCallEnded(sessionId: String, text: String, transcript: VoiceTranscriptAttachment?, clientId: String) async throws {}
}

/// A finished turn should go within about 600 ms. A short pause asks whether the turn is over; a sure yes ends it at
/// once, anything else leaves the normal pause in charge.
@MainActor
final class VoiceEndpointingTests: XCTestCase {
    private func listening(_ endpointer: FakeEndpointer, _ listener: LineListener, _ poster: TurnPoster) async -> VoiceRoomCoordinator {
        let room = VoiceRoomCoordinator(sessionId: "room_endpoint", with: ["pocket-forge"], you: "mrrcarter",
                                        ownAuthorIds: ["human-mrrcarter"], listener: listener, speaker: LineSpeaker(),
                                        audio: LineAudio(), poster: poster, endpointer: endpointer,
                                        sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) })
        room.begin(rings: false)
        for _ in 0..<200 where listener.partial == nil { try? await Task.sleep(nanoseconds: 2_000_000) }
        return room
    }

    func test_a_finished_turn_ends_on_a_short_pause() async {
        let endpointer = FakeEndpointer(.success(0.95)), listener = LineListener(), poster = TurnPoster()
        let room = await listening(endpointer, listener, poster)
        let said = Date()
        listener.say("Ship it tonight")
        for _ in 0..<400 where poster.turns.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(poster.turns, ["@pocket-forge Ship it tonight"])
        XCTAssertLessThan(Date().timeIntervalSince(said), VoiceRoomCoordinator.pauseEndsTurn - 0.3,
                          "well before the 1.4 s pause")
        XCTAssertEqual(endpointer.asked, ["Ship it tonight"], "one pause is asked about once")
        XCTAssertEqual(room.timings.endedEarly, 1)
        await room.hangUp()
    }

    /// Warden (#276): the recognizer can lag the voice; a sure 'finished' never ends a turn while the microphone still
    /// hears speech.
    func test_a_finished_answer_waits_while_the_microphone_still_hears_speech() async {
        let endpointer = FakeEndpointer(.success(0.95)), listener = LineListener(), poster = TurnPoster()
        let room = await listening(endpointer, listener, poster)
        listener.say("I want to")
        let loud = Task { @MainActor in
            for _ in 0..<8 {
                room.hear(level: 0.8)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(poster.turns.isEmpty, "still talking: not ended early")
        await loud.value
        for _ in 0..<400 where poster.turns.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(poster.turns.count, 1, "the normal pause ends it")
        await room.hangUp()
    }

    func test_an_unsure_answer_leaves_the_normal_pause_in_charge() async {
        let endpointer = FakeEndpointer(.success(0.4)), listener = LineListener(), poster = TurnPoster()
        let room = await listening(endpointer, listener, poster)
        listener.say("Can you add the new tester and then")
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(poster.turns.isEmpty, "not ended on the short pause")
        XCTAssertEqual(endpointer.asked.count, 1)
        for _ in 0..<400 where poster.turns.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(poster.turns.count, 1, "the normal pause still ends it")
        XCTAssertEqual(room.timings.endedEarly, 0)
        await room.hangUp()
    }

    func test_without_endpointing_on_the_server_the_call_stops_asking() async {
        let endpointer = FakeEndpointer(.failure(.unavailable)), listener = LineListener(), poster = TurnPoster()
        let room = await listening(endpointer, listener, poster)
        listener.say("Status please")
        for _ in 0..<400 where poster.turns.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(endpointer.asked.count, 1)
        // Hands-free, listening stays on a moment after the turn: the next words are heard there.
        for _ in 0..<200 where listener.partial == nil { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNotNil(listener.partial, "listening again after the turn")
        listener.say("And one more thing")
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(endpointer.asked.count, 1, "asked once, then never again in this call")
        await room.hangUp()
    }
}

/// Answers each voice turn with the next status in line, and keeps every body it was sent.
private final class VoiceTurnURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var statuses: [Int] = []
    private static var bodies: [[String: Any]] = []

    static func reset(statuses: [Int]) {
        lock.withLock {
            self.statuses = statuses
            bodies = []
        }
    }

    static func sent() -> [[String: Any]] { lock.withLock { bodies } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
        }
        let status: Int = Self.lock.withLock {
            Self.bodies.append((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
            return Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let events = status == 200
            ? "event: sentence\ndata: {\"text\": \"Yes.\"}\n\nevent: done\ndata: {\"speaker\": \"pocket-forge (voice)\", \"chars\": 4}\n\n"
            : "{}"
        client?.urlProtocol(self, didLoad: Data(events.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The voice turn as the server is asked it.
final class VoiceLineRequestTests: XCTestCase {
    private func sender() -> HTTPRoomMessageSender {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceTurnURLProtocol.self]
        return HTTPRoomMessageSender(apiBaseURL: URL(string: "https://api.example.invalid"),
                                     urlSession: URLSession(configuration: configuration),
                                     tokenProvider: { "test-bearer-token" })
    }

    private func sentences(ringCallId: String?) async throws -> [String] {
        var heard: [String] = []
        let stream = sender().voiceLine(sessionId: "room-1", agentId: "Pocket-Forge", text: "Status?",
                                        callId: "4f1c2d3e-5a6b-4c7d-8e9f-0a1b2c3d4e5f", ringCallId: ringCallId, history: [])
        for try await event in stream {
            if case .sentence(let text) = event { heard.append(text) }
        }
        return heard
    }

    func test_an_answered_call_rides_along_and_a_call_you_started_sends_none() async throws {
        VoiceTurnURLProtocol.reset(statuses: [200])
        let heard = try await sentences(ringCallId: "ring-1")
        XCTAssertEqual(heard, ["Yes."])
        XCTAssertEqual(VoiceTurnURLProtocol.sent().first?["ringCallId"] as? String, "ring-1")
        XCTAssertEqual(VoiceTurnURLProtocol.sent().first?["agentId"] as? String, "pocket-forge")

        VoiceTurnURLProtocol.reset(statuses: [200])
        _ = try await sentences(ringCallId: nil)
        XCTAssertNil(VoiceTurnURLProtocol.sent().first?["ringCallId"], "no key at all, so an older server takes it")
    }

    /// A refused turn that names a call (422 can be the call's own refusal, not an older server) fails as it is: it is
    /// never asked again with the call stripped off.
    func test_a_refused_turn_that_names_a_call_fails_and_is_not_asked_again_without_it() async throws {
        for ringCallId in ["ring-1", nil] as [String?] {
            VoiceTurnURLProtocol.reset(statuses: [422, 200])
            do {
                _ = try await sentences(ringCallId: ringCallId)
                XCTFail("a refused turn fails")
            } catch {
                XCTAssertEqual(error as? VoiceLineError, .failed)
            }
            let sent = VoiceTurnURLProtocol.sent()
            XCTAssertEqual(sent.count, 1, "asked once")
            XCTAssertEqual(sent.first?["ringCallId"] as? String, ringCallId)
        }
    }
}
