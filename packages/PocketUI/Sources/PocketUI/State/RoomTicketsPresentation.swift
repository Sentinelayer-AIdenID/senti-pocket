import Foundation
import PocketContracts

/// One ticket as the app hands it to PocketUI.
public struct RoomTicketInput: Equatable, Sendable {
    /// Who holds the ticket's lease, and whether it was live when the input was made.
    public struct Lease: Equatable, Sendable {
        public let holder: String
        public let isLive: Bool
        public let expiresAt: Date?

        public init(holder: String, isLive: Bool, expiresAt: Date? = nil) {
            self.holder = holder
            self.isLive = isLive
            self.expiresAt = expiresAt
        }
    }

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
    public let lease: Lease?

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
        isVerifiedDone: Bool = false,
        lease: Lease? = nil
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
        self.lease = lease
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
    public let lease: RoomTicketInput.Lease?

    public init(
        id: String,
        title: String,
        body: String = "",
        status: String,
        createdBy: String = "",
        assignee: String? = nil,
        priority: Int? = nil,
        createdDate: Date? = nil,
        updatedDate: Date? = nil,
        sourceSequenceId: Int64? = nil,
        isVerifiedDone: Bool = false,
        decision: TicketDecision? = nil,
        lease: RoomTicketInput.Lease? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.status = status
        self.createdBy = createdBy
        self.assignee = assignee
        self.priority = priority
        self.createdDate = createdDate
        self.updatedDate = updatedDate
        self.sourceSequenceId = sourceSequenceId
        self.isVerifiedDone = isVerifiedDone
        self.decision = decision
        self.lease = lease
    }

    /// `done`, or `killed`, the API's other final status.
    public var isArchived: Bool { status == "done" || status == "killed" }

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

    /// Someone on a ticket the way the room names them: "you", an agent by its id, and anyone else as "a person",
    /// never by user id (a ticket names a person by user id, which only the web's presence list can label).
    public static func actorLabel(_ id: String, viewerId: String?) -> String {
        if let viewerId, !viewerId.isEmpty, id.lowercased() == viewerId.lowercased() { return "you" }
        if UUID(uuidString: id) != nil { return "a person" }
        return displayName(id)
    }
}

/// The room's Tickets tab: active or archived (done or killed) tickets ranked by impact, or a search across all of them.
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
    /// The status a decision answer reaches once the room has it.
    public static let decisionSentStatus = "Answer sent to the room."
    /// The ticket a link opened, found among all tickets whatever the archive toggle or search shows.
    public let focusedTicket: RoomTicketRow?
    /// This phone may file tickets here (contributor or above).
    public let canFileTickets: Bool
    /// Per ticket: what this phone may do to it now. Tickets with nothing to offer are absent.
    public let actions: [String: RoomTicketActions]
    /// Per ticket: a write in flight, or why the last one did not land. A ticket being filed is under `fileStatusKey`.
    public let ticketWriteStatus: [String: String]
    /// Who Assign offers: you first, then the agents on this room's tickets. Any other id can still be typed.
    public let assignChoices: [RoomTicketAssignChoice]
    /// How many tickets this phone has filed here; a change tells the filing form its ticket landed.
    public let filedCount: Int
    /// The viewer, for "you" in ticket lines.
    public let viewerId: String?

    public static let fileStatusKey = "__file__"

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
        focusTicketId: String? = nil,
        viewerId: String? = nil,
        canWriteTickets: Bool = false,
        heldLeases: Set<String> = [],
        ticketWriteStatus: [String: String] = [:],
        filedCount: Int = 0,
        viewerLogin: String? = nil,
        rosterAgentIds: [String] = []
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
                decision: input.status == "done" || input.status == "killed" ? nil : TicketDecision.parse(body),
                lease: input.lease
            )
        }
        let protected = failure?.suppressesProtectedContent == true
        let canWrite = canWriteTickets && !protected
        self.canFileTickets = canWrite
        var actions: [String: RoomTicketActions] = [:]
        if canWrite {
            for row in all {
                let offered = RoomTicketActions(
                    row: row, viewerId: viewerId, canWrite: true, holdsLease: heldLeases.contains(row.id)
                )
                if !offered.isEmpty { actions[row.id] = offered }
            }
        }
        self.actions = actions
        self.ticketWriteStatus = protected ? [:] : ticketWriteStatus
        self.filedCount = filedCount
        self.viewerId = viewerId
        self.assignChoices = canWrite
            ? RoomTicketAssignChoice.choices(viewerId: viewerId, viewerLogin: viewerLogin, roster: rosterAgentIds, tickets: all)
            : []
        self.archivedCount = protected ? 0 : all.filter(\.isArchived).count
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
            visible = all.filter { $0.isArchived == showsArchived }
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

/// One person or agent Assign offers.
public struct RoomTicketAssignChoice: Equatable, Identifiable, Sendable {
    /// What the API is sent: a person's user id, or an agent id.
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    /// You first, then the room's agents (web `ticketAssignCandidates`): the roster the room shows, in its order,
    /// then any other agent already on this room's tickets. People other than you are not offered: a ticket names a
    /// person by user id, and the member directory that would map them is not served yet. Any id can still be typed.
    static func choices(
        viewerId: String?,
        viewerLogin: String? = nil,
        roster: [String] = [],
        tickets: [RoomTicketRow]
    ) -> [RoomTicketAssignChoice] {
        var out: [RoomTicketAssignChoice] = []
        var seen = Set<String>()
        if let viewerId, !viewerId.isEmpty {
            seen.insert(viewerId.lowercased())
            out.append(RoomTicketAssignChoice(id: viewerId, label: viewerLogin.map { "Me (\($0))" } ?? "Me"))
        }
        func add(_ id: String) {
            let key = id.trimmingCharacters(in: .whitespaces).lowercased()
            guard isAgentId(key), seen.insert(key).inserted else { return }
            out.append(RoomTicketAssignChoice(id: key, label: "@\(key)"))
        }
        roster.forEach(add)
        var onTickets = Set<String>()
        for ticket in tickets {
            for id in [ticket.assignee, ticket.createdBy].compactMap({ $0 }) { onTickets.insert(id.lowercased()) }
        }
        onTickets.sorted().forEach(add)
        return out
    }

    /// An agent id: not a person's user id, not a `human-` sender, and not a placeholder.
    static func isAgentId(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 64, UUID(uuidString: trimmed) == nil,
              !trimmed.lowercased().hasPrefix("human-"), !["unknown", "system", "cli-user"].contains(trimmed.lowercased()) else {
            return false
        }
        return trimmed.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil
    }
}
