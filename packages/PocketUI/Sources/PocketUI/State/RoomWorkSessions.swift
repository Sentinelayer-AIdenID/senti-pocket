import Foundation

/// One agent's work on a message, as its Working row shows it (Carter, #61655): while it works, its newest step in a
/// few words; tapped, every step with its time; once done, how long it worked, with the steps kept. Built from the
/// agents' "working on" notes on the message (`RoomChatWorkLine`).
public struct RoomWorkSession: Equatable, Identifiable, Sendable {
    public struct Step: Equatable, Identifiable, Sendable {
        public let id: String
        public let text: String
        public let at: Date?

        public init(id: String, text: String, at: Date?) {
            self.id = id
            self.text = text
            self.at = at
        }
    }

    /// The agent, lowercased: one session per agent on a message.
    public let id: String
    public let agentId: String
    /// Oldest first.
    public let steps: [Step]
    public let isLive: Bool
    /// When it finished: its "done" note, the answer it posted after its last step, or its last step.
    public let endedAt: Date?

    public init(agentId: String, steps: [Step], isLive: Bool, endedAt: Date?) {
        self.id = agentId.lowercased()
        self.agentId = agentId
        self.steps = steps
        self.isLive = isLive
        self.endedAt = endedAt
    }

    public var latestStep: String { steps.last?.text ?? "" }
    public var startedAt: Date? { steps.first?.at }
    /// When it last did something: its newest step, or its end.
    public var lastActivity: Date? { isLive ? steps.last?.at : (endedAt ?? steps.last?.at) }

    /// How long it worked, once done.
    public var workedFor: TimeInterval? {
        guard !isLive, let start = startedAt, let end = endedAt, end >= start else { return nil }
        return end.timeIntervalSince(start)
    }

    /// "Worked for 2m 14s", "Worked for 9s", "Worked for 1h 5m".
    public static func workedForLabel(_ seconds: TimeInterval) -> String {
        "Worked for " + duration(seconds)
    }

    /// The same, read aloud: "2 minutes 14 seconds".
    public static func spokenDuration(_ seconds: TimeInterval) -> String {
        let (hours, minutes, secs) = parts(seconds)
        func unit(_ value: Int, _ name: String) -> String { "\(value) \(name)\(value == 1 ? "" : "s")" }
        if hours > 0 { return [unit(hours, "hour"), minutes > 0 ? unit(minutes, "minute") : nil].compactMap { $0 }.joined(separator: " ") }
        if minutes > 0 { return [unit(minutes, "minute"), secs > 0 ? unit(secs, "second") : nil].compactMap { $0 }.joined(separator: " ") }
        return unit(secs, "second")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let (hours, minutes, secs) = parts(seconds)
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    private static func parts(_ seconds: TimeInterval) -> (Int, Int, Int) {
        let total = max(0, Int(seconds.rounded()))
        return (total / 3_600, (total % 3_600) / 60, total % 60)
    }

    /// Each agent's work on one message, live ones first, then newest first. A session is live while its newest note
    /// is (not done, not stale) and the agent has posted nothing since: an answer after its last step ends it, as the
    /// relay never says "done" for a box. `posts` are each agent's post times, by lowercased id.
    public static func sessions(lines: [RoomChatWorkLine], posts: [String: [Date]]) -> [RoomWorkSession] {
        guard !lines.isEmpty else { return [] }
        var byAgent: [String: [RoomChatWorkLine]] = [:]
        var order: [String] = []
        for line in lines {
            let key = line.actorId.lowercased()
            if byAgent[key] == nil { order.append(key) }
            byAgent[key, default: []].append(line)
        }
        let sessions = order.compactMap { key -> RoomWorkSession? in
            guard let agentLines = byAgent[key] else { return nil }
            let ordered = agentLines.sorted { ($0.at ?? .distantPast, $0.id) < ($1.at ?? .distantPast, $1.id) }
            guard let newest = ordered.last else { return nil }
            let answer = newest.at.flatMap { last in posts[key]?.filter { $0 > last }.min() }
            let isLive = newest.isLive && answer == nil
            let saysDone = newest.text.lowercased().hasPrefix("done")
            return RoomWorkSession(
                agentId: newest.actorId,
                steps: ordered.map { Step(id: $0.id, text: $0.text, at: $0.at) },
                isLive: isLive,
                endedAt: isLive ? nil : (saysDone ? newest.at : (answer ?? newest.at))
            )
        }
        return sessions.sorted { left, right in
            if left.isLive != right.isLive { return left.isLive }
            return (left.lastActivity ?? .distantPast, left.id) > (right.lastActivity ?? .distantPast, right.id)
        }
    }

    /// The most rows shown under one message before the rest become "+N working".
    public static let shownLimit = 3
}
