import Foundation
import PocketContracts

/// One ticket as the app hands it to PocketUI.
public struct RoomTicketInput: Equatable, Sendable {
    /// Where the ticket is, as the server reads it from typed facts: step `index` of `count` (counted from 1; 0 is not
    /// started), its name, and when it stopped moving, why, and whom it waits on or who last held it, in the server's
    /// own words (`in_review`, `waiting_on_review`, actor ids). Never worked out on the phone.
    public struct Step: Equatable, Sendable {
        public let index: Int
        public let count: Int
        /// `not_started`, `taken`, `in_review`, `merged`, `shipped` or `done`.
        public let name: String
        public let stalledSince: Date?
        /// `holder_lease_expired`, `waiting_on_assignee`, `waiting_on_review`, `waiting_on_owner`, `blocked` or
        /// `no_activity`.
        public let stalledReason: String?
        /// Actor ids.
        public let lastHolder: String?
        public let waitingOn: String?

        public init(index: Int, count: Int, name: String, stalledSince: Date? = nil, stalledReason: String? = nil,
                    lastHolder: String? = nil, waitingOn: String? = nil) {
            self.index = index
            self.count = count
            self.name = name
            self.stalledSince = stalledSince
            self.stalledReason = stalledReason
            self.lastHolder = lastHolder
            self.waitingOn = waitingOn
        }
    }

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
    /// Where the ticket is, from the server; nil from an older server, whose tickets show their status alone.
    public let step: Step?

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
        lease: Lease? = nil,
        step: Step? = nil
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
        self.step = step
    }
}

/// A row's strip of steps: `count` segments; those before `index` are done, `index` is the current one, named. At
/// index 0 the ticket has not started: no segment is filled and the strip says so.
public struct RoomTicketStepStrip: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        case done
        case current
        case ahead
    }

    public let index: Int
    public let count: Int
    /// What the strip says beside it: the current step's name ("In review"), or "Not started".
    public let label: String

    /// The steps' names as a person reads them.
    public static let names = [
        "not_started": "Not started", "taken": "Taken", "in_review": "In review", "merged": "Merged",
        "shipped": "Shipped", "done": "Done"
    ]

    /// `name` as the server sends it (`in_review`).
    public init(index: Int, count: Int, name: String) {
        self.index = index
        self.count = count
        self.label = index < 1 ? "Not started" : Self.names[name] ?? "Step \(index)"
    }

    /// False before the first step (index 0).
    public var isStarted: Bool { index >= 1 }

    /// Each step's segment, first to last.
    public var segments: [Segment] {
        (1...max(count, 1)).map { $0 < index ? .done : $0 == index ? .current : .ahead }
    }

    /// What VoiceOver says for the strip: "Step 3 of 4, in review", or "Not started, 4 steps".
    public var accessibilityLabel: String {
        guard isStarted else { return "Not started, \(count) \(count == 1 ? "step" : "steps")" }
        return "Step \(index) of \(count), \(label.lowercased())"
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
    /// Where the ticket is, from the server (Carter, 11-05: real steps, not a percentage).
    public let step: RoomTicketInput.Step?

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
        lease: RoomTicketInput.Lease? = nil,
        step: RoomTicketInput.Step? = nil
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
        self.step = step
    }

    /// `done`, or `killed`, the API's other final status.
    public var isArchived: Bool { status == "done" || status == "killed" }

    /// Someone is on it now: working, or in review, or held by a live lease (Carter, #55238: "the ones that are
    /// currently being worked on should be atop with a progress bar").
    public var isBeingWorkedOn: Bool {
        !isArchived && (["working", "in_progress", "in_review"].contains(status) || lease?.isLive == true)
    }

    /// The strip of named steps a row shows: one segment per step, those before the current one done, the current one
    /// named. Only from the server's step; a ticket without one shows its status alone, never a bar or a percentage
    /// (Carter, 11-05: "fix the progress thing. I hate it.").
    public var stepStrip: RoomTicketStepStrip? {
        step.map { RoomTicketStepStrip(index: $0.index, count: $0.count, name: $0.name) }
    }

    /// Why a ticket stopped, in plain words, the same as the web's, when no one is named (warden, 11-05).
    public static let stallReasons = [
        "holder_lease_expired": "the person working on it went quiet",
        "waiting_on_assignee": "waiting on whoever it's assigned to",
        "waiting_on_review": "waiting on review",
        "waiting_on_owner": "waiting on the owner",
        "blocked": "blocked",
        "no_activity": "no activity"
    ]

    /// The small print under the strip, once the ticket has stopped moving: since when, then why, as a sentence with
    /// the person in it ("Stalled since 2:10 PM · waiting on review by alex"). Nil while it moves. A time today reads as
    /// its time, an earlier one with its date.
    public func stallNote(now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current,
                          viewerId: String? = nil, viewerSenderId: String? = nil,
                          names: [String: String] = [:]) -> String? {
        stallParts(now: now, timeZone: timeZone, locale: locale, viewerId: viewerId, viewerSenderId: viewerSenderId,
                   names: names)?
            .joined(separator: " · ")
    }

    /// What VoiceOver says for the strip: "Step 2 of 5, in review" (or "Not started, 5 steps"), then the small print:
    /// "Step 2 of 5, in review. Stalled since 2:10 PM, waiting on review by alex".
    public func stepAccessibilityLabel(now: Date = Date(), timeZone: TimeZone = .current, locale: Locale = .current,
                                       viewerId: String? = nil, viewerSenderId: String? = nil,
                                       names: [String: String] = [:]) -> String? {
        guard let base = stepStrip?.accessibilityLabel else { return nil }
        guard let parts = stallParts(now: now, timeZone: timeZone, locale: locale, viewerId: viewerId,
                                     viewerSenderId: viewerSenderId, names: names)
        else { return base }
        return base + ". " + parts.joined(separator: ", ")
    }

    private func stallParts(now: Date, timeZone: TimeZone, locale: Locale, viewerId: String?, viewerSenderId: String?,
                            names: [String: String]) -> [String]? {
        guard let step, let since = step.stalledSince else { return nil }
        var parts = ["Stalled since \(Self.moment(since, now: now, timeZone: timeZone, locale: locale))"]
        if let reason = Self.stallSentence(step, viewerId: viewerId, viewerSenderId: viewerSenderId, names: names) {
            parts.append(reason)
        }
        return parts
    }

    /// Why it stopped, with the person it concerns in it, as the web says it (warden, 11-05, web #753; the shared table
    /// ticket-step-cases.json pins every case):
    /// - `holder_lease_expired` names the last holder: "alex, who was working on it, went quiet";
    /// - `waiting_on_assignee` names the one it waits on: "waiting on alex, who it's assigned to";
    /// - `waiting_on_review`: "waiting on review by alex"; `waiting_on_owner`: "waiting on the owner, alex";
    /// - `blocked`, `no_activity`: as they are, with no one named.
    /// The viewer is "you" ("waiting on review by you", "waiting on you", "waiting on you, the owner", "you went quiet
    /// while working on it"). Someone the room does not name is left out: the reason's plain words, or "waiting on the
    /// person it's assigned to". Without a reason it is "waiting on <the one it waits on>", else "last held by <the last
    /// holder>", and nothing when that person is not named.
    static func stallSentence(_ step: RoomTicketInput.Step, viewerId: String?, viewerSenderId: String?,
                              names: [String: String]) -> String? {
        func person(_ id: String?) -> (name: String?, isViewer: Bool)? {
            id.map { ticketPerson($0, viewerId: viewerId, viewerSenderId: viewerSenderId, names: names) }
        }
        guard let reason = step.stalledReason else {
            guard let who = person(step.waitingOn ?? step.lastHolder),
                  let name = who.isViewer ? "you" : who.name else { return nil }
            return step.waitingOn != nil ? "waiting on \(name)" : "last held by \(name)"
        }
        let plain = stallReasons[reason]
        switch reason {
        case "holder_lease_expired":
            guard let holder = person(step.lastHolder) else { return plain }
            if holder.isViewer { return "you went quiet while working on it" }
            return holder.name.map { "\($0), who was working on it, went quiet" } ?? plain
        case "waiting_on_assignee":
            guard let assignee = person(step.waitingOn) else { return plain }
            if assignee.isViewer { return "waiting on you" }
            return assignee.name.map { "waiting on \($0), who it's assigned to" }
                ?? "waiting on the person it's assigned to"
        case "waiting_on_review":
            guard let reviewer = person(step.waitingOn) else { return plain }
            if reviewer.isViewer { return "waiting on review by you" }
            return reviewer.name.map { "waiting on review by \($0)" } ?? plain
        case "waiting_on_owner":
            guard let owner = person(step.waitingOn) else { return plain }
            if owner.isViewer { return "waiting on you, the owner" }
            return owner.name.map { "waiting on the owner, \($0)" } ?? plain
        default:
            return plain
        }
    }

    private static func moment(_ date: Date, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(date, inSameDayAs: now) ? "jmm" : "MMMdjmm")
        return formatter.string(from: date)
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

    /// The lease, in words that cannot be misread: who holds it and until when ("Held by alex until 9:41 PM"), or that it
    /// lapsed. A lapsed lease names its last holder only when the room names them, as warden set for the web's chip
    /// (#753): "Lease expired · was alex", "Lease expired · was you", and "Lease expired" alone for someone the room does
    /// not name.
    public func leaseLine(viewerId: String?, viewerSenderId: String? = nil, names: [String: String] = [:],
                          time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> String? {
        guard let lease else { return nil }
        let holder = Self.ticketPerson(lease.holder, viewerId: viewerId, viewerSenderId: viewerSenderId, names: names)
        let who = holder.isViewer ? "you" : holder.name
        guard lease.isLive else { return who.map { "Lease expired · was \($0)" } ?? "Lease expired" }
        guard let until = lease.expiresAt else { return "Held by \(who ?? "a person")" }
        return "Held by \(who ?? "a person") until \(time(until))"
    }

    /// Someone on a ticket the way the room names them: "you", a person by the name the room's member directory gives
    /// them, an agent by its id, and a person the directory does not know as "a person", never by an id.
    public static func actorLabel(_ id: String, viewerId: String?, viewerSenderId: String? = nil,
                                  names: [String: String] = [:]) -> String {
        let person = ticketPerson(id, viewerId: viewerId, viewerSenderId: viewerSenderId, names: names)
        return person.isViewer ? "you" : person.name ?? "a person"
    }

    /// How an actor id reads (API #1167, as on the web, #753). An account (`human-g.<32 hex>`, `human-<uuid>`, or a
    /// bare user id) is the room's name for it, else not named: never its hex or its id. `human-<login>` is the room's
    /// name for that login, else the login. Anything else (an agent) is its id. `isViewer`: the id is the viewer's own,
    /// by account (`viewerId`, a user id) or by their own sender id as the API writes it (`viewerSenderId`, its
    /// `sender_id`), never by their login: a Google signup's login is its email's local part, which can be someone
    /// else's GitHub login (warden, 11-06). `names` is keyed by lowercased user id and by `human-<login>`.
    public static func ticketPerson(_ id: String, viewerId: String?, viewerSenderId: String?,
                                    names: [String: String]) -> (name: String?, isViewer: Bool) {
        let lower = id.lowercased()
        let account = accountKey(lower)
        let viewerAccount = viewerId.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let isViewer = (viewerAccount != nil && (viewerAccount == lower || viewerAccount == account))
            || (viewerSenderId.map { !$0.isEmpty && lower == $0.lowercased() } ?? false)
        if let name = names[lower], !name.isEmpty { return (name, isViewer) }
        if let account {
            return (names[account].flatMap { $0.isEmpty ? nil : $0 }, isViewer)
        }
        return (displayName(id), isViewer)
    }

    /// The user id an account's actor id stands for, lowercased: `human-g.<32 hex>` as a UUID, `human-<uuid>` and a
    /// bare UUID as they are, and any other `human-g.` id as its own text (never shown). Nil for a login or an agent.
    static func accountKey(_ lower: String) -> String? {
        let rest = lower.hasPrefix("human-") ? String(lower.dropFirst("human-".count)) : lower
        if UUID(uuidString: rest) != nil { return rest }
        guard lower.hasPrefix("human-g.") else { return nil }
        let hex = Array(rest.dropFirst(2))
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return rest }
        return [hex[0..<8], hex[8..<12], hex[12..<16], hex[16..<20], hex[20..<32]].map { String($0) }
            .joined(separator: "-")
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
    /// The viewer, for "you" in ticket lines: their user id, and their own sender id as the API writes it (its
    /// `sender_id`; a ticket may name them by either). Never their login, which a Google signup can share with someone.
    public let viewerId: String?
    public let viewerSenderId: String?
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
        viewerSenderId: String? = nil,
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
                lease: input.lease,
                step: input.step
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
        self.viewerSenderId = viewerSenderId
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
