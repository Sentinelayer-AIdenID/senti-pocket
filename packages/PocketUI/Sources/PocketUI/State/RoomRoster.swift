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
        /// In the room now: in presence (active or idle), or a box still running.
        public let isOnline: Bool

        /// In the room and doing something now (not idle).
        public var isActive: Bool { isOnline && status == .here }

        public init(id: String, name: String, kind: Kind, status: Status, model: String? = nil, effort: String? = nil,
                    job: String? = nil, phase: String? = nil, firstSeen: Date? = nil, lastSeen: Date? = nil,
                    expiresAt: Date? = nil, posts: Int = 0, isOnline: Bool = false) {
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
            self.isOnline = isOnline
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

    /// Each member's model where the room knows it, by lowercased id (a box's model, from the Flight record).
    public var modelsById: [String: String] {
        var models: [String: String] = [:]
        for member in members {
            if let model = member.model, !model.isEmpty { models[member.id.lowercased()] = model }
        }
        return models
    }

    /// One side of the people list (Carter, 10-30: "I need agents and humans separated and a total number of online and
    /// offline", then "separation of humans, live agents and agents in boxes"): people, live agents, or agents in
    /// boxes, online ones first, with how many are active, idle and offline.
    public struct Side: Equatable, Sendable {
        public let title: String
        public let members: [Member]
        public var online: Int { members.filter(\.isOnline).count }
        public var offline: Int { members.count - online }
        /// Online and doing something now: the number the room's ring shows (Carter, 10-30: "If one idles that number
        /// drops").
        public var active: Int { members.filter(\.isActive).count }
        public var idle: Int { online - active }

        /// "Agents · 2 active · 5 idle · 3 offline", so the ring's number and the list's agree.
        public var header: String { "\(title) · \(active) active · \(idle) idle · \(offline) offline" }
    }

    /// Agents, then people; a side with nobody is left out.
    /// How many are in the room and active: the ring's number, the same as the people list's.
    public var activeCount: Int { members.filter(\.isActive).count }

    /// Who is in the room and active, by `presenceKey`: the ring colours exactly these (warden, #269).
    public var activeKeys: Set<String> { Set(members.filter(\.isActive).map { $0.id.lowercased() }) }

    /// One member's key: a person by their login (the handle their posts carry), anyone else by their id.
    public static func presenceKey(_ person: RoomChatPresence.Person) -> String {
        if person.isHuman, let login = person.login?.lowercased(), !login.isEmpty { return "human-\(login)" }
        return person.id.lowercased()
    }

    /// "4 active · 6 idle · 3 offline": the whole room, the ring's number first.
    public var summary: String {
        let online = members.filter(\.isOnline).count
        return "\(activeCount) active · \(online - activeCount) idle · \(members.count - online) offline"
    }

    public var sides: [Side] {
        let people = members.filter { $0.kind == .person }
        let agents = members.filter { $0.kind == .agent }
        let boxes = members.filter { $0.kind == .box }
        func ordered(_ list: [Member]) -> [Member] {
            list.enumerated().sorted { a, b in
                if a.element.isOnline != b.element.isOnline { return a.element.isOnline }
                return a.offset < b.offset
            }.map(\.element)
        }
        // The web's names for the same three (warden, 10-30), so both read alike.
        return [Side(title: "Humans", members: ordered(people)), Side(title: "Live agents", members: ordered(agents)),
                Side(title: "Agents in boxes", members: ordered(boxes))]
            .filter { !$0.members.isEmpty }
    }

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
        // Presence names a person by their account (`human-<user id>`, the server's unique key), and gives their login,
        // the handle their posts carry (`human-<login>`, API #1055): a person here is one member with their posts, not
        // one here and one idle (Carter, #55524: "it kept my name in idle still").
        let keyed = present.map { (presenceKey($0), $0) }
        // One person on two devices or tabs is here if either is (as the server merges them).
        let presence = Dictionary(keyed, uniquingKeysWith: { first, second in first.isIdle ? second : first })
        for (key, person) in keyed where seen[key] == nil && !RoomChatQuiet.systemAuthors.contains(key) {
            seen[key] = Seen(name: person.name, isHuman: person.isHuman)
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
                              expiresAt: box.expiresAt, posts: entry.posts, isOnline: true)
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
                          firstSeen: entry.first, lastSeen: entry.last, posts: entry.posts, isOnline: here != nil)
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
