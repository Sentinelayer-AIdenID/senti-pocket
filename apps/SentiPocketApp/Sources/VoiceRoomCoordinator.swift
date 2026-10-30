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
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let onEnded: @MainActor () -> Void

    /// Answers waiting to be read, oldest first.
    private var queue: [VoiceRoomTurn] = []
    /// Messages and replies already taken, so a message seen twice (stream and poll) is read once.
    private var taken: Set<String> = []
    private var lastHeard: Date?
    private var silenceWatch: Task<Void, Never>?
    private var ringWatch: Task<Void, Never>?
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
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        onEnded: @escaping @MainActor () -> Void = {}
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
        self.now = now
        self.sleep = sleep
        self.onEnded = onEnded
        state = VoiceRoomState(with: agents, startedAt: now())
    }

    /// Rings the agents (one message that mentions them and opens the call's card), takes the phone's audio and plays
    /// the ring until an agent picks up. Answering an agent's own call there is nothing to ring: the line is open.
    func begin(rings: Bool = true) {
        do {
            try audio.activate()
        } catch {
            state.notice = "The phone's audio is busy (a call or another app). End it and try again."
            return
        }
        let ring = VoiceCallMarkers.start(caller: you, agents: invited, meeting: state.with.isEmpty)
        let clientId = "voice-start-" + UUID().uuidString.lowercased()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.poster.postCallStarted(sessionId: self.sessionId, text: ring, clientId: clientId)
            } catch {
                self.state.notice = "The agents could not be rung. Check the connection."
            }
        }
        guard rings else {
            state.ringStopped = true
            if state.isHandsFree { startListening() }
            return
        }
        ringer?.startRinging()
        watchForPickup()
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
                self.state.notice = "\(self.state.title) hasn't picked up yet. Talk when you're ready; the answer is read when it comes."
                if self.state.isHandsFree, self.state.phase == .ready { self.startListening() }
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
        speaker.speak(next.text, as: next.speaker, started: { [weak self] in
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
        silenceWatch = Task { [weak self] in
            while let self, !Task.isCancelled, generation == self.listenGeneration, self.state.isListening {
                await self.sleep(0.25)
                guard generation == self.listenGeneration, self.state.isListening else { return }
                let elapsed = self.now().timeIntervalSince(started)
                if elapsed >= Self.longestTurn {
                    self.endTurn()
                    return
                }
                if self.state.isHandsFree, let heard = self.lastHeard,
                   self.now().timeIntervalSince(heard) >= Self.pause(after: self.state.partial) {
                    self.endTurn()
                    return
                }
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
            self.state.phase = .ready
            self.speakIfReady()
            await self.post(text)
        }
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
        if !state.turns.isEmpty {
            let markdown = Self.transcript(state, ended: ended, timings: timings)
            let stamp = Self.fileStamp(state.startedAt)
            let clientId = "voice-end-" + UUID().uuidString.lowercased()
            var saved: VoiceTranscriptAttachment?
            do {
                saved = try await poster.uploadTranscript(
                    sessionId: sessionId,
                    filename: "voice-\(Self.slug(state.title))-\(stamp).md",
                    markdown: markdown,
                    clientId: clientId + "-file"
                )
            } catch {
                state.notice = "The transcript could not be saved to the room."
            }
            let text = Self.closingMessage(state, ended: ended, hasTranscript: saved != nil, timings: timings)
            try? await poster.postCallEnded(sessionId: sessionId, text: text, transcript: saved, clientId: clientId)
        }
        state.phase = .ended
        onEnded()
    }

    /// The whole conversation, oldest first, as Markdown.
    static func transcript(_ state: VoiceRoomState, ended: Date, timings: VoiceCallTimings = VoiceCallTimings()) -> String {
        var lines = [
            "# Voice room with \(state.title)",
            "",
            "\(Self.dayAndTime(state.startedAt)) · \(Self.duration(from: state.startedAt, to: ended)) · \(state.turns.count) turns",
            ""
        ]
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
        let speakers = Array(Set(state.turns.filter { !$0.isYou }.map(\.speaker))).sorted()
        let asked = (state.with.isEmpty ? speakers : state.with).map { "@\($0)" }.joined(separator: " ")
        var text = "📞 Voice room with \(state.title) ended · \(Self.duration(from: state.startedAt, to: ended)) · \(state.turns.count) turns."
        // Without the file, the conversation is the call's card in the room.
        if hasTranscript { text += " The full transcript is attached." }
        if !asked.isEmpty { text += " \(asked) please post a 3–5 line summary of what we decided and what happens next." }
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
