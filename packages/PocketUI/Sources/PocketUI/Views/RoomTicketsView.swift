#if canImport(SwiftUI)
import SwiftUI

public enum RoomTicketsIntent: Equatable, Sendable {
    case setShowsArchived(Bool)
    case search(String)
    case refresh
    case openSourceMessage(sequenceId: Int64)
    case answerDecision(ticketId: String, answer: String, detail: String)
    /// Sends the ticket's last answer again, as the same message.
    case retryDecision(ticketId: String)
    case fileTicket(title: String, body: String, assignee: String?)
    /// Claims the ticket, or takes over a lease that expired.
    case claim(ticketId: String)
    case release(ticketId: String)
    /// nil unassigns.
    case assign(ticketId: String, assignee: String?)
    case edit(ticketId: String, title: String, body: String)
    /// Loads (or tops up) a ticket's comments when it is opened.
    case loadComments(ticketId: String)
    case comment(ticketId: String, body: String)
    /// Posts the ticket's last comment again, with the same key.
    case retryComment(ticketId: String)
    /// "Chat about it" (web): the ticket's card and a note, posted to this room as you.
    case chatAboutIt(ticketId: String, note: String)
    /// Start an agent on its own machine for the ticket (web "Mint for this ticket").
    case startAgent(ticketId: String)
}

/// The room's Tickets tab: Active / Archived (N), search across all tickets, ranked by impact. Tapping a ticket
/// opens its full Markdown body.
public struct RoomTicketsView: View {
    private let state: RoomTicketsPresentationState
    private let send: (RoomTicketsIntent) -> Void
    @State private var query = ""
    @State private var filing = false

    /// `startsFiling` opens the new-ticket sheet at once (the composer's "File a ticket").
    public init(state: RoomTicketsPresentationState, startsFiling: Bool = false, send: @escaping (RoomTicketsIntent) -> Void) {
        self.state = state
        self.send = send
        _filing = State(initialValue: startsFiling)
    }

    public var body: some View {
        List {
            Section {
                Picker("Tickets", selection: Binding(
                    get: { state.showsArchived },
                    set: { send(.setShowsArchived($0)) }
                )) {
                    Text("Active (\(state.activeCount))").tag(false)
                    Text("Archived (\(state.archivedCount))").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(!state.query.isEmpty)
                .accessibilityIdentifier("pocket.tickets.archivedToggle")
            }
            .listRowBackground(Color.clear)

            if let failure = state.failure {
                Section {
                    Text(failure.detail).foregroundStyle(PocketPalette.warning)
                }
            } else if state.isStale {
                Section {
                    Label("Showing the last tickets loaded; updates will resume.", systemImage: "arrow.clockwise")
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
            }

            if state.rows.isEmpty && !state.isLoading && state.failure == nil {
                Text(state.query.isEmpty ? (state.showsArchived ? "No archived tickets." : "No open tickets.") : "No tickets match.")
                    .foregroundStyle(PocketPalette.textSecondary)
            }

            ForEach(state.rows) { row in
                NavigationLink {
                    RoomTicketDetailView(
                        row: row,
                        canAnswer: state.canAnswerDecisions,
                        decisionStatus: state.decisionStatus[row.id],
                        canRetryDecision: state.retryableDecisions.contains(row.id),
                        actions: state.actions[row.id] ?? .none,
                        writeStatus: state.ticketWriteStatus[row.id],
                        assignChoices: state.assignChoices,
                        viewerId: state.viewerId,
                        names: state.personNames,
                        comments: state.comments[row.id],
                        canComment: state.canFileTickets,
                        commentStatus: state.commentStatus[row.id],
                        canRetryComment: state.retryableComments.contains(row.id),
                        canStartAgent: state.canStartAgents,
                        send: send
                    )
                } label: {
                    RoomTicketRowView(row: row)
                }
                .accessibilityIdentifier("pocket.tickets.row.\(row.id)")
            }
        }
        .overlay {
            if state.isLoading && state.rows.isEmpty {
                ProgressView("Loading tickets")
            }
        }
        .searchable(text: $query, prompt: "Search tickets")
        .onChange(of: query) { send(.search($0)) }
        .refreshable { send(.refresh) }
        .navigationTitle("Tickets")
        .toolbar {
            if state.canFileTickets {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        filing = true
                    } label: {
                        Label("File a ticket", systemImage: "plus")
                    }
                    .accessibilityIdentifier("pocket.tickets.file")
                }
            }
        }
        .sheet(isPresented: $filing) {
            RoomTicketFileSheet(
                status: state.ticketWriteStatus[RoomTicketsPresentationState.fileStatusKey],
                filedCount: state.filedCount,
                assignChoices: state.assignChoices,
                send: send
            )
        }
        .accessibilityIdentifier("pocket.tickets.screen")
    }
}

private struct RoomTicketRowView: View {
    let row: RoomTicketRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let label = row.priorityLabel {
                    Text(label)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoomTicketPalette.priority(row.priority).opacity(0.18), in: Capsule())
                        .foregroundStyle(RoomTicketPalette.priority(row.priority))
                }
                Text(row.displayTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
            }
            // Its own line, so the status row never wraps on a phone.
            if row.decision != nil {
                Label("Decision needed", systemImage: "questionmark.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketPalette.warning)
                    .accessibilityIdentifier("pocket.tickets.row.decision")
            }
            HStack(spacing: 8) {
                Text(row.statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RoomTicketPalette.status(row.status))
                if let assignee = row.assignee {
                    Label(RoomTicketRow.displayName(assignee), systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                Spacer(minLength: 0)
                if let date = row.updatedDate {
                    Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
            }
            // Being worked on: how far along, and who holds it (Carter, #55238).
            if let progress = row.stageProgress {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(RoomTicketPalette.status(row.status))
                    if let holder = row.lease.flatMap({ $0.isLive ? $0.holder : nil }) {
                        Text("\(RoomTicketRow.displayName(holder)) is on it")
                            .font(.caption2)
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(Int(progress * 100)) percent along")
                .accessibilityIdentifier("pocket.tickets.row.progress")
            }
        }
        .padding(.vertical, 4)
    }
}

/// One ticket: its title, status, people and dates, and the full body rendered as Markdown.
public struct RoomTicketDetailView: View {
    let row: RoomTicketRow
    var canAnswer = false
    var decisionStatus: String?
    var canRetryDecision = false
    var actions: RoomTicketActions = .none
    var writeStatus: String?
    var assignChoices: [RoomTicketAssignChoice] = []
    var viewerId: String?
    var names: [String: String] = [:]
    var comments: [RoomTicketCommentRow]?
    var canComment = false
    var commentStatus: String?
    var canRetryComment = false
    /// Agents can be started from here: the room takes ticket writes and the mint admits this account.
    var canStartAgent = false
    let send: (RoomTicketsIntent) -> Void
    @State private var customAnswer = ""
    @State private var assigning = false
    @State private var editing = false
    @State private var draftComment = ""
    @State private var chatNote = ""

    public init(
        row: RoomTicketRow,
        canAnswer: Bool = false,
        decisionStatus: String? = nil,
        canRetryDecision: Bool = false,
        actions: RoomTicketActions = .none,
        writeStatus: String? = nil,
        assignChoices: [RoomTicketAssignChoice] = [],
        viewerId: String? = nil,
        names: [String: String] = [:],
        comments: [RoomTicketCommentRow]? = nil,
        canComment: Bool = false,
        commentStatus: String? = nil,
        canRetryComment: Bool = false,
        canStartAgent: Bool = false,
        send: @escaping (RoomTicketsIntent) -> Void
    ) {
        self.row = row
        self.canStartAgent = canStartAgent
        self.canAnswer = canAnswer
        self.decisionStatus = decisionStatus
        self.canRetryDecision = canRetryDecision
        self.actions = actions
        self.writeStatus = writeStatus
        self.assignChoices = assignChoices
        self.viewerId = viewerId
        self.names = names
        self.comments = comments
        self.canComment = canComment
        self.commentStatus = commentStatus
        self.canRetryComment = canRetryComment
        self.send = send
    }

    /// Comments, oldest first, then a box to add one (web `TicketComments`). Comments cannot be edited or deleted.
    @ViewBuilder
    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Comments").font(.headline)
            if let comments {
                if comments.isEmpty {
                    Text("No comments yet.").font(.footnote).foregroundStyle(PocketPalette.textSecondary)
                }
                ForEach(comments) { comment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(RoomTicketRow.actorLabel(comment.authorId, viewerId: viewerId, names: names))
                                .font(.caption.weight(.semibold))
                            if let date = comment.date {
                                Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                                    .font(.caption)
                                    .foregroundStyle(PocketPalette.textSecondary)
                            }
                        }
                        ChatMarkdownView(text: comment.body).font(.subheadline)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PocketPalette.textSecondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("pocket.ticket.comment")
                }
            } else {
                ProgressView().accessibilityLabel("Loading comments")
            }
            if canComment {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Add a comment", text: $draftComment, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("pocket.ticket.comment.field")
                    Button("Post") {
                        let text = draftComment.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty, text.count <= 4_000 else { return }
                        send(.comment(ticketId: row.id, body: text))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PocketPalette.accent)
                    .disabled(draftComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftComment.count > 4_000)
                    .accessibilityIdentifier("pocket.ticket.comment.post")
                }
            }
            if let commentStatus {
                HStack(spacing: 12) {
                    Text(commentStatus).font(.footnote.weight(.semibold)).foregroundStyle(PocketPalette.accent)
                    if canRetryComment {
                        Button("Retry") { send(.retryComment(ticketId: row.id)) }
                            .font(.footnote.weight(.semibold))
                            .accessibilityIdentifier("pocket.ticket.comment.retry")
                    }
                }
            }
        }
        .onChange(of: commentStatus) { status in
            // Cleared only once the ticket has it: a failed post keeps what was typed.
            if status == RoomTicketsPresentationState.commentPostedStatus { draftComment = "" }
        }
        .task(id: row.id) { send(.loadComments(ticketId: row.id)) }
    }

    /// The lease, in words that cannot be misread: who holds it and until when, or that it lapsed.
    private var leaseLine: String? {
        guard let lease = row.lease else { return nil }
        let who = RoomTicketRow.actorLabel(lease.holder, viewerId: viewerId, names: names)
        guard lease.isLive else { return "Lease expired · was \(who)" }
        guard let until = lease.expiresAt else { return "Held by \(who)" }
        return "Held by \(who) until \(until.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder
    private var actionsCard: some View {
        if !actions.isEmpty || writeStatus != nil {
            VStack(alignment: .leading, spacing: 10) {
                if !actions.isEmpty {
                    HStack(spacing: 8) {
                        if let claim = actions.claim {
                            Button(claim == .takeOver ? "Take over" : "Claim") { send(.claim(ticketId: row.id)) }
                                .buttonStyle(.borderedProminent)
                                .tint(PocketPalette.accent)
                                .accessibilityIdentifier("pocket.ticket.claim")
                        }
                        if actions.canRelease {
                            Button("Release") { send(.release(ticketId: row.id)) }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("pocket.ticket.release")
                        }
                        if actions.canAssign {
                            Button(row.assignee == nil ? "Assign" : "Reassign") { assigning = true }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("pocket.ticket.assign")
                        }
                        if actions.canEdit {
                            Button("Edit") { editing = true }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("pocket.ticket.edit")
                        }
                    }
                    if canStartAgent {
                        Button {
                            send(.startAgent(ticketId: row.id))
                        } label: {
                            Label("Start an agent on this", systemImage: "cpu")
                        }
                        .buttonStyle(.bordered)
                        .tint(PocketPalette.listening)
                        .accessibilityHint("Starts an agent on its own machine for this ticket, then assigns it")
                        .accessibilityIdentifier("pocket.ticket.startAgent")
                    }
                    if actions.claim == .takeOver {
                        Text("The lease lapsed without a release. Taking over makes the ticket yours.")
                            .font(.caption)
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                }
                if let writeStatus {
                    Text(writeStatus)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.accent)
                        .accessibilityIdentifier("pocket.ticket.writeStatus")
                }
            }
        }
    }

    /// "Chat about it", as on the web: the ticket's card goes to the room with your note, so everyone and every agent
    /// sees it and an agent can pick it up.
    @ViewBuilder
    private var chatCard: some View {
        if canAnswer {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chat about it")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PocketPalette.textPrimary)
                TextField("Add a note (optional)", text: $chatNote, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("pocket.ticket.chatNote")
                Button {
                    send(.chatAboutIt(ticketId: row.id, note: chatNote))
                    chatNote = ""
                } label: {
                    Label("Post to this room", systemImage: "bubble.left.and.text.bubble.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketPalette.accent)
                .accessibilityIdentifier("pocket.ticket.chatAboutIt")
            }
            .padding(12)
            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private var decisionCard: some View {
        if let decision = row.decision {
            VStack(alignment: .leading, spacing: 10) {
                Label("Decision needed", systemImage: "questionmark.bubble")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PocketPalette.warning)
                Text(decision.question).font(.body.weight(.semibold))
                if canAnswer {
                    if !decision.options.isEmpty {
                        FlexibleOptions(options: decision.options) { option in
                            send(.answerDecision(ticketId: row.id, answer: option, detail: ""))
                        }
                    }
                    if decision.allowsCustom {
                        HStack {
                            TextField(decision.options.isEmpty ? "Your answer" : "Something else", text: $customAnswer, axis: .vertical)
                                .lineLimit(1...4)
                                .textFieldStyle(.roundedBorder)
                            Button("Send") {
                                let text = customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { return }
                                if decision.options.isEmpty {
                                    send(.answerDecision(ticketId: row.id, answer: text, detail: ""))
                                } else {
                                    send(.answerDecision(ticketId: row.id, answer: "Custom", detail: text))
                                }
                                // Cleared only once the room has the answer (below): a failed send keeps it.
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(PocketPalette.accent)
                        }
                    }
                    Text(row.assignee.map { "Your answer goes to the room as one line, mentioning @\(RoomTicketRow.displayName($0))." }
                         ?? "Your answer goes to the room as one line.")
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                } else {
                    Text("Answer this from a room you can post in.")
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                if let decisionStatus {
                    HStack(spacing: 12) {
                        Text(decisionStatus).font(.footnote.weight(.semibold)).foregroundStyle(PocketPalette.accent)
                        if canRetryDecision {
                            Button("Retry") { send(.retryDecision(ticketId: row.id)) }
                                .font(.footnote.weight(.semibold))
                                .accessibilityIdentifier("pocket.ticket.decision.retry")
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PocketPalette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: decisionStatus) { status in
                if status == RoomTicketsPresentationState.decisionSentStatus { customAnswer = "" }
            }
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(row.displayTitle)
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let label = row.priorityLabel {
                        Text(label)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoomTicketPalette.priority(row.priority).opacity(0.18), in: Capsule())
                            .foregroundStyle(RoomTicketPalette.priority(row.priority))
                    }
                    Text(row.statusLabel)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoomTicketPalette.status(row.status).opacity(0.15), in: Capsule())
                        .foregroundStyle(RoomTicketPalette.status(row.status))
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let assignee = row.assignee {
                        Label("Assigned to \(RoomTicketRow.actorLabel(assignee, viewerId: viewerId, names: names))", systemImage: "person")
                    }
                    if let leaseLine {
                        Label(leaseLine, systemImage: row.lease?.isLive == true ? "lock" : "lock.open")
                            .accessibilityIdentifier("pocket.ticket.lease")
                    }
                    if !row.createdBy.isEmpty {
                        Label("Requested by \(RoomTicketRow.displayName(row.createdBy))", systemImage: "person.wave.2")
                    }
                    if let created = row.createdDate {
                        Label {
                            Text("Filed ") + Text(created, format: .relative(presentation: .named, unitsStyle: .wide))
                        } icon: {
                            Image(systemName: "clock")
                        }
                    }
                }
                .font(.footnote)
                .foregroundStyle(PocketPalette.textSecondary)

                actionsCard

                decisionCard

                chatCard

                if let sequence = row.sourceSequenceId {
                    Button {
                        send(.openSourceMessage(sequenceId: sequence))
                    } label: {
                        Label("From message #\(sequence)", systemImage: "text.bubble")
                            .font(.footnote.weight(.semibold))
                    }
                }

                Divider()
                ChatMarkdownView(text: row.body.isEmpty ? "_No description._" : row.displayBody)
                    .font(.body)
                Divider()
                commentsSection
                Text("Ticket \(row.id)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(PocketPalette.textSecondary)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(row.priorityLabel ?? "Ticket")
        .sheet(isPresented: $assigning) {
            RoomTicketAssignSheet(row: row, choices: assignChoices, viewerId: viewerId) { assignee in
                send(.assign(ticketId: row.id, assignee: assignee))
            }
        }
        .sheet(isPresented: $editing) {
            RoomTicketEditSheet(row: row) { title, body in
                send(.edit(ticketId: row.id, title: title, body: body))
            }
        }
        .accessibilityIdentifier("pocket.tickets.detail")
    }
}

/// Decision options as wrapping buttons.
private struct FlexibleOptions: View {
    let options: [String]
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button {
                    choose(option)
                } label: {
                    Text(option)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("pocket.tickets.decision.option")
            }
        }
    }
}

enum RoomTicketPalette {
    static func priority(_ priority: Int?) -> Color {
        switch priority {
        case 0: return PocketPalette.danger
        case 1: return PocketPalette.warning
        case 2: return PocketPalette.accent
        default: return PocketPalette.textSecondary
        }
    }

    static func status(_ status: String) -> Color {
        switch status {
        case "done": return PocketPalette.textSecondary
        case "blocked": return PocketPalette.danger
        case "in_review": return PocketPalette.recommendation
        case "working", "accepted": return PocketPalette.listening
        default: return PocketPalette.accent
        }
    }
}
#endif
