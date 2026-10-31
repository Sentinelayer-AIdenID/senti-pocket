import Foundation

/// What a room's row in the room list says besides its name (Carter, 10-31): who is in the room now, a person and a
/// bot with how many of each, right after how long ago it was active; and a badge with your unread messages on the
/// right, as Discord shows them. A count of 0, or one the server did not give, shows nothing.
public struct RoomListActivity: Equatable, Sendable {
    public let humansOnline: Int
    public let agentsOnline: Int
    public let unread: Int

    public static let none = RoomListActivity(humansOnline: 0, agentsOnline: 0, unread: 0)
    /// The most a badge counts before it says "99+".
    public static let badgeLimit = 99

    public init(humansOnline: Int?, agentsOnline: Int?, unread: Int?) {
        self.humansOnline = max(humansOnline ?? 0, 0)
        self.agentsOnline = max(agentsOnline ?? 0, 0)
        self.unread = max(unread ?? 0, 0)
    }

    public var showsHumans: Bool { humansOnline > 0 }
    public var showsAgents: Bool { agentsOnline > 0 }
    public var showsOnline: Bool { showsHumans || showsAgents }

    /// The badge: the count, "99+" past 99, or nil (no badge) with nothing unread.
    public var badgeText: String? { Self.badgeText(for: unread) }

    public static func badgeText(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > badgeLimit ? "\(badgeLimit)+" : "\(count)"
    }

    /// The room you are in: what it shows is being read, so it has no badge.
    public var whileReading: RoomListActivity {
        RoomListActivity(humansOnline: humansOnline, agentsOnline: agentsOnline, unread: 0)
    }

    /// "3 people and 2 agents online", "1 person online", "1 agent online"; nil when nobody is counted.
    public var onlineDescription: String? {
        var who: [String] = []
        if showsHumans { who.append(humansOnline == 1 ? "1 person" : "\(humansOnline) people") }
        if showsAgents { who.append(agentsOnline == 1 ? "1 agent" : "\(agentsOnline) agents") }
        return who.isEmpty ? nil : who.joined(separator: " and ") + " online"
    }

    /// "5 unread"; past the badge's 99+, "more than 99 unread" (the server counts to 100 at most, so 100 means 100
    /// or more); nil with nothing unread.
    public var unreadDescription: String? { Self.unreadDescription(for: unread) }

    public static func unreadDescription(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > badgeLimit ? "more than \(badgeLimit) unread" : "\(count) unread"
    }

    /// What VoiceOver says for the row after the room's name: "3 people and 2 agents online, 5 unread".
    public var accessibilityDescription: String? {
        let parts = [onlineDescription, unreadDescription].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
