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
/// its hello is heard before you say anything. After a while with no answer the ring stops and the
/// line is open.
///
/// One thing at a time: while you talk, answers wait; while an answer is read, the next waits. An answer that lands
/// while the phone is listening but you have not started talking is read at once. Each turn is answered once, by the
/// agent's own post. While the agent writes, its fast voice says at most a short bridge with nothing of the answer in
/// it, and says so when no answer has come in 20 s; only a turn for Senti, whose posts a call never reads, is answered
/// by the fast voice line itself. Talking over an agent's post pauses it; it is read again later. Hands-free, listening
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
    /// The room's agents who could be added: "bring warden into this call" adds one by voice.
    private let addable: @MainActor () -> [String]
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
    /// This account said OK to its words reaching the room's AI agents (`AIConsent`, asked before a call starts):
    /// without it nothing of the call is posted or listened to.
    private let mayShareWithAgents: @MainActor () -> Bool
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
    /// A turn is answered once, by the agent it is for, in its own post. The fast voice line used to answer each turn
    /// first as the agent, and the agent's own post was then read after a handoff, so every turn was heard twice: a
    /// paraphrase, then the real answer (Carter, ticket 13ec2d12). Now the line is asked only for a turn for Senti
    /// (`isSenti(_:)`), whose posts a call never reads. For any other agent the phone waits for its post, and while it
    /// waits the agent's fast voice says at most `bridge(for:)` once `bridgeAfter` has passed, and
    /// `noAnswerYet(from:)` at `givesUpAfter`. Both are the phone's own fixed words, never asked of the line, so
    /// neither can carry any of the answer. The wait ends when the agent posts or leaves the call, or with your next
    /// turn.
    private var answerWatch: Task<Void, Never>?
    /// The agent `answerWatch` waits on (lowercased).
    private var awaited: String?
    /// Who this turn is for when more than one agent is on the call (`VoiceTurnAddressee`). Nil is everyone. It gets
    /// the turn's mention, the floor, and the bridge (or, for Senti, the voice line's answer).
    private var turnFor: String?
    /// Your latest turn, by its id.
    private var latestTurn: String?
    /// The agents (lowercased) whose post came during your latest turn: a turn said to one of them is not owed.
    private var answeredLatest: Set<String> = []
    /// On a call with several agents, the answers still owed: for each agent (lowercased), the earlier turns said to it
    /// alone that it had not answered when the next turn went, oldest first. Agents can take longer than a turn, so
    /// the agent's next posts, one per turn owed, are its late answers: each is read whenever it comes, takes no
    /// turn's floor and is never held for one. A turn carried on is still one turn, owed once.
    private var owed: [String: [String]] = [:]
    /// What the voice line said when it picked up, as `words(_:)`, and the agent it spoke as (lowercased): the agent's
    /// own hello in the same words is the one post that is not read.
    private var lineHello: (agent: String, words: String)?
    /// The queued posts that are an agent's late answer to an earlier turn (`owed`), by id. Each waits while the voice
    /// line is still answering a turn for Senti, so it never cuts into that answer.
    private var lateAnswers: Set<String> = []
    /// The voice line's answer still streaming, by its id: late answers wait for it.
    private var lineStreaming: String?
    /// What is being read aloud now.
    private var reading: Reading?
    /// Agents' posts you talked over that have not been read in full since: the transcript marks any the call never
    /// got back to.
    private var talkedOver: Set<String> = []
    /// The listening you started by talking over what was being read (its `listenGeneration`): it never gives way to
    /// what is waiting, which waits for your turn.
    private var bargeIn: Int?

    private enum Reading {
        /// A sentence of the voice line's answer, its hello, or a line the fast voice says while an agent writes.
        case line
        /// An agent's own post.
        case post(VoiceRoomTurn)
    }
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
    /// After a turn goes, listening stays on this long, and what you say joins it: calls should feel live and lose no
    /// words. A pause mid-thought used to end the turn and drop what came next.
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
    /// In a call to one agent with the voice line on, the agent's fast voice picks up this soon, as that agent, so
    /// a busy agent (of any lab) never leaves you ringing (Carter, 11-02: "I kept dialing forge and warden").
    static let voicePicksUpAfter: TimeInterval = 2
    /// The agent a turn is for has not posted this long after the turn went: its fast voice says the bridge. An answer
    /// that lands sooner is read with nothing before it.
    static let bridgeAfter: TimeInterval = 1.5
    /// Still no post this long after the turn went: its fast voice says the agent has not answered yet. The answer is
    /// read whenever it comes.
    static let givesUpAfter: TimeInterval = 20

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
        addable: @escaping @MainActor () -> [String] = { [] },
        callScreen: (any VoiceRoomCallScreen)? = nil,
        poster: any VoiceRoomPosting,
        voiceLine: (any VoiceLining)? = nil,
        endpointer: (any VoiceEndpointing)? = nil,
        finishedAt: Double = VoiceRoomCoordinator.finishedAt,
        ringCallId: String? = nil,
        about: String? = nil,
        mayShareWithAgents: @escaping @MainActor () -> Bool = { true },
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
        self.addable = addable
        self.callScreen = callScreen
        self.poster = poster
        self.voiceLine = voiceLine
        self.endpointer = endpointer
        finishedLine = finishedAt
        self.ringCallId = ringCallId
        self.mayShareWithAgents = mayShareWithAgents
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
        // The room asks for the OK before a call starts; a call that got here without it rings nobody and listens to
        // nothing.
        guard mayShareWithAgents() else {
            state.ringStopped = true
            state.notice = Self.needsConsent
            return
        }
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
                if self.voiceLineSpeaks, self.state.with.count == 1, !self.state.sharesFloor,
                   self.now().timeIntervalSince(started) >= Self.voicePicksUpAfter {
                    self.voicePickUp()
                    return
                }
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

    /// The agent's fast voice answers the ring with a short hello in the agent's own voice, then the line is open.
    private func voicePickUp() {
        guard let agent = state.with.first else { return }
        stopRinging()
        state.notice = nil
        if !state.joined.contains(where: { $0.lowercased() == agent.lowercased() }) { state.joined.append(agent) }
        let text = "Hi, it's \(agent). Go ahead."
        lineHello = (agent.lowercased(), Self.words(text))
        let hello = VoiceRoomTurn(id: "line:hello:" + UUID().uuidString.lowercased(), speaker: agent + Self.voiceSuffix,
                                  isYou: false, text: text, at: now())
        queue.append(hello)
        state.turns.append(hello)
        state.waiting = queue.count
        speakIfReady()
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
            if case .post(let turn) = reading { state.skipped[turn.id] = .youSkipped }
            afterSpeaking()
        case .setHandsFree(let on):
            state.isHandsFree = on
            if on, state.phase == .ready, readyIndex() == nil { startListening() }
        case .add(let agent):
            add(agent)
        case .setMuted(let on):
            askToMute(on)
        case .hangUp:
            Task { await hangUp() }
        }
    }

    /// Brings another agent into the call while it is going: one message rings it by mention and
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
            // Not on the call: its fast voice says nothing more while it would have written.
            self.stopWaiting(on: key)
            self.state.notice = "\(name) could not be added. Try again."
            self.addingNotice = nil
        }
        pendingAdds.append(posting)
    }

    /// The panel's Mute, so a call always has one in the app. In a call on
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
            // Answers are still read while muted: one waiting, or one you talked over, is read now.
            speakIfReady()
        } else if state.phase == .ready {
            // Unmuted: what waits is read first, and hands-free listening comes back only once nothing is read.
            speakIfReady()
            if state.isHandsFree, state.phase == .ready, !state.isRinging { startListening() }
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
    /// may be your next words on their way through the recognizer, so the answer waits a moment for them. Listening you
    /// started by talking over an answer never gives way: what waits, waits for your turn.
    private func yieldIfNotTalking() {
        guard state.isListening, state.isHandsFree, readyIndex() != nil, lastHeard == nil, state.partial.isEmpty,
              bargeIn != listenGeneration,
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
        let turn = VoiceRoomTurn(id: id, speaker: name, isYou: false, text: text, at: at)
        // The agent's own hello in the very words the voice line picked up with would say it twice: the one post not
        // read.
        if !isHuman, !isAddedHello, let lineHello, lineHello.agent == lowered, Self.words(text) == lineHello.words {
            state.turns.append(turn)
            state.skipped[id] = .sameAsHello
            return
        }
        // The agent's answer to the oldest earlier turn said to it alone that it had not answered when the next turn
        // went: read whenever it comes, and it takes no floor from the turn going now.
        if !isHuman, !isAddedHello, state.with.count > 1, let turns = owed[lowered], !turns.isEmpty {
            owed[lowered] = turns.count > 1 ? Array(turns.dropFirst()) : nil
            lateAnswers.insert(id)
            queue.append(turn)
            state.turns.append(turn)
            stopWaiting(on: lowered)
            return
        }
        if !isHuman { answeredLatest.insert(lowered) }
        // With more than one agent (a meeting, or several picked or added) the first to answer a turn has the floor;
        // the others are kept, not read.
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
        queue.append(turn)
        state.turns.append(turn)
        // Its post is here: nothing its fast voice was still to say while it wrote comes before it.
        stopWaiting(on: lowered)
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
        guard state.phase == .ready, let said = nextToSay() else {
            state.waiting = queue.count
            return
        }
        let next = said.turn
        reading = said.reading
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
        // Read to the end (or skipped, which marks it itself): nothing left to mark.
        if case .post(let turn) = reading { talkedOver.remove(turn.id) }
        reading = nil
        state.phase = .ready
        if readyIndex() != nil {
            speakIfReady()
        } else if state.isHandsFree {
            startListening()
        }
    }

    /// The next thing to say, out of the queue.
    private func nextToSay() -> (turn: VoiceRoomTurn, reading: Reading)? {
        guard let index = readyIndex() else { return nil }
        let next = queue.remove(at: index)
        return (next, Self.isLine(next) ? .line : .post(next))
    }

    /// Where in the queue the next thing that can be said now is. While the voice line is still answering (streaming,
    /// or with lines still to say), late answers wait and everything else goes in order.
    private func readyIndex() -> Int? {
        let lineAnswering = lineStreaming != nil || queue.contains(where: { Self.isLine($0) })
        return lineAnswering ? queue.firstIndex(where: { !lateAnswers.contains($0.id) }) : queue.indices.first
    }

    /// A sentence of the voice line's answer, its hello, or a line the fast voice says while an agent writes.
    private static func isLine(_ turn: VoiceRoomTurn) -> Bool { turn.id.hasPrefix("line:") }

    /// What starts the id of a line the fast voice says while an agent writes (`bridge(for:)`, `noAnswerYet(from:)`).
    private static let whileWriting = "line:waiting:"

    /// A post's words, lowercased, without punctuation: two posts with the same words say the same thing.
    static func words(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    /// You talked over what was being read. An agent's post is paused, never dropped: it goes back to the front of the
    /// queue and is read in full later. What the fast voice was saying is not kept, since your new turn gets its own.
    private func pauseReading() {
        switch reading {
        case .post(let turn):
            queue.insert(turn, at: 0)
            talkedOver.insert(turn.id)
        case .line, nil:
            break
        }
        reading = nil
        state.waiting = queue.count
    }

    // MARK: - Your turns

    /// Your latest turn as sent: what you say next may join it.
    private struct SentTurn {
        /// Its turn in the call (`state.turns`).
        let id: String
        /// All of it so far.
        let text: String
        /// Its posts so far: the ones the room has not confirmed once they are done. Empty means all of it is in.
        let posted: Task<[TurnPost], Never>
    }

    /// One post of a turn, with the client ID it goes under. Sent again under the same ID, the room keeps one copy,
    /// so a post whose answer was lost can be retried without its words reaching the room twice (#290).
    private struct TurnPost {
        let text: String
        let clientId: String
    }

    /// `turn` is the turn that just went, when this listening is the moment after it: what you say joins that turn.
    private func startListening(joining turn: SentTurn? = nil) {
        guard !state.isMuted, state.phase == .ready || state.speaker != nil, mayShareWithAgents() else { return }
        // Talking while it rings: no need to keep ringing.
        stopRinging()
        let talksOver = state.speaker != nil
        if talksOver {
            // Talking over an answer stops it, and pauses what waits: nothing waiting is read until your turn is done.
            speaker.stop()
            pauseReading()
        }
        listenGeneration += 1
        let generation = listenGeneration
        bargeIn = talksOver ? generation : nil
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
                // What waited, or what you talked over to talk, is read now that nothing listens.
                self.speakIfReady()
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
        let answerWaiting = readyIndex() != nil
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
    /// has been said since, so a finished turn goes within about 600 ms. Unsure, slow or unavailable, the normal pause
    /// still ends it.
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
        guard mayShareWithAgents() else {
            state.notice = Self.needsConsent
            return
        }
        // "Bring warden into this call": adding someone is a control, not a turn for the room or the voice line.
        if state.canAdd, let agent = VoiceAddIntent.agent(in: text, among: addable()) {
            state.turns.append(VoiceRoomTurn(id: "you:\(UUID().uuidString.lowercased())", speaker: you, isYou: true,
                                             text: text, at: now()))
            readyAfterSending()
            add(agent)
            // What you talked over to say it, or what came in meanwhile, is read now; otherwise, hands-free listens.
            speakIfReady()
            if state.isHandsFree, state.phase == .ready { startListening() }
            return
        }
        let turn = VoiceRoomTurn(id: "you:\(UUID().uuidString.lowercased())", speaker: you, isYou: true, text: text,
                                 at: now())
        state.turns.append(turn)
        // A new turn: the floor is open again, and its answer is timed from here.
        turnStoppedAt = stoppedTalking
        floorHolder = nil
        floorAnnounced = false
        gapAnswerId = nil
        // The turn before, said to one agent that has not answered it, is owed; this one starts with no answers.
        oweLatestTurn()
        latestTurn = turn.id
        answeredLatest = []
        // With more than one agent, a turn that addresses one of them (or, naming none, comes when only one has said
        // hello) is that agent's: it alone is mentioned, it has the floor, and the phone waits for its answer.
        turnFor = VoiceTurnAddressee.of(text, with: state.with, joined: state.joined)
        if let turnFor { floorHolder = (turnFor.lowercased(), turnFor) }
        // What is left of the last quick answer goes first, so none of it plays after you spoke (warden, #274).
        dropVoiceLineLeftovers()
        readyAfterSending()
        // Senti's answer is asked of the voice line first, so it comes before any late answer still waiting.
        answer(text, turn: turn.id)
        speakIfReady()
        let first = TurnPost(text: text, clientId: Self.newClientId())
        let posted = Task { [weak self] () -> [TurnPost] in
            guard let self else { return [first] }
            let inRoom = await self.post(first, stoppedTalking: stoppedTalking)
            if inRoom { self.awaitingAnswerSince = self.now() }
            return inRoom ? [] : [first]
        }
        listenForMore(after: SentTurn(id: turn.id, text: text, posted: posted))
        _ = await posted.value
    }

    /// What you said just after a turn went joins it (a pause mid-thought used to end the turn, and the rest
    /// was lost). The call keeps one turn, on the same floor. The room gets the new words as a turn that carries on
    /// the last one ("…and the dial?"), addressed the same way and posted after it: the agents' listeners answer new
    /// messages and never see edits, so editing the first would go unanswered. The wait for the answer starts again
    /// from the whole turn (for Senti, the voice line is asked again with it), and whatever the fast voice had not yet
    /// said about the first part is dropped.
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
        // The words added may change who it is for ("Okay so… Ada, what is next?"). Once it is everyone's, the floor
        // the first part gave its agent is open again.
        let wasFor = turnFor
        turnFor = VoiceTurnAddressee.of(whole, with: state.with, joined: state.joined)
        if let turnFor {
            floorHolder = (turnFor.lowercased(), turnFor)
        } else if wasFor != nil {
            floorHolder = nil
            floorAnnounced = false
        }
        if let id = gapAnswerId, !queue.contains(where: { $0.id == id }) { gapAnswerId = nil }
        readyAfterSending()
        answer(whole, turn: sent.id)
        speakIfReady()
        let more = TurnPost(text: Self.carriesOn + text, clientId: Self.newClientId())
        let posted = Task { [weak self] () -> [TurnPost] in
            // After the turn it carries on, so the room has them in order. A post the room did not confirm may still
            // have reached it (its answer lost), so it goes again under its own client ID, never inside a new message:
            // the room keeps one copy, and nothing said is lost or posted twice (#290).
            let unconfirmed = await sent.posted.value
            guard let self else { return unconfirmed + [more] }
            var left: [TurnPost] = []
            for post in unconfirmed {
                if !(await self.post(post, stoppedTalking: stoppedTalking)) { left.append(post) }
            }
            if !unconfirmed.isEmpty, left.count < unconfirmed.count { self.awaitingAnswerSince = self.now() }
            if !(await self.post(more, stoppedTalking: stoppedTalking)) { left.append(more) }
            if !left.isEmpty { self.state.notice = Self.turnLost }
            return left
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

    /// Senti, the room's own assistant (agent id `RoomChatCoordinator.senti`, compared without case). A call never reads
    /// its posts (`RoomChatQuiet.isRoomVoice`), so a turn for it is the one turn the voice line answers.
    static func isSenti(_ agent: String) -> Bool { agent.lowercased() == RoomChatCoordinator.senti }

    /// Who answers your turn `turn`, said as `text`: the call's one agent, or the one this turn is for. A turn for
    /// Senti is answered by the voice line. Any other agent answers in the room, and its post is read once when it
    /// comes; until then the phone waits for it (`waitForAnswer(from:)`). A turn for everyone gets neither: the agents'
    /// own answers are read. The line never speaks for "the room": on a call with two agents it used to answer every
    /// turn as the room while the agents waited.
    private func answer(_ text: String, turn: String) {
        guard let agent = state.with.count == 1 ? state.with.first : turnFor else { return }
        if Self.isSenti(agent) {
            askVoiceLine(text, turn: turn, as: agent)
        } else {
            waitForAnswer(from: agent)
        }
    }

    /// Asks the voice line for Senti's answer while the turn goes to the room (Phase 2): each sentence is read as it
    /// arrives. A new turn drops what is left of the last answer. `turn` is your turn being asked about, which the
    /// history leaves out.
    private func askVoiceLine(_ text: String, turn: String, as agent: String) {
        // Not asked while off, or resting after a 429.
        guard let voiceLine, !voiceLineOff, now() >= voiceLineRestsUntil else { return }
        let speaker = agent + Self.voiceSuffix
        let history = state.turns.filter { $0.id != turn }.suffix(12)
            .map { VoiceLineHistory(speaker: $0.speaker, text: $0.text) }
        let answerId = "line:" + UUID().uuidString.lowercased()
        let stream = voiceLine.voiceLine(sessionId: sessionId, agentId: agent, text: text, callId: callId,
                                         ringCallId: ringCallId,
                                         history: Array(history))
        lineStreaming = answerId
        voiceLineAsk = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self, !Task.isCancelled else { return }
                    if case .sentence(let sentence) = event {
                        self.takeVoiceLine(sentence, answerId: answerId, as: speaker)
                    }
                }
                guard !Task.isCancelled else { return }
                self?.lineEnded(answerId)
            } catch VoiceLineError.unavailable {
                // Off for the call either way; only this turn's own ask may end its answer (a cancelled one belongs to
                // a turn already gone).
                self?.voiceLineOff = true
                if !Task.isCancelled { self?.lineEnded(answerId) }
            } catch VoiceLineError.notAllowed {
                // Not this person's to use (warden, #274): off for the rest of the call.
                self?.voiceLineOff = true
                if !Task.isCancelled { self?.lineEnded(answerId) }
            } catch VoiceLineError.rateLimited(let retryAfter) {
                guard let self else { return }
                self.voiceLineRestsUntil = self.now().addingTimeInterval(min(300, max(1, retryAfter ?? 30)))
                if !Task.isCancelled { self.lineEnded(answerId) }
            } catch is CancellationError {
                // A newer turn or the hang-up dropped it.
            } catch {
                // A failed voice line is quiet. A cancelled ask (a newer turn, the hang-up) is not a failure, however
                // the client reports it.
                guard !Task.isCancelled else { return }
                self?.lineEnded(answerId)
            }
        }
    }

    /// The voice line's answer `answerId` is over (finished, failed, or said nothing): the late answers that waited for
    /// it are read once the line's last sentence has been said and you are not talking.
    private func lineEnded(_ answerId: String) {
        guard lineStreaming == answerId else { return }
        lineStreaming = nil
        yieldIfNotTalking()
        speakIfReady()
    }

    /// The voice line is on for this call (on the server, allowed for this person, and not resting after a 429). Its
    /// fast voice then also picks up a busy agent's ring, and speaks while an agent writes.
    private var voiceLineSpeaks: Bool { voiceLine != nil && !voiceLineOff && now() >= voiceLineRestsUntil }

    /// Waits for `agent`'s post, the answer to the turn that just went. If none has come by `bridgeAfter`, the agent's
    /// fast voice says `bridge(for:)`; if none by `givesUpAfter`, `noAnswerYet(from:)`. Each is said at most once a
    /// turn, and neither once the post is here.
    private func waitForAnswer(from agent: String) {
        guard voiceLineSpeaks else { return }
        let key = agent.lowercased()
        let since = now()
        awaited = key
        answerWatch = Task { [weak self] in
            var bridged = false
            while let self, !Task.isCancelled, self.awaited == key {
                await self.sleep(0.1)
                guard !Task.isCancelled, self.awaited == key else { return }
                let waited = self.now().timeIntervalSince(since)
                if waited >= Self.givesUpAfter {
                    self.awaited = nil
                    self.answerWatch = nil
                    self.sayWhileWriting(Self.noAnswerYet(from: agent), as: agent)
                    return
                }
                if !bridged, waited >= Self.bridgeAfter {
                    bridged = true
                    self.sayWhileWriting(Self.bridge(for: agent), as: agent)
                }
            }
        }
    }

    /// What the agent's fast voice says while the agent writes its answer: that it is answering, and nothing of what.
    /// The phone's own words, never asked of the voice line, so it cannot answer for the agent.
    static func bridge(for agent: String) -> String { "One moment, \(agent) is answering." }

    /// What the agent's fast voice says when no answer has come by `givesUpAfter`.
    static func noAnswerYet(from agent: String) -> String { "\(agent) hasn't answered yet." }

    /// Queues a line the agent's fast voice says while the agent writes, in the agent's voice. It is not kept in the
    /// transcript, and one not said yet gives way to the next (the bridge to "hasn't answered yet").
    private func sayWhileWriting(_ text: String, as agent: String) {
        guard state.phase != .ending, state.phase != .ended else { return }
        queue.removeAll { $0.id.hasPrefix(Self.whileWriting) }
        queue.append(VoiceRoomTurn(id: Self.whileWriting + UUID().uuidString.lowercased(),
                                   speaker: agent + Self.voiceSuffix, isYou: false, text: text, at: now()))
        state.waiting = queue.count
        yieldIfNotTalking()
        speakIfReady()
    }

    /// `agent` (lowercased) has posted, or left the call: the phone stops waiting on it, and what its fast voice had
    /// not said yet while it wrote is dropped, so nothing comes between you and the answer.
    private func stopWaiting(on agent: String) {
        if awaited == agent {
            answerWatch?.cancel()
            answerWatch = nil
            awaited = nil
        }
        queue.removeAll { $0.id.hasPrefix(Self.whileWriting) && Self.voiceOf($0.speaker).lowercased() == agent }
        state.waiting = queue.count
    }

    /// A new turn: the turn before it, if it was said to one agent on a call with several and that agent's post has
    /// not come since, is owed. Never Senti's, which the voice line answered.
    private func oweLatestTurn() {
        guard state.with.count > 1, let turn = latestTurn, let agent = turnFor?.lowercased(), !Self.isSenti(agent),
              !answeredLatest.contains(agent) else { return }
        owed[agent, default: []].append(turn)
    }

    /// A new turn or hang-up: the last quick answer stops streaming and what is left of it is not read, and the wait
    /// for the last turn's answer ends.
    private func dropVoiceLineLeftovers() {
        voiceLineAsk?.cancel()
        voiceLineAsk = nil
        lineStreaming = nil
        answerWatch?.cancel()
        answerWatch = nil
        awaited = nil
        queue.removeAll(where: { Self.isLine($0) })
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
    private func post(_ turnPost: TurnPost, stoppedTalking: Date) async -> Bool {
        let mentions = (turnFor.map { [$0] } ?? state.with).map { "@\($0)" }.joined(separator: " ")
        let addressed = mentions.isEmpty ? turnPost.text : "\(mentions) \(turnPost.text)"
        let sending = now()
        do {
            try await poster.postVoiceTurn(sessionId: sessionId, text: addressed, clientId: turnPost.clientId)
            let posted = now()
            timings.record(.post, posted.timeIntervalSince(sending))
            timings.record(.endpoint, posted.timeIntervalSince(stoppedTalking))
            // A turn that failed and was then sent again is in the room after all.
            if state.notice == Self.turnLost { state.notice = nil }
            return true
        } catch {
            state.notice = Self.turnLost
            return false
        }
    }

    static let turnLost = "That turn did not reach the room. Say it again."
    static let needsConsent = "Calls share what you say with the room's AI agents. Hang up, and say OK when the room asks."

    static func newClientId() -> String { "voice-" + UUID().uuidString.lowercased() }

    // MARK: - Hanging up

    func hangUp() async {
        guard state.phase != .ending, state.phase != .ended else { return }
        listenGeneration += 1
        silenceWatch?.cancel()
        joining = nil
        stopRinging()
        listener.cancel()
        speaker.stop()
        markUnread()
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

    /// The call is ending: the agents' posts it never read in full are marked in the transcript, with why. Nothing an
    /// agent said goes unread without a reason.
    private func markUnread() {
        var unread = queue.filter({ !Self.isLine($0) })
        if case .post(let turn) = reading { unread.insert(turn, at: 0) }
        reading = nil
        for turn in unread where state.skipped[turn.id] == nil {
            let why: VoiceRoomSkip = talkedOver.contains(turn.id) ? .youTalkedOver : .callEnded
            state.skipped[turn.id] = why
        }
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
            let mark = state.skipped[turn.id].map { " · skipped: " + $0.rawValue }
                ?? (turn.isHeld ? " · held: another agent had the floor" : "")
            lines.append("**\(turn.speaker)** · \(Self.clock(turn.at))" + mark)
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

/// Asking to add someone to the call by voice: "bring Claude warden into this call", "add forge", "get chatgpt on the
/// call". The name is matched against the room's agents; only a single clear match adds anyone.
enum VoiceAddIntent {
    private static let verbs: Set<String> = ["bring", "add", "invite", "get", "pull", "loop"]
    private static let stops: Set<String> = ["in", "into", "on", "onto", "to", "this", "the", "call", "too", "also",
                                              "please", "here", "now", "and", "me"]

    static func agent(in text: String, among agents: [String]) -> String? {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty }
        guard let verb = words.firstIndex(where: { verbs.contains($0) }) else { return nil }
        // A request to add someone mentions the call (or is short: "add warden").
        guard words.contains("call") || words.count <= 4 else { return nil }
        let name = words[(verb + 1)...].prefix { !stops.contains($0) }
        guard !name.isEmpty else { return nil }
        let joined = name.joined(separator: "-")
        let matches = agents.filter { agent in
            let id = agent.lowercased()
            return id == joined || id.hasSuffix("-" + joined) || id.split(separator: "-").map(String.init).contains(joined)
                || name.allSatisfy { part in id.split(separator: "-").contains(Substring(part)) }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Who a spoken turn is for on a call with several agents. The agent already listening used to answer every turn, even
/// one said to the agent just added ("the host is speaking the whole time").
enum VoiceTurnAddressee {
    /// Who a turn is for, by these rules in order. Nil is everyone, as it always is on a call with one agent or in a
    /// meeting.
    ///
    /// 1. A turn that says "both", "everyone", "everybody", "all", "y'all", "guys", "team", "you two" or "you all" is
    ///    everyone's.
    /// 2. Otherwise, the agents it addresses: a clause made only of names, greetings, "and" and "or" ("Hi Ada", "Good
    ///    morning Ada", "Ada and Max"); a clause that opens with a name and then a question or a request ("Ada what do
    ///    you think", "Ada can you…"); a name that ends a clause right after "me", "you" or "us" ("Can you hear me
    ///    Ada?"). A clause may open with "okay", "so"… first.
    /// 3. If it addresses no one so, the agents it thanks ("Thanks Ada", "Thank you, Ada.").
    ///
    /// One agent addressed is the one; two or more, or a name two agents share equally, is everyone. A name anywhere
    /// else addresses no one: the subject ("Ada said no", "Ada will ship it"), a possessive ("Ada's build"), or a name
    /// mid-clause ("ask Ada to check").
    ///
    /// 4. A turn that says no agent's name at all goes to the only agent that has said hello, if just one has. A turn
    ///    that names an agent without addressing one is everyone's.
    static func of(_ text: String, with agents: [String], joined: [String]) -> String? {
        guard agents.count > 1 else { return nil }
        let clauses = clauses(of: text)
        let words = clauses.flatMap { $0 }
        if saysEveryone(words) { return nil }
        let names = agents.map { (agent: $0, words: nameWords(of: $0)) }
        let allNames = names.reduce(into: Set<String>()) { $0.formUnion($1.words) }
        let found = addressed(in: clauses, names: allNames)
        if !found.strong.isEmpty { return one(found.strong, among: names) }
        if !found.thanked.isEmpty { return one(found.thanked, among: names) }
        guard !words.contains(where: { allNames.contains($0.text) }) else { return nil }
        let here = agents.filter { agent in joined.contains { $0.lowercased() == agent.lowercased() } }
        return here.count == 1 ? here[0] : nil
    }

    /// A word said, lowercased, with the character right after it (nil at the end).
    private struct Word {
        let text: String
        let next: Character?

        /// "Ada's build", "Ada's on it": a possessive or a contraction, never an address (not even thanked: "Thanks to
        /// Ada's fix").
        var isPossessive: Bool { next.map { "'’".contains($0) } ?? false }
    }

    /// Words that make a turn everyone's ("y'all" is said as "y" and "all").
    private static let everyone: Set<String> = ["both", "everyone", "everybody", "all", "yall", "guys", "team"]
    /// Words that greet ("Hi Ada", "Good morning Ada", "Welcome Ada").
    private static let greetings: Set<String> = ["hi", "hey", "hello", "yo", "welcome", "good", "morning", "afternoon",
                                                 "evening"]
    /// Words a clause may open with before the name it addresses ("Okay so Ada, …").
    private static let openers: Set<String> = ["ok", "okay", "so", "and", "um", "uh", "well", "right", "alright", "now",
                                               "oh", "then"]
    /// Words that join two names ("Ada and Max").
    private static let joiners: Set<String> = ["and", "or"]
    /// Words that, right after a name, ask or request something of it ("Ada what do you think", "Ada please…").
    private static let asking: Set<String> = ["what", "when", "where", "why", "how", "who", "which", "please", "do",
                                              "any"]
    /// These ask something of the name only when a person follows ("Ada can you…"); "Ada will ship it" and "Ada can't"
    /// say something about it.
    private static let modals: Set<String> = ["can", "could", "would", "will", "should"]
    private static let askedOf: Set<String> = ["you", "we", "i", "someone", "somebody", "anyone", "anybody"]
    /// A name that ends a clause right after one of these is said to that agent ("Nice to have you Ada.").
    private static let saidTo: Set<String> = ["me", "you", "us"]
    /// Words of an agent's id too common to address it by.
    private static let notNames: Set<String> = ["agent", "bot", "box", "the", "and", "for", "you"]

    /// The words an agent can be addressed by: its id's words (`build-helper` is "build" and "helper").
    static func nameWords(of agent: String) -> Set<String> {
        Set(agent.lowercased().split(whereSeparator: { "-_. ".contains($0) }).map(String.init)
            .filter { $0.count >= 3 && !notNames.contains($0) })
    }

    /// A turn's clauses: its words up to each , ; : . ? ! or ….
    private static func clauses(of text: String) -> [[Word]] {
        var clauses: [[Word]] = [[]]
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
                continue
            }
            if !current.isEmpty {
                clauses[clauses.count - 1].append(Word(text: current, next: character))
                current = ""
            }
            if ",;:.?!…".contains(character) { clauses.append([]) }
        }
        if !current.isEmpty { clauses[clauses.count - 1].append(Word(text: current, next: nil)) }
        return clauses.filter { !$0.isEmpty }
    }

    /// "Can you both hear me?", "Hi everyone", "you two": everyone's. "All right" is not "all".
    private static func saysEveryone(_ words: [Word]) -> Bool {
        words.indices.contains { index in
            let next = index + 1 < words.count ? words[index + 1].text : nil
            switch words[index].text {
            case "all": return next != "right"
            case "you": return next == "two"
            case let word: return everyone.contains(word)
            }
        }
    }

    /// The names a turn addresses (rule 2) and those it thanks (rule 3), as runs: "build helper" said together is one.
    private static func addressed(in clauses: [[Word]],
                                  names: Set<String>) -> (strong: [[String]], thanked: [[String]]) {
        let isName: (Word) -> Bool = { names.contains($0.text) && !$0.isPossessive }
        let onlyNames: (ArraySlice<Word>) -> Bool = { words in
            words.allSatisfy { isName($0) || greetings.contains($0.text) || joiners.contains($0.text) }
        }
        var strong: [[String]] = [], thanked: [[String]] = []
        // A clause that only says thanks ("Thank you, Ada.") makes the names right after it thanked too.
        var thanking = false
        for clause in clauses {
            var words = clause[...]
            while let first = words.first, openers.contains(first.text), !isName(first) { words = words.dropFirst() }
            let thanks = words.first?.text == "thanks"
                || (words.first?.text == "thank" && words.dropFirst().first?.text == "you")
            let afterThanks = thanking
            thanking = thanks && !words.contains(where: isName)
            if thanks || (afterThanks && onlyNames(words)) {
                thanked += runs(in: words, isName)
                continue
            }
            guard words.contains(where: isName) else { continue }
            // Only names and greetings: "Hi Ada", "Ada and Max", "Good morning Ada".
            if onlyNames(words) {
                strong += runs(in: words, isName)
                continue
            }
            // A name that opens the clause, then a question or a request: "Hey Ada what do you think".
            let opened = words.drop { greetings.contains($0.text) && !isName($0) }
            let name = opened.prefix(while: isName)
            if !name.isEmpty, asks(Array(opened.dropFirst(name.count).prefix(2))) {
                strong.append(name.map(\.text))
            }
            // A name that ends the clause right after "me", "you" or "us": "Can you hear me Ada?".
            let last = Array(words.reversed().prefix(while: isName).reversed())
            if !last.isEmpty, let before = words.dropLast(last.count).last, saidTo.contains(before.text) {
                strong.append(last.map(\.text))
            }
        }
        return (strong, thanked)
    }

    /// Whether the words right after a name ask or request something of it.
    private static func asks(_ after: [Word]) -> Bool {
        guard let first = after.first else { return false }
        if modals.contains(first.text) { return after.count > 1 && askedOf.contains(after[1].text) }
        return asking.contains(first.text)
    }

    /// The runs of names among these words: "Hi build helper and Ada" is ["build", "helper"] and ["ada"].
    private static func runs(in words: ArraySlice<Word>, _ isName: (Word) -> Bool) -> [[String]] {
        var runs: [[String]] = [], run: [String] = []
        for word in words {
            if isName(word) {
                run.append(word.text)
            } else if !run.isEmpty {
                runs.append(run)
                run = []
            }
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }

    /// The one agent these runs are for. A run is the agent with the most of its words in it; a run two agents share
    /// equally (a word two ids both have), or runs for two agents, are everyone's (nil).
    private static func one(_ runs: [[String]], among names: [(agent: String, words: Set<String>)]) -> String? {
        var agents: [String] = []
        for run in runs {
            let scores = names.map { (agent: $0.agent, said: Set(run).intersection($0.words).count) }
            let best = scores.map(\.said).max() ?? 0
            let top = scores.filter { $0.said == best }
            guard best > 0, top.count == 1 else { return nil }
            if !agents.contains(top[0].agent) { agents.append(top[0].agent) }
        }
        return agents.count == 1 ? agents[0] : nil
    }
}
