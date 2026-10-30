import Foundation

/// The read line and ticks under a message, in the web's words (sentinelayer-web `SessionMessageContent`,
/// `MessageReadTicks`, `sessionViewerNames.ts`).
public struct RoomChatViews: Equatable, Sendable {
    public enum Ticks: Equatable, Sendable {
        /// ✓: nobody other than the author has viewed it yet.
        case sent
        /// ✓✓: someone other than the author has. (The web's blue "everyone has" waits for its member-list fix.)
        case seen
    }

    /// "Viewed by A, B and 2 more", "Viewed by N viewers" or "Not yet viewed".
    public let line: String
    public let ticks: Ticks
    /// For the ticks: "Seen by A at 10:42 and B at 10:43", "Seen by N viewers" or "Not yet seen".
    public let seenBy: String

    public init(line: String, ticks: Ticks, seenBy: String) {
        self.line = line
        self.ticks = ticks
        self.seenBy = seenBy
    }

    /// Someone who viewed it: a person by account id, an agent by its id.
    public struct Viewer: Equatable, Sendable {
        public let isHuman: Bool
        public let actorId: String
        public let viewedAt: Date?

        public init(isHuman: Bool, actorId: String, viewedAt: Date?) {
            self.isHuman = isHuman
            self.actorId = actorId
            self.viewedAt = viewedAt
        }
    }

    /// The web names at most three viewers before "and N more".
    static let maximumNames = 3
    /// A person presence has not named: never their account id, which would show one member's id to everyone.
    public static let unnamedPerson = "Signed-in viewer"

    /// - Parameters:
    ///   - viewedCount: views of the current revision, which may exceed the viewers listed.
    ///   - authorActorId: the author as viewers carry it (your account id for your message, the agent id for an
    ///     agent's), so the author's own view does not tick; nil when unknown.
    ///   - ownAccountId: you, shown as `ownName` in the line and "You" in the ticks.
    ///   - names: people's names from presence, keyed `human-<account id>`.
    public static func make(
        viewedCount: Int,
        viewers: [Viewer],
        selfViewed: Bool,
        authorActorId: String?,
        ownAccountId: String?,
        ownName: String?,
        names: [String: String],
        time: (Date) -> String
    ) -> RoomChatViews {
        func name(_ viewer: Viewer, selfLabel: String) -> String {
            guard viewer.isHuman else { return viewer.actorId }
            if let ownAccountId, viewer.actorId.lowercased() == ownAccountId.lowercased() { return selfLabel }
            return names["human-\(viewer.actorId.lowercased())"] ?? unnamedPerson
        }

        let complete = viewers.count == viewedCount
        let line = viewedCount > 0
            ? viewedByLabel(viewers.map { name($0, selfLabel: ownName ?? "You") },
                            unlisted: complete ? 0 : max(viewedCount - viewers.count, 0))
            : "Not yet viewed"

        // Ticks leave the author out. Your own view counts as the author's only on your own message.
        let author = authorActorId?.lowercased()
        let others = viewers.filter { $0.actorId.lowercased() != author }
        let authorIsYou = author != nil && author == ownAccountId?.lowercased()
        let authorViews = selfViewed && authorIsYou ? 1 : viewers.count - others.count
        let otherCount = max(0, viewedCount - authorViews)
        let seen = !others.isEmpty || otherCount > 0

        let seenBy: String
        if !seen {
            seenBy = "Not yet seen"
        } else {
            let shown = others.prefix(maximumNames).map { viewer -> String in
                let label = name(viewer, selfLabel: "You")
                return viewer.viewedAt.map { "\(label) at \(time($0))" } ?? label
            }
            let remaining = others.count - shown.count + max(0, otherCount - others.count)
            if shown.isEmpty {
                seenBy = "Seen by \(remaining) viewers"
            } else {
                let parts = remaining > 0 ? shown + ["\(remaining) more"] : Array(shown)
                seenBy = "Seen by " + joined(parts)
            }
        }
        return RoomChatViews(line: line, ticks: seen ? .seen : .sent, seenBy: seenBy)
    }

    /// "Viewed by A", "Viewed by A and B", "Viewed by A, B, C and 2 more", or the count when nobody is named.
    static func viewedByLabel(_ names: [String], unlisted: Int) -> String {
        let shown = Array(names.prefix(maximumNames))
        let more = names.count - shown.count + unlisted
        if shown.isEmpty { return more > 0 ? "Viewed by \(more) viewers" : "Viewed" }
        return "Viewed by " + joined(more > 0 ? shown + ["\(more) more"] : shown)
    }

    private static func joined(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
    }
}

/// Who is in the room now, for the "N humans here" pill and its list (sentinelayer-web `HumanPresencePill`).
public struct RoomChatPresence: Equatable, Sendable {
    public struct Person: Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let isHuman: Bool
        public let isIdle: Bool

        public init(id: String, name: String, isHuman: Bool, isIdle: Bool) {
            self.id = id
            self.name = name
            self.isHuman = isHuman
            self.isIdle = isIdle
        }
    }

    /// "2 humans here", "1 human here", "0 humans here", or "presence unavailable" when the server cannot tell.
    public let label: String
    /// The people count for a compact pill: "2", or "?" when the server cannot tell.
    public let compactCount: String
    public let isAvailable: Bool
    /// People first, then agents, each in the server's most-recent-first order.
    public let people: [Person]

    public init(label: String, compactCount: String, isAvailable: Bool, people: [Person] = []) {
        self.label = label
        self.compactCount = compactCount
        self.isAvailable = isAvailable
        self.people = people
    }

    public static func make(isAvailable: Bool, humansOnline: Int?, people: [Person]) -> RoomChatPresence {
        guard isAvailable, let humans = humansOnline else {
            return RoomChatPresence(label: "presence unavailable", compactCount: "?", isAvailable: false)
        }
        return RoomChatPresence(
            label: "\(humans) human\(humans == 1 ? "" : "s") here",
            compactCount: String(humans),
            isAvailable: true,
            people: people.filter(\.isHuman) + people.filter { !$0.isHuman }
        )
    }

    /// How many people and how many agents are here, each counted once (one agent can hold two leases).
    public var humanCount: Int { Set(people.filter(\.isHuman).map { $0.id.lowercased() }).count }
    public var agentCount: Int { Set(people.filter { !$0.isHuman }.map { $0.id.lowercased() }).count }

    /// Who arrived and who left between two readings, for the notes that come out of the room's floating avatars
    /// (Carter, #55354): people first, then agents, arrivals before departures, one note each. Nothing while either
    /// reading cannot tell, so opening the room or coming back after an outage is not a crowd arriving.
    public static func changes(from old: RoomChatPresence?, to new: RoomChatPresence?) -> [RoomPresenceChange] {
        guard let old, let new, old.isAvailable, new.isAvailable else { return [] }
        func names(_ presence: RoomChatPresence, humans: Bool) -> [(id: String, name: String)] {
            var seen = Set<String>()
            return presence.people.filter { $0.isHuman == humans && seen.insert($0.id.lowercased()).inserted }
                .map { ($0.id.lowercased(), $0.name) }
        }
        var changes: [RoomPresenceChange] = []
        for humans in [true, false] {
            let before = names(old, humans: humans)
            let after = names(new, humans: humans)
            let beforeIds = Set(before.map(\.id))
            let afterIds = Set(after.map(\.id))
            let arrived = after.filter { !beforeIds.contains($0.id) }.map(\.name)
            let left = before.filter { !afterIds.contains($0.id) }.map(\.name)
            if let text = RoomPresenceChange.line(arrived, "joined") {
                changes.append(RoomPresenceChange(isHuman: humans, joined: true, text: text))
            }
            if let text = RoomPresenceChange.line(left, "left") {
                changes.append(RoomPresenceChange(isHuman: humans, joined: false, text: text))
            }
        }
        return changes
    }
}

/// Someone arriving in the room or leaving it: "Simone joined", "Simone and Ade left", "lab-box-1 and 3 more joined".
public struct RoomPresenceChange: Equatable, Sendable {
    public let isHuman: Bool
    public let joined: Bool
    public let text: String

    public init(isHuman: Bool, joined: Bool, text: String) {
        self.isHuman = isHuman
        self.joined = joined
        self.text = text
    }

    static func line(_ names: [String], _ verb: String) -> String? {
        switch names.count {
        case 0: return nil
        case 1: return "\(names[0]) \(verb)"
        case 2: return "\(names[0]) and \(names[1]) \(verb)"
        default: return "\(names[0]) and \(names.count - 1) more \(verb)"
        }
    }
}
