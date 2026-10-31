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
/// comes back after the answers and a pause sends your turn. The pause is timed from when the microphone last heard
/// you, not from the recognizer's last word, and listening stays on a moment after your turn goes, so what you say
/// next joins it until an answer starts. Hanging up saves the whole transcript to the room as one
/// Markdown file on the message that closes the call, which asks the agents for a short summary.
@MainActor
final class VoiceRoomCoordinator: ObservableObject {
    @Published private(set) var state: VoiceRoomState

    private let sessionId: String
    private let you: String
    /// The agents the call rings: those you talk with (and any added since), or everyone here in a meeting.
    private var invited: [String]
    /// Agents added mid-call that have not answered yet, and the notice that says so.
    private var adding: Set<String> = []
    private var addingNotice: String?
    /// The messages adding agents, still on their way: the call's end waits for them, so no add lands after it.
    private var pendingAdds: [Task<Void, Never>] = []
    private let ownAuthorIds: Set<String>
    private let listener: any VoiceListening
    private let speaker: any VoiceSpeaking
    private let audio: any VoiceRoomAudioSession
    private let ringer: (any VoiceRoomRinging)?
    /// The phone's own call this voice room talks inside, when it answers an agent's call; nil for a call made here.
    private let callScreen: (any VoiceRoomCallScreen)?
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
    /// How sure the answer must be to end a turn early (`finishedAt` unless the call is given another line).
    private let finishedLine: Double
    /// The words already asked about in this pause, so one pause is asked about once.
    private var askedAbout: String?
    /// When the microphone last heard speech-loud sound while listening: a pause is timed from it, since the
    /// recognizer hands words over a beat after they are said, and a turn never ends early while the microphone still
    /// hears you (warden, #276).
    private var lastLoud: Date?
    /// A microphone level (0 to 1, as the waveform's) this loud is someone speaking.
    static let speakingLevel = 0.35
    /// One id for the whole call, so the voice line meters and limits it as one.
    private let callId = UUID().uuidString.lowercased()
    /// The agent's call you answered, if this is one: the voice line grounds its answers in why it called.
    private let ringCallId: String?
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
    /// Listening just after your turn went: what you say joins that turn, unless nothing is said by `until`.
    private var joining: (turn: SentTurn, until: Date)?
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

    /// A pause this long ends your turn, hands-free, timed from the last sound loud enough to be you talking.
    static let pauseEndsTurn: TimeInterval = 1.4
    /// After words that end a sentence ("." "?" "!"), a shorter pause does.
    static let pauseAfterSentence: TimeInterval = 0.8
    /// The recognizer hands a word over up to about this long after it is said (the voice comparison, 10-31, put it at
    /// 0.2–0.5 s). A word that arrives later than this after the last loud sound was said below the microphone's
    /// speaking level, so it moves the pause on as well: while words keep coming, a turn waits for them.
    static let recognizerLag: TimeInterval = 0.5
    /// After a turn goes, listening stays on this long, and what you say joins it (Carter, 10-31: calls should feel
    /// live and lose no words). A pause mid-thought used to end the turn and drop what came next.
    static let joinsWithin: TimeInterval = 1.2
    /// What starts the words that carry on a turn already in the room.
    static let carriesOn = "…"
    /// A turn never runs past this (the recognizer's own limit is about a minute).
    static let longestTurn: TimeInterval = 50
    /// Answers from just before the call started still count (clocks differ a little).
    static let clockSlack: TimeInterval = 5
    /// After this much silence the phone asks whether the turn is over, and ends it at once when it is.
    static let askAfter: TimeInterval = 0.3
    /// How sure the answer must be to end a turn early. The voice comparison (10-31) scored 30 labelled phrases: at
    /// 0.6, 15 of 16 finished turns end early (13 at 0.7) and none of the 14 unfinished ones is cut off; the highest
    /// unfinished score was 0.10. It asked for a way to recover a wrong early end before lowering the line: a turn
    /// ended too soon is now carried on by what you say next.
    static let finishedAt = 0.6

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
        callScreen: (any VoiceRoomCallScreen)? = nil,
        poster: any VoiceRoomPosting,
        voiceLine: (any VoiceLining)? = nil,
        endpointer: (any VoiceEndpointing)? = nil,
        finishedAt: Double = VoiceRoomCoordinator.finishedAt,
        ringCallId: String? = nil,
        about: String? = nil,
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
        self.callScreen = callScreen
        self.poster = poster
        self.voiceLine = voiceLine
        self.endpointer = endpointer
        finishedLine = finishedAt
        self.ringCallId = ringCallId
        self.now = now
        self.sleep = sleep
        self.onEnded = onEnded
        self.onRecordFailed = onRecordFailed
        state = VoiceRoomState(with: agents, startedAt: now())
        state.about = about.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        state.hasCallScreen = callScreen != nil
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
        let ring = VoiceCallMarkers.start(caller: you, agents: invited, meeting: state.sharesFloor)
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
        case .add(let agent):
            add(agent)
        case .setMuted(let on):
            askToMute(on)
        case .hangUp:
            Task { await hangUp() }
        }
    }

    /// Brings another agent into the call (Carter, 10-30: "add warden mid-call"): one message rings it by mention and
    /// adds it to the call's card, and from then on its answers are read like the others'. With two or more agents the
    /// first to answer a turn has the floor. A meeting already has everyone.
    private func add(_ agent: String) {
        let name = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = name.lowercased()
        guard state.canAdd, !name.isEmpty, !key.hasPrefix("human"),
              !state.with.contains(where: { $0.lowercased() == key }) else { return }
        let others = state.with
        state.with.append(name)
        invited.append(name)
        adding.insert(key)
        let notice = "\(name) was asked to join. Their hello is read when it comes."
        state.notice = notice
        addingNotice = notice
        let text = VoiceCallMarkers.added(caller: you, agent: name, joining: others)
        let clientId = "voice-add-\(callId)-\(UUID().uuidString.lowercased())"
        let posting = Task { [weak self] in
            guard let self else { return }
            // After the message that opened the call, so the card exists before anyone is added to it; a call that
            // never opened has no one to add, and one already ending asks no one to say hello (warden, #279).
            var added = await self.startPost?.value == true
            if self.state.phase == .ending || self.state.phase == .ended { return }
            if added {
                do {
                    try await self.poster.postCallStarted(sessionId: self.sessionId, text: text, clientId: clientId)
                } catch {
                    added = false
                }
            }
            guard !added, self.state.phase != .ending, self.state.phase != .ended else { return }
            self.state.with.removeAll { $0.lowercased() == key }
            self.invited.removeAll { $0.lowercased() == key }
            self.adding.remove(key)
            self.state.notice = "\(name) could not be added. Try again."
            self.addingNotice = nil
        }
        pendingAdds.append(posting)
    }

    /// The panel's Mute (Carter, Voice Lab #56359: "I don't see a mute button in this when I call you"). In a call on
    /// the phone's call screen it is asked of the call screen, and the call screen's own mute comes back through
    /// `callScreenMuted(_:)` as a tap there does: one mute, applied once, the same on both screens. A call made here
    /// mutes at once.
    private func askToMute(_ on: Bool) {
        guard let callScreen else {
            setMuted(on)
            return
        }
        callScreen.setMuted(on) { [weak self] done in
            // The call screen could not (its call is already going away): the tap still does what it says here.
            if !done { self?.setMuted(on) }
        }
    }

    /// Muted or unmuted on the phone's own call screen, or by the panel's Mute through it (warden, #281).
    func callScreenMuted(_ on: Bool) {
        setMuted(on)
    }

    /// Muted (warden, #281): what was being heard is dropped, not posted, and nothing listens until unmuted. Answers
    /// are still read. Unmuted, hands-free listening comes back, once the agent has picked up, for a new turn: muting
    /// just after a turn went stops anything joining it.
    private func setMuted(_ on: Bool) {
        guard state.isMuted != on else { return }
        state.isMuted = on
        if on {
            guard state.isListening else { return }
            listenGeneration += 1
            silenceWatch?.cancel()
            listener.cancel()
            joining = nil
            lastHeard = nil
            state.partial = ""
            state.phase = .ready
        } else if state.isHandsFree, state.phase == .ready, queue.isEmpty, !state.isRinging {
            startListening()
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
    /// listening comes back after it. Once you have started talking, answers wait. Just after your turn went, a sound
    /// may be your next words on their way through the recognizer, so the answer waits a moment for them.
    private func yieldIfNotTalking() {
        guard state.isListening, state.isHandsFree, !queue.isEmpty, lastHeard == nil, state.partial.isEmpty,
              joining == nil || quiet(for: Self.recognizerLag) else { return }
        stopListeningForNow()
    }

    /// Listening that heard no words lets go of the microphone; the phone is ready for the next answer.
    private func stopListeningForNow() {
        listenGeneration += 1
        silenceWatch?.cancel()
        listener.cancel()
        joining = nil
        state.phase = .ready
    }

    private func take(id: String, author: String, isHuman: Bool, text: String, timestamp: String) {
        guard state.phase != .ending, state.phase != .ended, !taken.contains(id) else { return }
        let lowered = author.lowercased()
        // The room's own voices never answer: in a meeting, a cost line would otherwise be read and take the floor
        // from the agents (found porting calls to the web, #702).
        guard !lowered.isEmpty, !ownAuthorIds.contains(lowered), !RoomChatQuiet.isRoomVoice(lowered),
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
        // An agent added mid-call says hello once: it is read whoever has the floor, and it takes neither the floor
        // nor the turn's timing (warden, #279).
        let isAddedHello = adding.remove(lowered) != nil
        if isAddedHello, adding.isEmpty, let addingNotice, state.notice == addingNotice {
            // Everyone added has answered.
            state.notice = nil
            self.addingNotice = nil
        }
        // With more than one agent (a meeting, or several picked or added) the first to answer a turn has the floor;
        // the others are kept, not read (Carter, 10-30).
        if state.sharesFloor, !isHuman, !isAddedHello {
            if let holder = floorHolder, holder.id != lowered {
                state.turns.append(VoiceRoomTurn(id: id, speaker: name, isYou: false, text: text, at: at, isHeld: true))
                timings.noteHeld()
                announceFloor(holder: holder.name)
                return
            }
            floorHolder = (lowered, name)
        }
        if !isAddedHello, let since = awaitingAnswerSince {
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

    /// Your latest turn as sent: what you say next may join it.
    private struct SentTurn {
        /// Its turn in the call (`state.turns`).
        let id: String
        /// All of it so far.
        let text: String
        /// Its latest post: true once all of it is in the room.
        let posted: Task<Bool, Never>
    }

    /// `turn` is the turn that just went, when this listening is the moment after it: what you say joins that turn.
    private func startListening(joining turn: SentTurn? = nil) {
        guard !state.isMuted, state.phase == .ready || state.speaker != nil else { return }
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
        lastLoud = nil
        joining = turn.map { (turn: $0, until: now().addingTimeInterval(Self.joinsWithin)) }
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

    /// Hands-free, a pause after some words sends the turn; any turn stops at the longest length. Just after a turn
    /// went, listening that hears no words lets go again.
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
                if self.letGoAfterTurn() {
                    self.speakIfReady()
                    return
                }
                guard self.state.isHandsFree, let heard = self.lastHeard else { continue }
                let silence = self.now().timeIntervalSince(self.lastSound(words: heard))
                if silence >= Self.pause(after: self.state.partial) {
                    self.endTurn()
                    return
                }
                if silence >= Self.askAfter { self.askIfFinished(generation) }
            }
        }
    }

    /// When you last made a sound, for timing a pause: the last speech-loud sound, since the recognizer hands words
    /// over a beat after the voice and the pause used to wait that beat as well (the voice comparison, 10-31). A word
    /// that comes more than `recognizerLag` after that sound was said too softly for the level, so it counts as sound
    /// until that long before it. Sound never holds a turn past the words' own pause, so a noisy room (a fan, a car) is
    /// no slower than before. Without the microphone's level, it is the last word, as before.
    private func lastSound(words heard: Date) -> Date {
        guard let loud = lastLoud else { return heard }
        return min(heard, max(loud, heard.addingTimeInterval(-Self.recognizerLag)))
    }

    /// Just after a turn went, with no words since; true when listening let go. Once the microphone has been quiet
    /// long enough for no words to be on their way, it lets go when an answer is waiting or the moment has passed:
    /// the turn stands as it went, and the phone waits for its answer. Sound that has brought no words by a little
    /// after the moment (a fan, a car) joins nothing: listening goes on as for a new turn, and gives way to an answer
    /// as soon as one is waiting, so a noisy room never holds an answer back for long.
    private func letGoAfterTurn() -> Bool {
        guard let joining, lastHeard == nil, state.partial.isEmpty else { return false }
        let at = now()
        let answerWaiting = !queue.isEmpty
        if quiet(for: Self.recognizerLag), at >= joining.until || answerWaiting {
            stopListeningForNow()
            return true
        }
        guard at >= joining.until.addingTimeInterval(Self.recognizerLag) else { return false }
        self.joining = nil
        guard answerWaiting else { return false }
        stopListeningForNow()
        return true
    }

    /// A short pause: asks whether the words so far are a finished turn, and ends it at once if they are and nothing
    /// has been said since (Carter, 10-30: "I thought jev would help us finish everything by 600ms"). Unsure, slow or
    /// unavailable, the normal pause still ends it.
    private func askIfFinished(_ generation: Int) {
        let words = state.partial
        guard let endpointer, !endpointerOff, askedAbout != words,
              !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        askedAbout = words
        // Words that carry on a turn are asked about with it: "the dial?" alone says little.
        let asked = joining.map { $0.turn.text + " " + words } ?? words
        Task { [weak self] in
            guard let self else { return }
            do {
                let done = try await endpointer.finished(sessionId: self.sessionId, text: asked, callId: self.callId)
                guard done >= self.finishedLine, generation == self.listenGeneration, self.state.isListening,
                      !self.stillSpeaking(),
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

    /// The microphone's level, as the phone hears it: the waveform's feed, from the recognizer's own audio tap. Only
    /// what is heard while listening counts, so muted, nothing is.
    func hear(level: Double) {
        guard state.isListening, level >= Self.speakingLevel else { return }
        lastLoud = now()
    }

    /// The microphone has heard nothing as loud as speech for this long (or at all) while listening.
    private func quiet(for seconds: TimeInterval) -> Bool {
        lastLoud.map { now().timeIntervalSince($0) >= seconds } ?? true
    }

    /// Sound as loud as speech within the short pause: the words have not caught up with the voice yet.
    private func stillSpeaking() -> Bool {
        !quiet(for: Self.askAfter)
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
        // You stopped talking when the sound did; the words come a beat later.
        let stoppedTalking = lastHeard.map { lastSound(words: $0) } ?? lastLoud ?? now()
        let joins = joining?.turn
        joining = nil
        let asked = now()
        Task { [weak self] in
            guard let self else { return }
            let heard = await self.listener.stop()
            self.timings.record(.recognition, self.now().timeIntervalSince(asked))
            // Fillers and words said twice are tidied before the turn is posted (Carter, #55058).
            let text = SpokenCleanup.clean(heard.isEmpty ? self.state.partial : heard)
            self.state.partial = ""
            guard !text.isEmpty else {
                self.readyAfterSending()
                self.speakIfReady()
                return
            }
            if let joins {
                await self.carryOn(joins, with: text, stoppedTalking: stoppedTalking)
            } else {
                await self.sendTurn(text, stoppedTalking: stoppedTalking)
            }
        }
    }

    private func sendTurn(_ text: String, stoppedTalking: Date) async {
        let turn = VoiceRoomTurn(id: "you:\(UUID().uuidString.lowercased())", speaker: you, isYou: true, text: text,
                                 at: now())
        state.turns.append(turn)
        // A new turn: the floor is open again, and its answer is timed from here.
        turnStoppedAt = stoppedTalking
        floorHolder = nil
        floorAnnounced = false
        gapAnswerId = nil
        // What is left of the last quick answer goes first, so none of it plays after you spoke (warden, #274).
        dropVoiceLineLeftovers()
        readyAfterSending()
        speakIfReady()
        askVoiceLine(text, turn: turn.id)
        let posted = Task { [weak self] () -> Bool in
            guard let self else { return false }
            let inRoom = await self.post(text, stoppedTalking: stoppedTalking)
            if inRoom { self.awaitingAnswerSince = self.now() }
            return inRoom
        }
        listenForMore(after: SentTurn(id: turn.id, text: text, posted: posted))
        _ = await posted.value
    }

    /// What you said just after a turn went joins it (Carter, 10-31: a pause mid-thought ended the turn and the rest
    /// was lost). The call keeps one turn, on the same floor. The room gets the new words as a turn that carries on
    /// the last one ("…and the dial?"), addressed the same way and posted after it: the agents' listeners answer new
    /// messages and never see edits, so editing the first would go unanswered. The voice line is asked again with the
    /// whole turn, and what it had not yet said about the first part is dropped.
    private func carryOn(_ sent: SentTurn, with text: String, stoppedTalking: Date) async {
        let whole = sent.text + " " + text
        if let index = state.turns.firstIndex(where: { $0.id == sent.id }) {
            let turn = state.turns[index]
            state.turns[index] = VoiceRoomTurn(id: turn.id, speaker: turn.speaker, isYou: true, text: whole, at: turn.at)
        }
        timings.noteContinued()
        // You stopped talking later than it seemed: the answer's gap is timed from now on.
        turnStoppedAt = stoppedTalking
        dropVoiceLineLeftovers()
        if let id = gapAnswerId, !queue.contains(where: { $0.id == id }) { gapAnswerId = nil }
        readyAfterSending()
        speakIfReady()
        askVoiceLine(whole, turn: sent.id)
        let posted = Task { [weak self] () -> Bool in
            // After the turn it carries on, so the room has them in order. If that never reached the room, all of it
            // goes now, so nothing said is lost.
            let inRoom = await sent.posted.value
            guard let self else { return false }
            let delivered = await self.post(inRoom ? Self.carriesOn + text : whole, stoppedTalking: stoppedTalking)
            if delivered, !inRoom { self.awaitingAnswerSince = self.now() }
            return delivered
        }
        listenForMore(after: SentTurn(id: sent.id, text: whole, posted: posted))
        _ = await posted.value
    }

    /// Your words are out of the recognizer: the phone is ready again, unless you hung up meanwhile. Then it stays
    /// ending, so nothing listens again after the call.
    private func readyAfterSending() {
        if state.phase == .sending { state.phase = .ready }
    }

    /// Hands-free, listening stays on a moment after a turn goes, so what you say next joins it instead of being lost.
    /// Not once an answer is being read: the phone never listens over an answer (no barge-in yet).
    private func listenForMore(after turn: SentTurn) {
        guard state.isHandsFree, state.phase == .ready else { return }
        startListening(joining: turn)
    }

    // MARK: - The voice line

    static let voiceSuffix = " (voice)"

    /// Whose voice says a turn: the voice line's turns are said in their agent's voice.
    static func voiceOf(_ speaker: String) -> String {
        speaker.hasSuffix(voiceSuffix) ? String(speaker.dropLast(voiceSuffix.count)) : speaker
    }

    /// Asks the voice line for a quick answer while the turn goes to the room (warden, Phase 2): each sentence is read
    /// as it arrives, and the agent's own answer still comes in the room after. A new turn drops what is left of the
    /// last quick answer. `turn` is your turn being asked about, which the history leaves out.
    private func askVoiceLine(_ text: String, turn: String) {
        guard let voiceLine, !voiceLineOff, now() >= voiceLineRestsUntil else { return }
        let agent = state.with.count == 1 ? state.with[0] : nil
        let speaker = (agent ?? "room") + Self.voiceSuffix
        let history = state.turns.filter { $0.id != turn }.suffix(12)
            .map { VoiceLineHistory(speaker: $0.speaker, text: $0.text) }
        let answerId = "line:" + UUID().uuidString.lowercased()
        let stream = voiceLine.voiceLine(sessionId: sessionId, agentId: agent, text: text, callId: callId,
                                         ringCallId: ringCallId,
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

    /// Your turn in the room. It starts with the mentions of the agents you called, so their listeners know it is for
    /// them; a meeting is for everyone. True once the room has it.
    private func post(_ text: String, stoppedTalking: Date) async -> Bool {
        let mentions = state.with.map { "@\($0)" }.joined(separator: " ")
        let addressed = mentions.isEmpty ? text : "\(mentions) \(text)"
        let sending = now()
        do {
            try await poster.postVoiceTurn(sessionId: sessionId, text: addressed,
                                           clientId: "voice-" + UUID().uuidString.lowercased())
            let posted = now()
            timings.record(.post, posted.timeIntervalSince(sending))
            timings.record(.endpoint, posted.timeIntervalSince(stoppedTalking))
            // A turn that failed and was then carried on went whole: it is in the room after all.
            if state.notice == Self.turnLost { state.notice = nil }
            return true
        } catch {
            state.notice = Self.turnLost
            return false
        }
    }

    static let turnLost = "That turn did not reach the room. Say it again."

    // MARK: - Hanging up

    func hangUp() async {
        guard state.phase != .ending, state.phase != .ended else { return }
        listenGeneration += 1
        silenceWatch?.cancel()
        joining = nil
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
        // An add still on its way lands before the end, never after it.
        for add in pendingAdds { await add.value }
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
