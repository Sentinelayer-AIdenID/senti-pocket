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

    private func call(_ line: FakeVoiceLine, listener: LineListener, speaker: LineSpeaker, poster: LinePoster,
                      ringCallId: String? = nil, about: String? = nil) -> VoiceRoomCoordinator {
        let room = VoiceRoomCoordinator(sessionId: "room_line", with: ["pocket-forge"], you: "mrrcarter",
                                        ownAuthorIds: ["human-mrrcarter"], listener: listener, speaker: speaker,
                                        audio: LineAudio(), poster: poster, voiceLine: line, ringCallId: ringCallId,
                                        about: about, sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) })
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

    /// Carter (10-30): "send an agent with your intentions and everything that you need, and the agent will call me
    /// and talk to me". Answering an agent's call, the quick answers are asked with that call, whose reason and brief
    /// the server reads; the screen says what it is about until someone speaks.
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
        room.send(.toggleTalk)
        for _ in 0..<200 where listener.partial == nil { try? await Task.sleep(nanoseconds: 2_000_000) }
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

    /// A server from before call briefs refuses the field it does not know (422): the turn is asked again without
    /// it, once, and still answered.
    func test_a_server_without_call_briefs_is_asked_again_without_the_call() async throws {
        VoiceTurnURLProtocol.reset(statuses: [422, 200])
        let heard = try await sentences(ringCallId: "ring-1")
        XCTAssertEqual(heard, ["Yes."])
        let sent = VoiceTurnURLProtocol.sent()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first?["ringCallId"] as? String, "ring-1")
        XCTAssertNil(sent.last?["ringCallId"])
        XCTAssertEqual(sent.last?["text"] as? String, "Status?")

        VoiceTurnURLProtocol.reset(statuses: [422, 200])
        do {
            _ = try await sentences(ringCallId: nil)
            XCTFail("a refused turn without the call is not asked again")
        } catch {
            XCTAssertEqual(VoiceTurnURLProtocol.sent().count, 1)
        }
    }
}
