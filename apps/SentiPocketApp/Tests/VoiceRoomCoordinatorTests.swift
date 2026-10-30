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
                      listener: FakeListener, speaker: FakeSpeaker, audio: FakeAudio, poster: FakePoster,
                      onEnded: @escaping @MainActor () -> Void = {}) -> VoiceRoomCoordinator {
        let clock = self.clock
        let room = VoiceRoomCoordinator(
            sessionId: "room_1",
            with: agents,
            you: "mrrcarter",
            ownAuthorIds: ["human-mrrcarter"],
            listener: listener,
            speaker: speaker,
            audio: audio,
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

        room.send(.toggleTalk)
        await until("listening") { listener.partial != nil }
        listener.say("Ship the composer fix tonight")
        XCTAssertEqual(room.state.partial, "Ship the composer fix tonight")
        room.send(.toggleTalk)
        await until("posted") { poster.turns.count == 1 }
        XCTAssertEqual(poster.turns, ["@pocket-forge Ship the composer fix tonight"], "your turn mentions the agent")
        XCTAssertEqual(room.state.turns.map(\.isYou), [true])

        await until("rang") { poster.starts.count == 1 }
        XCTAssertTrue(poster.starts[0].hasPrefix("📞 Calling @pocket-forge:"), "the call rings the agent by mention")
        XCTAssertEqual(VoiceCallMarkers.calledAgents(in: poster.starts[0]), ["pocket-forge"])
        XCTAssertTrue(room.state.isRinging, "ringing until the agent answers")
        room.receive([
            message("m1", from: "claude-warden", "Not my call"),
            message("m2", from: "human-mrrcarter", "@pocket-forge Ship the composer fix tonight"),
            message("m3", from: "pocket-forge", "On it. **Build 09** goes out tonight.")
        ])
        await until("speaking") { room.state.speaker == "pocket-forge" }
        XCTAssertEqual(speaker.spoken.map(\.speaker), ["pocket-forge"], "another agent and your own echo are not read")
        XCTAssertFalse(room.state.isRinging, "the agent joined by answering")
        XCTAssertEqual(room.state.joined, ["pocket-forge"])
        room.receive([message("m3", from: "pocket-forge", "On it. **Build 09** goes out tonight.")])
        speaker.finish()
        XCTAssertEqual(speaker.spoken.count, 1, "a message seen twice is read once")
        XCTAssertEqual(room.state.phase, .ready)
    }

    func test_answers_wait_while_you_talk_and_hands_free_listening_comes_back_after_them() async {
        let listener = FakeListener(), speaker = FakeSpeaker(), audio = FakeAudio(), poster = FakePoster()
        let room = room(with: [], listener: listener, speaker: speaker, audio: audio, poster: poster)
        room.begin()
        await until("listening") { listener.partial != nil }
        room.receive([message("m1", from: "pocket-forge", "First answer")])
        XCTAssertTrue(speaker.spoken.isEmpty, "never read over you")
        XCTAssertEqual(room.state.waiting, 1)

        listener.say("What is left for tonight")
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
