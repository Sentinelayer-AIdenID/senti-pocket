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

    /// The title and body as a person sees them: the signal model's name hidden, as the web shows them. Edits and
    /// posts keep the ticket's own words.
    public var displayTitle: String { TicketSignal.publicTitle(title) }
    public var displayBody: String { TicketSignal.hideModelName(body) }

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

    /// Someone is on it now: working, or in review, or held by a live lease (Carter, #55238: "the ones that are
    /// currently being worked on should be atop with a progress bar").
    public var isBeingWorkedOn: Bool {
        !isArchived && (["working", "in_progress", "in_review"].contains(status) || lease?.isLive == true)
    }

    /// How far along a ticket being worked on is, by its stage: started, then in review. Carter asked for the signal
    /// layer to judge this from everything happening in the room; until the API carries that estimate, the stage is
    /// the honest number.
    public var stageProgress: Double? {
        guard isBeingWorkedOn else { return nil }
        return status == "in_review" ? 0.85 : 0.45
    }

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

    /// Someone on a ticket the way the room names them: "you", a person by the name the room's member directory gives
    /// their user id, an agent by its id, and a person the directory does not know as "a person", never by user id.
    public static func actorLabel(_ id: String, viewerId: String?, names: [String: String] = [:]) -> String {
        if let viewerId, !viewerId.isEmpty, id.lowercased() == viewerId.lowercased() { return "you" }
        if let name = names[id.lowercased()], !name.isEmpty { return name }
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
    /// Names for people's user ids, from the room's member directory.
    public let personNames: [String: String]
    /// Per ticket: its comments, oldest first, once loaded.
    public let comments: [String: [RoomTicketCommentRow]]
    /// Per ticket: a comment being posted, or why it did not post.
    public let commentStatus: [String: String]
    /// Tickets whose comment failed in a way posting it again may fix (Retry reuses its key, so it never posts twice).
    public let retryableComments: Set<String>
    /// "Start an agent on this" is offered: you can write tickets here and the mint admits your account.
    public let canStartAgents: Bool

    public static let fileStatusKey = "__file__"
    /// The status a comment reaches once the ticket has it.
    public static let commentPostedStatus = "Comment posted."

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
        rosterAgentIds: [String] = [],
        people: [RoomTicketAssignChoice] = [],
        personNames: [String: String] = [:],
        comments: [String: [RoomTicketCommentRow]] = [:],
        commentStatus: [String: String] = [:],
        retryableComments: Set<String> = [],
        canStartAgents: Bool = false
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
        self.canStartAgents = canWrite && canStartAgents
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
        self.personNames = personNames
        self.comments = protected ? [:] : comments
        self.commentStatus = protected ? [:] : commentStatus
        self.retryableComments = protected ? [] : retryableComments
        self.assignChoices = canWrite
            ? RoomTicketAssignChoice.choices(
                viewerId: viewerId, viewerLogin: viewerLogin, people: people, roster: rosterAgentIds, tickets: all
            )
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
        // Tickets being worked on come first (Carter, #55238), then by priority and the newest change.
        if lhs.isBeingWorkedOn != rhs.isBeingWorkedOn { return lhs.isBeingWorkedOn }
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

    /// You first, then the room's people from its member directory (by user id, which is what a ticket names a person
    /// by), then the room's agents (web `ticketAssignCandidates`): the roster the room shows, in its order, then any
    /// other agent already on this room's tickets. When the directory cannot be read, people other than you are not
    /// offered. Any id can still be typed.
    static func choices(
        viewerId: String?,
        viewerLogin: String? = nil,
        people: [RoomTicketAssignChoice] = [],
        roster: [String] = [],
        tickets: [RoomTicketRow]
    ) -> [RoomTicketAssignChoice] {
        var out: [RoomTicketAssignChoice] = []
        var seen = Set<String>()
        if let viewerId, !viewerId.isEmpty {
            seen.insert(viewerId.lowercased())
            out.append(RoomTicketAssignChoice(id: viewerId, label: viewerLogin.map { "Me (\($0))" } ?? "Me"))
        }
        for person in people where UUID(uuidString: person.id) != nil && seen.insert(person.id.lowercased()).inserted {
            out.append(person)
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

/// One comment under a ticket.
public struct RoomTicketCommentRow: Equatable, Identifiable, Sendable {
    public let id: String
    /// The author's id: a person's user id, or an agent id.
    public let authorId: String
    public let body: String
    public let date: Date?

    public init(id: String, authorId: String, body: String, createdAt: String) {
        self.id = id
        self.authorId = authorId
        self.body = body
        self.date = ParsedSessionTimestamp(createdAt).date
    }
}
