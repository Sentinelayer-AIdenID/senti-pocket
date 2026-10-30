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
    var starts: [String] { lock.withLock { _starts } }

    func postCallStarted(sessionId: String, text: String, clientId: String) async throws {
        lock.withLock { _starts.append(text) }
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
        lock.withLock { _endings.append((text, transcript?.attachmentId)) }
    }
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
                      listener: FakeListener, speaker: FakeSpeaker, audio: FakeAudio, ringer: FakeRinger? = nil,
                      poster: FakePoster, onEnded: @escaping @MainActor () -> Void = {}) -> VoiceRoomCoordinator {
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
            poster: poster,
            now: { clock.now },
            // Time moves only when a test moves it; the pause watcher just polls.
            sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) },
            onEnded: onEnded
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
        XCTAssertTrue(ringer.ringing)
        XCTAssertTrue(room.state.isRinging)
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

    func test_with_no_answer_the_ring_stops_and_the_line_opens() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), ringer = FakeRinger(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], listener: listener, speaker: speaker, audio: audio, ringer: ringer, poster: poster)
        room.begin()
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

    func test_hanging_up_a_call_where_nothing_was_said_posts_nothing() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = FakePoster()
        let room = room(with: ["pocket-forge"], handsFree: false, listener: listener, speaker: speaker, audio: audio, poster: poster)
        room.begin()
        await room.hangUp()
        XCTAssertTrue(poster.uploads.isEmpty)
        XCTAssertTrue(poster.endings.isEmpty)
        XCTAssertEqual(room.state.phase, .ended)
    }
}
