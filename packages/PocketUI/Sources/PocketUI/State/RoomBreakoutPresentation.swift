import Foundation

/// A breakout as its card in the parent room shows it. The app maps it from the server's per-viewer descriptor.
public struct RoomBreakoutCard: Equatable, Identifiable, Sendable {
    public var id: String { childSessionId }
    public let childSessionId: String
    public let title: String
    /// Participant display names; nil when the server withholds them from this viewer.
    public let participantNames: [String]?
    public let messageCount: Int?
    public let unreadCount: Int?
    public let isLocked: Bool
    public let isOpen: Bool
    /// Whether this viewer may open the breakout and read it.
    public let canRead: Bool
    public let canPost: Bool
    public let createdDate: Date?

    public init(
        childSessionId: String,
        title: String,
        participantNames: [String]? = nil,
        messageCount: Int? = nil,
        unreadCount: Int? = nil,
        isLocked: Bool = false,
        isOpen: Bool = true,
        canRead: Bool = true,
        canPost: Bool = false,
        createdDate: Date? = nil
    ) {
        self.childSessionId = childSessionId
        self.title = title
        self.participantNames = participantNames
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.isLocked = isLocked
        self.isOpen = isOpen
        self.canRead = canRead
        self.canPost = canPost
        self.createdDate = createdDate
    }

    /// "warden, coral +2": the first two names and how many more.
    public var participantsLine: String? {
        guard let names = participantNames, !names.isEmpty else { return nil }
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) +\(names.count - 2)" : shown
    }

    /// "12 messages", "1 message"; nil when the count is withheld.
    public var messagesLine: String? {
        messageCount.map { $0 == 1 ? "1 message" : "\($0) messages" }
    }
}

/// A breakout's published outcome in the parent room.
public struct RoomBreakoutOutcomeCard: Equatable, Sendable {
    public struct Acknowledgement: Equatable, Identifiable, Sendable {
        public enum State: Equatable, Sendable {
            case ack
            case disagree
            case missing
        }

        public var id: String { name }
        public let name: String
        public let state: State

        public init(name: String, state: State) {
            self.name = name
            self.state = state
        }
    }

    public let childSessionId: String
    public let text: String
    public let authorName: String
    public let acknowledgements: [Acknowledgement]

    public init(childSessionId: String, text: String, authorName: String, acknowledgements: [Acknowledgement]) {
        self.childSessionId = childSessionId
        self.text = text
        self.authorName = authorName
        self.acknowledgements = acknowledgements
    }

    /// The acknowledgement line. "All acknowledged" appears only when every required participant acknowledged;
    /// disagreement and missing answers are always said (publication is not a claim of consensus).
    public var acknowledgementSummary: String {
        let total = acknowledgements.count
        guard total > 0 else { return "No acknowledgements were required" }
        let acked = acknowledgements.filter { $0.state == .ack }.count
        if acked == total { return "All \(total) acknowledged" }
        var parts = ["\(acked) of \(total) acknowledged"]
        let disagreed = acknowledgements.filter { $0.state == .disagree }.map(\.name)
        if !disagreed.isEmpty { parts.append("disagreed: " + disagreed.joined(separator: ", ")) }
        let missing = acknowledgements.filter { $0.state == .missing }.map(\.name)
        if !missing.isEmpty { parts.append("waiting on: " + missing.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// The room's breakouts in list order: open ones first, then the newest.
public enum RoomBreakoutOrdering {
    public static func sorted(_ cards: [RoomBreakoutCard]) -> [RoomBreakoutCard] {
        cards.sorted { lhs, rhs in
            if lhs.isOpen != rhs.isOpen { return lhs.isOpen }
            let left = lhs.createdDate ?? .distantPast
            let right = rhs.createdDate ?? .distantPast
            if left != right { return left > right }
            return lhs.childSessionId < rhs.childSessionId
        }
    }
}
