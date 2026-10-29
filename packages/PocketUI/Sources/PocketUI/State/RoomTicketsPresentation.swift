import Foundation
import PocketContracts

/// One ticket as the app hands it to PocketUI.
public struct RoomTicketInput: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let status: String
    public let createdBy: String
    public let assignee: String?
    public let createdAt: String
    public let updatedAt: String
    public let priority: Int?
    public let sourceSequenceId: Int64?
    public let isVerifiedDone: Bool

    public init(
        id: String,
        title: String,
        body: String = "",
        status: String,
        createdBy: String = "",
        assignee: String? = nil,
        createdAt: String = "",
        updatedAt: String = "",
        priority: Int? = nil,
        sourceSequenceId: Int64? = nil,
        isVerifiedDone: Bool = false
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.status = status
        self.createdBy = createdBy
        self.assignee = assignee
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.priority = priority
        self.sourceSequenceId = sourceSequenceId
        self.isVerifiedDone = isVerifiedDone
    }
}

public struct RoomTicketRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let status: String
    public let createdBy: String
    public let assignee: String?
    public let priority: Int?
    public let createdDate: Date?
    public let updatedDate: Date?
    public let sourceSequenceId: Int64?
    public let isVerifiedDone: Bool
    /// The question the ticket keeper is waiting on, while the ticket is not done.
    public let decision: TicketDecision?

    public var statusLabel: String {
        switch status {
        case "in_review": return "In review"
        case "done": return isVerifiedDone ? "Done" : "Done · unverified"
        default: return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public var priorityLabel: String? { priority.map { "P\($0)" } }

    /// Shown names drop the server's `human-` prefix.
    public static func displayName(_ id: String) -> String {
        id.hasPrefix("human-") ? String(id.dropFirst("human-".count)) : id
    }
}

/// The room's Tickets tab: active or archived (done) tickets ranked by impact, or a search across all of them.
public struct RoomTicketsPresentationState: Equatable, Sendable {
    public let rows: [RoomTicketRow]
    public let activeCount: Int
    public let archivedCount: Int
    public let showsArchived: Bool
    public let query: String
    public let isLoading: Bool
    public let isStale: Bool
    public let failure: SessionLoadFailure?
    /// Whether this phone can answer a ticket's decision (it can post to the room).
    public let canAnswerDecisions: Bool
    /// Per ticket: the answer being sent, sent, or why it failed.
    public let decisionStatus: [String: String]
    /// Tickets whose answer failed in a way the same message may fix (Retry sends it again, same client id).
    public let retryableDecisions: Set<String>
    /// The ticket a link opened, found among all tickets whatever the archive toggle or search shows.
    public let focusedTicket: RoomTicketRow?

    public init(
        tickets: [RoomTicketInput],
        showsArchived: Bool = false,
        query: String = "",
        isLoading: Bool = false,
        isStale: Bool = false,
        failure: SessionLoadFailure? = nil,
        canAnswerDecisions: Bool = false,
        decisionStatus: [String: String] = [:],
        retryableDecisions: Set<String> = [],
        focusTicketId: String? = nil
    ) {
        let all = tickets.map { input in
            let body = input.body
            return RoomTicketRow(
                id: input.id,
                title: input.title,
                body: body,
                status: input.status,
                createdBy: input.createdBy,
                assignee: input.assignee,
                priority: input.priority,
                createdDate: ParsedSessionTimestamp(input.createdAt).date,
                updatedDate: ParsedSessionTimestamp(input.updatedAt).date,
                sourceSequenceId: input.sourceSequenceId,
                isVerifiedDone: input.isVerifiedDone,
                decision: input.status == "done" ? nil : TicketDecision.parse(body)
            )
        }
        let protected = failure?.suppressesProtectedContent == true
        self.archivedCount = protected ? 0 : all.filter { $0.status == "done" }.count
        self.activeCount = protected ? 0 : all.count - archivedCount
        self.showsArchived = showsArchived
        self.query = query
        self.isLoading = isLoading
        self.isStale = isStale
        self.failure = failure
        self.canAnswerDecisions = canAnswerDecisions && failure?.suppressesProtectedContent != true
        self.decisionStatus = decisionStatus
        self.retryableDecisions = retryableDecisions
        self.focusedTicket = protected ? nil : focusTicketId.flatMap { id in all.first { $0.id == id } }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible: [RoomTicketRow]
        if protected {
            visible = []
        } else if !needle.isEmpty {
            // Search covers archived tickets too, as on the web.
            visible = all.filter {
                $0.title.lowercased().contains(needle) || $0.id.lowercased().hasPrefix(needle)
                    || $0.body.lowercased().contains(needle)
                    || ($0.assignee?.lowercased().contains(needle) ?? false)
            }
        } else {
            visible = all.filter { ($0.status == "done") == showsArchived }
        }
        self.rows = visible.sorted(by: RoomTicketsPresentationState.byImpact)
    }

    /// P0 first, unprioritised last; then the most recently changed.
    static func byImpact(_ lhs: RoomTicketRow, _ rhs: RoomTicketRow) -> Bool {
        let left = lhs.priority ?? 9
        let right = rhs.priority ?? 9
        if left != right { return left < right }
        let leftDate = lhs.updatedDate ?? .distantPast
        let rightDate = rhs.updatedDate ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return lhs.id < rhs.id
    }
}
