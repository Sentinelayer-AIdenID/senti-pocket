import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI

/// A voice conversation in a room, run on the phone: you talk, the phone recognizes it and posts it to the room as a
/// spoken turn (`channel: "voice"`), the agents answer in the room from their own listeners on their own models, and
/// the phone reads each answer aloud in that agent's own voice. No audio leaves the phone. With one agent, your turns
/// mention it so it knows they are for it; with everyone, it is a meeting and every agent's answer is read.
///
/// One thing at a time: while you talk, answers wait; while an answer is read, the next waits. Hands-free, listening
/// comes back after the answers and a pause sends your turn. Hanging up saves the whole transcript to the room as one
/// Markdown file on the message that closes the call, which asks the agents for a short summary.
@MainActor
final class VoiceRoomCoordinator: ObservableObject {
    @Published private(set) var state: VoiceRoomState

    private let sessionId: String
    private let you: String
    private let ownAuthorIds: Set<String>
    private let listener: any VoiceListening
    private let speaker: any VoiceSpeaking
    private let audio: any VoiceRoomAudioSession
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
    private var listenGeneration = 0

    /// A pause this long ends your turn, hands-free.
    static let pauseEndsTurn: TimeInterval = 1.4
    /// A turn never runs past this (the recognizer's own limit is about a minute).
    static let longestTurn: TimeInterval = 50
    /// Answers from just before the call started still count (clocks differ a little).
    static let clockSlack: TimeInterval = 5

    init(
        sessionId: String,
        with agents: [String],
        you: String,
        ownAuthorIds: Set<String>,
        listener: any VoiceListening,
        speaker: any VoiceSpeaking,
        audio: any VoiceRoomAudioSession,
        poster: any VoiceRoomPosting,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        onEnded: @escaping @MainActor () -> Void = {}
    ) {
        self.sessionId = sessionId
        self.you = you
        self.ownAuthorIds = Set(ownAuthorIds.map { $0.lowercased() })
        self.listener = listener
        self.speaker = speaker
        self.audio = audio
        self.poster = poster
        self.now = now
        self.sleep = sleep
        self.onEnded = onEnded
        state = VoiceRoomState(with: agents, startedAt: now())
    }

    /// Takes the phone's audio and, hands-free, starts listening.
    func begin() {
        do {
            try audio.activate()
        } catch {
            state.notice = "The phone's audio is busy (a call or another app). End it and try again."
            return
        }
        if state.isHandsFree { startListening() }
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
        speakIfReady()
    }

    /// Threaded replies seen since the last read: an agent may answer in a thread.
    func receive(replies: [RoomReply]) {
        for reply in replies {
            take(id: "reply:\(reply.id)", author: reply.authorId, isHuman: reply.isHuman, text: reply.text,
                 timestamp: reply.createdAt)
        }
        speakIfReady()
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
        let turn = VoiceRoomTurn(id: id, speaker: name, isYou: false, text: text, at: at)
        queue.append(turn)
        state.turns.append(turn)
        state.waiting = queue.count
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
        speaker.speak(next.text, as: next.speaker) { [weak self] in
            self?.afterSpeaking()
        }
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
                   self.now().timeIntervalSince(heard) >= Self.pauseEndsTurn {
                    self.endTurn()
                    return
                }
            }
        }
    }

    private func endTurn() {
        guard state.isListening else { return }
        listenGeneration += 1
        silenceWatch?.cancel()
        state.phase = .sending
        Task { [weak self] in
            guard let self else { return }
            let heard = await self.listener.stop()
            let text = heard.isEmpty ? self.state.partial.trimmingCharacters(in: .whitespacesAndNewlines) : heard
            self.state.partial = ""
            guard !text.isEmpty else {
                self.state.phase = .ready
                self.speakIfReady()
                return
            }
            let turn = VoiceRoomTurn(id: "you:\(UUID().uuidString.lowercased())", speaker: self.you, isYou: true,
                                     text: text, at: self.now())
            self.state.turns.append(turn)
            self.state.phase = .ready
            self.speakIfReady()
            await self.post(text)
        }
    }

    /// Your turn in the room. With one agent it starts with that agent's mention, so its listener knows it is for it.
    private func post(_ text: String) async {
        let addressed = state.with.count == 1 ? "@\(state.with[0]) \(text)" : text
        do {
            try await poster.postVoiceTurn(sessionId: sessionId, text: addressed,
                                           clientId: "voice-" + UUID().uuidString.lowercased())
        } catch {
            state.notice = "That turn did not reach the room. Say it again."
        }
    }

    // MARK: - Hanging up

    func hangUp() async {
        guard state.phase != .ending, state.phase != .ended else { return }
        listenGeneration += 1
        silenceWatch?.cancel()
        listener.cancel()
        speaker.stop()
        queue.removeAll()
        state.waiting = 0
        state.phase = .ending
        audio.deactivate()
        let ended = now()
        if !state.turns.isEmpty {
            let markdown = Self.transcript(state, ended: ended)
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
            let text = Self.closingMessage(state, ended: ended, hasTranscript: saved != nil)
            try? await poster.postCallEnded(sessionId: sessionId, text: text, transcript: saved, clientId: clientId)
        }
        state.phase = .ended
        onEnded()
    }

    /// The whole conversation, oldest first, as Markdown.
    static func transcript(_ state: VoiceRoomState, ended: Date) -> String {
        var lines = [
            "# Voice room with \(state.title)",
            "",
            "\(Self.dayAndTime(state.startedAt)) · \(Self.duration(from: state.startedAt, to: ended)) · \(state.turns.count) turns",
            ""
        ]
        for turn in state.turns.sorted(by: { $0.at < $1.at }) {
            lines.append("**\(turn.speaker)** · \(Self.clock(turn.at))")
            lines.append(turn.text.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The message that closes the call: how long, the transcript, and a request for a short summary.
    static func closingMessage(_ state: VoiceRoomState, ended: Date, hasTranscript: Bool) -> String {
        let speakers = Array(Set(state.turns.filter { !$0.isYou }.map(\.speaker))).sorted()
        let asked = (state.with.isEmpty ? speakers : state.with).map { "@\($0)" }.joined(separator: " ")
        var text = "📞 Voice room with \(state.title) ended · \(Self.duration(from: state.startedAt, to: ended)) · \(state.turns.count) turns."
        text += hasTranscript ? " The full transcript is attached." : " The transcript could not be attached."
        if !asked.isEmpty { text += " \(asked) please post a 3–5 line summary of what we decided and what happens next." }
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
