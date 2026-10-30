import Foundation

/// One spoken turn in a voice room: yours (recognized on the phone) or an agent's (read aloud in its voice).
public struct VoiceRoomTurn: Equatable, Identifiable, Sendable {
    public let id: String
    public let speaker: String
    public let isYou: Bool
    public let text: String
    public let at: Date

    public init(id: String, speaker: String, isYou: Bool, text: String, at: Date) {
        self.id = id
        self.speaker = speaker
        self.isYou = isYou
        self.text = text
        self.at = at
    }
}

/// A voice conversation in a room, as the panel shows it.
public struct VoiceRoomState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Ready for you to talk.
        case ready
        /// Listening to you; `partial` holds what has been recognized so far.
        case listening
        /// Your turn is on its way to the room.
        case sending
        /// An agent's answer is being read aloud.
        case speaking(speaker: String)
        /// Hanging up: the transcript is being saved to the room.
        case ending
        case ended
    }

    public var phase: Phase
    /// Who you are talking with: one agent, or everyone in the room (a meeting) when empty.
    public var with: [String]
    public var partial: String
    public var turns: [VoiceRoomTurn]
    public var startedAt: Date
    /// Answers waiting to be read aloud after the current one.
    public var waiting: Int
    /// After an answer is read, listening starts again by itself, and a pause ends your turn.
    public var isHandsFree: Bool
    public var notice: String?
    /// The agents who have answered so far; until one does, the call is ringing.
    public var joined: [String] = []

    public init(
        phase: Phase = .ready,
        with: [String] = [],
        partial: String = "",
        turns: [VoiceRoomTurn] = [],
        startedAt: Date = Date(),
        waiting: Int = 0,
        isHandsFree: Bool = true,
        notice: String? = nil
    ) {
        self.phase = phase
        self.with = with
        self.partial = partial
        self.turns = turns
        self.startedAt = startedAt
        self.waiting = waiting
        self.isHandsFree = isHandsFree
        self.notice = notice
    }

    /// "pocket-forge", "pocket-forge and warden", or "everyone".
    public var title: String {
        switch with.count {
        case 0: return "everyone"
        case 1: return with[0]
        default: return with.dropLast().joined(separator: ", ") + " and " + (with.last ?? "")
        }
    }

    public var isListening: Bool { phase == .listening }

    public var isRinging: Bool { joined.isEmpty && phase != .ending && phase != .ended }

    public var speaker: String? {
        if case .speaking(let speaker) = phase { return speaker }
        return nil
    }
}

public enum VoiceRoomIntent: Equatable, Sendable {
    /// Start or stop your turn (a tap), or hold to talk: `talk(true)` when pressed and `talk(false)` when let go.
    case toggleTalk
    case talk(Bool)
    /// Stop reading the current answer (the next one, if any, follows).
    case skip
    case setHandsFree(Bool)
    case hangUp
}

/// Whom a call can ring (Carter, #55061): only agents that can answer now. A box (an agent minted for a job) while it
/// runs, never once it ended; any other agent while it is here (active or idle) or has posted within the hour. The
/// room's own services (costs, mints, ticket filing) never answer a call.
public enum VoiceCallRoster {
    /// An agent heard from within this long can still answer.
    public static let recent: TimeInterval = 60 * 60
    /// The most the picker offers.
    public static let limit = 8

    public struct Post: Equatable, Sendable {
        public let authorId: String
        public let at: Date?

        public init(authorId: String, at: Date?) {
            self.authorId = authorId
            self.at = at
        }
    }

    /// - Parameters:
    ///   - present: the agents here now, active or idle, in the order the room shows them.
    ///   - posts: agents' messages, newest first.
    ///   - runningBoxes: the boxes the Flight record shows running, which answer even when quiet.
    ///   - endedBoxes: boxes that ended, from the Flight record and the room's own lines.
    public static func partners(present: [String], posts: [Post], runningBoxes: [String], endedBoxes: Set<String>,
                                now: Date) -> [String] {
        let running = Set(runningBoxes.map { $0.lowercased() })
        let ended = Set(endedBoxes.map { $0.lowercased() })
        var partners: [String] = []
        var seen = Set<String>()
        func offer(_ id: String) {
            let key = id.lowercased()
            guard !key.isEmpty, !key.hasPrefix("human"), !RoomChatQuiet.systemAuthors.contains(key),
                  running.contains(key) || !ended.contains(key),
                  seen.insert(key).inserted else { return }
            partners.append(id)
        }
        present.forEach(offer)
        for post in posts {
            guard let at = post.at, now.timeIntervalSince(at) <= recent else { continue }
            offer(post.authorId)
        }
        runningBoxes.forEach(offer)
        return Array(partners.prefix(limit))
    }
}
