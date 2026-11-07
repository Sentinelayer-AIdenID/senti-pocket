import Foundation

/// The destructive choice a chat row can offer. Authority comes from the current room list, and the server checks
/// it again when the person confirms. Leaving is held off until that route is released.
public enum ChatRowLifecycleAction: String, Equatable, Sendable {
    case archive
    case end
    case leave

    public var label: String {
        switch self {
        case .archive: return "Archive chat"
        case .end: return "End chat"
        case .leave: return "Leave chat"
        }
    }
    public var confirmationTitle: String {
        switch self {
        case .archive: return "Archive this chat?"
        case .end: return "End this chat for everyone?"
        case .leave: return "Leave this chat?"
        }
    }
    public var confirmationMessage: String {
        switch self {
        case .archive: return "It leaves everyone's chat list."
        case .end: return "No one can post in it after this."
        case .leave: return "You will no longer see this chat in your list."
        }
    }
    public var confirmLabel: String {
        switch self {
        case .archive: return "Archive"
        case .end: return "End"
        case .leave: return "Leave"
        }
    }
    public var symbolName: String {
        switch self {
        case .archive: return "archivebox"
        case .end: return "stop.circle"
        case .leave: return "rectangle.portrait.and.arrow.right"
        }
    }

    /// A row whose owner can end it can also archive it. A leave-only row grants neither owner action.
    public func permits(_ action: Self) -> Bool {
        self == action || (self == .end && action == .archive)
    }

    public static func available(membershipRole: String, status: String, leaveEnabled: Bool = false) -> Self? {
        guard status.lowercased() == "active" else { return nil }
        if membershipRole.lowercased() == "owner" { return .end }
        guard leaveEnabled, ["admin", "member", "contributor", "viewer"].contains(membershipRole.lowercased()) else {
            return nil
        }
        return .leave
    }
}

/// The order used by the existing long-press menu: folders first, the destructive choice last and separated.
public enum ChatRowMenuItem: Equatable, Hashable, Sendable {
    case moveToFolder
    case removeFromFolder
    case divider
    case archiveChat
    case endChat
    case leaveChat

    public var lifecycleAction: ChatRowLifecycleAction? {
        switch self {
        case .archiveChat: return .archive
        case .endChat: return .end
        case .leaveChat: return .leave
        default: return nil
        }
    }

    public static func ordered(foldersAvailable: Bool, filedInFolder: Bool,
                               lifecycle: ChatRowLifecycleAction?) -> [Self] {
        var items: [Self] = foldersAvailable ? [.moveToFolder] : []
        if foldersAvailable && filedInFolder { items.append(.removeFromFolder) }
        if let lifecycle {
            if !items.isEmpty { items.append(.divider) }
            switch lifecycle {
            case .end: items += [.archiveChat, .endChat]
            case .archive: items.append(.archiveChat)
            case .leave: items.append(.leaveChat)
            }
        }
        return items
    }
}
