import Foundation

/// One spoken turn in a voice room: yours (recognized on the phone) or an agent's (read aloud in its voice).
public struct VoiceRoomTurn: Equatable, Identifiable, Sendable {
    public let id: String
    public let speaker: String
    public let isYou: Bool
    public let text: String
    public let at: Date
    /// In a meeting, another agent already had the floor for this turn: kept in the transcript, never read aloud.
    public let isHeld: Bool

    public init(id: String, speaker: String, isYou: Bool, text: String, at: Date, isHeld: Bool = false) {
        self.id = id
        self.speaker = speaker
        self.isYou = isYou
        self.text = text
        self.at = at
        self.isHeld = isHeld
    }
}

/// How fast a call felt, measured on the phone (Carter, 10-30: "something to measure response time for TTS and
/// STT"). Each measure keeps every sample; the call's end reports the middle (p50) and the slow end (p95).
public struct VoiceCallTimings: Equatable, Sendable {
    public enum Measure: String, CaseIterable, Sendable {
        /// You stopped talking (the last word heard) to the first sound of the answer: the gap people feel.
        case gap
        /// Your turn accepted by the room to the first answer arriving on the phone.
        case answer
        /// Ending your turn to the phone's recognizer handing over its words.
        case recognition
        /// Sending your turn to the room accepting it.
        case post
        /// Asking the phone to speak an answer to its first sound.
        case voiceStart

        public var label: String {
            switch self {
            case .gap: return "you stop → answer heard"
            case .answer: return "turn posted → answer arrives"
            case .recognition: return "speech recognized"
            case .post: return "turn posted"
            case .voiceStart: return "voice starts"
            }
        }
    }

    public private(set) var samples: [Measure: [TimeInterval]] = [:]
    /// Answers held because another agent had the floor.
    public private(set) var held = 0

    public init() {}

    public var isEmpty: Bool { samples.values.allSatisfy(\.isEmpty) && held == 0 }

    public mutating func record(_ measure: Measure, _ seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        samples[measure, default: []].append(seconds)
    }

    public mutating func noteHeld() { held += 1 }

    /// The nearest-rank percentile (0...1) of a measure, nil without samples.
    public func percentile(_ measure: Measure, _ fraction: Double) -> TimeInterval? {
        guard let values = samples[measure], !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    /// For the call's closing message: "Timings: you stop → answer heard 4.2 s (p95 6.0 s, 5 turns) · …".
    public func line() -> String? {
        let parts = Measure.allCases.compactMap { measure -> String? in
            guard let middle = percentile(measure, 0.5), let slow = percentile(measure, 0.95) else { return nil }
            let count = samples[measure]?.count ?? 0
            return count > 1
                ? "\(measure.label) \(Self.seconds(middle)) (p95 \(Self.seconds(slow)), \(count))"
                : "\(measure.label) \(Self.seconds(middle))"
        }
        var line = parts.joined(separator: " · ")
        if held > 0 { line += (line.isEmpty ? "" : " · ") + "\(held) held for the floor" }
        return line.isEmpty ? nil : "Timings: " + line + "."
    }

    /// For the transcript: a table of every measure.
    public func markdown() -> [String] {
        var lines = ["| Measure | p50 | p95 | Samples |", "| --- | --- | --- | --- |"]
        for measure in Measure.allCases {
            guard let middle = percentile(measure, 0.5), let slow = percentile(measure, 0.95) else { continue }
            lines.append("| \(measure.label) | \(Self.seconds(middle)) | \(Self.seconds(slow)) | \(samples[measure]?.count ?? 0) |")
        }
        if held > 0 { lines.append("| answers held for the floor | | | \(held) |") }
        return lines.count > 2 ? lines : []
    }

    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f s", value)
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
    /// The ring has stopped: an agent picked up, nobody did for a while, or you started talking.
    public var ringStopped = false

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

    public var isRinging: Bool { joined.isEmpty && !ringStopped && phase != .ending && phase != .ended }

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
