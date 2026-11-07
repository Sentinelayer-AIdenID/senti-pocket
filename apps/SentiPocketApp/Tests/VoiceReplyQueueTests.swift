import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

// A call where each turn is answered once, by the agent's own reply (Carter, ticket 13ec2d12): replies are queued,
// never dropped, and read in full, and while the agent writes its fast voice says at most a short bridge with nothing
// of the answer in it. Agents and words here are made up.

private final class QueueClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_810_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// A voice line the test steps through, ask by ask: sentences, then the end or a failure.
private final class QueueVoiceLine: VoiceLining, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [AsyncThrowingStream<VoiceLineEvent, Error>.Continuation] = []
    private var _agents: [String?] = []
    var askCount: Int { lock.withLock { held.count } }
    var agents: [String?] { lock.withLock { _agents } }

    func voiceLine(sessionId: String, agentId: String?, text: String, callId: String, ringCallId: String?,
                   history: [VoiceLineHistory]) -> AsyncThrowingStream<VoiceLineEvent, Error> {
        AsyncThrowingStream { continuation in
            self.lock.withLock {
                self.held.append(continuation)
                self._agents.append(agentId)
            }
        }
    }

    private func ask(_ index: Int) -> AsyncThrowingStream<VoiceLineEvent, Error>.Continuation? {
        lock.withLock { index < held.count ? held[index] : nil }
    }

    func say(_ index: Int, _ sentences: String...) {
        for sentence in sentences { ask(index)?.yield(.sentence(sentence)) }
    }

    func end(_ index: Int) {
        ask(index)?.yield(.done(speaker: "voice"))
        ask(index)?.finish()
    }

    func answer(_ index: Int, _ sentences: String...) {
        for sentence in sentences { ask(index)?.yield(.sentence(sentence)) }
        end(index)
    }

    /// The server's answer that the line cannot answer (off, not yours, or resting).
    func fail(_ index: Int, _ error: VoiceLineError) {
        ask(index)?.finish(throwing: error)
    }
}

/// The microphone could not be had.
private struct MicrophoneBusy: LocalizedError {
    var errorDescription: String? { "The microphone is busy." }
}

@MainActor
private final class QueueListener: VoiceListening {
    var partial: (@MainActor (String) -> Void)?
    var said = ""
    /// Listening cannot start (another app has the microphone).
    var failsToStart = false
    func start(partial: @escaping @MainActor (String) -> Void) async throws {
        if failsToStart { throw MicrophoneBusy() }
        said = ""
        self.partial = partial
    }
    func say(_ text: String) { said = text; partial?(text) }
    func stop() async -> String { partial = nil; return said }
    func cancel() { partial = nil }
}

@MainActor
private final class QueueSpeaker: VoiceSpeaking {
    var spoken: [(text: String, speaker: String)] = []
    var finished: (@MainActor () -> Void)?
    var stops = 0
    func speak(_ markdown: String, as speaker: String, finished: @escaping @MainActor () -> Void) {
        spoken.append((markdown, speaker))
        self.finished = finished
    }
    func finish() { let done = finished; finished = nil; done?() }
    func stop() { stops += 1; finished = nil }
    var texts: [String] { spoken.map(\.text) }
}

@MainActor
private final class QueueAudio: VoiceRoomAudioSession {
    func activate() throws {}
    func deactivate() {}
}

private final class QueuePoster: VoiceRoomPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var _uploads: [String] = []
    var transcript: String { lock.withLock { _uploads.first ?? "" } }
    func postCallStarted(sessionId: String, text: String, clientId: String) async throws {}
    func postVoiceTurn(sessionId: String, text: String, clientId: String) async throws {}
    func uploadTranscript(sessionId: String, filename: String, markdown: String, clientId: String) async throws -> VoiceTranscriptAttachment {
        lock.withLock { _uploads.append(markdown) }
        return VoiceTranscriptAttachment(attachmentId: "att-1", filename: filename, kind: "text",
                                         contentType: "text/markdown", sizeBytes: markdown.utf8.count, status: "ready")
    }
    func postCallEnded(sessionId: String, text: String, transcript: VoiceTranscriptAttachment?, clientId: String) async throws {}
}

/// The microphone's level on the test's clock, a level every 50 ms, as the audio tap gives it.
@MainActor
private struct QueueMicrophone {
    static let step: TimeInterval = 0.05
    let room: VoiceRoomCoordinator
    let clock: QueueClock

    func loud(for seconds: TimeInterval) {
        room.hear(level: 0.8)
        for _ in 0..<Int((seconds / Self.step).rounded()) {
            clock.advance(Self.step)
            room.hear(level: 0.8)
        }
    }

    func quiet(for seconds: TimeInterval) {
        for _ in 0..<Int((seconds / Self.step).rounded()) {
            clock.advance(Self.step)
            room.hear(level: 0.1)
        }
    }
}

@MainActor
final class VoiceReplyQueueTests: XCTestCase {
    private let clock = QueueClock()
    private static let bridge = "One moment, ada is answering."
    private static let noAnswer = "ada hasn't answered yet."

    private func until(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    private func call(_ line: QueueVoiceLine, _ listener: QueueListener, _ speaker: QueueSpeaker, _ poster: QueuePoster,
                      with agents: [String] = ["ada"], handsFree: Bool) -> VoiceRoomCoordinator {
        let clock = self.clock
        let room = VoiceRoomCoordinator(sessionId: "room_reply_queue_\(UUID().uuidString)", with: agents,
                                        you: "mrrcarter", ownAuthorIds: ["human-mrrcarter"], listener: listener,
                                        speaker: speaker, audio: QueueAudio(), poster: poster, voiceLine: line,
                                        now: { clock.now },
                                        // Time moves only when a test moves it; the watchers just poll.
                                        sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) })
        if !handsFree { room.send(.setHandsFree(false)) }
        return room
    }

    private func post(_ id: String, _ text: String, from author: String = "ada") -> RoomMessage {
        RoomMessage(id: id, sequenceId: Int64(abs(id.hashValue % 100_000)) + 1, kind: .message, authorId: author,
                    authorName: author, isHuman: false, text: text,
                    timestamp: ISO8601DateFormatter().string(from: clock.now))
    }

    /// A turn with Talk tapped, then tapped again (not hands-free).
    private func tapTurn(_ room: VoiceRoomCoordinator, _ listener: QueueListener, _ text: String) async {
        room.send(.toggleTalk)
        await until("listening") { listener.partial != nil }
        listener.say(text)
        room.send(.toggleTalk)
    }

    /// A hands-free turn: you talk, then a pause sends it. Every turn here ends a sentence.
    private func handsFreeTurn(_ room: VoiceRoomCoordinator, _ listener: QueueListener, _ microphone: QueueMicrophone,
                               _ text: String, talking seconds: TimeInterval = 1) async {
        await until("listening for: \(text)") { room.state.isListening && listener.partial != nil }
        microphone.loud(for: seconds)
        listener.say(text)
        microphone.quiet(for: VoiceRoomCoordinator.pauseAfterSentence + 0.1)
    }

    /// Waits until `count` of your turns are in the call.
    private func sent(_ room: VoiceRoomCoordinator, _ count: Int) async {
        await until("\(count) turns sent") { room.state.turns.filter(\.isYou).count == count }
    }

    /// Waits for the phone to start saying its `index`th thing (0 is the first), and checks it is `text`.
    private func says(_ speaker: QueueSpeaker, _ index: Int, _ text: String, line: UInt = #line) async {
        await until("thing \(index) said: \(text.prefix(40))") { speaker.spoken.count > index }
        XCTAssertEqual(speaker.spoken.count > index ? speaker.spoken[index].text : nil, text, line: line)
    }

    /// The transcript's header line for the turn whose text is `text`.
    private func header(of text: String, in transcript: String) -> String? {
        let lines = transcript.components(separatedBy: "\n")
        guard let index = lines.firstIndex(of: text), index > 0 else { return nil }
        return lines[index - 1]
    }

    // MARK: - The 17:15 call, replayed

    /// A real call, replayed with made-up words (seconds after the agent's fast voice picked up). The voice line
    /// answered every turn as the agent, and the agent's own replies landed 4 to 18 s later, so each turn was heard
    /// twice: a paraphrase, then the real answer. Now the voice line is never asked for the agent's turns, and each
    /// reply is read once, in order, in the agent's voice. While the agent writes, its fast voice says at most the
    /// bridge, never before a reply that lands within a moment, and says plainly when nothing has come in 20 s. A turn
    /// carried on gets one bridge, after the whole turn.
    func test_the_17_15_call_hears_each_reply_once_with_at_most_a_bridge_before_it() async {
        let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
        let room = call(line, listener, speaker, poster, handsFree: true)
        let microphone = QueueMicrophone(room: room, clock: clock)
        let hello = "Hi, it's ada. Go ahead."
        let replies: [String] = [
            "Hi, ada here, good morning.",
            "Here is the whole picture. The drawings were approved by both reviewers and the paint order went in with "
                + "the blue we picked. The crane is booked for Tuesday, but the lift stays parked until the inspector "
                + "signs off. After your run I need two things from you: a yes on the safety plan, and more room in the "
                + "budget so the night crew can finish. Also, someone spotted a crack in the east rail this morning, and "
                + "it is being checked now.",
            "The walkway lights are coming along. The first two rows are on, the timer fix passed both checks, and "
                + "night mode stays off for now while a third small fix goes in. One problem: the sensors miss people "
                + "who walk slowly, so on dark evenings fewer lamps switch on than they should. A second kind of sensor "
                + "is on order to cover that, and we will try it for a week, only watching, before it controls "
                + "anything. I will post the numbers from that week here when they are in.",
            "Got it, I asked for the call to stop skipping my replies. In short, the first lamps are on, night mode is "
                + "off, and the second sensor comes before anything changes.",
            "Opening day is three weeks out. Several parts are done, some work is not confirmed yet, and a few blockers "
                + "are still open. I'll post the current opening details in the room."
        ]
        var next = 0

        // 0 s: the ring is picked up by the agent's fast voice. 3 s later the agent's own hello lands, and is read.
        room.begin()
        for _ in 0..<200 where speaker.spoken.isEmpty {
            clock.advance(0.25)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await says(speaker, next, hello); next += 1
        clock.advance(2)
        speaker.finish()
        await until("listening after the hello") { room.state.isListening && listener.partial != nil }
        clock.advance(1)
        room.receive([post("r0", replies[0])])
        await says(speaker, next, replies[0]); next += 1
        clock.advance(3)
        speaker.finish()

        // Your first turn. Nothing has come 1.5 s after it, so the bridge; the reply lands 15 s after the turn.
        clock.advance(4)
        await handsFreeTurn(room, listener, microphone, "What did I miss this morning? I'm heading out for a run.")
        await sent(room, 1)
        clock.advance(VoiceRoomCoordinator.bridgeAfter + 0.1)
        await says(speaker, next, Self.bridge); next += 1
        XCTAssertEqual(speaker.spoken.last?.speaker, "ada", "the bridge is in the agent's voice")
        XCTAssertEqual(room.state.speaker, "ada (voice)", "said by its fast voice")
        clock.advance(2)
        speaker.finish()
        await until("listening after the bridge") { room.state.isListening && listener.partial != nil }
        clock.advance(11.4)
        room.receive([post("r1", replies[1])])
        await says(speaker, next, replies[1]); next += 1
        clock.advance(32)
        speaker.finish()

        // Your second turn, carried on just after it went: nothing for its first part, one bridge after the whole
        // turn, and the reply 18 s after it.
        clock.advance(2)
        await handsFreeTurn(room, listener, microphone, "Sounds good. How is the other part going?", talking: 1.5)
        await sent(room, 2)
        await until("listening a moment after it") { room.state.isListening && listener.partial != nil }
        microphone.loud(for: 0.4)
        listener.say("The lights along the walkway?")
        microphone.quiet(for: VoiceRoomCoordinator.pauseAfterSentence + 0.1)
        await until("the turn is carried on") {
            room.state.turns.last(where: \.isYou)?.text.hasSuffix("The lights along the walkway?") == true
        }
        XCTAssertEqual(speaker.spoken.count, next, "nothing for the first part")
        clock.advance(VoiceRoomCoordinator.bridgeAfter + 0.1)
        await says(speaker, next, Self.bridge); next += 1
        clock.advance(2)
        speaker.finish()
        await until("listening after the bridge") { room.state.isListening && listener.partial != nil }
        clock.advance(14.4)
        room.receive([post("r2", replies[2])])
        await says(speaker, next, replies[2]); next += 1
        clock.advance(36)
        speaker.finish()

        // Your third turn: the reply lands a second after it, so nothing comes before it.
        clock.advance(2)
        await handsFreeTurn(room, listener, microphone,
                            "Okay. I saw you said more about the lights, but I did not get to hear it.", talking: 2)
        await sent(room, 3)
        clock.advance(1)
        room.receive([post("r3", replies[3])])
        await says(speaker, next, replies[3]); next += 1
        clock.advance(10)
        speaker.finish()

        // Your fourth turn: nothing in 20 s, so the bridge and then that it has not answered; the reply comes after.
        clock.advance(2)
        await handsFreeTurn(room, listener, microphone, "How far are we from opening day?")
        await sent(room, 4)
        clock.advance(VoiceRoomCoordinator.bridgeAfter + 0.1)
        await says(speaker, next, Self.bridge); next += 1
        clock.advance(2)
        speaker.finish()
        await until("listening after the bridge") { room.state.isListening && listener.partial != nil }
        clock.advance(17)
        await says(speaker, next, Self.noAnswer); next += 1
        XCTAssertEqual(speaker.spoken.last?.speaker, "ada")
        clock.advance(2)
        speaker.finish()
        await until("listening again") { room.state.isListening && listener.partial != nil }
        clock.advance(6)
        room.receive([post("r4", replies[4])])
        await says(speaker, next, replies[4]); next += 1
        clock.advance(8)
        speaker.finish()
        XCTAssertEqual(speaker.stops, 0, "nothing was cut off")
        await room.hangUp()

        XCTAssertEqual(line.askCount, 0, "the voice line is never asked for the agent's turns")
        XCTAssertEqual(speaker.texts, [hello, replies[0], Self.bridge, replies[1], Self.bridge, replies[2], replies[3],
                                       Self.bridge, Self.noAnswer, replies[4]])
        XCTAssertEqual(speaker.texts.filter { replies.contains($0) }, replies, "every reply, each once, in order")
        XCTAssertTrue(speaker.spoken.filter { replies.contains($0.text) }.allSatisfy { $0.speaker == "ada" })
        let transcript = poster.transcript
        XCTAssertFalse(transcript.contains("not read"), transcript)
        XCTAssertFalse(transcript.contains("skipped"), transcript)
        XCTAssertFalse(transcript.contains(Self.bridge), "what the fast voice says while the agent writes is not kept")
        for reply in replies {
            XCTAssertEqual(header(of: reply, in: transcript)?.hasPrefix("**ada** · "), true, reply)
            XCTAssertEqual(header(of: reply, in: transcript)?.contains(" · held"), false, reply)
        }
    }

    // MARK: - Talking over a reply

    /// Talking over a reply pauses it, never drops it. While you talk nothing waiting is read, even what lands then;
    /// after your new turn the reply you talked over is read again in full, with the ones after it, in order.
    func test_talking_over_a_reply_pauses_it_and_it_is_read_in_full_after_your_turn() async {
        let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
        let room = call(line, listener, speaker, poster, handsFree: true)
        let microphone = QueueMicrophone(room: room, clock: clock)
        let r1 = "Both builds passed review, and the release goes out at noon."
        let r2 = "One more thing: the guide is live."
        let r3 = "Also, the dashboard is back."
        room.begin(rings: false)

        await handsFreeTurn(room, listener, microphone, "What did I miss?")
        await sent(room, 1)
        room.receive([post("r1", r1), post("r2", r2)])
        await says(speaker, 0, r1)

        // You talk over it.
        room.send(.toggleTalk)
        XCTAssertEqual(speaker.stops, 1, "talking over it stops it")
        XCTAssertTrue(room.state.isListening)
        XCTAssertEqual(room.state.waiting, 2, "the reply you talked over waits, with the one after it")
        await until("listening over the reply") { listener.partial != nil }
        room.receive([post("r3", r3)])
        await settle()
        XCTAssertTrue(room.state.isListening, "what lands while you talk over a reply waits for your turn")
        XCTAssertEqual(speaker.spoken.count, 1, "nothing is read while you talk")
        XCTAssertEqual(room.state.waiting, 3)

        microphone.loud(for: 0.6)
        listener.say("Wait, which builds?")
        microphone.quiet(for: VoiceRoomCoordinator.pauseAfterSentence + 0.1)
        await says(speaker, 1, r1)
        speaker.finish()
        await says(speaker, 2, r2)
        speaker.finish()
        await says(speaker, 3, r3)
        speaker.finish()
        await until("listening again") { room.state.isListening }
        await room.hangUp()
        XCTAssertEqual(speaker.texts, [r1, r1, r2, r3])
        XCTAssertEqual(line.askCount, 0)
        XCTAssertFalse(poster.transcript.contains("skipped"), "every reply was read in full in the end")
    }

    /// Talking over a reply to bring someone in ("add max") is a control, not a turn: the reply you talked over picks
    /// up again right after it, never left waiting for something else to happen.
    func test_talking_over_a_reply_to_add_an_agent_picks_the_reply_up_again() async {
        let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
        let clock = self.clock
        let room = VoiceRoomCoordinator(sessionId: "room_reply_queue_\(UUID().uuidString)", with: ["ada"],
                                        you: "mrrcarter", ownAuthorIds: ["human-mrrcarter"], listener: listener,
                                        speaker: speaker, audio: QueueAudio(), addable: { ["ada", "max"] },
                                        poster: poster, voiceLine: line, now: { clock.now },
                                        sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) })
        room.send(.setHandsFree(false))
        room.begin(rings: false)
        await tapTurn(room, listener, "Any news?")
        await sent(room, 1)
        let reply = "The roof is done, and the porch starts Monday."
        room.receive([post("p1", reply)])
        await says(speaker, 0, reply)

        await tapTurn(room, listener, "Add max to this call.")
        await until("max is asked to join") { room.state.with.contains("max") }
        XCTAssertEqual(line.askCount, 0, "a control, not a turn for the voice line")
        await says(speaker, 1, reply)
        speaker.finish()
        await room.hangUp()
        XCTAssertEqual(speaker.texts, [reply, reply], "picked up again, with nothing before it")
        XCTAssertEqual(header(of: reply, in: poster.transcript)?.contains("skipped"), false)
    }

    // MARK: - Nothing waits in silence

    /// Answers are still read while muted. Muting after talking over a reply reads it; unmuting while it is read never
    /// listens over it, and listening comes back after it.
    func test_muting_after_talking_over_a_reply_reads_it_and_unmuting_never_listens_over_it() async {
        let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
        let room = call(line, listener, speaker, poster, handsFree: true)
        let microphone = QueueMicrophone(room: room, clock: clock)
        let reply = "Both builds passed review, and the release goes out at noon."
        room.begin(rings: false)
        await handsFreeTurn(room, listener, microphone, "What did I miss?")
        await sent(room, 1)
        room.receive([post("r1", reply)])
        await says(speaker, 0, reply)

        room.send(.toggleTalk)
        XCTAssertTrue(room.state.isListening, "talking over it")
        room.send(.setMuted(true))
        XCTAssertTrue(room.state.isMuted)
        await says(speaker, 1, reply)
        XCTAssertFalse(room.state.isListening, "muted, the reply you talked over is read")

        room.send(.setMuted(false))
        await settle()
        XCTAssertEqual(room.state.speaker, "ada", "still read")
        XCTAssertFalse(room.state.isListening, "unmuting never listens over a reply")
        XCTAssertEqual(speaker.stops, 1, "only the talk-over stopped anything")
        speaker.finish()
        await until("listening once it is read") { room.state.isListening }
        await room.hangUp()
        XCTAssertFalse(poster.transcript.contains("skipped"), poster.transcript)
    }

    /// Talking over a reply when the microphone cannot be had: nothing listens, so the reply is read again.
    func test_when_listening_cannot_start_the_reply_talked_over_is_read() async {
        let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
        let room = call(line, listener, speaker, poster, handsFree: false)
        let reply = "The roof is done, and the porch starts Monday."
        room.begin(rings: false)
        await tapTurn(room, listener, "Any news?")
        await sent(room, 1)
        room.receive([post("p1", reply)])
        await says(speaker, 0, reply)

        listener.failsToStart = true
        room.send(.toggleTalk)
        await says(speaker, 1, reply)
        XCTAssertEqual(room.state.notice, "The microphone is busy.")
        XCTAssertFalse(room.state.isListening)
        await room.hangUp()
    }

    /// Hands-free, a spoken "add max" said over a reply reads the reply again before listening comes back.
    func test_hands_free_a_spoken_add_said_over_a_reply_reads_it_before_listening() async {
        let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
        let clock = self.clock
        let room = VoiceRoomCoordinator(sessionId: "room_reply_queue_\(UUID().uuidString)", with: ["ada"],
                                        you: "mrrcarter", ownAuthorIds: ["human-mrrcarter"], listener: listener,
                                        speaker: speaker, audio: QueueAudio(), addable: { ["ada", "max"] },
                                        poster: poster, voiceLine: line, now: { clock.now },
                                        sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) })
        let microphone = QueueMicrophone(room: room, clock: clock)
        let reply = "The roof is done, and the porch starts Monday."
        room.begin(rings: false)
        await handsFreeTurn(room, listener, microphone, "Any news?")
        await sent(room, 1)
        room.receive([post("p1", reply)])
        await says(speaker, 0, reply)

        room.send(.toggleTalk)
        await handsFreeTurn(room, listener, microphone, "Add max to this call.")
        await until("max is asked to join") { room.state.with.contains("max") }
        await says(speaker, 1, reply)
        XCTAssertFalse(room.state.isListening, "the reply comes first, then listening")
        XCTAssertEqual(line.askCount, 0, "a control, not a turn")
        await room.hangUp()
    }

    /// A late answer waiting on the voice line's answer to a turn for Senti is read when the line answers that it
    /// cannot (off, not yours, or resting).
    func test_a_late_answer_waiting_on_the_line_is_read_when_the_line_says_it_cannot_answer() async {
        let errors: [VoiceLineError] = [.unavailable, .notAllowed, .rateLimited(retryAfter: 30)]
        for error in errors {
            let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
            let room = call(line, listener, speaker, poster, with: ["senti", "ada"], handsFree: false)
            room.begin(rings: false)
            await tapTurn(room, listener, "Ada, any news?")
            await sent(room, 1)
            await tapTurn(room, listener, "Senti, any news?")
            await until("\(error): asked as Senti") { line.askCount == 1 }
            XCTAssertEqual(line.agents, ["senti"], "\(error)")
            room.receive([post("p1", "The roof is done.")])
            await settle()
            XCTAssertTrue(speaker.spoken.isEmpty, "\(error): waits while the line may answer")
            line.fail(0, error)
            await says(speaker, 0, "The roof is done.")
            await settle()
            XCTAssertEqual(speaker.spoken.count, 1, "\(error): read once, with nothing before it")
            await room.hangUp()
        }
    }

    // MARK: - What is never read is marked

    /// A reply skipped with Skip, one talked over and never got back to, and one still waiting when the call ends are
    /// each marked in the transcript with why, never as "not read".
    func test_a_reply_never_read_in_full_is_marked_skipped_in_the_transcript_with_why() async {
        let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
        let room = call(line, listener, speaker, poster, handsFree: false)
        let r1 = "The first reply, skipped."
        let r2 = "The second reply, talked over."
        let r3 = "The third reply, still waiting."
        let r4 = "The fourth reply, read in full."
        room.begin(rings: false)
        await tapTurn(room, listener, "What is new?")
        await sent(room, 1)
        room.receive([post("r4", r4), post("r1", r1), post("r2", r2)])
        await says(speaker, 0, r4)
        speaker.finish()
        await says(speaker, 1, r1)
        room.send(.skip)
        await says(speaker, 2, r2)
        room.send(.toggleTalk)
        await until("listening over it") { listener.partial != nil }
        room.receive([post("r3", r3)])
        await settle()
        await room.hangUp()

        let transcript = poster.transcript
        XCTAssertFalse(transcript.contains("not read"), transcript)
        XCTAssertEqual(header(of: r1, in: transcript)?.hasSuffix(" · skipped: you skipped it"), true, transcript)
        XCTAssertEqual(header(of: r2, in: transcript)?.hasSuffix(" · skipped: you talked over it"), true, transcript)
        XCTAssertEqual(header(of: r3, in: transcript)?.hasSuffix(" · skipped: the call ended first"), true, transcript)
        XCTAssertEqual(header(of: r4, in: transcript)?.contains("skipped"), false, "read in full: no mark")
    }

    // MARK: - A long reply is read whole

    /// A reply of about a hundred words is read in full, as one piece, and nothing that lands meanwhile cuts it off.
    func test_a_reply_of_about_a_hundred_words_is_read_whole() async {
        let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
        let room = call(line, listener, speaker, poster, handsFree: false)
        let long: String = "Here is everything from this week. The garden beds on the north side are built and filled, and "
            + "the drip lines are in, though two of the timers still need new batteries before they run on their own. "
            + "The shed roof was patched on Tuesday after the storm, and the gutter on the back corner was rehung so "
            + "the water now runs away from the door. The tool order came in short by one rake and two pairs of "
            + "gloves, which are on their way. Next week we plant the beans and the squash, and the compost bins get "
            + "turned for the first time."
        XCTAssertGreaterThanOrEqual(long.split(separator: " ").count, 95)
        room.begin(rings: false)
        await tapTurn(room, listener, "How is the garden?")
        await sent(room, 1)
        room.receive([post("long", long)])
        await says(speaker, 0, long)
        room.receive([post("after", "And the gate is fixed.")])
        await settle()
        XCTAssertEqual(speaker.stops, 0, "nothing cuts it off")
        XCTAssertEqual(speaker.spoken.count, 1)
        speaker.finish()
        await says(speaker, 1, "And the gate is fixed.")
        speaker.finish()
        await room.hangUp()
        XCTAssertEqual(header(of: long, in: poster.transcript)?.contains("skipped"), false)
    }

    // MARK: - The bridge

    /// While the agent a turn is for writes, its fast voice says it is answering, by name, in that agent's voice: on a
    /// call with one agent, and on a call with several, for the one the turn is for.
    func test_the_bridge_names_the_agent_the_turn_is_for_in_its_own_voice() async {
        do {
            let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
            let room = call(line, listener, speaker, poster, handsFree: false)
            room.begin(rings: false)
            await tapTurn(room, listener, "Any news?")
            await sent(room, 1)
            clock.advance(VoiceRoomCoordinator.bridgeAfter + 0.1)
            await says(speaker, 0, "One moment, ada is answering.")
            XCTAssertEqual(speaker.spoken[0].speaker, "ada")
            speaker.finish()
            room.receive([post("p1", "The roof is done.")])
            await says(speaker, 1, "The roof is done.")
            XCTAssertEqual(line.askCount, 0)
            await room.hangUp()
        }
        do {
            let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
            let room = call(line, listener, speaker, poster, with: ["ada", "max"], handsFree: false)
            room.begin(rings: false)
            room.receive([post("h1", "Ada here."), post("h2", "Max here.", from: "max")])
            await says(speaker, 0, "Ada here.")
            speaker.finish()
            await tapTurn(room, listener, "Max, what's next?")
            await sent(room, 1)
            clock.advance(VoiceRoomCoordinator.bridgeAfter + 0.1)
            await says(speaker, 1, "One moment, max is answering.")
            XCTAssertEqual(speaker.spoken[1].speaker, "max", "in the voice of the agent the turn is for")
            speaker.finish()
            room.receive([post("p1", "The roof, then the porch.", from: "max")])
            await says(speaker, 2, "The roof, then the porch.")
            XCTAssertEqual(line.askCount, 0)
            await room.hangUp()
        }
    }

    // MARK: - The hello

    /// The agent's fast voice picks up with a hello. The agent's own hello in exactly those words is the one post not
    /// read (it would say it twice); a hello in any other words is read, with nothing before it.
    func test_only_a_hello_in_the_same_words_as_the_fast_voices_is_not_read() async {
        let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
        let room = call(line, listener, speaker, poster, handsFree: false)
        room.begin()
        for _ in 0..<200 where speaker.spoken.isEmpty {
            clock.advance(0.25)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await says(speaker, 0, "Hi, it's ada. Go ahead.")
        speaker.finish()
        room.receive([post("same", "hi, it's Ada... go ahead!")])
        await settle()
        XCTAssertEqual(speaker.spoken.count, 1, "the same words are not said twice")
        room.receive([post("own", "Hi there, ada here. Good morning.")])
        await says(speaker, 1, "Hi there, ada here. Good morning.")
        speaker.finish()
        await room.hangUp()
        let transcript = poster.transcript
        XCTAssertEqual(header(of: "hi, it's Ada... go ahead!", in: transcript)?.hasSuffix(" · skipped: same words as the hello"),
                       true, transcript)
        XCTAssertEqual(header(of: "Hi there, ada here. Good morning.", in: transcript)?.contains("skipped"), false)
    }
}
