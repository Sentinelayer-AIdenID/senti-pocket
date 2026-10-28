import Foundation
import PocketContracts

/// One row in the bell.
public struct NotificationRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let title: String
    public let body: String
    public let roomTitle: String?
    public let date: Date?
    public let isRead: Bool
    public let canOpen: Bool

    public init(id: String, kind: String, title: String, body: String, roomTitle: String?, createdAt: String, isRead: Bool, canOpen: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.roomTitle = roomTitle
        self.date = ParsedSessionTimestamp(createdAt).date
        self.isRead = isRead
        self.canOpen = canOpen
    }

    var symbol: String {
        switch kind {
        case "mention": return "at"
        case "invite_accepted", "join_link_accepted": return "person.badge.plus"
        case "member_returned": return "person.wave.2"
        default: return "bell"
        }
    }
}

/// Unread first (newest first), then earlier ones.
public struct NotificationsPresentationState: Equatable, Sendable {
    public let unread: [NotificationRow]
    public let earlier: [NotificationRow]
    public let isLoading: Bool
    public let failure: SessionLoadFailure?

    public init(rows: [NotificationRow], isLoading: Bool = false, failure: SessionLoadFailure? = nil) {
        let ordered = rows.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let protected = failure?.suppressesProtectedContent == true
        self.unread = protected ? [] : ordered.filter { !$0.isRead }
        self.earlier = protected ? [] : ordered.filter(\.isRead)
        self.isLoading = isLoading
        self.failure = failure
    }

    public var unreadCount: Int { unread.count }
}

public enum NotificationsIntent: Equatable, Sendable {
    case open(id: String)
    case markRead(id: String)
    case markAllRead
    case refresh
    case close
}
