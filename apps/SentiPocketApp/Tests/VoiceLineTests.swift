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
    private(set) var asks: [(agentId: String?, text: String, history: [VoiceLineHistory])] = []

    init(_ answers: [Result<[String], VoiceLineError>]) { self.answers = answers }

    var askCount: Int { lock.withLock { asks.count } }

    func voiceLine(sessionId: String, agentId: String?, text: String, callId: String,
                   history: [VoiceLineHistory]) -> AsyncThrowingStream<VoiceLineEvent, Error> {
        let answer: Result<[String], VoiceLineError> = lock.withLock {
            asks.append((agentId, text, history))
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

@MainActor
final class VoiceLineCallTests: XCTestCase {
    private func until(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    private func call(_ line: FakeVoiceLine, listener: LineListener, speaker: LineSpeaker, poster: LinePoster) -> VoiceRoomCoordinator {
        let room = VoiceRoomCoordinator(sessionId: "room_line", with: ["pocket-forge"], you: "mrrcarter",
                                        ownAuthorIds: ["human-mrrcarter"], listener: listener, speaker: speaker,
                                        audio: LineAudio(), poster: poster, voiceLine: line,
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

    /// Carter (10-30): each answer took 18 s. The voice line answers in its agent's voice, marked "(voice)".
    func test_a_turn_is_answered_by_the_voice_line_in_the_agents_voice_and_marked_as_the_voice_line() async {
        let line = FakeVoiceLine([.success(["Build 15 is on TestFlight.", "Calls ring first now."])])
        let listener = LineListener(), speaker = LineSpeaker(), poster = LinePoster()
        let room = call(line, listener: listener, speaker: speaker, poster: poster)
        room.begin()
        await turn(room, listener, "What's new in the build?")
        await until("the first sentence is heard") { speaker.spoken.count == 1 }
        XCTAssertEqual(line.asks.first?.agentId, "pocket-forge")
        XCTAssertEqual(line.asks.first?.text, "What's new in the build?")
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

    func voiceLine(sessionId: String, agentId: String?, text: String, callId: String,
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
        let room = VoiceRoomCoordinator(sessionId: "room_meeting", with: [], invited: ["pocket-forge"], you: "mrrcarter",
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
        XCTAssertEqual(room.state.speaker, "room (voice)")
        XCTAssertFalse(line.stopped)
        await room.hangUp()
        for _ in 0..<200 where !line.stopped { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(line.stopped, "the stream ends with the call")
        XCTAssertFalse(poster.endings.first?.contains("@room") == true, poster.endings.first ?? "")
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

/// Carter (10-30): "I thought jev would help us finish everything by 600ms". A short pause asks whether the turn is
/// over; a sure yes ends it at once, anything else leaves the normal pause in charge.
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
        room.send(.toggleTalk)
        for _ in 0..<200 where listener.partial == nil { try? await Task.sleep(nanoseconds: 2_000_000) }
        listener.say("And one more thing")
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(endpointer.asked.count, 1, "asked once, then never again in this call")
        await room.hangUp()
    }
}
