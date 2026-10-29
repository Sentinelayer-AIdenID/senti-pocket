import Foundation

/// What this phone may do to one ticket now. Source-bound to the web's rules (sentinelayer-web `Tickets.helpers.ts`
/// `claimKind`, `canAssign`, `canEditTicket` at 56a2435), which mirror the lease service so no button offers what the
/// API would refuse, with two differences the API itself decides:
/// - the live lease holder may edit the title and body (session_relay_service `live_holder_content_edit`), which the
///   web does not offer yet;
/// - a `killed` ticket offers nothing: nothing transitions out of it, and the web does not know the status.
public struct RoomTicketActions: Equatable, Sendable {
    public enum Claim: Equatable, Sendable {
        case claim
        /// The lease expired without a release: claiming takes the ticket over.
        case takeOver
    }

    public let claim: Claim?
    /// This phone holds the credential for a live lease of yours (returned once, by its claim).
    public let canRelease: Bool
    public let canAssign: Bool
    public let canEdit: Bool

    public static let none = RoomTicketActions(claim: nil, canRelease: false, canAssign: false, canEdit: false)

    public var isEmpty: Bool { self == .none }

    public init(claim: Claim?, canRelease: Bool, canAssign: Bool, canEdit: Bool) {
        self.claim = claim
        self.canRelease = canRelease
        self.canAssign = canAssign
        self.canEdit = canEdit
    }

    /// - Parameters:
    ///   - viewerId: the signed-in account id, which is what a person's claim makes the assignee and lease holder.
    ///   - canWrite: owner, admin or contributor in the room (the API's `min_role="contributor"` on ticket writes).
    ///   - holdsLease: this phone kept the lease credential from its claim.
    public init(row: RoomTicketRow, viewerId: String?, canWrite: Bool, holdsLease: Bool) {
        guard canWrite, let viewer = viewerId, !viewer.isEmpty, row.status != "killed" else {
            self = .none
            return
        }
        let lease = row.lease
        let mine = lease.map { Self.sameActor($0.holder, viewer) } ?? false

        var claim: Claim?
        if lease?.isLive != true {
            switch row.status {
            case "open":
                claim = .claim
            case "assigned", "accepted":
                claim = Self.sameActor(row.assignee, viewer) ? .claim : nil
            case "working":
                if lease != nil {
                    claim = .takeOver
                } else if row.assignee == nil || Self.sameActor(row.assignee, viewer) {
                    claim = .claim
                }
            default:
                claim = nil
            }
        }
        self.init(
            claim: claim,
            canRelease: holdsLease && mine && lease?.isLive == true,
            canAssign: lease == nil,
            canEdit: lease == nil || (lease?.isLive == true && mine)
        )
    }

    /// Ids compare case-insensitively: the API lowercases assignees and lease holders.
    static func sameActor(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs.lowercased() == rhs.lowercased()
    }
}
