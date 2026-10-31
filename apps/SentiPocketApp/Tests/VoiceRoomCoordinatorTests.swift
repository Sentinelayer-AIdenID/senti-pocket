import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

@MainActor
private final class FakeListener: VoiceListening {
    var partial: (@MainActor (String) -> Void)?
    var said = ""
    var starts = 0
    var cancels = 0

    func start(partial: @escaping @MainActor (String) -> Void) async throws {
        starts += 1
        said = ""
        self.partial = partial
    }

    func say(_ text: String) {
        said = text
        partial?(text)
    }

    func stop() async -> String {
        partial = nil
        return said
    }

    func cancel() {
        cancels += 1
        partial = nil
    }
}

@MainActor
private final class FakeSpeaker: VoiceSpeaking {
    var spoken: [(text: String, speaker: String)] = []
    var finished: (@MainActor () -> Void)?
    var stops = 0

    func speak(_ markdown: String, as speaker: String, finished: @escaping @MainActor () -> Void) {
        spoken.append((markdown, speaker))
        self.finished = finished
    }

    func finish() {
        let done = finished
        finished = nil
        done?()
    }

    func stop() {
        stops += 1
        finished = nil
    }
}

@MainActor
private final class FakeAudio: VoiceRoomAudioSession {
    var active = false
    func activate() throws { active = true }
    func deactivate() { active = false }
}

@MainActor
private final class FakeRinger: VoiceRoomRinging {
    var ringing = false
    var rings = 0
    func startRinging() {
        ringing = true
        rings += 1
    }
    func stopRinging() { ringing = false }
}

private final class FakePoster: VoiceRoomPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _turns: [String] = []
    private var _uploads: [(filename: String, markdown: String)] = []
    private var _endings: [(text: String, attachmentId: String?)] = []
    private var _starts: [String] = []
    private var _ids: [String] = []
    var starts: [String] { lock.withLock { _starts } }
    /// The client ids of the ring and the end, in order.
    var ids: [String] { lock.withLock { _ids } }

    func postCallStarted(sessionId: String, text: String, clientId: String) async throws {
        lock.withLock { _starts.append(text); _ids.append(clientId) }
    }

    var turns: [String] { lock.withLock { _turns } }
    var uploads: [(filename: String, markdown: String)] { lock.withLock { _uploads } }
    var endings: [(text: String, attachmentId: String?)] { lock.withLock { _endings } }

    func postVoiceTurn(sessionId: String, text: String, clientId: String) async throws {
        lock.withLock { _turns.append(text) }
    }

    func uploadTranscript(sessionId: String, filename: String, markdown: String, clientId: String) async throws -> VoiceTranscriptAttachment {
        lock.withLock { _uploads.append((filename, markdown)) }
        return VoiceTranscriptAttachment(attachmentId: "att-123456", filename: filename, kind: "text",
                                         contentType: "text/markdown", sizeBytes: markdown.utf8.count, status: "ready")
    }

    func postCallEnded(sessionId: String, text: String, transcript: VoiceTranscriptAttachment?, clientId: String) async throws {
        lock.withLock { _endings.append((text, transcript?.attachmentId)); _ids.append(clientId) }
    }
}

/// A room whose posts can stall or fail, for hanging up on a bad network.
private final class TroubledPoster: VoiceRoomPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var _endings = 0
    let failsStart: Bool
    let failsUpload: Bool

    init(failsStart: Bool = false, failsUpload: Bool = false) {
        self.failsStart = failsStart
        self.failsUpload = failsUpload
    }

    func release() { lock.withLock { released = true } }
    var endings: Int { lock.withLock { _endings } }

    func postCallStarted(sessionId: String, text: String, clientId: String) async throws {
        if failsStart { throw RoomSendError.retryable(retryAfterSeconds: nil) }
    }

    func postVoiceTurn(sessionId: String, text: String, clientId: String) async throws {}

    func uploadTranscript(sessionId: String, filename: String, markdown: String, clientId: String) async throws -> VoiceTranscriptAttachment {
        while !lock.withLock({ released }) { try await Task.sleep(nanoseconds: 2_000_000) }
        if failsUpload { throw RoomSendError.retryable(retryAfterSeconds: nil) }
        return VoiceTranscriptAttachment(attachmentId: "att-9", filename: filename, kind: "text",
                                         contentType: "text/markdown", sizeBytes: markdown.utf8.count, status: "ready")
    }

    func postCallEnded(sessionId: String, text: String, transcript: VoiceTranscriptAttachment?, clientId: String) async throws {
        lock.withLock { _endings += 1 }
    }
}

/// Writes every start and end into one shared log, and can hold a start or an end until released.
private final class OrderedPoster: VoiceRoomPosting, @unchecked Sendable {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        func add(_ event: String) { lock.withLock { _events.append(event) } }
        var events: [String] { lock.withLock { _events } }
    }

    private let lock = NSLock()
    private let log: Log
    private let name: String
    private var holdStart: Bool
    private var holdEnd: Bool

    init(_ name: String, log: Log, holdStart: Bool = false, holdEnd: Bool = false) {
        self.name = name
        self.log = log
        self.holdStart = holdStart
        self.holdEnd = holdEnd
    }

    func release() { lock.withLock { holdStart = false; holdEnd = false } }

    func postCallStarted(sessionId: String, text: String, clientId: String) async throws {
        while lock.withLock({ holdStart }) { try await Task.sleep(nanoseconds: 2_000_000) }
        log.add("\(name) start")
    }

    func postVoiceTurn(sessionId: String, text: String, clientId: String) async throws {}

    func uploadTranscript(sessionId: String, filename: String, markdown: String, clientId: String) async throws -> VoiceTranscriptAttachment {
        VoiceTranscriptAttachment(attachmentId: "att-1", filename: filename, kind: "text", contentType: "text/markdown",
                                  sizeBytes: markdown.utf8.count, status: "ready")
    }

    func postCallEnded(sessionId: String, text: String, transcript: VoiceTranscriptAttachment?, clientId: String) async throws {
        while lock.withLock({ holdEnd }) { try await Task.sleep(nanoseconds: 2_000_000) }
        log.add("\(name) end")
    }
}

/// Opens the call, then refuses to ring anyone else.
private final class RefusesAddsPoster: VoiceRoomPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var rings = 0

    func postCallStarted(sessionId: String, text: String, clientId: String) async throws {
        let count = lock.withLock { () -> Int in
            rings += 1
            return rings
        }
        if count > 1 { throw RoomSendError.retryable(retryAfterSeconds: nil) }
    }

    func postVoiceTurn(sessionId: String, text: String, clientId: String) async throws {}

    func uploadTranscript(sessionId: String, filename: String, markdown: String, clientId: String) async throws -> VoiceTranscriptAttachment {
        VoiceTranscriptAttachment(attachmentId: "att-2", filename: filename, kind: "text", contentType: "text/markdown",
                                  sizeBytes: markdown.utf8.count, status: "ready")
    }

    func postCallEnded(sessionId: String, text: String, transcript: VoiceTranscriptAttachment?, clientId: String) async throws {}
}

/// The phone's call screen: keeps what the panel asked of it until the test has CallKit perform it, which reaches the
/// room the way a tap on the call screen does, or refuse it.
@MainActor
private final class FakeCallScreen: VoiceRoomCallScreen {
    private(set) var asked: [Bool] = []
    private var pending: [(on: Bool, done: @MainActor (Bool) -> Void)] = []

    func setMuted(_ on: Bool, done: @escaping @MainActor (Bool) -> Void) {
        asked.append(on)
        pending.append((on, done))
    }

    func perform(on room: VoiceRoomCoordinator) {
        let next = pending.removeFirst()
        room.callScreenMuted(next.on)
        next.done(true)
    }

    func refuse() {
        pending.removeFirst().done(false)
    }
}

@MainActor
private final class BusyAudio: VoiceRoomAudioSession {
    func activate() throws { throw VoiceRoomAudioError.recognizerUnavailable }
    func deactivate() {}
}

/// A clock only the test moves.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_793_300_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@MainActor
final class VoiceRoomCoordinatorTests: XCTestCase {
    private let clock = TestClock()

    private func room(with agents: [String], handsFree: Bool = true,
                      listener: FakeListener, speaker: FakeSpeaker, audio: any VoiceRoomAudioSession, ringer: FakeRinger? = nil,
                      callScreen: FakeCallScreen? = nil,
                      poster: any VoiceRoomPosting, onEnded: @escaping @MainActor () -> Void = {},
                      onRecordFailed: @escaping @MainActor (String) -> Void = { _ in }) -> VoiceRoomCoordinator {
        let clock = self.clock
        let room = VoiceRoomCoordinator(
            sessionId: "room_1",
            with: agents,
            you: "mrrcarter",
            ownAuthorIds: ["human-mrrcarter"],
            listener: listener,
            speaker: speaker,
            audio: audio,
            ringer: ringer,
            callScreen: callScreen,
            poster: poster,
            now: { clock.now },
            // Time moves only when a test moves it; the pause watcher just polls.
            sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) },
            onEnded: onEnded,
            onRecordFailed: onRecordFailed
        )
        if !handsFree { room.send(.setHandsFree(false)) }
        return room
    }

    private func message(_ id: String, from author: String, _ text: String, secondsAfterStart: TimeInterval = 2) -> RoomMessage {
        let stamp = ISO8601DateFormatter().string(from: clock.now.addingTimeInterval(secondsAfterStart))
        return RoomMessage(id: id, sequenceId: Int64(abs(id.hashValue % 100_000)) + 1, kind: .message, authorId: author,
                           authorName: author, isHuman: RoomMessage.isHumanAuthor(author), text: text, timestamp: stamp)
    }

    private func until(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    func test_a_one_to_one_call_posts_your_turns_to_that_agent_and_reads_only_its_answers() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], handsFree: false, listener: listener, speaker: speaker, audio: audio, poster: poster)
        room.begin()
        XCTAssertTrue(audio.active)
        XCTAssertEqual(room.state.phase, .ready, "not hands-free: waits for a tap")
        await until("rang") { poster.starts.count == 1 }
        XCTAssertTrue(poster.starts[0].hasPrefix("📞 Calling @pocket-forge:"), "the call rings the agent by mention")
        XCTAssertEqual(VoiceCallMarkers.calledAgents(in: poster.starts[0]), ["pocket-forge"])
        XCTAssertTrue(room.state.isRinging, "ringing until the agent answers")

        room.send(.toggleTalk)
        XCTAssertFalse(room.state.isRinging, "talking stops the ring")
        await until("listening") { listener.partial != nil }
        listener.say("Ship the composer fix tonight")
        XCTAssertEqual(room.state.partial, "Ship the composer fix tonight")
        room.send(.toggleTalk)
        await until("posted") { poster.turns.count == 1 }
        XCTAssertEqual(poster.turns, ["@pocket-forge Ship the composer fix tonight"], "your turn mentions the agent")
        XCTAssertEqual(room.state.turns.map(\.isYou), [true])

        room.receive([
            message("m1", from: "claude-warden", "Not my call"),
            message("m2", from: "human-mrrcarter", "@pocket-forge Ship the composer fix tonight"),
            message("m3", from: "pocket-forge", "On it. **Build 09** goes out tonight.")
        ])
        await until("speaking") { room.state.speaker == "pocket-forge" }
        XCTAssertEqual(speaker.spoken.map(\.speaker), ["pocket-forge"], "another agent and your own echo are not read")
        XCTAssertEqual(room.state.joined, ["pocket-forge"], "the agent joined by answering")
        room.receive([message("m3", from: "pocket-forge", "On it. **Build 09** goes out tonight.")])
        speaker.finish()
        XCTAssertEqual(speaker.spoken.count, 1, "a message seen twice is read once")
        XCTAssertEqual(room.state.phase, .ready)
    }

    func test_answers_wait_while_you_talk_and_hands_free_listening_comes_back_after_them() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = FakePoster()
        let room = room(with: [], listener: listener, speaker: speaker, audio: audio, poster: poster)
        room.begin()
        clock.advance(VoiceRoomCoordinator.ringsFor + 0.1)
        await until("listening") { listener.partial != nil }
        listener.say("What is left for tonight")
        room.receive([message("m1", from: "pocket-forge", "First answer", secondsAfterStart: -28)])
        XCTAssertTrue(speaker.spoken.isEmpty, "never read over you")
        XCTAssertEqual(room.state.waiting, 1)

        // Hands-free: a pause ends the turn.
        clock.advance(VoiceRoomCoordinator.pauseEndsTurn + 0.1)
        await until("sent after a pause") { poster.turns.count == 1 }
        XCTAssertEqual(poster.turns, ["What is left for tonight"], "a meeting addresses no one in particular")
        await until("speaking") { room.state.speaker == "pocket-forge" }
        room.receive([message("m2", from: "claude-warden", "Second answer", secondsAfterStart: 3)])
        XCTAssertEqual(room.state.waiting, 1)

        room.send(.skip)
        await until("next answer") { room.state.speaker == "claude-warden" }
        XCTAssertEqual(speaker.stops, 1)
        speaker.finish()
        // The phase changes at once; the microphone starts a moment later.
        await until("listening again") { room.state.isListening && listener.starts == 2 }
        XCTAssertEqual(listener.starts, 2, "hands-free: listening comes back after the answers")
    }

    /// Carter (10-30): "when I call there should be a ring calling and when picked up there should be me hearing the
    /// hi Carter part. These only come or came after I spoke".
    func test_a_call_rings_until_the_agent_picks_up_and_its_hello_is_heard_before_you_say_anything() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), ringer = FakeRinger(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], listener: listener, speaker: speaker, audio: audio, ringer: ringer, poster: poster)
        room.begin()
        XCTAssertTrue(room.state.isRinging, "ringing from the start")
        await until("the ring sounds once the agents are rung") { ringer.ringing }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(listener.starts, 0, "hands-free does not listen while it rings")

        room.receive([message("hi", from: "pocket-forge", "Hi Carter, forge here.")])
        XCTAssertFalse(ringer.ringing, "picked up: the ring stops")
        XCTAssertFalse(room.state.isRinging)
        await until("the hello is read") { room.state.speaker == "pocket-forge" }
        XCTAssertEqual(speaker.spoken.map(\.text), ["Hi Carter, forge here."])
        speaker.finish()
        await until("then it listens") { listener.starts == 1 && room.state.isListening }
        XCTAssertEqual(ringer.rings, 1)
    }

    /// Warden (#275): the ring sounds once the ring message has gone out, not while it waits.
    func test_the_ring_waits_for_the_ring_message() async {
        let log = OrderedPoster.Log()
        let held = OrderedPoster("held", log: log, holdStart: true)
        let ringer = FakeRinger()
        let room = room(with: ["pocket-forge"], listener: FakeListener(), speaker: FakeSpeaker(), audio: FakeAudio(),
                        ringer: ringer, poster: held)
        room.begin()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(ringer.ringing, "silent while the ring message is on its way")
        XCTAssertTrue(room.state.isRinging, "the screen still says it is calling")
        held.release()
        await until("rings once the agents are rung") { ringer.ringing }
        await room.hangUp()
    }

    func test_with_no_answer_the_ring_stops_and_the_line_opens() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), ringer = FakeRinger(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], listener: listener, speaker: speaker, audio: audio, ringer: ringer, poster: poster)
        room.begin()
        await until("the ring sounds once the agents are rung") { ringer.ringing }
        clock.advance(VoiceRoomCoordinator.ringsFor - 1)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(ringer.ringing, "still ringing before the time is up")
        clock.advance(1.1)
        await until("the line opens") { listener.starts == 1 }
        XCTAssertFalse(ringer.ringing)
        XCTAssertFalse(room.state.isRinging)
        XCTAssertEqual(room.state.notice?.hasPrefix("pocket-forge hasn't picked up yet."), true)
        room.receive([message("late", from: "pocket-forge", "Sorry, here now.", secondsAfterStart: 31)])
        XCTAssertNil(room.state.notice, "a late answer clears it")
    }

    func test_an_answer_that_lands_before_you_talk_is_read_at_once_but_one_that_lands_while_you_talk_waits() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], listener: listener, speaker: speaker, audio: audio, poster: poster)
        room.begin(rings: false)
        await until("listening") { listener.partial != nil }
        room.receive([message("m1", from: "pocket-forge", "Hi Carter.")])
        await until("read at once") { room.state.speaker == "pocket-forge" }
        XCTAssertEqual(listener.cancels, 1, "the microphone gave way")
        speaker.finish()
        await until("listening again") { listener.starts == 2 && listener.partial != nil }

        listener.say("Wait, one more thing")
        room.receive([message("m2", from: "pocket-forge", "Also, build 15 is up.", secondsAfterStart: 3)])
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(speaker.spoken.count, 1, "never read over you")
        XCTAssertEqual(room.state.waiting, 1)
    }

    func test_answering_an_agents_own_call_does_not_ring() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), ringer = FakeRinger(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], listener: listener, speaker: speaker, audio: audio, ringer: ringer, poster: poster)
        room.begin(rings: false)
        XCTAssertEqual(ringer.rings, 0)
        XCTAssertFalse(room.state.isRinging)
        await until("hands-free listens at once") { listener.starts == 1 }
    }

    func test_old_messages_from_before_the_call_are_not_read() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = FakePoster()
        let room = room(with: [], handsFree: false, listener: listener, speaker: speaker, audio: audio, poster: poster)
        room.begin()
        room.receive([message("old", from: "pocket-forge", "From an hour ago", secondsAfterStart: -3_600)])
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(speaker.spoken.isEmpty)
        XCTAssertTrue(room.state.turns.isEmpty)
    }

    func test_hanging_up_saves_the_transcript_and_asks_for_a_summary() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = FakePoster()
        var ended = false
        let room = room(with: ["pocket-forge"], handsFree: false, listener: listener, speaker: speaker, audio: audio,
                        poster: poster, onEnded: { ended = true })
        room.begin()
        room.send(.toggleTalk)
        await until("listening") { listener.partial != nil }
        listener.say("Can you hear me")
        room.send(.toggleTalk)
        await until("posted") { poster.turns.count == 1 }
        room.receive([message("m1", from: "pocket-forge", "Loud and clear.", secondsAfterStart: 5)])
        await until("speaking") { room.state.speaker != nil }
        clock.advance(125)

        await room.hangUp()
        XCTAssertTrue(ended)
        XCTAssertEqual(room.state.phase, .ended)
        XCTAssertFalse(audio.active, "the phone's audio is given back")
        XCTAssertEqual(poster.uploads.count, 1)
        let markdown = poster.uploads.first?.markdown ?? ""
        XCTAssertTrue(markdown.hasPrefix("# Voice room with pocket-forge"))
        let you = markdown.range(of: "**mrrcarter**")
        let agent = markdown.range(of: "**pocket-forge**")
        XCTAssertNotNil(you)
        XCTAssertNotNil(agent)
        if let you, let agent { XCTAssertTrue(you.lowerBound < agent.lowerBound, "oldest first") }
        XCTAssertTrue(markdown.contains("Can you hear me"))
        XCTAssertTrue(markdown.contains("Loud and clear."))
        XCTAssertEqual(poster.endings.count, 1)
        XCTAssertEqual(poster.endings.first?.attachmentId, "att-123456", "the transcript rides on the closing message")
        XCTAssertTrue(poster.endings.first?.text.contains("@pocket-forge please post a 3–5 line summary") == true)
        XCTAssertTrue(poster.uploads.first?.filename.hasPrefix("voice-pocket-forge-") == true)
    }

    /// Carter (10-30): in a meeting the first agent to answer takes the turn; the others hold, and they are told.
    func test_in_a_meeting_the_first_answer_takes_the_turn_and_the_others_hold() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = FakePoster()
        let room = room(with: [], handsFree: false, listener: listener, speaker: speaker, audio: audio, poster: poster)
        room.begin()
        room.send(.toggleTalk)
        await until("listening") { listener.partial != nil }
        listener.say("Who takes the release notes?")
        room.send(.toggleTalk)
        await until("posted") { poster.turns.count == 1 }

        room.receive([
            message("a1", from: "review-agent", "I will.", secondsAfterStart: 3),
            message("b1", from: "build-agent", "I can take them.", secondsAfterStart: 4),
            message("c1", from: "docs-agent", "Me too.", secondsAfterStart: 5)
        ])
        await until("speaking") { room.state.speaker == "review-agent" }
        await until("floor posted") { poster.turns.count == 2 }
        XCTAssertEqual(poster.turns.last, "🎙️ review-agent has the floor for this turn. Everyone else, hold until the next one.",
                       "the others are told once")
        XCTAssertEqual(room.state.turns.filter(\.isHeld).map(\.speaker), ["build-agent", "docs-agent"])
        XCTAssertEqual(room.state.waiting, 0, "held answers are never read")
        room.receive([message("a2", from: "review-agent", "Draft by noon.", secondsAfterStart: 6)])
        XCTAssertEqual(room.state.waiting, 1, "the agent with the floor keeps it")
        speaker.finish()
        await until("second") { speaker.spoken.count == 2 }
        speaker.finish()

        // The next turn opens the floor again.
        room.send(.toggleTalk)
        await until("listening again") { listener.partial != nil }
        listener.say("And the changelog?")
        room.send(.toggleTalk)
        await until("posted again") { poster.turns.count == 3 }
        room.receive([message("b2", from: "build-agent", "That one is mine.", secondsAfterStart: 8)])
        await until("build speaks") { room.state.speaker == "build-agent" }
        XCTAssertEqual(room.timings.held, 2)
    }

    /// Carter (10-30): the call measures itself, and the closing message says how fast it was.
    func test_a_call_measures_its_turns_and_reports_them_when_it_ends() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], handsFree: false, listener: listener, speaker: speaker, audio: audio, poster: poster)
        room.begin()
        room.send(.toggleTalk)
        await until("listening") { listener.partial != nil }
        listener.say("Status please.")
        clock.advance(0.5)
        room.send(.toggleTalk)
        await until("posted") { poster.turns.count == 1 }
        // The room starts timing the answer once the post has returned to it, which on a slow runner comes after the
        // poster has the turn (warden, 10-30: nil timings on the hosted runner).
        await until("post timed") { room.timings.percentile(.post, 0.5) != nil }
        clock.advance(3)
        room.receive([message("m1", from: "pocket-forge", "Build 21 is up.", secondsAfterStart: 4)])
        await until("speaking") { room.state.speaker == "pocket-forge" }
        XCTAssertEqual(room.timings.percentile(.answer, 0.5), 3, "turn posted to answer arriving")
        XCTAssertEqual(room.timings.percentile(.gap, 0.5), 3.5, "the last word heard to the answer's first sound")
        XCTAssertNotNil(room.timings.percentile(.recognition, 0.5))
        XCTAssertNotNil(room.timings.percentile(.post, 0.5))
        speaker.finish()

        await room.hangUp()
        XCTAssertTrue(poster.endings.first?.text.contains("\nTimings: you stop → answer heard 3.5 s") == true,
                      poster.endings.first?.text ?? "")
        XCTAssertTrue(poster.uploads.first?.markdown.contains("## Timings, measured on the phone") == true)
    }

    /// Carter (#55058): the recognizer's fillers and doubled words are tidied before the turn reaches the room.
    func test_a_spoken_turn_is_tidied_before_it_is_posted() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], handsFree: false, listener: listener, speaker: speaker, audio: audio, poster: poster)
        room.begin()
        room.send(.toggleTalk)
        await until("listening") { listener.partial != nil }
        listener.say("um the the build is uh green")
        room.send(.toggleTalk)
        await until("posted") { poster.turns.count == 1 }
        XCTAssertEqual(poster.turns, ["@pocket-forge The build is green"])
        XCTAssertEqual(room.state.turns.last?.text, "The build is green")
    }

    func test_a_finished_sentence_ends_a_hands_free_turn_sooner() {
        XCTAssertEqual(VoiceRoomCoordinator.pause(after: "Ship it tonight."), VoiceRoomCoordinator.pauseAfterSentence)
        XCTAssertEqual(VoiceRoomCoordinator.pause(after: "What about the build? "), VoiceRoomCoordinator.pauseAfterSentence)
        XCTAssertEqual(VoiceRoomCoordinator.pause(after: "Ship it and then"), VoiceRoomCoordinator.pauseEndsTurn)
        XCTAssertEqual(VoiceRoomCoordinator.pause(after: ""), VoiceRoomCoordinator.pauseEndsTurn)
    }

    /// Warden (#267): a call is always closed in the room, so its card ends and no agent says hello into it.
    func test_hanging_up_a_call_where_nothing_was_said_still_closes_it_without_a_transcript() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], handsFree: false, listener: listener, speaker: speaker, audio: audio, poster: poster)
        room.begin()
        await room.hangUp()
        XCTAssertTrue(poster.uploads.isEmpty, "nothing said, nothing to attach")
        XCTAssertEqual(poster.endings.count, 1)
        XCTAssertTrue(poster.endings.first?.text.hasPrefix("📞 Voice room with pocket-forge ended") == true)
        XCTAssertFalse(poster.endings.first?.text.contains("summary") == true, "nothing to sum up")
        XCTAssertEqual(room.state.phase, .ended)
        // Warden (API #1060): the end names its start, so the call log pairs them even with two phones in a room.
        XCTAssertEqual(poster.ids.count, 2)
        XCTAssertEqual(poster.ids[0].dropFirst("voice-start-".count), poster.ids[1].dropFirst("voice-end-".count))
        XCTAssertTrue(poster.ids[1].hasPrefix("voice-end-"))
    }

    /// Warden (#267): hanging up locked the app until the transcript saved, up to two minutes on a stalled network.
    func test_hanging_up_takes_the_call_screen_away_before_the_record_is_saved() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = TroubledPoster()
        var ended = false
        let room = room(with: ["pocket-forge"], handsFree: false, listener: listener, speaker: speaker, audio: audio,
                        poster: poster, onEnded: { ended = true })
        room.begin()
        room.send(.toggleTalk)
        await until("listening") { listener.partial != nil }
        listener.say("Status please")
        room.send(.toggleTalk)
        await until("turn kept") { room.state.turns.count == 1 }

        let hanging = Task { await room.hangUp() }
        await until("the screen goes at once") { ended }
        XCTAssertEqual(poster.endings, 0, "the record is still being saved")
        XCTAssertFalse(audio.active, "the microphone and speaker are given back at once")
        poster.release()
        await hanging.value
        XCTAssertEqual(poster.endings, 1)
        XCTAssertEqual(room.state.phase, .ended)
    }

    func test_a_record_that_does_not_save_is_said_in_the_room() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = TroubledPoster(failsUpload: true)
        var said: [String] = []
        let room = room(with: ["pocket-forge"], handsFree: false, listener: listener, speaker: speaker, audio: audio,
                        poster: poster, onRecordFailed: { said.append($0) })
        room.begin()
        room.send(.toggleTalk)
        await until("listening") { listener.partial != nil }
        listener.say("Status please")
        room.send(.toggleTalk)
        await until("turn kept") { room.state.turns.count == 1 }
        poster.release()
        await room.hangUp()
        XCTAssertEqual(said, ["The call's transcript could not be saved to the room."])
        XCTAssertEqual(poster.endings, 1, "the call is still closed, without its file")
    }

    /// Warden (#267): a call whose ring never went out was never opened, so hanging up posts no end for it.
    func test_a_call_that_was_never_rung_ends_without_an_end_message() async {
        let poster = TroubledPoster(failsStart: true)
        let room = room(with: ["pocket-forge"], listener: FakeListener(), speaker: FakeSpeaker(), audio: FakeAudio(),
                        poster: poster)
        room.begin()
        await until("the ring failed") { room.state.notice != nil }
        await room.hangUp()
        XCTAssertEqual(poster.endings, 0, "no stray \"ended · 0 turns\"")
        XCTAssertEqual(room.state.phase, .ended)
    }

    /// Warden (#267): the end waits for its start, and a new call's ring waits for the room's last end.
    func test_the_end_never_lands_before_the_start_and_a_quick_recall_rings_after_the_old_end() async {
        let log = OrderedPoster.Log()
        let first = OrderedPoster("first", log: log, holdStart: true, holdEnd: false)
        let call = room(with: ["pocket-forge"], handsFree: false, listener: FakeListener(), speaker: FakeSpeaker(),
                        audio: FakeAudio(), poster: first)
        call.begin()
        let hanging = Task { await call.hangUp() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(log.events, [], "the end waits while the start is still on its way")
        first.release()
        await hanging.value
        XCTAssertEqual(log.events, ["first start", "first end"])

        let slowEnd = OrderedPoster("second", log: log, holdEnd: true)
        let second = room(with: ["pocket-forge"], handsFree: false, listener: FakeListener(), speaker: FakeSpeaker(),
                          audio: FakeAudio(), poster: slowEnd)
        second.begin()
        await until("second rang") { log.events.count == 3 }
        let closing = Task { await second.hangUp() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let third = room(with: ["pocket-forge"], handsFree: false, listener: FakeListener(), speaker: FakeSpeaker(),
                         audio: FakeAudio(), poster: OrderedPoster("third", log: log))
        third.begin()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(log.events.last, "second start", "the new ring waits for the old end")
        slowEnd.release()
        await closing.value
        await until("third rang") { log.events.count == 5 }
        XCTAssertEqual(Array(log.events.suffix(2)), ["second end", "third start"])
        await third.hangUp()
    }

    func test_a_ring_that_could_not_be_sent_or_without_the_phones_audio_does_not_ring() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), ringer = FakeRinger()
        let unsent = room(with: ["pocket-forge"], listener: listener, speaker: speaker, audio: FakeAudio(), ringer: ringer,
                          poster: TroubledPoster(failsStart: true))
        unsent.begin()
        await until("the ring stops") { !ringer.ringing && !unsent.state.isRinging }
        XCTAssertEqual(unsent.state.notice, "The agents could not be rung. Check the connection.")

        let busy = room(with: ["pocket-forge"], listener: FakeListener(), speaker: FakeSpeaker(), audio: BusyAudio(),
                        poster: FakePoster())
        busy.begin()
        XCTAssertFalse(busy.state.isRinging, "no \"Ringing…\" for ever without the phone's audio")
    }

    /// Carter (10-30): call several agents at once. Each turn mentions them all, and the first to answer has the floor.
    func test_a_call_with_several_agents_mentions_them_all_and_the_first_answer_has_the_floor() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = FakePoster()
        let room = room(with: ["pocket-forge", "claude-warden"], handsFree: false, listener: listener, speaker: speaker,
                        audio: audio, poster: poster)
        room.begin()
        await until("rang") { poster.starts.count == 1 }
        XCTAssertEqual(VoiceCallMarkers.calledAgents(in: poster.starts[0]), ["pocket-forge", "claude-warden"])
        XCTAssertTrue(poster.starts[0].contains("has the floor"), "two agents share the floor")
        room.send(.toggleTalk)
        await until("listening") { listener.partial != nil }
        listener.say("Who ships tonight?")
        room.send(.toggleTalk)
        await until("posted") { poster.turns.count == 1 }
        XCTAssertEqual(poster.turns, ["@pocket-forge @claude-warden Who ships tonight?"])

        room.receive([
            message("a1", from: "claude-warden", "I will.", secondsAfterStart: 3),
            message("b1", from: "pocket-forge", "Me.", secondsAfterStart: 4),
            message("c1", from: "review-agent", "Not called.", secondsAfterStart: 5)
        ])
        await until("speaking") { room.state.speaker == "claude-warden" }
        XCTAssertEqual(room.state.turns.filter(\.isHeld).map(\.speaker), ["pocket-forge"])
        XCTAssertFalse(room.state.turns.contains { $0.speaker == "review-agent" }, "an agent not in the call is not heard")
        await room.hangUp()
        XCTAssertTrue(poster.endings.first?.text.contains("@pocket-forge @claude-warden please post") == true)
    }

    /// Carter (10-30): add warden mid-call. One message rings it; from then on its answers are read, and your turns
    /// mention it too.
    func test_adding_an_agent_mid_call_rings_it_and_its_answers_are_read() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], handsFree: false, listener: listener, speaker: speaker, audio: audio,
                        poster: poster)
        room.begin()
        await until("rang") { poster.starts.count == 1 }
        room.receive([message("hi", from: "pocket-forge", "Hi Carter.")])
        await until("hello") { room.state.speaker == "pocket-forge" }
        speaker.finish()

        room.send(.add("claude-warden"))
        XCTAssertEqual(room.state.with, ["pocket-forge", "claude-warden"])
        XCTAssertEqual(room.state.title, "pocket-forge and claude-warden")
        XCTAssertEqual(room.state.notice, "claude-warden was asked to join. Their hello is read when it comes.")
        await until("the add went out") { poster.starts.count == 2 }
        XCTAssertEqual(VoiceCallMarkers.addedAgents(in: poster.starts[1]), ["claude-warden"])
        XCTAssertTrue(poster.starts[1].contains("already going with pocket-forge"))
        XCTAssertTrue(poster.ids[1].hasPrefix("voice-add-"))
        room.send(.add("Claude-Warden"))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(poster.starts.count, 2, "someone already in the call is not added twice")

        room.receive([message("w1", from: "claude-warden", "Warden here.", secondsAfterStart: 6)])
        await until("its hello is read") { room.state.speaker == "claude-warden" }
        XCTAssertNil(room.state.notice, "everyone added has answered")
        speaker.finish()

        room.send(.toggleTalk)
        await until("listening") { listener.partial != nil }
        listener.say("Merge it")
        room.send(.toggleTalk)
        await until("posted") { poster.turns.count == 1 }
        XCTAssertEqual(poster.turns, ["@pocket-forge @claude-warden Merge it"])
    }

    func test_an_agent_that_could_not_be_added_leaves_the_call_and_you_are_told() async {
        let room = room(with: ["pocket-forge"], handsFree: false, listener: FakeListener(), speaker: FakeSpeaker(),
                        audio: FakeAudio(), poster: RefusesAddsPoster())
        room.begin()
        room.send(.add("claude-warden"))
        XCTAssertEqual(room.state.with, ["pocket-forge", "claude-warden"])
        await until("taken back out") { room.state.with == ["pocket-forge"] }
        XCTAssertEqual(room.state.notice, "claude-warden could not be added. Try again.")
        room.receive([message("w1", from: "claude-warden", "Hello?", secondsAfterStart: 3)])
        XCTAssertTrue(room.state.turns.isEmpty, "not in the call, not heard")
    }

    func test_a_meeting_has_no_one_to_add() async {
        let poster = FakePoster()
        let room = room(with: [], handsFree: false, listener: FakeListener(), speaker: FakeSpeaker(), audio: FakeAudio(),
                        poster: poster)
        room.begin()
        await until("opened") { poster.starts.count == 1 }
        room.send(.add("claude-warden"))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(room.state.with, [])
        XCTAssertEqual(poster.starts.count, 1)
    }

    /// Warden (#279): on a call with two agents where one already has the floor, the agent added next still says hello.
    func test_an_added_agents_hello_is_read_even_when_another_agent_has_the_floor() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), poster = FakePoster()
        let room = room(with: ["pocket-forge", "claude-warden"], handsFree: false, listener: listener, speaker: speaker,
                        audio: FakeAudio(), poster: poster)
        room.begin()
        await until("rang") { poster.starts.count == 1 }
        room.receive([message("a1", from: "pocket-forge", "Hi Carter.")])
        await until("pocket-forge has the floor") { room.state.speaker == "pocket-forge" }
        speaker.finish()

        room.send(.add("review-agent"))
        await until("added") { poster.starts.count == 2 }
        room.receive([message("c1", from: "review-agent", "Review agent here.", secondsAfterStart: 4)])
        await until("its hello is read") { room.state.speaker == "review-agent" }
        XCTAssertTrue(room.state.turns.filter(\.isHeld).isEmpty, "the hello is not held for the floor")
        XCTAssertEqual(poster.turns.filter { $0.contains("has the floor") }, [], "nobody is told to hold")
    }

    /// Warden (#279): add someone and speak at once; the new agent's hello landing first never holds the answer.
    func test_an_added_agents_hello_takes_no_floor_from_the_answer_to_your_turn() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], handsFree: false, listener: listener, speaker: speaker, audio: FakeAudio(),
                        poster: poster)
        room.begin()
        await until("rang") { poster.starts.count == 1 }
        room.send(.add("claude-warden"))
        await until("added") { poster.starts.count == 2 }
        room.send(.toggleTalk)
        await until("listening") { listener.partial != nil }
        listener.say("Is the build up?")
        room.send(.toggleTalk)
        await until("posted") { poster.turns.count == 1 }

        room.receive([
            message("w1", from: "claude-warden", "Warden here.", secondsAfterStart: 3),
            message("a1", from: "pocket-forge", "Yes, build 16 is up.", secondsAfterStart: 4)
        ])
        await until("the hello is read") { room.state.speaker == "claude-warden" }
        speaker.finish()
        await until("then the answer") { room.state.speaker == "pocket-forge" }
        XCTAssertTrue(room.state.turns.filter(\.isHeld).isEmpty, "the answer is not held behind the hello")
    }

    /// Warden (#279): an add made as the call ends is never posted after the end.
    func test_an_add_made_as_the_call_ends_is_not_posted_after_it() async {
        let poster = FakePoster()
        let room = room(with: ["pocket-forge"], handsFree: false, listener: FakeListener(), speaker: FakeSpeaker(),
                        audio: FakeAudio(), poster: poster)
        room.begin()
        await until("rang") { poster.starts.count == 1 }
        room.send(.add("claude-warden"))
        await room.hangUp()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(poster.starts.count, 1, "the call ended first: no one is asked to say hello")
        XCTAssertEqual(poster.endings.count, 1)
    }

    /// Warden (#281): Mute on the lock screen's call screen stops the room hearing you. What was being heard is
    /// dropped, answers are still read, and nothing listens again until unmuted.
    func test_muting_on_the_call_screen_stops_listening_until_unmuted() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], listener: listener, speaker: speaker, audio: FakeAudio(), poster: poster)
        room.begin(rings: false)
        await until("listening") { listener.partial != nil }
        listener.say("This is private")
        room.callScreenMuted(true)
        XCTAssertTrue(room.state.isMuted)
        XCTAssertFalse(room.state.isListening)
        XCTAssertEqual(room.state.partial, "")
        XCTAssertEqual(listener.cancels, 1)
        clock.advance(VoiceRoomCoordinator.pauseEndsTurn + 1)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(poster.turns.isEmpty, "nothing heard while muted is posted")

        room.receive([message("a1", from: "pocket-forge", "Still here.", secondsAfterStart: 3)])
        await until("the answer is read") { room.state.speaker == "pocket-forge" }
        speaker.finish()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(listener.starts, 1, "hands-free does not listen again while muted")
        room.send(.toggleTalk)
        XCTAssertFalse(room.state.isListening, "a tap does not listen while muted")

        room.callScreenMuted(false)
        await until("listening again once unmuted") { listener.starts == 2 && room.state.isListening }
    }

    /// Carter (Voice Lab #56359): "I don't see a mute button in this when I call you". In a call made in the app the
    /// panel's Mute mutes at once: listening stops, words the recognizer still delivers are dropped, holding or tapping
    /// Talk does nothing, answers are still read, and unmuting brings hands-free listening back.
    func test_the_panels_mute_stops_the_room_hearing_you_until_unmuted() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], listener: listener, speaker: speaker, audio: FakeAudio(), poster: poster)
        room.begin(rings: false)
        XCTAssertFalse(room.state.hasCallScreen, "a call made in the app")
        await until("listening") { listener.partial != nil }
        listener.say("Keep this")
        let recognizer = listener.partial
        room.send(.setMuted(true))
        XCTAssertTrue(room.state.isMuted)
        XCTAssertFalse(room.state.isListening)
        XCTAssertFalse(room.state.canTalk)
        XCTAssertEqual(listener.cancels, 1)
        // The recognizer runs a beat behind the voice: what it still delivers while muted is never taken.
        recognizer?("Keep this between us")
        XCTAssertEqual(room.state.partial, "")
        clock.advance(VoiceRoomCoordinator.pauseEndsTurn + 1)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(poster.turns.isEmpty, "nothing heard while muted is posted")

        room.send(.talk(true))
        room.send(.talk(false))
        room.send(.toggleTalk)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(listener.starts, 1, "holding or tapping Talk does nothing while muted")
        XCTAssertFalse(room.state.isListening)

        room.receive([message("a1", from: "pocket-forge", "Still here.", secondsAfterStart: 3)])
        await until("the answer is still read") { room.state.speaker == "pocket-forge" }
        speaker.finish()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(listener.starts, 1, "hands-free does not listen again while muted")

        room.send(.setMuted(false))
        await until("hands-free listening resumes") { listener.starts == 2 && room.state.isListening }
        listener.say("Now you can hear me")
        room.send(.toggleTalk)
        await until("posted") { poster.turns.count == 1 }
        XCTAssertEqual(poster.turns, ["@pocket-forge Now you can hear me"], "only what was said unmuted reaches the room")
    }

    /// Carter (Voice Lab #56359): in an agent's call answered on the phone's call screen, the panel's Mute is asked of
    /// the call screen and only its answer mutes the room, so the two always agree. A mute made on the call screen and
    /// the panel's own converge on one state, each applied once.
    func test_on_the_call_screen_the_panels_mute_and_the_call_screens_are_one_mute() async {
        let listener = FakeListener(), screen = FakeCallScreen()
        let room = room(with: ["pocket-forge"], listener: listener, speaker: FakeSpeaker(), audio: FakeAudio(),
                        callScreen: screen, poster: FakePoster())
        room.begin(rings: false)
        XCTAssertTrue(room.state.hasCallScreen)
        await until("listening") { listener.partial != nil }

        room.send(.setMuted(!room.state.isMuted))
        XCTAssertEqual(screen.asked, [true], "the call screen is asked")
        XCTAssertFalse(room.state.isMuted, "not muted here before the call screen is")
        XCTAssertTrue(room.state.isListening)
        screen.perform(on: room)
        XCTAssertTrue(room.state.isMuted)
        XCTAssertFalse(room.state.isListening)
        XCTAssertEqual(listener.cancels, 1)
        room.callScreenMuted(true)
        XCTAssertEqual(listener.cancels, 1, "the call screen's mute seen again changes nothing")

        // Unmuted on the call screen itself: the panel follows, and its next tap mutes again.
        room.callScreenMuted(false)
        XCTAssertFalse(room.state.isMuted)
        await until("listening again") { listener.starts == 2 && room.state.isListening }
        room.send(.setMuted(!room.state.isMuted))
        screen.perform(on: room)
        XCTAssertTrue(room.state.isMuted)
        XCTAssertEqual(listener.cancels, 2)

        // Muted on the call screen: the panel shows it, and its next tap asks to unmute, never to mute again.
        room.callScreenMuted(false)
        await until("listening") { listener.starts == 3 }
        room.callScreenMuted(true)
        room.send(.setMuted(!room.state.isMuted))
        XCTAssertEqual(screen.asked, [true, true, false])
        screen.perform(on: room)
        XCTAssertFalse(room.state.isMuted)
        await until("listening once more") { listener.starts == 4 && room.state.isListening }
    }

    /// The call screen could not mute (its call is already going away): the tap still stops the room hearing you.
    func test_a_mute_the_call_screen_could_not_make_still_mutes_here() async {
        let listener = FakeListener(), screen = FakeCallScreen()
        let room = room(with: ["pocket-forge"], listener: listener, speaker: FakeSpeaker(), audio: FakeAudio(),
                        callScreen: screen, poster: FakePoster())
        room.begin(rings: false)
        await until("listening") { listener.partial != nil }
        room.send(.setMuted(true))
        screen.refuse()
        XCTAssertTrue(room.state.isMuted)
        XCTAssertFalse(room.state.isListening)
    }

    /// Unmuting while it still rings does not open the line: as without Mute, the phone listens once the agent picks
    /// up. Muted when it does, its hello is read and nothing listens until unmuted.
    func test_unmuting_while_it_rings_keeps_ringing_and_listens_only_after_the_pickup() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), ringer = FakeRinger(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], listener: listener, speaker: speaker, audio: FakeAudio(), ringer: ringer,
                        poster: poster)
        room.begin()
        await until("ringing") { ringer.ringing }
        room.send(.setMuted(true))
        room.send(.setMuted(false))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(ringer.ringing, "still ringing")
        XCTAssertTrue(room.state.isRinging)
        XCTAssertEqual(listener.starts, 0)

        room.send(.setMuted(true))
        room.receive([message("hi", from: "pocket-forge", "Hi Carter.")])
        await until("the hello is read") { room.state.speaker == "pocket-forge" }
        speaker.finish()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(listener.starts, 0, "muted: nothing listens after the hello")
        room.send(.setMuted(false))
        await until("listening once unmuted") { listener.starts == 1 && room.state.isListening }
    }

    /// Found porting calls to the web (#702): in a meeting the room's own voices (cost lines, the ticket keeper,
    /// Senti's notices) are never read, and never take the floor from the agents.
    func test_a_meeting_never_reads_the_rooms_own_voices() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), poster = FakePoster()
        let room = room(with: [], handsFree: false, listener: listener, speaker: speaker, audio: FakeAudio(), poster: poster)
        room.begin()
        room.send(.toggleTalk)
        await until("listening") { listener.partial != nil }
        listener.say("Who has the release?")
        room.send(.toggleTalk)
        await until("posted") { poster.turns.count == 1 }

        room.receive([
            message("o1", from: "respawn-orchestrator", "[cost] astra-web: $15.26 est over 101 calls", secondsAfterStart: 3),
            message("k1", from: "ticket-keeper", "1 asks: R1: no action", secondsAfterStart: 3),
            message("s1", from: "senti", "📞 mrrCarter answered pocket-forge's call", secondsAfterStart: 3),
            message("a1", from: "claude-warden", "I have it.", secondsAfterStart: 4)
        ])
        await until("the agent is read") { room.state.speaker == "claude-warden" }
        XCTAssertEqual(speaker.spoken.map(\.speaker), ["claude-warden"], "only the agent is read")
        XCTAssertEqual(room.state.turns.filter { !$0.isYou }.map(\.speaker), ["claude-warden"])
        XCTAssertTrue(room.state.turns.filter(\.isHeld).isEmpty, "no cost line took the floor")
    }
}
