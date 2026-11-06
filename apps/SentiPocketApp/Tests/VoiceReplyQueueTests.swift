import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

// A call the fast voice line answers first (Carter, 11-06): the agent's own replies are queued, never dropped, and read
// in full after a short handoff in the same voice. Agents and words here are made up.

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
}

@MainActor
private final class QueueListener: VoiceListening {
    var partial: (@MainActor (String) -> Void)?
    var said = ""
    func start(partial: @escaping @MainActor (String) -> Void) async throws { said = ""; self.partial = partial }
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
    private static let firstPerson = "I have the full update for you now, here it is."

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

    /// A real call, replayed with made-up words at its own pace (seconds after the agent's fast voice picked up). The
    /// voice line answered all five turns, and the agent's own four replies landed 15 s, 18 s, 10 s and 4 s after the
    /// line's answers; every one was kept as text and never heard. Now each is read in full, in order, after the
    /// handoff: one that lands while the phone listens is read at once, one that lands while another is read follows
    /// it in the same batch, and one that lands while the line is still talking waits for it. The person talks once
    /// what is read is over, as they would have.
    func test_a_call_where_the_voice_line_answered_every_turn_reads_all_four_replies_in_order_after_the_handoff() async {
        let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
        let room = call(line, listener, speaker, poster, handsFree: true)
        let microphone = QueueMicrophone(room: room, clock: clock)
        let hello = "Hi, it's ada. Go ahead."
        let a: [String] = ["Two things changed: the bridge drawings were approved and the paint order went in.",
                 "One delivery slot moved to Friday, and a new slot is waiting for your pick."]
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
                + "off, and the second sensor comes before anything changes."
        ]
        let early = "The last notes say the lights and the rails are still in progress."
        let b: [String] = ["The last notes say the walkway lights are still being wired, and the test results are not in yet.",
                 "I don't have more on the walkway in the room right now, so I'll post the details there."]
        let c = "Got it, I'll say the lights update again more briefly and post the details in the room."
        let d: [String] = ["I don't have an opening date in the room right now.",
                 "Several parts are done, some work is not confirmed yet, and a few blockers are still open.",
                 "I'll post the current opening details in the room."]
        let e = "You're welcome. I'll keep the opening and lights details posted in the room."
        var next = 0

        // 0 s: the ring is picked up by the agent's fast voice.
        room.begin()
        for _ in 0..<200 where speaker.spoken.isEmpty {
            clock.advance(0.25)
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await says(speaker, next, hello); next += 1
        clock.advance(2)
        speaker.finish()

        // 10 s: your first turn. 13 s: the line's quick answer, two sentences.
        clock.advance(6)
        await handsFreeTurn(room, listener, microphone, "What did I miss this morning? I'm heading out for a run.")
        await until("asked about turn 1") { line.askCount == 1 }
        clock.advance(3)
        line.answer(0, a[0], a[1])
        await says(speaker, next, a[0]); next += 1
        clock.advance(10)
        speaker.finish()
        await says(speaker, next, a[1]); next += 1
        clock.advance(5)
        speaker.finish()

        // 28 s: the agent's first reply lands while the phone listens: the handoff, then the reply.
        await until("listening after the line's answer") { room.state.isListening && listener.partial != nil }
        room.receive([post("r1", replies[0])])
        await says(speaker, next, Self.firstPerson); next += 1
        XCTAssertEqual(speaker.spoken.last?.speaker, "ada", "the handoff is in the agent's voice")
        XCTAssertEqual(room.state.speaker, "ada (voice)", "said by the voice line")
        clock.advance(2.5)
        speaker.finish()
        await says(speaker, next, replies[0]); next += 1
        // 31 s: the second lands while the first is read: it follows it, in the same batch.
        clock.advance(0.5)
        room.receive([post("r2", replies[1])])
        clock.advance(2.5)
        speaker.finish()
        await says(speaker, next, replies[1]); next += 1
        clock.advance(32)
        speaker.finish()

        // Your second turn, carried on just after it went; the line's answer to its first part is dropped, and it is
        // asked again with the whole turn.
        clock.advance(2)
        await handsFreeTurn(room, listener, microphone, "Sounds good. How is the other part going?", talking: 1.5)
        await until("asked about turn 2") { line.askCount == 2 }
        await until("listening a moment after it") { room.state.isListening && listener.partial != nil }
        microphone.loud(for: 0.5)
        listener.say("The lights along the walkway?")
        line.say(1, early)
        await until("the early answer is in the transcript") { room.state.turns.contains { $0.text == early } }
        microphone.quiet(for: VoiceRoomCoordinator.pauseAfterSentence + 0.1)
        await until("asked about the whole turn") { line.askCount == 3 }
        clock.advance(2)
        line.say(2, b[0], b[1])
        await says(speaker, next, b[0]); next += 1
        clock.advance(9)
        speaker.finish()
        await says(speaker, next, b[1]); next += 1
        // The third reply lands while the line is still talking and its answer still streams: it waits for it.
        clock.advance(1)
        room.receive([post("r3", replies[2])])
        await settle()
        XCTAssertEqual(speaker.spoken.count, next, "nothing cuts in over the line")
        line.end(2)
        clock.advance(8)
        speaker.finish()
        await says(speaker, next, Self.firstPerson); next += 1
        clock.advance(3)
        speaker.finish()
        await says(speaker, next, replies[2]); next += 1
        clock.advance(36)
        speaker.finish()

        // Your third turn and the line's answer.
        clock.advance(2)
        await handsFreeTurn(room, listener, microphone,
                            "Okay. I saw you said more about the lights, but I did not get to hear it.", talking: 2)
        await until("asked about turn 3") { line.askCount == 4 }
        clock.advance(2)
        line.answer(3, c)
        await says(speaker, next, c); next += 1
        clock.advance(5)
        speaker.finish()

        // Your fourth turn; the fourth reply lands 4 s into the line's three-sentence answer, and waits for all of it.
        clock.advance(13)
        await handsFreeTurn(room, listener, microphone, "How far are we from opening day?")
        await until("asked about turn 4") { line.askCount == 5 }
        clock.advance(1)
        line.answer(4, d[0], d[1], d[2])
        await says(speaker, next, d[0]); next += 1
        clock.advance(4)
        room.receive([post("r4", replies[3])])
        clock.advance(1)
        speaker.finish()
        await says(speaker, next, d[1]); next += 1
        clock.advance(5)
        speaker.finish()
        await says(speaker, next, d[2]); next += 1
        clock.advance(3)
        speaker.finish()
        await says(speaker, next, Self.firstPerson); next += 1
        clock.advance(3)
        speaker.finish()
        await says(speaker, next, replies[3]); next += 1
        clock.advance(10)
        speaker.finish()

        // Your last turn, and the line's answer.
        clock.advance(5)
        await handsFreeTurn(room, listener, microphone, "Thank you.", talking: 0.6)
        await until("asked about turn 5") { line.askCount == 6 }
        clock.advance(1)
        line.answer(5, e)
        await says(speaker, next, e); next += 1
        clock.advance(4)
        speaker.finish()
        XCTAssertEqual(speaker.stops, 0, "nothing was cut off")
        await room.hangUp()

        XCTAssertEqual(speaker.texts.filter { replies.contains($0) }, replies, "all four replies, each once, in order")
        XCTAssertEqual(speaker.texts, [hello, a[0], a[1], Self.firstPerson, replies[0], replies[1], b[0], b[1],
                                       Self.firstPerson, replies[2], c, d[0], d[1], d[2], Self.firstPerson, replies[3], e])
        XCTAssertTrue(speaker.spoken.filter { replies.contains($0.text) }.allSatisfy { $0.speaker == "ada" })
        let transcript = poster.transcript
        XCTAssertFalse(transcript.contains("not read"), transcript)
        XCTAssertFalse(transcript.contains("skipped"), transcript)
        for reply in replies {
            XCTAssertEqual(header(of: reply, in: transcript)?.hasPrefix("**ada** · "), true, reply)
            XCTAssertEqual(header(of: reply, in: transcript)?.contains(" · held"), false, reply)
        }
    }

    // MARK: - Talking over a reply

    /// Talking over a reply pauses it, never drops it. While you talk nothing waiting is read, even what lands then;
    /// the line answers your new turn first, and then the reply you talked over is introduced again and read in full,
    /// with the ones after it, in order.
    func test_talking_over_a_reply_pauses_it_and_it_is_read_in_full_after_your_turn() async {
        let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
        let room = call(line, listener, speaker, poster, handsFree: true)
        let microphone = QueueMicrophone(room: room, clock: clock)
        let r1 = "Both builds passed review, and the release goes out at noon."
        let r2 = "One more thing: the guide is live."
        let r3 = "Also, the dashboard is back."
        room.begin(rings: false)

        await handsFreeTurn(room, listener, microphone, "What did I miss?")
        await until("asked") { line.askCount == 1 }
        clock.advance(2)
        line.answer(0, "Two builds shipped.")
        await says(speaker, 0, "Two builds shipped.")
        speaker.finish()
        await until("listening") { room.state.isListening && listener.partial != nil }
        room.receive([post("r1", r1), post("r2", r2)])
        await says(speaker, 1, Self.firstPerson)
        speaker.finish()
        await says(speaker, 2, r1)

        // You talk over it.
        room.send(.toggleTalk)
        XCTAssertEqual(speaker.stops, 1, "talking over it stops it")
        XCTAssertTrue(room.state.isListening)
        XCTAssertEqual(room.state.waiting, 2, "the reply you talked over waits, with the one after it")
        await until("listening over the reply") { listener.partial != nil }
        room.receive([post("r3", r3)])
        await settle()
        XCTAssertTrue(room.state.isListening, "what lands while you talk over a reply waits for your turn")
        XCTAssertEqual(speaker.spoken.count, 3, "nothing is read while you talk")
        XCTAssertEqual(room.state.waiting, 3)

        microphone.loud(for: 0.6)
        listener.say("Wait, which builds?")
        microphone.quiet(for: VoiceRoomCoordinator.pauseAfterSentence + 0.1)
        await until("asked about your new turn") { line.askCount == 2 }
        clock.advance(2)
        line.answer(1, "The phone and the web builds.")
        await says(speaker, 3, "The phone and the web builds.")
        speaker.finish()
        await says(speaker, 4, Self.firstPerson)
        speaker.finish()
        await says(speaker, 5, r1)
        speaker.finish()
        await says(speaker, 6, r2)
        speaker.finish()
        await says(speaker, 7, r3)
        speaker.finish()
        await until("listening again") { room.state.isListening }
        await room.hangUp()
        XCTAssertEqual(speaker.texts, ["Two builds shipped.", Self.firstPerson, r1, "The phone and the web builds.",
                                       Self.firstPerson, r1, r2, r3])
        XCTAssertFalse(poster.transcript.contains("skipped"), "every reply was read in full in the end")
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
        await until("asked") { line.askCount == 1 }
        line.answer(0, "A few things.")
        await says(speaker, 0, "A few things.")
        speaker.finish()
        room.receive([post("r4", r4), post("r1", r1), post("r2", r2)])
        await says(speaker, 1, Self.firstPerson)
        speaker.finish()
        await says(speaker, 2, r4)
        speaker.finish()
        await says(speaker, 3, r1)
        room.send(.skip)
        await says(speaker, 4, r2)
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
        await until("asked") { line.askCount == 1 }
        line.answer(0, "The beds are built.")
        await says(speaker, 0, "The beds are built.")
        speaker.finish()
        room.receive([post("long", long)])
        await says(speaker, 1, Self.firstPerson)
        speaker.finish()
        await says(speaker, 2, long)
        room.receive([post("after", "And the gate is fixed.")])
        await settle()
        XCTAssertEqual(speaker.stops, 0, "nothing cuts it off")
        XCTAssertEqual(speaker.spoken.count, 3)
        speaker.finish()
        await says(speaker, 3, "And the gate is fixed.")
        speaker.finish()
        await room.hangUp()
        XCTAssertEqual(header(of: long, in: poster.transcript)?.contains("skipped"), false)
    }

    // MARK: - The handoff

    /// On a call with one agent the voice line is that agent speaking, so its handoff says "I". On a call with
    /// several, it says whose update it is.
    func test_the_handoff_is_first_person_with_one_agent_and_names_the_agent_with_several() async {
        do {
            let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
            let room = call(line, listener, speaker, poster, handsFree: false)
            room.begin(rings: false)
            await tapTurn(room, listener, "Any news?")
            await until("asked") { line.askCount == 1 }
            line.answer(0, "Some.")
            await says(speaker, 0, "Some.")
            speaker.finish()
            room.receive([post("p1", "The roof is done.")])
            await says(speaker, 1, "I have the full update for you now, here it is.")
            XCTAssertEqual(speaker.spoken[1].speaker, "ada")
            speaker.finish()
            await says(speaker, 2, "The roof is done.")
            await room.hangUp()
        }
        do {
            let line = QueueVoiceLine(), listener = QueueListener(), speaker = QueueSpeaker(), poster = QueuePoster()
            let room = call(line, listener, speaker, poster, with: ["ada", "max"], handsFree: false)
            room.begin(rings: false)
            room.receive([post("h1", "Ada here."), post("h2", "Max here.", from: "max")])
            await says(speaker, 0, "Ada here.")
            speaker.finish()
            await tapTurn(room, listener, "Ada, what's next?")
            await until("asked as Ada") { line.askCount == 1 }
            XCTAssertEqual(line.agents, ["ada"])
            line.answer(0, "The roof.")
            await says(speaker, 1, "The roof.")
            speaker.finish()
            room.receive([post("p1", "The roof, then the porch.")])
            await says(speaker, 2, "ada has the full update for you now, here it is.")
            XCTAssertEqual(speaker.spoken[2].speaker, "ada", "in the voice that answered")
            speaker.finish()
            await says(speaker, 3, "The roof, then the porch.")
            await room.hangUp()
        }
    }

    // MARK: - The hello

    /// The agent's fast voice picks up with a hello. The agent's own hello in exactly those words is the one post not
    /// read (it would say it twice); a hello in any other words is read, after the handoff.
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
        await says(speaker, 1, Self.firstPerson)
        speaker.finish()
        await says(speaker, 2, "Hi there, ada here. Good morning.")
        speaker.finish()
        await room.hangUp()
        let transcript = poster.transcript
        XCTAssertEqual(header(of: "hi, it's Ada... go ahead!", in: transcript)?.hasSuffix(" · skipped: same words as the hello"),
                       true, transcript)
        XCTAssertEqual(header(of: "Hi there, ada here. Good morning.", in: transcript)?.contains("skipped"), false)
    }
}
