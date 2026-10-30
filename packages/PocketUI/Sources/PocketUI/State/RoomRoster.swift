import Foundation

/// Everyone who came to a room, not only who is here now (Carter, 10-30: "Every one should be there who came and
/// clicking on them should tell me literally everything about them like what model and strength and how long they
/// were here for and whether they're still active or destroyed"). Built from what the room already knows: who
/// posted and when, who is here, and the room's boxes from the Flight record.
public struct RoomRoster: Equatable, Sendable {
    public enum Status: Int, Comparable, CaseIterable, Sendable {
        /// Here and active now (green).
        case here
        /// Here but idle, or heard from within the hour (gray).
        case idle
        /// Not here and quiet for over an hour (red).
        case gone
        /// A box that ended: destroyed, killed or lost (red).
        case ended

        public static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .here: return "Here"
            case .idle: return "Idle"
            case .gone: return "Gone"
            case .ended: return "Ended"
            }
        }
    }

    public enum Kind: String, Equatable, Sendable {
        case person
        case agent
        case box
    }

    public struct Member: Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let kind: Kind
        public let status: Status
        public let model: String?
        public let effort: String?
        /// A box's job, or nil.
        public let job: String?
        /// A box's own phase on the mint ("working", "ready", "destroyed" ...).
        public let phase: String?
        public let firstSeen: Date?
        public let lastSeen: Date?
        public let expiresAt: Date?
        public let posts: Int

        public init(id: String, name: String, kind: Kind, status: Status, model: String? = nil, effort: String? = nil,
                    job: String? = nil, phase: String? = nil, firstSeen: Date? = nil, lastSeen: Date? = nil,
                    expiresAt: Date? = nil, posts: Int = 0) {
            self.id = id
            self.name = name
            self.kind = kind
            self.status = status
            self.model = model
            self.effort = effort
            self.job = job
            self.phase = phase
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
            self.expiresAt = expiresAt
            self.posts = posts
        }

        /// From the first post seen here to the last one.
        public var timeHere: TimeInterval? {
            guard let firstSeen, let lastSeen, lastSeen > firstSeen else { return nil }
            return lastSeen.timeIntervalSince(firstSeen)
        }
    }

    /// A post the roster learns from.
    public struct Post: Equatable, Sendable {
        public let authorId: String
        public let name: String
        public let isHuman: Bool
        public let at: Date?

        public init(authorId: String, name: String, isHuman: Bool, at: Date?) {
            self.authorId = authorId
            self.name = name
            self.isHuman = isHuman
            self.at = at
        }
    }

    /// A running box from the Flight record.
    public struct Box: Equatable, Sendable {
        public let name: String
        public let model: String
        public let effort: String?
        public let phase: String
        public let job: String?
        public let lastActivity: Date?
        public let expiresAt: Date?

        public init(name: String, model: String, effort: String? = nil, phase: String, job: String? = nil,
                    lastActivity: Date? = nil, expiresAt: Date? = nil) {
            self.name = name
            self.model = model
            self.effort = effort
            self.phase = phase
            self.job = job
            self.lastActivity = lastActivity
            self.expiresAt = expiresAt
        }
    }

    public let members: [Member]

    public init(members: [Member]) {
        self.members = members
    }

    public static let empty = RoomRoster(members: [])

    /// Someone heard from within this long counts as idle rather than gone.
    public static let recent: TimeInterval = 60 * 60
    /// A box active within this long counts as here.
    public static let activeBox: TimeInterval = 5 * 60

    public static func build(posts: [Post], present: [RoomChatPresence.Person], runningBoxes: [Box],
                             endedBoxes: Set<String>, now: Date) -> RoomRoster {
        struct Seen {
            var name: String
            var isHuman: Bool
            var first: Date?
            var last: Date?
            var posts = 0
        }
        var seen: [String: Seen] = [:]
        for post in posts {
            let key = post.authorId.lowercased()
            guard !key.isEmpty, !RoomChatQuiet.systemAuthors.contains(key) else { continue }
            var entry = seen[key] ?? Seen(name: post.name, isHuman: post.isHuman)
            entry.posts += 1
            if let at = post.at {
                entry.first = min(entry.first ?? at, at)
                entry.last = max(entry.last ?? at, at)
            }
            seen[key] = entry
        }
        let presence = Dictionary(present.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for person in present where seen[person.id.lowercased()] == nil
            && !RoomChatQuiet.systemAuthors.contains(person.id.lowercased()) {
            seen[person.id.lowercased()] = Seen(name: person.name, isHuman: person.isHuman)
        }
        let boxes = Dictionary(runningBoxes.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for box in runningBoxes where seen[box.name.lowercased()] == nil {
            seen[box.name.lowercased()] = Seen(name: box.name, isHuman: false)
        }
        let ended = Set(endedBoxes.map { $0.lowercased() })
        for name in ended where seen[name] == nil && boxes[name] == nil {
            seen[name] = Seen(name: name, isHuman: false)
        }

        let members = seen.map { key, entry -> Member in
            let here = presence[key]
            if let box = boxes[key] {
                let active = box.lastActivity.map { now.timeIntervalSince($0) <= activeBox } ?? false
                let status: Status = (here.map { !$0.isIdle } ?? false) || active ? .here : .idle
                return Member(id: key, name: box.name, kind: .box, status: status, model: box.model, effort: box.effort,
                              job: box.job, phase: box.phase, firstSeen: entry.first, lastSeen: latest(entry.last, box.lastActivity),
                              expiresAt: box.expiresAt, posts: entry.posts)
            }
            if ended.contains(key) {
                return Member(id: key, name: entry.name, kind: .box, status: .ended, phase: "ended",
                              firstSeen: entry.first, lastSeen: entry.last, posts: entry.posts)
            }
            let status: Status
            if let here {
                status = here.isIdle ? .idle : .here
            } else if let last = entry.last, now.timeIntervalSince(last) <= recent {
                status = .idle
            } else {
                status = .gone
            }
            return Member(id: key, name: entry.name, kind: entry.isHuman ? .person : .agent, status: status,
                          firstSeen: entry.first, lastSeen: entry.last, posts: entry.posts)
        }
        .sorted {
            if $0.status != $1.status { return $0.status < $1.status }
            return ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast)
        }
        return RoomRoster(members: members)
    }
}

private func latest(_ a: Date?, _ b: Date?) -> Date? {
    switch (a, b) {
    case let (a?, b?): return Swift.max(a, b)
    case let (a?, nil): return a
    case let (nil, b?): return b
    case (nil, nil): return nil
    }
}
