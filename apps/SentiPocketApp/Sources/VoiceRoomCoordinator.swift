import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import PocketVoice

/// A voice conversation in a room, run on the phone: you talk, the phone recognizes it and posts it to the room as a
/// spoken turn (`channel: "voice"`), the agents answer in the room from their own listeners on their own models, and
/// the phone reads each answer aloud in that agent's own voice. No audio leaves the phone. With one agent, your turns
/// mention it so it knows they are for it; with everyone, it is a meeting and every agent's answer is read.
///
/// It rings like a call: a ringback tone plays and the phone does not listen until the agent picks up by answering, so
/// its hello is heard before you say anything (Carter, 10-30: "when I call there should be a ring calling and when
/// picked up there should be me hearing the hi Carter part"). After a while with no answer the ring stops and the
/// line is open.
///
/// One thing at a time: while you talk, answers wait; while an answer is read, the next waits. An answer that lands
/// while the phone is listening but you have not started talking is read at once. Hands-free, listening
/// comes back after the answers and a pause sends your turn. Hanging up saves the whole transcript to the room as one
/// Markdown file on the message that closes the call, which asks the agents for a short summary.
@MainActor
final class VoiceRoomCoordinator: ObservableObject {
    @Published private(set) var state: VoiceRoomState

    private let sessionId: String
    private let you: String
    /// The agents the call rings: the one you talk with, or everyone here in a meeting.
    private let invited: [String]
    private let ownAuthorIds: Set<String>
    private let listener: any VoiceListening
    private let speaker: any VoiceSpeaking
    private let audio: any VoiceRoomAudioSession
    private let ringer: (any VoiceRoomRinging)?
    private let poster: any VoiceRoomPosting
    /// The fast voice line (API #1062): a spoken answer in about a second, as "<agent> (voice)"; nil without one.
    private let voiceLine: (any VoiceLining)?
    /// The server said it has no voice line: the rest of the call waits for the agents' own answers.
    private var voiceLineOff = false
    private var voiceLineAsk: Task<Void, Never>?
    /// After a 429 the voice line rests until then (the server's Retry-After).
    private var voiceLineRestsUntil = Date.distantPast
    /// Asks whether a pause ends the turn (the signal model, through the server); nil without it.
    private let endpointer: (any VoiceEndpointing)?
    private var endpointerOff = false
    /// The words already asked about in this pause, so one pause is asked about once.
    private var askedAbout: String?
    /// One id for the whole call, so the voice line meters and limits it as one.
    private let callId = UUID().uuidString.lowercased()
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let onEnded: @MainActor () -> Void
    /// The call's record could not be saved after the call screen went: said in the room instead.
    private let onRecordFailed: @MainActor (String) -> Void

    /// Answers waiting to be read, oldest first.
    private var queue: [VoiceRoomTurn] = []
    /// Messages and replies already taken, so a message seen twice (stream and poll) is read once.
    private var taken: Set<String> = []
    private var lastHeard: Date?
    private var silenceWatch: Task<Void, Never>?
    private var ringWatch: Task<Void, Never>?
    /// The message that rang the agents: hang-up waits for it, so an end never lands before its start, and a call
    /// whose ring never went out ends without an end message (warden, #267).
    private var startPost: Task<Bool, Never>?
    /// Each room's last call record still being saved: a new call's ring waits for it, so an old end can't close a
    /// new call's card.
    private static var closing: [String: Task<Void, Never>] = [:]
    private var listenGeneration = 0

    /// How fast the call is, measured as it goes; reported when it ends.
    private(set) var timings = VoiceCallTimings()
    /// When you last stopped talking, for the gap until the answer is heard.
    private var turnStoppedAt: Date?
    /// When the room accepted your latest turn; nil once its first answer arrived.
    private var awaitingAnswerSince: Date?
    /// The first answer to your latest turn: when it is heard, the gap is measured.
    private var gapAnswerId: String?
    /// In a meeting, who answered your latest turn first (lowercased), and whether the others were told.
    private var floorHolder: (id: String, name: String)?
    private var floorAnnounced = false

    /// A pause this long ends your turn, hands-free.
    static let pauseEndsTurn: TimeInterval = 1.4
    /// After words that end a sentence ("." "?" "!"), a shorter pause does.
    static let pauseAfterSentence: TimeInterval = 0.8
    /// A turn never runs past this (the recognizer's own limit is about a minute).
    static let longestTurn: TimeInterval = 50
    /// Answers from just before the call started still count (clocks differ a little).
    static let clockSlack: TimeInterval = 5
    /// After this much silence the phone asks whether the turn is over, and ends it at once when it is.
    static let askAfter: TimeInterval = 0.3
    /// How sure the answer must be to end a turn early (9 of 10 test phrases right at this line, 10-30).
    static let finishedAt = 0.7

    /// How long the call rings before the line opens without an answer.
    static let ringsFor: TimeInterval = 30

    init(
        sessionId: String,
        with agents: [String],
        invited: [String]? = nil,
        you: String,
        ownAuthorIds: Set<String>,
        listener: any VoiceListening,
        speaker: any VoiceSpeaking,
        audio: any VoiceRoomAudioSession,
        ringer: (any VoiceRoomRinging)? = nil,
        poster: any VoiceRoomPosting,
        voiceLine: (any VoiceLining)? = nil,
        endpointer: (any VoiceEndpointing)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        onEnded: @escaping @MainActor () -> Void = {},
        onRecordFailed: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.sessionId = sessionId
        self.you = you
        self.invited = invited ?? agents
        self.ownAuthorIds = Set(ownAuthorIds.map { $0.lowercased() })
        self.listener = listener
        self.speaker = speaker
        self.audio = audio
        self.ringer = ringer
        self.poster = poster
        self.voiceLine = voiceLine
        self.endpointer = endpointer
        self.now = now
        self.sleep = sleep
        self.onEnded = onEnded
        self.onRecordFailed = onRecordFailed
        state = VoiceRoomState(with: agents, startedAt: now())
    }

    /// Rings the agents (one message that mentions them and opens the call's card), takes the phone's audio and plays
    /// the ring until an agent picks up. Answering an agent's own call there is nothing to ring: the line is open.
    func begin(rings: Bool = true) {
        do {
            try audio.activate()
        } catch {
            // Nothing rings without the phone's audio (warden, #267: it showed "Ringing…" for ever).
            state.ringStopped = true
            state.notice = "The phone's audio is busy (a call or another app). End it and try again."
            return
        }
        let ring = VoiceCallMarkers.start(caller: you, agents: invited, meeting: state.with.isEmpty)
        let clientId = "voice-start-" + callId
        let previous = Self.closing[sessionId]
        startPost = Task { [weak self] in
            // The room's last call is closed first, so its end lands before this ring.
            await previous?.value
            guard let self else { return false }
            do {
                try await self.poster.postCallStarted(sessionId: self.sessionId, text: ring, clientId: clientId)
                // The ring sounds, and its 30 s run, once the agents have been rung, not while the ring message waits
                // on the network or on the room's last end (warden, #271).
                if self.state.isRinging {
                    self.ringer?.startRinging()
                    self.watchForPickup()
                }
                return true
            } catch {
                // Nobody was rung, so nothing rings (warden, #267).
                self.stopRinging()
                self.state.notice = "The agents could not be rung. Check the connection."
                return false
            }
        }
        // Nobody to ring (a meeting in a room with no agents): the line is open at once.
        guard rings, !invited.isEmpty else {
            state.ringStopped = true
            if state.isHandsFree { startListening() }
            return
        }
    }

    /// No answer for a while: the ring stops and the line opens (hands-free, listening starts).
    private func watchForPickup() {
        let started = now()
        ringWatch = Task { [weak self] in
            while let self, !Task.isCancelled, self.state.isRinging {
                await self.sleep(0.25)
                guard !Task.isCancelled, self.state.isRinging else { return }
                guard self.now().timeIntervalSince(started) >= Self.ringsFor else { continue }
                self.stopRinging()
                if self.state.isHandsFree, self.state.phase == .ready { self.startListening() }
                // After listening starts, which clears notices.
                self.state.notice = "\(self.state.title) hasn't picked up yet. Talk when you're ready; the answer is read when it comes."
                return
            }
        }
    }

    private func stopRinging() {
        ringWatch?.cancel()
        ringWatch = nil
        guard state.isRinging else { return }
        state.ringStopped = true
        ringer?.stopRinging()
    }

    func send(_ intent: VoiceRoomIntent) {
        switch intent {
        case .toggleTalk:
            if state.isListening { endTurn() } else { startListening() }
        case .talk(let pressed):
            if pressed, !state.isListening { startListening() } else if !pressed, state.isListening { endTurn() }
        case .skip:
            guard state.speaker != nil else { return }
            speaker.stop()
            afterSpeaking()
        case .setHandsFree(let on):
            state.isHandsFree = on
            if on, state.phase == .ready, queue.isEmpty { startListening() }
        case .hangUp:
            Task { await hangUp() }
        }
    }

    // MARK: - Answers

    /// Live room messages: the agents' answers (in a call with one agent, only that agent's).
    func receive(_ messages: [RoomMessage]) {
        for message in messages where message.kind == .message {
            take(id: "msg:\(message.id)", author: message.authorId, isHuman: message.isHuman, text: message.text,
                 timestamp: message.timestamp)
        }
        yieldIfNotTalking()
        speakIfReady()
    }

    /// Threaded replies seen since the last read: an agent may answer in a thread.
    func receive(replies: [RoomReply]) {
        for reply in replies {
            take(id: "reply:\(reply.id)", author: reply.authorId, isHuman: reply.isHuman, text: reply.text,
                 timestamp: reply.createdAt)
        }
        yieldIfNotTalking()
        speakIfReady()
    }

    /// Hands-free listening that has heard nothing yet gives way to an answer that has come in: it is read now, and
    /// listening comes back after it. Once you have started talking, answers wait.
    private func yieldIfNotTalking() {
        guard state.isListening, state.isHandsFree, !queue.isEmpty, lastHeard == nil, state.partial.isEmpty else { return }
        listenGeneration += 1
        silenceWatch?.cancel()
        listener.cancel()
        state.phase = .ready
    }

    private func take(id: String, author: String, isHuman: Bool, text: String, timestamp: String) {
        guard state.phase != .ending, state.phase != .ended, !taken.contains(id) else { return }
        let lowered = author.lowercased()
        guard !lowered.isEmpty, !ownAuthorIds.contains(lowered),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let at = ParsedSessionTimestamp(timestamp).date ?? now()
        guard at >= state.startedAt.addingTimeInterval(-Self.clockSlack) else { return }
        let name = isHuman ? String(author.dropFirst("human-".count)) : author
        if !state.with.isEmpty, !state.with.contains(where: { $0.lowercased() == lowered }) { return }
        taken.insert(id)
        if state.joined.isEmpty {
            // Picked up: the ring stops and the answer is read.
            stopRinging()
            state.notice = nil
        }
        if !state.joined.contains(where: { $0.lowercased() == lowered }) { state.joined.append(name) }
        // In a meeting the first agent to answer a turn has the floor; the others are kept, not read (Carter, 10-30).
        if state.with.isEmpty, !isHuman {
            if let holder = floorHolder, holder.id != lowered {
                state.turns.append(VoiceRoomTurn(id: id, speaker: name, isYou: false, text: text, at: at, isHeld: true))
                timings.noteHeld()
                announceFloor(holder: holder.name)
                return
            }
            floorHolder = (lowered, name)
        }
        if let since = awaitingAnswerSince {
            timings.record(.answer, now().timeIntervalSince(since))
            awaitingAnswerSince = nil
            gapAnswerId = id
        }
        let turn = VoiceRoomTurn(id: id, speaker: name, isYou: false, text: text, at: at)
        queue.append(turn)
        state.turns.append(turn)
        state.waiting = queue.count
    }

    /// Tells the room, once a turn, who has the floor, so the agents still writing hold back.
    private func announceFloor(holder: String) {
        guard !floorAnnounced else { return }
        floorAnnounced = true
        let text = "🎙️ \(holder) has the floor for this turn. Everyone else, hold until the next one."
        Task { [weak self] in
            guard let self else { return }
            try? await self.poster.postVoiceTurn(sessionId: self.sessionId, text: text,
                                                 clientId: "voice-floor-" + UUID().uuidString.lowercased())
        }
    }

    /// Reads the next answer when nothing else is happening: never over you while you talk.
    private func speakIfReady() {
        guard state.phase == .ready, !queue.isEmpty else {
            state.waiting = queue.count
            return
        }
        let next = queue.removeFirst()
        state.waiting = queue.count
        state.phase = .speaking(speaker: next.speaker)
        let asked = now()
        let measuresGap = next.id == gapAnswerId
        if measuresGap { gapAnswerId = nil }
        // The voice line speaks in its agent's own voice; it is named "(voice)" everywhere else.
        speaker.speak(next.text, as: Self.voiceOf(next.speaker), started: { [weak self] in
            guard let self else { return }
            let heard = self.now()
            self.timings.record(.voiceStart, heard.timeIntervalSince(asked))
            if measuresGap, let stopped = self.turnStoppedAt {
                self.timings.record(.gap, heard.timeIntervalSince(stopped))
            }
        }, finished: { [weak self] in
            self?.afterSpeaking()
        })
    }

    private func afterSpeaking() {
        guard state.speaker != nil else { return }
        state.phase = .ready
        if !queue.isEmpty {
            speakIfReady()
        } else if state.isHandsFree {
            startListening()
        }
    }

    // MARK: - Your turns

    private func startListening() {
        guard state.phase == .ready || state.speaker != nil else { return }
        // Talking while it rings: no need to keep ringing.
        stopRinging()
        if state.speaker != nil {
            // Talking over an answer cuts it off; the ones after it wait.
            speaker.stop()
        }
        listenGeneration += 1
        let generation = listenGeneration
        state.phase = .listening
        state.partial = ""
        state.notice = nil
        lastHeard = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.listener.start { [weak self] text in
                    guard let self, generation == self.listenGeneration, self.state.isListening else { return }
                    self.state.partial = text
                    self.lastHeard = self.now()
                }
            } catch {
                guard generation == self.listenGeneration else { return }
                self.state.phase = .ready
                self.state.isHandsFree = false
                self.state.notice = (error as? LocalizedError)?.errorDescription ?? "Listening could not start."
                return
            }
            // The turn ended (or the call did) while listening was still starting: let go of the microphone.
            guard generation == self.listenGeneration, self.state.isListening else {
                self.listener.cancel()
                return
            }
            self.watchForPause(generation)
        }
    }

    /// Hands-free, a pause after some words sends the turn; any turn stops at the longest length.
    private func watchForPause(_ generation: Int) {
        silenceWatch?.cancel()
        let started = now()
        askedAbout = nil
        silenceWatch = Task { [weak self] in
            while let self, !Task.isCancelled, generation == self.listenGeneration, self.state.isListening {
                await self.sleep(0.1)
                guard generation == self.listenGeneration, self.state.isListening else { return }
                let elapsed = self.now().timeIntervalSince(started)
                if elapsed >= Self.longestTurn {
                    self.endTurn()
                    return
                }
                guard self.state.isHandsFree, let heard = self.lastHeard else { continue }
                let silence = self.now().timeIntervalSince(heard)
                if silence >= Self.pause(after: self.state.partial) {
                    self.endTurn()
                    return
                }
                if silence >= Self.askAfter { self.askIfFinished(generation) }
            }
        }
    }

    /// A short pause: asks whether the words so far are a finished turn, and ends it at once if they are and nothing
    /// has been said since (Carter, 10-30: "I thought jev would help us finish everything by 600ms"). Unsure, slow or
    /// unavailable, the normal pause still ends it.
    private func askIfFinished(_ generation: Int) {
        let words = state.partial
        guard let endpointer, !endpointerOff, askedAbout != words,
              !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        askedAbout = words
        Task { [weak self] in
            guard let self else { return }
            do {
                let done = try await endpointer.finished(sessionId: self.sessionId, text: words, callId: self.callId)
                guard done >= Self.finishedAt, generation == self.listenGeneration, self.state.isListening,
                      self.state.partial == words else { return }
                self.timings.noteEarlyEnd()
                self.endTurn()
            } catch VoiceLineError.unavailable {
                self.endpointerOff = true
            } catch {
                // Busy or failed: the normal pause ends the turn.
            }
        }
    }

    /// How long a silence ends a hands-free turn: shorter once the words so far end a sentence.
    static func pause(after partial: String) -> TimeInterval {
        let last = partial.trimmingCharacters(in: .whitespacesAndNewlines).last
        return last.map { ".?!".contains($0) } == true ? pauseAfterSentence : pauseEndsTurn
    }

    private func endTurn() {
        guard state.isListening else { return }
        listenGeneration += 1
        silenceWatch?.cancel()
        state.phase = .sending
        let stoppedTalking = lastHeard ?? now()
        let asked = now()
        Task { [weak self] in
            guard let self else { return }
            let heard = await self.listener.stop()
            self.timings.record(.recognition, self.now().timeIntervalSince(asked))
            // Fillers and words said twice are tidied before the turn is posted (Carter, #55058).
            let text = SpokenCleanup.clean(heard.isEmpty ? self.state.partial : heard)
            self.state.partial = ""
            guard !text.isEmpty else {
                self.state.phase = .ready
                self.speakIfReady()
                return
            }
            let turn = VoiceRoomTurn(id: "you:\(UUID().uuidString.lowercased())", speaker: self.you, isYou: true,
                                     text: text, at: self.now())
            self.state.turns.append(turn)
            // A new turn: the floor is open again, and its answer is timed from here.
            self.turnStoppedAt = stoppedTalking
            self.floorHolder = nil
            self.floorAnnounced = false
            self.gapAnswerId = nil
            // What is left of the last quick answer goes first, so none of it plays after you spoke (warden, #274).
            self.dropVoiceLineLeftovers()
            self.state.phase = .ready
            self.speakIfReady()
            self.askVoiceLine(text)
            await self.post(text)
        }
    }

    // MARK: - The voice line

    static let voiceSuffix = " (voice)"

    /// Whose voice says a turn: the voice line's turns are said in their agent's voice.
    static func voiceOf(_ speaker: String) -> String {
        speaker.hasSuffix(voiceSuffix) ? String(speaker.dropLast(voiceSuffix.count)) : speaker
    }

    /// Asks the voice line for a quick answer while the turn goes to the room (warden, Phase 2): each sentence is read
    /// as it arrives, and the agent's own answer still comes in the room after. A new turn drops what is left of the
    /// last quick answer.
    private func askVoiceLine(_ text: String) {
        guard let voiceLine, !voiceLineOff, now() >= voiceLineRestsUntil else { return }
        let agent = state.with.count == 1 ? state.with[0] : nil
        let speaker = (agent ?? "room") + Self.voiceSuffix
        let history = state.turns.dropLast().suffix(12).map { VoiceLineHistory(speaker: $0.speaker, text: $0.text) }
        let answerId = "line:" + UUID().uuidString.lowercased()
        let stream = voiceLine.voiceLine(sessionId: sessionId, agentId: agent, text: text, callId: callId,
                                         history: Array(history))
        voiceLineAsk = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self, !Task.isCancelled else { return }
                    if case .sentence(let sentence) = event { self.takeVoiceLine(sentence, answerId: answerId, as: speaker) }
                }
            } catch VoiceLineError.unavailable {
                self?.voiceLineOff = true
            } catch VoiceLineError.notAllowed {
                // Not this person's to use (warden, #274): off for the rest of the call.
                self?.voiceLineOff = true
            } catch VoiceLineError.rateLimited(let retryAfter) {
                guard let self else { return }
                self.voiceLineRestsUntil = self.now().addingTimeInterval(min(300, max(1, retryAfter ?? 30)))
            } catch {
                // A failed voice line is quiet: the agents' own answers still come.
            }
        }
    }

    /// A new turn or hang-up: the last quick answer stops streaming and what is left of it is not read.
    private func dropVoiceLineLeftovers() {
        voiceLineAsk?.cancel()
        voiceLineAsk = nil
        queue.removeAll { $0.id.hasPrefix("line:") }
        state.waiting = queue.count
    }

    private func takeVoiceLine(_ sentence: String, answerId: String, as speaker: String) {
        guard state.phase != .ending, state.phase != .ended else { return }
        let pieceId = answerId + ":" + UUID().uuidString.lowercased()
        if gapAnswerId == nil, turnStoppedAt != nil { gapAnswerId = pieceId }
        queue.append(VoiceRoomTurn(id: pieceId, speaker: speaker, isYou: false, text: sentence, at: now()))
        // The transcript keeps the quick answer as one turn, marked as the voice line's.
        if let index = state.turns.firstIndex(where: { $0.id == answerId }) {
            let turn = state.turns[index]
            state.turns[index] = VoiceRoomTurn(id: answerId, speaker: speaker, isYou: false,
                                               text: turn.text + " " + sentence, at: turn.at)
        } else {
            state.turns.append(VoiceRoomTurn(id: answerId, speaker: speaker, isYou: false, text: sentence, at: now()))
        }
        state.waiting = queue.count
        yieldIfNotTalking()
        speakIfReady()
    }

    /// Your turn in the room. With one agent it starts with that agent's mention, so its listener knows it is for it.
    private func post(_ text: String) async {
        let addressed = state.with.count == 1 ? "@\(state.with[0]) \(text)" : text
        let sending = now()
        do {
            try await poster.postVoiceTurn(sessionId: sessionId, text: addressed,
                                           clientId: "voice-" + UUID().uuidString.lowercased())
            timings.record(.post, now().timeIntervalSince(sending))
            awaitingAnswerSince = now()
        } catch {
            state.notice = "That turn did not reach the room. Say it again."
        }
    }

    // MARK: - Hanging up

    func hangUp() async {
        guard state.phase != .ending, state.phase != .ended else { return }
        listenGeneration += 1
        silenceWatch?.cancel()
        stopRinging()
        listener.cancel()
        speaker.stop()
        queue.removeAll()
        state.waiting = 0
        state.phase = .ending
        audio.deactivate()
        let ended = now()
        // The call screen goes at once; the call's record is saved after it (warden, #267: a stalled network held
        // every control for up to two minutes).
        onEnded()
        // A quick answer still streaming stops with the call, so it isn't billed until it times out (warden, #274).
        dropVoiceLineLeftovers()
        let saving = Task { [self] in await saveRecord(ended: ended) }
        Self.closing[sessionId] = saving
        await saving.value
        if Self.closing[sessionId] == saving { Self.closing[sessionId] = nil }
        state.phase = .ended
    }

    /// The call's record: its transcript and the message that closes it, after the ring went out. A call whose ring
    /// never went out (no audio, or the post failed) was never opened, so nothing closes it.
    private func saveRecord(ended: Date) async {
        guard await startPost?.value == true else { return }
        // The end carries the start's own id, so the call log pairs them even when two phones call in one room
        // (warden, API #1060).
        let clientId = "voice-end-" + callId
        var saved: VoiceTranscriptAttachment?
        var failure: String?
        if !state.turns.isEmpty {
            do {
                saved = try await poster.uploadTranscript(
                    sessionId: sessionId,
                    filename: "voice-\(Self.slug(state.title))-\(Self.fileStamp(state.startedAt)).md",
                    markdown: Self.transcript(state, ended: ended, timings: timings),
                    clientId: clientId + "-file"
                )
            } catch {
                failure = "The call's transcript could not be saved to the room."
            }
        }
        // Always closed, even with nothing said, so its card ends and no agent says hello into a finished call.
        let text = Self.closingMessage(state, ended: ended, hasTranscript: saved != nil, timings: timings)
        do {
            try await poster.postCallEnded(sessionId: sessionId, text: text, transcript: saved, clientId: clientId)
        } catch {
            failure = "The call's end could not be posted to the room. Its card may still show it as live."
        }
        if let failure {
            state.notice = failure
            onRecordFailed(failure)
        }
    }

    /// The whole conversation, oldest first, as Markdown.
    static func transcript(_ state: VoiceRoomState, ended: Date, timings: VoiceCallTimings = VoiceCallTimings()) -> String {
        var lines = [
            "# Voice room with \(state.title)",
            "",
            "\(Self.dayAndTime(state.startedAt)) · \(Self.duration(from: state.startedAt, to: ended)) · \(state.turns.count) turns",
            ""
        ]
        if state.turns.contains(where: { $0.speaker.hasSuffix(voiceSuffix) }) {
            // Warden's condition: the voice line is never taken for the agent's own words.
            lines.append("Turns marked (voice) are the fast voice line answering from the room, not the agent's own words.")
            lines.append("")
        }
        for turn in state.turns.sorted(by: { $0.at < $1.at }) {
            lines.append("**\(turn.speaker)** · \(Self.clock(turn.at))" + (turn.isHeld ? " · held: another agent had the floor" : ""))
            lines.append(turn.text.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        let table = timings.markdown()
        if !table.isEmpty {
            lines.append("## Timings, measured on the phone")
            lines.append("")
            lines.append(contentsOf: table)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The message that closes the call: how long, the transcript, and a request for a short summary.
    static func closingMessage(_ state: VoiceRoomState, ended: Date, hasTranscript: Bool,
                               timings: VoiceCallTimings = VoiceCallTimings()) -> String {
        // The voice line is never asked for a summary: it speaks for the room, it isn't an agent (warden, #274).
        let speakers = Array(Set(state.turns.filter { !$0.isYou && !$0.speaker.hasSuffix(voiceSuffix) }.map(\.speaker))).sorted()
        let asked = (state.with.isEmpty ? speakers : state.with).map { "@\($0)" }.joined(separator: " ")
        var text = "📞 Voice room with \(state.title) ended · \(Self.duration(from: state.startedAt, to: ended)) · \(state.turns.count) turns."
        // Without the file, the conversation is the call's card in the room.
        if hasTranscript { text += " The full transcript is attached." }
        // Nothing said, nothing to sum up.
        if !asked.isEmpty, !state.turns.isEmpty {
            text += " \(asked) please post a 3–5 line summary of what we decided and what happens next."
        }
        if let line = timings.line() { text += "\n" + line }
        return text
    }

    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date) + "Z"
    }

    private static func dayAndTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date) + " UTC"
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: date)
    }

    static func slug(_ text: String) -> String {
        let cleaned = text.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "room" : String(cleaned.prefix(40))
    }
}
