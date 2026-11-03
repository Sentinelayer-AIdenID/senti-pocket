import Foundation
import PocketSyncClient
import PocketUI

/// What tapping a link does inside a room.
enum RoomLinkAction: Equatable {
    /// Bring a message in this room into view.
    case focusMessage(Int64)
    /// Open one of this room's tickets over the chat (the web's `?ticket=` drawer).
    case openTicket(String)
    /// Open this room's agent requests (`?admission=`).
    case openAdmissions
    /// Open another room.
    case openRoom(SentiLink)
    /// Any other web link: the browser.
    case openInBrowser(URL)
    /// Refused by the link policy, or nothing to do.
    case ignore
}

/// Link routing with the web's rules: Senti room links open in the app, other web links open in the browser, and
/// anything `RoomLinkPolicy` refuses does nothing. In-app paths (`/dashboard/sessions/...`) resolve on the Senti web
/// origin, as the web resolves them. A link only navigates: answering a decision or approving an agent takes a tap.
enum RoomLinkRouter {
    static func action(for url: URL, inRoom sessionId: String?) -> RoomLinkAction {
        guard let absolute = RoomLinkPolicy.resolved(url) else { return .ignore }
        guard let link = SentiLink(string: absolute.absoluteString) else { return .openInBrowser(absolute) }
        guard let sessionId, link.sessionId.lowercased() == sessionId.lowercased() else { return .openRoom(link) }
        if let ticketId = link.ticketId { return .openTicket(ticketId) }
        if link.admissionId != nil { return .openAdmissions }
        if let sequence = link.messageSequence { return .focusMessage(sequence) }
        return .ignore
    }
}

/// Room links iOS hands the app (universal links to sentinelayer.com room pages). The newest one waits here until a
/// signed-in root opens it, so a link tapped while signed out opens once sign-in completes. Only the revision is
/// published: a view reacts with `onChange` after the change is committed, then takes the link exactly once.
@MainActor
final class IncomingLinkInbox: ObservableObject {
    @Published private(set) var revision = 0
    private var pending: SentiLink?

    /// Queues a Senti room link; anything else is refused. Returns whether the link was queued.
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard let link = SentiLink(string: url.absoluteString) else { return false }
        pending = link
        revision &+= 1
        return true
    }

    /// Queues a link that is already a Senti room link (a tapped notification).
    func receive(_ link: SentiLink) {
        pending = link
        revision &+= 1
    }

    /// The newest link not yet opened. Taking it clears it, so each link opens once.
    func take() -> SentiLink? {
        defer { pending = nil }
        return pending
    }
}
