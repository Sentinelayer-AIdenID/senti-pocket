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
    /// The call's clock: time moves only when a test moves it.
    private let clock = ManualClock()

    private func until(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    /// Long enough for the call's own waits to notice the time a test moved on.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    private func call(_ line: any VoiceLining, listener: LineListener, speaker: LineSpeaker, poster: LinePoster,
                      with agents: [String] = ["pocket-forge"], ringCallId: String? = nil,
                      about: String? = nil) -> VoiceRoomCoordinator {
        let clock = self.clock
        let room = VoiceRoomCoordinator(sessionId: "room_line", with: agents, you: "mrrcarter",
                                        ownAuthorIds: ["human-mrrcarter"], listener: listener, speaker: speaker,
                                        audio: LineAudio(), poster: poster, voiceLine: line, ringCallId: ringCallId,
                                        about: about, now: { clock.now },
                                        // Time moves only when a test moves it; the call's waits just poll.
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

    /// Your turns kept in the call so far.
    private func yours(_ room: VoiceRoomCoordinator) -> Int { room.state.turns.filter(\.isYou).count }

    private func agentPost(_ id: String, _ text: String, in room: VoiceRoomCoordinator,
                           author: String = "pocket-forge") -> RoomMessage {
        let stamp = ISO8601DateFormatter().string(from: room.state.startedAt.addingTimeInterval(2))
        return RoomMessage(id: id, sequenceId: Int64(abs(id.hashValue % 100_000)) + 1, kind: .message, authorId: author,
                           authorName: author, isHuman: false, text: text, timestamp: stamp)
    }

    // MARK: - One answer a turn

    /// Carter (ticket 13ec2d12): each turn was heard twice, the voice line answering as the agent and then the agent's
    /// own post. A turn for an agent is answered once, by its own post. The voice line, which has an answer ready, is
    /// never asked; while the agent writes, its fast voice says only the bridge.
    func test_a_turn_for_an_agent_gets_one_answer_its_own_post_and_never_the_voice_lines() async {
        let line = FakeVoiceLine([.success(["Build 15 is on TestFlight."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin(rings: false)
        await turn(room, listener, "What's new in the build?")
        await until("the turn is kept") { yours(room) == 1 }
        clock.advance(VoiceRoomCoordinator.bridgeAfter + 0.1)
        await until("the bridge") { speaker.spoken.count == 1 }
        speaker.finish()
        clock.advance(3)
        room.receive([agentPost("m1", "Build 15 is on TestFlight with the call fixes.", in: room)])
        await until("the agent's post") { speaker.spoken.count == 2 }
        XCTAssertEqual(room.state.speaker, "pocket-forge")
        speaker.finish()
        clock.advance(VoiceRoomCoordinator.givesUpAfter)
        await settle()
        XCTAssertEqual(speaker.spoken.map(\.text),
                       ["One moment, pocket-forge is answering.", "Build 15 is on TestFlight with the call fixes."],
                       "one answer, the agent's own, after a bridge that says nothing of it")
        XCTAssertEqual(line.askCount, 0, "the voice line is never asked for an agent's turn")
        XCTAssertFalse(speaker.spoken.contains { $0.text == "Build 15 is on TestFlight." })
        XCTAssertFalse(room.state.turns.contains { $0.speaker.hasSuffix(VoiceRoomCoordinator.voiceSuffix) })
        await room.hangUp()
        let transcript = poster.uploads.first ?? ""
        XCTAssertEqual(transcript.components(separatedBy: "Build 15 is on TestFlight with the call fixes.").count, 2,
                       "the answer once in the transcript")
        XCTAssertFalse(transcript.contains("(voice)"), transcript)
        XCTAssertFalse(transcript.contains("skipped"), transcript)
    }

    /// An answer that lands within a moment of the turn is read with nothing before it, and nothing is said after it.
    func test_an_answer_that_lands_within_a_moment_gets_no_bridge() async {
        let line = FakeVoiceLine([])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin(rings: false)
        await turn(room, listener, "Is the build up?")
        await until("the turn is kept") { yours(room) == 1 }
        clock.advance(VoiceRoomCoordinator.bridgeAfter - 0.5)
        await settle()
        XCTAssertTrue(speaker.spoken.isEmpty, "nothing yet")
        room.receive([agentPost("m1", "Yes, build 16 is up.", in: room)])
        await until("the answer") { speaker.spoken.count == 1 }
        speaker.finish()
        // Well past the bridge and the 20 s line, a second at a time.
        for _ in 0..<25 {
            clock.advance(1)
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        await settle()
        XCTAssertEqual(speaker.spoken.map(\.text), ["Yes, build 16 is up."], "no bridge, and nothing after the answer")
        XCTAssertEqual(line.askCount, 0)
        await room.hangUp()
    }

    /// The bridge says the agent is answering and nothing of the answer, in the agent's own voice, once a turn. It is
    /// the phone's own words: the voice line, which has an answer ready, is never asked, and it is not kept in the
    /// transcript.
    func test_the_bridge_is_said_once_in_the_agents_voice_and_carries_nothing_of_the_answer() async {
        let line = FakeVoiceLine([.success(["The release ships tonight at nine."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin(rings: false)
        await turn(room, listener, "When does the release ship?")
        await until("the turn is kept") { yours(room) == 1 }
        clock.advance(VoiceRoomCoordinator.bridgeAfter + 0.1)
        await until("the bridge") { speaker.spoken.count == 1 }
        XCTAssertEqual(speaker.spoken[0].text, "One moment, pocket-forge is answering.")
        XCTAssertEqual(speaker.spoken[0].speaker, "pocket-forge", "in the agent's own voice")
        XCTAssertEqual(room.state.speaker, "pocket-forge (voice)", "shown as its fast voice")
        speaker.finish()
        clock.advance(10)
        await settle()
        XCTAssertEqual(speaker.spoken.count, 1, "said once a turn")
        XCTAssertEqual(line.askCount, 0, "never asked of the voice line")
        for word in ["release", "ships", "tonight", "nine"] {
            XCTAssertFalse(speaker.spoken[0].text.lowercased().contains(word), "nothing of the answer: \(word)")
        }
        XCTAssertFalse(room.state.turns.contains { $0.text.contains("One moment") }, "not kept in the transcript")
        await room.hangUp()
    }

    /// No answer 20 s after the turn: the agent's fast voice says so, plainly, once. The answer, when it comes, is read
    /// once.
    func test_with_no_answer_by_20_s_its_fast_voice_says_so_and_the_late_answer_is_read_once() async {
        let line = FakeVoiceLine([])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin(rings: false)
        await turn(room, listener, "Can you check the deploy?")
        await until("the turn is kept") { yours(room) == 1 }
        clock.advance(VoiceRoomCoordinator.bridgeAfter + 0.1)
        await until("the bridge") { speaker.spoken.count == 1 }
        speaker.finish()
        clock.advance(VoiceRoomCoordinator.givesUpAfter - VoiceRoomCoordinator.bridgeAfter - 0.5)
        await settle()
        XCTAssertEqual(speaker.spoken.count, 1, "nothing more before 20 s")
        clock.advance(0.5)
        await until("no answer yet") { speaker.spoken.count == 2 }
        XCTAssertEqual(speaker.spoken[1].text, "pocket-forge hasn't answered yet.")
        XCTAssertEqual(speaker.spoken[1].speaker, "pocket-forge", "in the agent's own voice")
        speaker.finish()
        clock.advance(10)
        await settle()
        XCTAssertEqual(speaker.spoken.count, 2, "said once")
        room.receive([agentPost("m1", "The deploy is green.", in: room)])
        await until("the late answer") { speaker.spoken.count == 3 }
        speaker.finish()
        XCTAssertEqual(speaker.spoken.map(\.text), ["One moment, pocket-forge is answering.",
                                                    "pocket-forge hasn't answered yet.", "The deploy is green."])
        XCTAssertEqual(line.askCount, 0)
        await room.hangUp()
    }

    /// A bridge not yet said when your next turn goes is dropped with the rest of the last turn's leftovers, so what
    /// the fast voice says is about the turn going now (#274).
    func test_a_bridge_not_yet_said_when_your_next_turn_goes_is_never_said() async {
        let line = FakeVoiceLine([])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin(rings: false)
        let hello = "Forge here, ready when you are."
        room.receive([agentPost("h1", hello, in: room)])
        await until("the hello is read") { speaker.spoken.count == 1 }
        // Talked over, the hello is read again after the turn, and the turn's bridge waits behind it.
        await turn(room, listener, "What's new?")
        await until("the hello again") { speaker.spoken.count == 2 }
        clock.advance(VoiceRoomCoordinator.bridgeAfter + 0.1)
        await settle()
        XCTAssertEqual(speaker.spoken.count, 2, "the bridge waits while the hello is read")
        await turn(room, listener, "And the build?")
        await until("the hello a third time") { speaker.spoken.count == 3 }
        speaker.finish()
        await settle()
        XCTAssertEqual(speaker.spoken.map(\.text), [hello, hello, hello], "the first turn's bridge is never said")
        clock.advance(VoiceRoomCoordinator.bridgeAfter + 0.1)
        await until("this turn's bridge") { speaker.spoken.count == 4 }
        XCTAssertEqual(speaker.spoken.filter { $0.text == "One moment, pocket-forge is answering." }.count, 1)
        await room.hangUp()
    }

    // MARK: - Senti

    /// Each answer used to take 18 s. A turn for Senti, whose posts a call never reads, is answered by the voice line in
    /// Senti's voice, marked "(voice)".
    func test_a_turn_for_senti_is_answered_by_the_voice_line_in_its_voice_and_marked_as_the_voice_line() async {
        let line = FakeVoiceLine([.success(["Build 15 is on TestFlight.", "Calls ring first now."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster, with: ["senti"])
        room.begin()
        await turn(room, listener, "What's new in the build?")
        await until("the first sentence is heard") { speaker.spoken.count == 1 }
        XCTAssertEqual(line.asks.first?.agentId, "senti")
        XCTAssertEqual(line.asks.first?.text, "What's new in the build?")
        XCTAssertNil(line.asks.first?.ringCallId, "a call you started is nobody's ring")
        XCTAssertEqual(speaker.spoken[0].speaker, "senti", "in Senti's own voice")
        XCTAssertEqual(room.state.speaker, "senti (voice)", "shown as the voice line")
        speaker.finish()
        await until("the second sentence") { speaker.spoken.count == 2 }
        speaker.finish()
        let quick = room.state.turns.filter { $0.speaker == "senti (voice)" }
        XCTAssertEqual(quick.map(\.text), ["Build 15 is on TestFlight. Calls ring first now."], "one answer in the transcript")
        XCTAssertNotNil(room.timings.percentile(.gap, 0.5), "the gap is measured to the voice line's first word")

        await room.hangUp()
        XCTAssertTrue(poster.uploads.first?.contains("Turns marked (voice) are the fast voice line") == true)
    }

    /// A turn for Senti alone keeps the voice line's own answer, read once: no bridge, nothing at 20 s, and Senti's
    /// room post is never read after it.
    func test_a_turn_for_senti_alone_gets_the_voice_lines_answer_read_once() async {
        let line = FakeVoiceLine([.success(["Two builds shipped today."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster, with: ["senti"])
        room.begin(rings: false)
        await turn(room, listener, "What did I miss?")
        await until("Senti's answer") { speaker.spoken.count == 1 }
        speaker.finish()
        room.receive([agentPost("s1", "Two builds shipped today, and one is in review.", in: room, author: "senti")])
        clock.advance(VoiceRoomCoordinator.givesUpAfter + 1)
        await settle()
        XCTAssertEqual(speaker.spoken.map(\.text), ["Two builds shipped today."], "read once: no bridge, no second answer")
        XCTAssertEqual(speaker.spoken.first?.speaker, "senti")
        XCTAssertEqual(line.asks.map(\.agentId), ["senti"])
        await room.hangUp()
    }

    /// On a call with Senti and an agent, the turn for Senti is the voice line's to answer, and the turn for the agent
    /// is the agent's: the line is not asked for it, and its fast voice says only the bridge.
    func test_on_a_call_with_senti_and_an_agent_only_the_turn_for_senti_asks_the_voice_line() async {
        let line = FakeVoiceLine([.success(["Two builds shipped today."]), .success(["Next up is the build."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster, with: ["senti", "pocket-forge"])
        room.begin(rings: false)
        await turn(room, listener, "Senti, what did I miss?")
        await until("Senti's answer") { speaker.spoken.count == 1 }
        XCTAssertEqual(line.asks.map(\.agentId), ["senti"])
        speaker.finish()
        clock.advance(VoiceRoomCoordinator.givesUpAfter + 1)
        await settle()
        XCTAssertEqual(speaker.spoken.count, 1, "no bridge for the turn for Senti")

        await turn(room, listener, "Forge, what's next?")
        await until("the second turn is kept") { yours(room) == 2 }
        clock.advance(VoiceRoomCoordinator.bridgeAfter + 0.1)
        await until("the bridge") { speaker.spoken.count == 2 }
        XCTAssertEqual(speaker.spoken[1].text, "One moment, pocket-forge is answering.")
        XCTAssertEqual(speaker.spoken[1].speaker, "pocket-forge")
        speaker.finish()
        room.receive([agentPost("f1", "The build, then the tests.", in: room)])
        await until("the agent's post") { speaker.spoken.count == 3 }
        XCTAssertEqual(speaker.spoken.map(\.text),
                       ["Two builds shipped today.", "One moment, pocket-forge is answering.", "The build, then the tests."])
        XCTAssertEqual(line.askCount, 1, "the agent's turn never asks the voice line")
        await room.hangUp()
    }

    /// Senti can call you with its reason and what it needs, and talk you through it. Answering its call, the quick
    /// answers are asked with that call, whose reason and brief the server reads; the screen says what it is about until
    /// someone speaks.
    func test_answering_sentis_call_asks_the_voice_line_with_that_call() async {
        let line = FakeVoiceLine([.success(["I need your yes on the release."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster, with: ["senti"],
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
        let room = call(line, listener: listener, speaker: speaker, poster: poster, with: ["senti"])
        room.begin()
        await turn(room, listener, "Status?")
        await until("asked once") { line.askCount == 1 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await turn(room, listener, "Anything else?")
        await until("the second turn is kept") { yours(room) == 2 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(line.askCount, 1, "no more asks once the server says it has none")
        XCTAssertTrue(speaker.spoken.isEmpty)
        await room.hangUp()
    }

    // MARK: - Late answers, and the voice line failing

    /// A call with Senti and an agent, where a turn said to the agent went unanswered before a turn for Senti: the
    /// agent's answer to it is owed, and is read whenever it comes.
    private func sentiAfterAnUnansweredTurn(_ line: any VoiceLining, _ listener: LineListener, _ speaker: LineSpeaker,
                                            _ poster: LinePoster) async -> VoiceRoomCoordinator {
        let room = call(line, listener: listener, speaker: speaker, poster: poster, with: ["senti", "pocket-forge"])
        room.begin(rings: false)
        await turn(room, listener, "Forge, what's next?")
        await until("the agent's turn is kept") { yours(room) == 1 }
        await turn(room, listener, "Senti, any news?")
        await until("the turn for Senti is kept") { yours(room) == 2 }
        return room
    }

    /// The voice line said a sentence for Senti and failed before the agent's late answer came: nothing waits on it,
    /// so the answer is read when it comes.
    func test_a_late_answer_after_the_voice_line_failed_for_senti_is_read() async {
        let line = SteppedVoiceLine()
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = await sentiAfterAnUnansweredTurn(line, listener, speaker, poster)
        await until("asked as Senti") { line.askCount == 1 }
        line.say(0, "Nothing new")
        await until("Senti's first sentence") { speaker.spoken.count == 1 }
        speaker.finish()
        line.fail(0)
        try? await Task.sleep(nanoseconds: 30_000_000)
        room.receive([agentPost("f1", "Next up is the build, then QA.", in: room)])
        await until("the agent's late answer") { speaker.spoken.count == 2 }
        XCTAssertEqual(speaker.spoken.map(\.text), ["Nothing new", "Next up is the build, then QA."])
        XCTAssertFalse(room.state.turns.contains { $0.isHeld }, "a late answer is never held")
        await room.hangUp()
    }

    /// The agent's late answer can land before the voice line has said anything for Senti (a slow network, a slow
    /// phone): it waits while the line may still answer, then is read when the line fails or ends with nothing said,
    /// not left waiting.
    func test_a_late_answer_that_beats_the_voice_lines_failure_is_read_when_it_fails() async {
        for failing in [true, false] {
            let line = GatedVoiceLine()
            let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
            let room = await sentiAfterAnUnansweredTurn(line, listener, speaker, poster)
            await until("asked as Senti") { line.askCount == 1 }
            room.receive([agentPost("f1", "Next up is the build.", in: room)])
            try? await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertTrue(speaker.spoken.isEmpty, "failing: \(failing): waits while the voice line may still answer")
            line.release(0, [], failing: failing)   // a failure, or an answer with no sentences
            await until("the late answer") { speaker.spoken.count == 1 }
            XCTAssertEqual(speaker.spoken.map(\.text), ["Next up is the build."], "failing: \(failing)")
            XCTAssertEqual(room.state.turns.filter(\.isHeld).count, 0, "nothing left held")
            await room.hangUp()
        }
    }

    /// The line said a sentence for Senti, the agent's late answer came, then the line failed: the answer waits while
    /// the line is still answering, so it never cuts into Senti's answer, and is read once the line has failed.
    func test_a_late_answer_waits_for_sentis_answer_and_is_read_when_the_line_then_fails() async {
        let line = SteppedVoiceLine()
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = await sentiAfterAnUnansweredTurn(line, listener, speaker, poster)
        await until("asked as Senti") { line.askCount == 1 }
        line.say(0, "Nothing new")
        await until("Senti's first sentence") { speaker.spoken.count == 1 }
        speaker.finish()
        room.receive([agentPost("f1", "Next up is the build, then QA.", in: room)])
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(speaker.spoken.count, 1, "waits while the line is still answering")
        line.fail(0)
        await until("the agent's late answer is read") { speaker.spoken.count == 2 }
        XCTAssertEqual(speaker.spoken.map(\.text), ["Nothing new", "Next up is the build, then QA."])
        await room.hangUp()
    }

    /// An ask a newer turn cancelled can still come back with a typed error. It turns the line off or rests it, but it
    /// must not let a late answer go ahead of the newer turn's answer from the line: the late answer is read after it.
    func test_a_cancelled_asks_typed_error_never_releases_a_late_answer_early() async {
        let errors: [VoiceLineError] = [.unavailable, .notAllowed, .rateLimited(retryAfter: 1)]
        for error in errors {
            let line = LateVoiceLine()
            let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
            let room = await sentiAfterAnUnansweredTurn(line, listener, speaker, poster)
            await until("first ask") { line.askCount == 1 }
            await turn(room, listener, "Senti, and the build?")   // cancels the first ask
            await until("second ask") { line.askCount == 2 }
            room.receive([agentPost("f1", "Next up is the build.", in: room)])
            line.fail(0, error)                                   // the cancelled ask's error arrives late
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(speaker.spoken.isEmpty, "\(error): the late answer waits for the newer ask")
            line.answer(1, "Build 15 shipped this morning.")
            await until("the second ask is heard") { speaker.spoken.count == 1 }
            speaker.finish()
            await until("then the late answer") { speaker.spoken.count == 2 }
            XCTAssertEqual(speaker.spoken.map(\.text), ["Build 15 shipped this morning.", "Next up is the build."],
                           "\(error): each once, in order")
            await room.hangUp()
        }
    }

    /// A turn for Senti sent while the line rests is never asked. A late answer that comes after the rest ends used to
    /// wait for an ask that was never made, and the call went silent; it is read.
    func test_a_turn_sent_while_the_line_rests_leaves_no_late_answer_waiting() async {
        let line = GatedVoiceLine()
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = await sentiAfterAnUnansweredTurn(line, listener, speaker, poster)
        await until("asked") { line.askCount == 1 }
        line.release(0, [], error: .rateLimited(retryAfter: 30))
        try? await Task.sleep(nanoseconds: 30_000_000)
        await turn(room, listener, "Senti, and the build?")    // resting: not asked
        await until("the turn is kept") { yours(room) == 3 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(line.askCount, 1, "not asked while resting")
        clock.advance(60)                                       // the rest is over before the late answer comes
        room.receive([agentPost("f1", "Next up is the build.", in: room)])
        await until("the late answer is heard") { speaker.spoken.count == 1 }
        XCTAssertEqual(speaker.spoken.map(\.text), ["Next up is the build."])
        await room.hangUp()
    }

    // MARK: - Several agents

    /// A call with two agents that have both said hello (the first one's hello is read, the second's kept).
    private func twoAgentCall(_ line: any VoiceLining, _ listener: LineListener, _ speaker: LineSpeaker,
                              _ poster: LinePoster) async -> VoiceRoomCoordinator {
        let room = call(line, listener: listener, speaker: speaker, poster: poster, with: ["ada", "pocket-forge"])
        room.begin(rings: false)
        room.receive([agentPost("h1", "Ada here.", in: room, author: "ada"),
                      agentPost("h2", "Forge here.", in: room)])
        await until("both have said hello") { room.state.joined.count == 2 }
        speaker.finish()
        return room
    }

    /// With two agents on the call the voice line used to answer every turn "as the room" while the agents waited. A
    /// turn for everyone gets neither the voice line nor a bridge: the agents' own answers are read.
    func test_on_a_call_with_two_agents_a_turn_for_everyone_gets_no_voice_line_and_no_bridge() async {
        let line = FakeVoiceLine([.success(["Next up is the build."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = await twoAgentCall(line, listener, speaker, poster)
        await turn(room, listener, "Who ships tonight?")
        await until("the turn is kept") { yours(room) == 1 }
        clock.advance(VoiceRoomCoordinator.givesUpAfter + 1)
        await settle()
        XCTAssertEqual(line.askCount, 0, "a turn for everyone is not answered by the voice line")
        XCTAssertEqual(speaker.spoken.count, 1, "only the hello: no bridge for a turn for everyone")
        room.receive([agentPost("a1", "I do.", in: room, author: "ada")])
        await until("the agent's answer") { speaker.spoken.last?.text == "I do." }
        XCTAssertFalse(room.state.turns.contains { $0.speaker == "room (voice)" })
        await room.hangUp()
    }

    /// Agents can take longer than a turn. Forge's answer to a turn said to it comes during the next turn: it is read,
    /// once, and takes no floor from that turn's answer.
    func test_a_late_answer_to_a_turn_said_to_the_agent_is_read_and_takes_no_floor() async {
        let line = FakeVoiceLine([])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = await twoAgentCall(line, listener, speaker, poster)
        await turn(room, listener, "Forge, what's next?")
        await until("the first turn is kept") { yours(room) == 1 }
        clock.advance(VoiceRoomCoordinator.bridgeAfter + 0.1)
        await until("the bridge") { speaker.spoken.last?.text == "One moment, pocket-forge is answering." }
        speaker.finish()
        await turn(room, listener, "Who ships tonight?")
        await until("the second turn is kept") { yours(room) == 2 }
        room.receive([agentPost("f1", "Next up is the build, then QA.", in: room),
                      agentPost("a1", "I ship tonight.", in: room, author: "ada")])
        await until("Forge's late answer") { speaker.spoken.last?.text == "Next up is the build, then QA." }
        speaker.finish()
        await until("Ada is heard") { speaker.spoken.last?.text == "I ship tonight." }
        XCTAssertFalse(room.state.turns.contains { ($0.id == "msg:f1" || $0.id == "msg:a1") && $0.isHeld },
                       "Forge's late answer took no floor from Ada's answer")
        XCTAssertEqual(speaker.spoken.filter { $0.text == "Next up is the build, then QA." }.count, 1)
        XCTAssertEqual(line.askCount, 0)
        await room.hangUp()
    }

    /// A meeting is everyone's: the voice line is never asked, nothing is said while the agents write, and the agents'
    /// own answers are read.
    func test_a_meeting_never_asks_the_voice_line() async {
        let line = FakeVoiceLine([.success(["Hello room."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster, with: [])
        room.begin()
        await turn(room, listener, "Who ships tonight?")
        await until("turn kept") { yours(room) == 1 }
        clock.advance(VoiceRoomCoordinator.givesUpAfter + 1)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(line.askCount, 0, "a meeting does not ask the voice line")
        XCTAssertTrue(speaker.spoken.isEmpty, "and nothing is said for it while the agents write")
        room.receive([agentPost("a1", "I do.", in: room, author: "review-agent")])
        await until("the agent is read") { speaker.spoken.contains { $0.text == "I do." } }
        XCTAssertFalse(room.state.turns.contains { $0.speaker.hasSuffix(VoiceRoomCoordinator.voiceSuffix) })
        await room.hangUp()
    }

    /// Two turns said to Forge that it had not answered when the next went owe two of its posts: both are read as late
    /// answers when they come, during a turn for everyone, after the other agent's answer to that turn, which came
    /// first and owes nothing.
    func test_two_turns_the_agent_had_not_answered_owe_two_posts() async {
        let line = FakeVoiceLine([])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = await twoAgentCall(line, listener, speaker, poster)
        await turn(room, listener, "Forge, what's next?")
        await until("first turn kept") { yours(room) == 1 }
        await turn(room, listener, "Forge, and after that?")
        await until("second turn kept") { yours(room) == 2 }
        await turn(room, listener, "Who ships tonight?")
        await until("third turn kept") { yours(room) == 3 }
        room.receive([agentPost("a3", "I ship tonight.", in: room, author: "ada"),
                      agentPost("f1", "Next up is the build, as planned.", in: room),
                      agentPost("f2", "After that, QA.", in: room)])
        await until("the other agent is read") { speaker.spoken.last?.text == "I ship tonight." }
        speaker.finish()
        await until("the first owed post") { speaker.spoken.last?.text == "Next up is the build, as planned." }
        speaker.finish()
        await until("the second, in the same batch") { speaker.spoken.last?.text == "After that, QA." }
        XCTAssertFalse(room.state.turns.contains { ["msg:a3", "msg:f1", "msg:f2"].contains($0.id) && $0.isHeld },
                       "the owed posts took no floor, and none was held")
        XCTAssertEqual(line.askCount, 0)
        await room.hangUp()
    }

    /// Forge's answer came during the turn said to it, so nothing is owed for that turn: its answer to the next turn,
    /// one for everyone, is that turn's answer and takes its floor.
    func test_an_answer_during_the_turn_said_to_the_agent_settles_that_turn() async {
        let line = FakeVoiceLine([])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = await twoAgentCall(line, listener, speaker, poster)
        await turn(room, listener, "Forge, what's next?")
        await until("first turn kept") { yours(room) == 1 }
        room.receive([agentPost("f1", "Next up is the build.", in: room)])
        await until("its answer") { speaker.spoken.last?.text == "Next up is the build." }
        speaker.finish()
        await turn(room, listener, "Who ships tonight?")
        await until("second turn kept") { yours(room) == 2 }
        room.receive([agentPost("f2", "I ship tonight.", in: room),
                      agentPost("a2", "Me too.", in: room, author: "ada")])
        await until("its answer to the next turn is read") { speaker.spoken.last?.text == "I ship tonight." }
        XCTAssertTrue(room.state.turns.contains { $0.id == "msg:a2" && $0.isHeld },
                      "Forge's answer has this turn's floor: nothing more was owed")
        await room.hangUp()
    }

    /// An add failed after a turn addressed the agent being added: the voice line is never asked as it, its fast voice
    /// says nothing for it once it has left, and the call's other agent's post is read.
    func test_after_a_failed_add_nothing_is_said_for_the_agent_that_left() async {
        let line = FakeVoiceLine([.success(["Welcome aboard."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = SlowFailingAddPoster()
        let clock = self.clock
        let room = VoiceRoomCoordinator(sessionId: "room_line", with: ["pocket-forge"], you: "mrrcarter",
                                        ownAuthorIds: ["human-mrrcarter"], listener: listener, speaker: speaker,
                                        audio: LineAudio(), poster: poster, voiceLine: line, now: { clock.now },
                                        sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) })
        room.send(.setHandsFree(false))
        room.begin(rings: false)
        room.receive([agentPost("h1", "Forge here.", in: room)])
        await until("hello") { speaker.spoken.count == 1 }
        speaker.finish()
        room.send(.add("ada"))
        await turn(room, listener, "Ada, welcome to the call.")
        await until("the turn is kept") { yours(room) == 1 }
        poster.release()
        await until("the add failed") { room.state.with == ["pocket-forge"] }
        clock.advance(VoiceRoomCoordinator.givesUpAfter + 1)
        await settle()
        XCTAssertEqual(speaker.spoken.count, 1, "nothing is said for an agent no longer on the call")
        room.receive([agentPost("f1", "Forge here, still on.", in: room)])
        await until("the other agent is read") { speaker.spoken.last?.text == "Forge here, still on." }
        XCTAssertEqual(line.askCount, 0, "the voice line is never asked as the agent being added")
        await room.hangUp()
    }

    /// A turn carried on is one turn: the wait for its answer starts again from the whole turn, with one bridge after
    /// it, and it is owed once. Forge's post for it, whether it came during the turn or only after the next turn went,
    /// settles it, so Forge's answer to that next turn, everyone's, has its floor and Ada's is held.
    func test_a_turn_carried_on_gets_one_bridge_and_is_owed_once() async {
        for answersInItsTurn in [false, true] {
            let clock = ManualClock()
            let line = FakeVoiceLine([])
            let listener = LineListener(), speaker = LineSpeaker()
            let room = VoiceRoomCoordinator(sessionId: "room_line", with: ["ada", "pocket-forge"],
                                            you: "mrrcarter", ownAuthorIds: ["human-mrrcarter"], listener: listener,
                                            speaker: speaker, audio: LineAudio(), poster: LinePoster(), voiceLine: line,
                                            now: { clock.now },
                                            sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) })
            let microphone = LineMicrophone(room: room, clock: clock)
            let label = "answers in its turn: \(answersInItsTurn)"
            let bridge = "One moment, pocket-forge is answering."
            let own = "The build, then the tests."
            room.begin(rings: false)
            await until("listening") { listener.partial != nil }
            room.receive([agentPost("h1", "Ada here.", in: room, author: "ada"),
                          agentPost("h2", "Forge here.", in: room)])
            await until("a hello is read") { speaker.spoken.count == 1 }
            speaker.finish()
            await until("listening again") { room.state.isListening && listener.partial != nil }

            microphone.loud(for: 0.4)
            listener.say("Forge, what's next?")
            microphone.quiet(for: VoiceRoomCoordinator.pauseAfterSentence + 0.1)
            await until("\(label): sent") { yours(room) == 1 }
            await until("still listening a moment") { room.state.isListening && listener.partial != nil }
            microphone.loud(for: 0.2)
            listener.say("And the tests?")
            microphone.quiet(for: VoiceRoomCoordinator.pauseAfterSentence + 0.1)
            await until("\(label): carried on") {
                room.state.turns.first(where: \.isYou)?.text.hasSuffix("And the tests?") == true
            }
            XCTAssertEqual(speaker.spoken.count, 1, "\(label): no bridge for the first part")
            clock.advance(VoiceRoomCoordinator.bridgeAfter + 0.1)
            await until("\(label): the bridge") { speaker.spoken.last?.text == bridge }
            speaker.finish()
            if answersInItsTurn {
                await until("listening after the bridge") { room.state.isListening && listener.partial != nil }
                room.receive([agentPost("f1", own, in: room)])
                await until("\(label): its answer") { speaker.spoken.last?.text == own }
                speaker.finish()
            }
            await until("\(label): listening for the next turn") { room.state.isListening && listener.partial != nil }

            microphone.loud(for: 0.4)
            listener.say("Who ships tonight?")
            microphone.quiet(for: VoiceRoomCoordinator.pauseAfterSentence + 0.1)
            await until("\(label): the next turn is kept") { yours(room) == 2 }
            var posts = [agentPost("f3", "I ship tonight.", in: room), agentPost("a3", "Me too.", in: room, author: "ada")]
            if !answersInItsTurn { posts.insert(agentPost("f1", own, in: room), at: 0) }
            room.receive(posts)
            if !answersInItsTurn {
                await until("\(label): its late answer") { speaker.spoken.last?.text == own }
                speaker.finish()
            }
            await until("\(label): its answer to the next turn is read") {
                speaker.spoken.last?.text == "I ship tonight."
            }
            XCTAssertEqual(speaker.spoken.filter { $0.text == bridge }.count, 1, "\(label): one bridge for the whole turn")
            XCTAssertEqual(speaker.spoken.filter { $0.text == own }.count, 1, "\(label): its answer read once")
            XCTAssertTrue(room.state.turns.contains { $0.id == "msg:a3" && $0.isHeld },
                          "\(label): owed once, so Forge's answer to this turn has its floor")
            XCTAssertEqual(line.askCount, 0, label)
            await room.hangUp()
        }
    }

    /// Carter kept dialing busy agents and nobody answered. With the voice line on, the agent's fast voice picks up
    /// the ring in about 2 s as that agent; the agent's own hello, when it comes in other words, is read after it, with
    /// nothing between.
    func test_a_busy_agents_fast_voice_picks_up_the_ring_and_its_late_hello_is_read_after_it() async {
        let line = FakeVoiceLine([])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin()
        for _ in 0..<250 where speaker.spoken.isEmpty {
            clock.advance(0.25)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(speaker.spoken.first?.text, "Hi, it's pocket-forge. Go ahead.")
        XCTAssertEqual(speaker.spoken.first?.speaker, "pocket-forge", "in the agent's own voice")
        XCTAssertFalse(room.state.isRinging)
        speaker.finish()
        room.receive([agentPost("hello", "Hi there, forge here.", in: room)])
        await until("the agent's own hello") { speaker.spoken.count == 2 }
        XCTAssertEqual(speaker.spoken.map(\.text), ["Hi, it's pocket-forge. Go ahead.", "Hi there, forge here."])
        XCTAssertEqual(line.askCount, 0)
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
        // The voice line answers only a turn for Senti (it never speaks for "the room", nor for another agent).
        let room = VoiceRoomCoordinator(sessionId: "room_call", with: ["senti"], you: "mrrcarter",
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
        XCTAssertEqual(room.state.speaker, "senti (voice)")
        XCTAssertFalse(line.stopped)
        await room.hangUp()
        for _ in 0..<200 where !line.stopped { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(line.stopped, "the stream ends with the call")
        XCTAssertTrue(poster.endings.first?.contains("@senti") == true, "the end asks the agent itself")
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
