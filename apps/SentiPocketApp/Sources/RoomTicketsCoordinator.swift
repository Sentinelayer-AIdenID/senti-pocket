import Foundation
import SwiftUI
import PocketContracts
import PocketSyncClient
import PocketUI

/// The room's ticket board on the phone: the snapshot, then the event feed every 30 seconds while the Tickets tab is
/// on screen (web parity: one board per room, upserted by version, atomic catch-ups). A failed poll keeps the last
/// committed board and marks it stale; access and sign-in failures stop the board.
@MainActor
final class RoomTicketsCoordinator: ObservableObject {
    @Published private(set) var state = RoomTicketsPresentationState(tickets: [], isLoading: true)

    private let sessionId: String
    private let transport: any RoomTicketsTransport
    private let sender: (any RoomMessageSending)?
    private let focusTicketId: String?
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let onReauthenticationRequired: @MainActor () -> Void

    private var board: RoomTicketBoard?
    private var showsArchived = false
    private var query = ""
    private var isLoading = false
    private var isStale = false
    private var failure: SessionLoadFailure?
    private var pollTask: Task<Void, Never>?
    private var decisionStatus: [String: String] = [:]
    private var answering: Set<String> = []
    /// The answer being sent or last tried per ticket, until the room has it. Its client id is minted once per answer
    /// to one ticket version: Retry, or the same answer again to that version, sends the same message, which the API
    /// de-duplicates (on your user and the client id, with no time window), so an attempt that did land is never
    /// posted twice. An answer that lands is forgotten, so the same words to a later step post again.
    private var lastAnswer: [String: (text: String, clientId: String, version: Int64)] = [:]
    private var retryableDecisions: Set<String> = []

    // Ticket writes (web parity: file, claim or take over, release, assign, edit).
    private let writer: (any RoomTicketWriting)?
    private let leases: any TicketLeaseStoring
    private let identity: (any AccountIdentityProviding)?
    private let canWriteTickets: Bool
    private let assignRoster: [String]
    private let extras: (any RoomTicketExtrasReading)?
    private let now: @Sendable () -> Date
    /// The room's people (member directory): who Assign offers and how tickets name them. Read once per screen.
    private var people: [RoomDirectoryMember] = []
    private var readDirectory = false
    /// Per ticket: comments oldest first, and the cursor to read on from.
    private var comments: [String: [RoomTicketComment]] = [:]
    private var commentCursor: [String: Int64] = [:]
    private var loadingComments: Set<String> = []
    private var commentStatus: [String: String] = [:]
    private var retryableComments: Set<String> = []
    private var postingComments: Set<String> = []
    /// The comment being posted or last tried per ticket, with its key: Retry, or the same words again, reuses the key,
    /// so a comment that did land is replayed by the API, never posted twice.
    private var pendingComment: [String: (body: String, key: String)] = [:]
    /// The latest comment post: awaited by tests.
    private(set) var lastComment: Task<Void, Never>?
    private var account: SignedInAccount?
    private var heldLeases: Set<String> = []
    private var ticketWriteStatus: [String: String] = [:]
    private var writing: Set<String> = []
    /// The latest write, through its refresh: awaited by tests.
    private(set) var lastWrite: Task<Void, Never>?
    /// The ticket being filed until the room has it. Filing the same fields again reuses its key, so an attempt that
    /// did land is replayed by the API, never filed twice.
    private var pendingFile: (fields: TicketFields, key: String)?
    /// The write status of a ticket being filed (no ticket id yet).
    static let fileStatusKey = RoomTicketsPresentationState.fileStatusKey
    private var filedCount = 0

    struct TicketFields: Equatable {
        let title: String
        let body: String
        let assignee: String?
    }

    static let pollInterval: TimeInterval = 30

    init(
        sessionId: String,
        transport: any RoomTicketsTransport,
        sender: (any RoomMessageSending)? = nil,
        writer: (any RoomTicketWriting)? = nil,
        leases: any TicketLeaseStoring = InMemoryTicketLeaseStore(),
        identity: (any AccountIdentityProviding)? = nil,
        canWriteTickets: Bool = false,
        assignRoster: [String] = [],
        extras: (any RoomTicketExtrasReading)? = nil,
        focusTicketId: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        self.sessionId = sessionId
        self.transport = transport
        self.sender = sender
        self.writer = writer
        self.leases = leases
        self.identity = identity
        self.canWriteTickets = canWriteTickets && writer != nil
        self.assignRoster = assignRoster
        self.extras = extras
        self.focusTicketId = focusTicketId
        self.now = now
        self.sleep = sleep
        self.onReauthenticationRequired = onReauthenticationRequired
        self.heldLeases = leases.ticketIds(sessionId: sessionId)
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                await self.sleep(Self.pollInterval)
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func send(_ intent: RoomTicketsIntent) {
        switch intent {
        case .setShowsArchived(let archived):
            showsArchived = archived
            publish()
        case .search(let text):
            query = text
            publish()
        case .refresh:
            Task { await refresh() }
        case .openSourceMessage:
            break   // the room screen handles jumping to a message
        case .answerDecision(let ticketId, let answer, let detail):
            answerDecision(ticketId: ticketId, answer: answer, detail: detail)
        case .retryDecision(let ticketId):
            guard retryableDecisions.contains(ticketId) else { return }
            deliverAnswer(ticketId)
        case .fileTicket(let title, let body, let assignee):
            fileTicket(TicketFields(title: title, body: body, assignee: assignee))
        case .claim(let ticketId):
            guard let ticket = board?.tickets[ticketId] else { return }
            perform(.claim(ticketId: ticketId, expectedVersion: ticket.version), progress: "Claiming…")
        case .release(let ticketId):
            guard let ticket = board?.tickets[ticketId],
                  let credential = leases.credential(sessionId: sessionId, ticketId: ticketId) else { return }
            perform(.release(ticketId: ticketId, lease: credential, expectedVersion: ticket.version), progress: "Releasing…")
        case .assign(let ticketId, let assignee):
            guard let ticket = board?.tickets[ticketId] else { return }
            let target = assignee?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            perform(.assign(ticketId: ticketId, assignee: target, expectedVersion: ticket.version),
                    progress: target.isEmpty ? "Unassigning…" : "Assigning…")
        case .edit(let ticketId, let title, let body):
            guard let ticket = board?.tickets[ticketId] else { return }
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            // The changed fields only, as the web sends them: an untouched field is never written back stale.
            let newTitle = cleanTitle == ticket.title ? nil : cleanTitle
            let newBody = body == ticket.body ? nil : body
            guard newTitle != nil || newBody != nil else { return }
            perform(.edit(ticketId: ticketId, title: newTitle, body: newBody, expectedVersion: ticket.version),
                    progress: "Saving…")
        case .loadComments(let ticketId):
            Task { await loadComments(ticketId) }
        case .comment(let ticketId, let body):
            let key = pendingComment[ticketId].flatMap { $0.body == body ? $0.key : nil } ?? Self.newKey()
            pendingComment[ticketId] = (body, key)
            postComment(ticketId)
        case .retryComment(let ticketId):
            guard retryableComments.contains(ticketId) else { return }
            postComment(ticketId)
        }
    }

    // MARK: - Comments

    /// Reads the ticket's comments on from the last cursor (all of them the first time), oldest first.
    func loadComments(_ ticketId: String) async {
        guard let extras, !loadingComments.contains(ticketId) else { return }
        loadingComments.insert(ticketId)
        defer { loadingComments.remove(ticketId) }
        var cursor = commentCursor[ticketId] ?? 0
        var loaded = comments[ticketId] ?? []
        do {
            for _ in 0..<5 {
                let page = try await extras.comments(sessionId: sessionId, ticketId: ticketId, after: cursor)
                for comment in page.comments where !loaded.contains(where: { $0.id == comment.id }) {
                    loaded.append(comment)
                }
                guard page.cursor > cursor else { break }
                cursor = page.cursor
                if !page.hasMore { break }
            }
        } catch RoomTicketExtrasError.reauthenticationRequired {
            onReauthenticationRequired()
        } catch {
            if comments[ticketId] == nil { commentStatus[ticketId] = "Comments could not load. Open the ticket again to retry." }
        }
        comments[ticketId] = loaded.sorted { $0.cursor < $1.cursor }
        commentCursor[ticketId] = cursor
        publish()
    }

    private func postComment(_ ticketId: String) {
        guard canWriteTickets, let writer, let pending = pendingComment[ticketId], !postingComments.contains(ticketId) else {
            return
        }
        postingComments.insert(ticketId)
        retryableComments.remove(ticketId)
        commentStatus[ticketId] = "Posting…"
        publish()
        let sessionId = self.sessionId
        lastComment = Task { [weak self] in
            var status = RoomTicketsPresentationState.commentPostedStatus
            var canRetry = false
            var landed: RoomTicketWriteResult?
            do {
                landed = try await writer.write(.comment(ticketId: ticketId, body: pending.body), sessionId: sessionId,
                                                idempotencyKey: pending.key)
            } catch let error as RoomTicketWriteError {
                if case .reauthenticationRequired = error { self?.onReauthenticationRequired() }
                status = error.userMessage
                if case .retryable = error { canRetry = true }
            } catch {
                status = RoomTicketWriteError.retryable(retryAfterSeconds: nil).userMessage
                canRetry = true
            }
            guard let self else { return }
            self.postingComments.remove(ticketId)
            self.commentStatus[ticketId] = status
            if canRetry { self.retryableComments.insert(ticketId) }
            if let landed {
                self.pendingComment[ticketId] = nil
                if let ticket = landed.ticket { self.board?.upsert(ticket) }
                if let comment = landed.comment {
                    var list = self.comments[ticketId] ?? []
                    if !list.contains(where: { $0.id == comment.id }) { list.append(comment) }
                    self.comments[ticketId] = list.sorted { $0.cursor < $1.cursor }
                }
            }
            self.publish()
        }
    }

    // MARK: - People

    /// The member directory, read once: three restarts when membership changes mid-read (web #682), then nothing on
    /// any failure. Without it, Assign offers you and the room's agents only.
    private func loadPeople() async {
        guard let extras, !readDirectory else { return }
        readDirectory = true
        for _ in 0..<4 {
            var members: [RoomDirectoryMember] = []
            var cursor: String?
            do {
                for _ in 0..<10 {
                    let page = try await extras.memberDirectory(sessionId: sessionId, cursor: cursor)
                    members += page.members
                    guard page.hasMore, let next = page.nextCursor else { break }
                    cursor = next
                }
                people = members
                return
            } catch RoomTicketExtrasError.directoryChanged {
                continue
            } catch {
                return
            }
        }
    }

    // MARK: - Ticket writes

    private func fileTicket(_ fields: TicketFields) {
        guard canWriteTickets, !writing.contains(Self.fileStatusKey) else { return }
        let key = pendingFile.flatMap { $0.fields == fields ? $0.key : nil } ?? Self.newKey()
        pendingFile = (fields, key)
        let write = RoomTicketWrite.file(
            title: fields.title,
            body: fields.body.isEmpty ? nil : fields.body,
            assignee: fields.assignee
        )
        perform(write, progress: "Filing…", key: key)
    }

    /// One write at a time per ticket. The result's ticket goes on the board at once, then the feed is read straight
    /// away rather than at the next 30-second poll. A conflict refreshes the board and says so; nothing is retried
    /// blindly, because the ticket the person decided on is no longer the one on the server.
    private func perform(_ write: RoomTicketWrite, progress: String, key: String? = nil) {
        guard canWriteTickets, let writer else { return }
        let key = key ?? Self.newKey()
        let statusKey = write.ticketId ?? Self.fileStatusKey
        guard !writing.contains(statusKey) else { return }
        writing.insert(statusKey)
        ticketWriteStatus[statusKey] = progress
        publish()
        let sessionId = self.sessionId
        lastWrite = Task { [weak self] in
            var outcome: Result<RoomTicketWriteResult, RoomTicketWriteError>
            do {
                outcome = .success(try await writer.write(write, sessionId: sessionId, idempotencyKey: key))
            } catch let error as RoomTicketWriteError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.retryable(retryAfterSeconds: nil))
            }
            guard let self else { return }
            self.writing.remove(statusKey)
            switch outcome {
            case .success(let result):
                await self.landed(write, result: result, statusKey: statusKey)
            case .failure(let error):
                await self.failed(write, error: error, statusKey: statusKey)
            }
        }
    }

    private func landed(_ write: RoomTicketWrite, result: RoomTicketWriteResult, statusKey: String) async {
        if let ticket = result.ticket { board?.upsert(ticket) }
        switch write {
        case .file:
            pendingFile = nil
            filedCount += 1
            ticketWriteStatus[statusKey] = result.replayed ? "Already filed." : "Filed."
        case .claim(let ticketId, _):
            if let lease = result.lease {
                leases.save(lease, sessionId: sessionId, ticketId: ticketId)
                heldLeases.insert(ticketId)
            }
            ticketWriteStatus[statusKey] = "Claimed. It's yours while the lease lasts."
        case .release(let ticketId, _, _):
            dropLease(ticketId)
            ticketWriteStatus[statusKey] = "Released."
        case .assign(let ticketId, let assignee, _):
            ticketWriteStatus[statusKey] = assignee.isEmpty ? "Unassigned." : "Assigned."
            publish()
            if !result.replayed, let ticket = board?.tickets[ticketId] { await postAssignmentLine(ticket, assignee: assignee) }
        case .edit:
            ticketWriteStatus[statusKey] = "Saved."
        case .comment:
            break   // comments post through postComment, with their own status
        }
        publish()
        await refresh()
    }

    private func failed(_ write: RoomTicketWrite, error: RoomTicketWriteError, statusKey: String) async {
        if case .reauthenticationRequired = error { onReauthenticationRequired() }
        if case .file = write {
            // A refusal of these fields will not change by sending them again: the next attempt starts over.
            if case .rejected = error { pendingFile = nil }
        }
        if case .conflict(let code) = error, code == "STALE_LEASE", let ticketId = write.ticketId {
            dropLease(ticketId)
        }
        ticketWriteStatus[statusKey] = error.userMessage
        publish()
        switch error {
        case .conflict, .notFound:
            // The ticket the person decided on is not the one on the server: show them the current one.
            await refresh()
        default:
            break
        }
    }

    private func dropLease(_ ticketId: String) {
        leases.remove(sessionId: sessionId, ticketId: ticketId)
        heldLeases.remove(ticketId)
    }

    /// Everyone sees an assignment in the chat, and an @-mention wakes an agent assignee (web `assignmentChatLine`).
    /// The assignment stands even when the line cannot be posted; the ticket says so.
    private func postAssignmentLine(_ ticket: RoomTicket, assignee: String) async {
        guard let sender else { return }
        let me = account
        let line = TicketDecision.assignmentLine(
            sessionId: sessionId,
            ticketId: ticket.id,
            title: ticket.title,
            assignee: assignee,
            personLabel: { id in
                if let me, id.lowercased() == me.accountId { return me.login ?? "Signed-in viewer" }
                return "Signed-in viewer"
            }
        )
        let clientId = "hm_" + UUID().uuidString.lowercased()
        do {
            try await sender.sendHumanMessage(sessionId: sessionId, text: line, clientId: clientId)
        } catch {
            ticketWriteStatus[ticket.id] = "Assignment saved; the chat line did not post."
        }
    }

    /// Credentials whose lease is gone: past its expiry (there is no renew, as on the web, so a lapsed lease is never
    /// released and never shown as held after a relaunch), taken over (another fence), or given back (a later version
    /// with no lease). A ticket the board does not hold yet keeps an unexpired credential.
    private func forgetEndedLeases() {
        let instant = now()
        for ticketId in heldLeases {
            guard let credential = leases.credential(sessionId: sessionId, ticketId: ticketId) else {
                heldLeases.remove(ticketId)
                continue
            }
            if let expiry = credential.expiresAt.flatMap({ ParsedSessionTimestamp($0).date }), expiry <= instant {
                dropLease(ticketId)
                continue
            }
            guard let ticket = board?.tickets[ticketId] else { continue }
            if let lease = ticket.lease {
                if lease.fence != credential.fence { dropLease(ticketId) }
            } else if ticket.version > credential.claimedVersion || ticket.isArchived {
                dropLease(ticketId)
            }
        }
    }

    private static func newKey() -> String { "tk_" + UUID().uuidString.lowercased() }

    /// Posts the web's decision line to the room as you: one message that @-mentions the ticket's assignee.
    private func answerDecision(ticketId: String, answer: String, detail: String) {
        guard sender != nil, let ticket = board?.tickets[ticketId], !answering.contains(ticketId) else { return }
        let text = TicketDecision.chatLine(
            sessionId: sessionId,
            ticketId: ticket.id,
            title: ticket.title,
            answer: answer,
            detail: detail,
            assignee: ticket.assignee,
            personLabel: { _ in "the assignee" }
        )
        let clientId = lastAnswer[ticketId].flatMap { $0.text == text && $0.version == ticket.version ? $0.clientId : nil }
            ?? "hm_" + UUID().uuidString.lowercased()
        lastAnswer[ticketId] = (text, clientId, ticket.version)
        deliverAnswer(ticketId)
    }

    /// Sends (or sends again, as the same message) the ticket's last answer.
    private func deliverAnswer(_ ticketId: String) {
        guard let sender, let answer = lastAnswer[ticketId], !answering.contains(ticketId) else { return }
        answering.insert(ticketId)
        retryableDecisions.remove(ticketId)
        decisionStatus[ticketId] = "Sending your answer…"
        publish()
        let sessionId = self.sessionId
        Task { [weak self] in
            var status = RoomTicketsPresentationState.decisionSentStatus
            var canRetry = false
            var landed = false
            do {
                try await sender.sendHumanMessage(sessionId: sessionId, text: answer.text, clientId: answer.clientId)
                landed = true
            } catch let error as RoomSendError {
                if case .reauthenticationRequired = error { self?.onReauthenticationRequired() }
                status = error.userMessage
                switch error {
                case .retryable, .reauthenticationRequired: canRetry = true
                case .notConfigured, .notAllowed, .rejected: canRetry = false
                }
            } catch {
                status = RoomSendError.retryable(retryAfterSeconds: nil).userMessage
                canRetry = true
            }
            guard let self else { return }
            self.answering.remove(ticketId)
            self.decisionStatus[ticketId] = status
            if canRetry { self.retryableDecisions.insert(ticketId) }
            if landed { self.lastAnswer[ticketId] = nil }
            self.publish()
        }
    }

    /// First call loads the baseline; later calls catch up from the committed cursor.
    func refresh() async {
        guard failure != .accessDenied, failure != .reauthenticationRequired else { return }
        if canWriteTickets, account == nil, let identity {
            account = await identity.currentAccount()
        }
        await loadPeople()
        let sessionId = self.sessionId
        let transport = self.transport
        if board == nil {
            isLoading = true
            publish()
        }
        do {
            if let current = board {
                let (next, changed) = try await current.caughtUp { after in
                    try await transport.roomTicketEvents(sessionId: sessionId, after: after, limit: 500)
                }
                board = next
                isStale = false
                _ = changed
            } else {
                board = try await RoomTicketBoard.loadBaseline { afterId in
                    try await transport.roomTicketSnapshot(sessionId: sessionId, afterId: afterId, limit: 200)
                }
                isStale = false
            }
            failure = nil
        } catch let error as SessionTransportError {
            switch error {
            case .reauthenticationRequired, .notLoggedIn:
                failure = .reauthenticationRequired
                onReauthenticationRequired()
                stop()
            case .accessDenied:
                failure = .accessDenied
                stop()
            case .cancelled:
                break
            default:
                if board == nil { failure = error == .invalidData ? .invalidData : .network } else { isStale = true }
            }
        } catch {
            if board == nil { failure = .network } else { isStale = true }
        }
        isLoading = false
        publish()
    }

    private func publish() {
        forgetEndedLeases()
        let tickets = (board?.tickets.values).map(Array.init) ?? []
        let instant = now()
        state = RoomTicketsPresentationState(
            tickets: tickets.map { ticket in
                RoomTicketInput(
                    id: ticket.id,
                    title: ticket.title,
                    body: ticket.body,
                    status: ticket.status,
                    createdBy: ticket.createdBy,
                    assignee: ticket.assignee,
                    createdAt: ticket.createdAt,
                    updatedAt: ticket.updatedAt,
                    priority: ticket.priority,
                    sourceSequenceId: ticket.sourceSequenceId,
                    isVerifiedDone: ticket.isVerifiedDone,
                    lease: ticket.lease.map { lease in
                        RoomTicketInput.Lease(
                            holder: lease.holder,
                            isLive: lease.isLive(at: instant),
                            expiresAt: lease.expiresAt.flatMap { ParsedSessionTimestamp($0).date }
                        )
                    }
                )
            },
            showsArchived: showsArchived,
            query: query,
            isLoading: isLoading,
            isStale: isStale,
            failure: failure,
            canAnswerDecisions: sender != nil,
            decisionStatus: decisionStatus,
            retryableDecisions: retryableDecisions,
            focusTicketId: focusTicketId,
            viewerId: account?.accountId,
            canWriteTickets: canWriteTickets && account?.accountId != nil,
            heldLeases: heldLeases,
            ticketWriteStatus: ticketWriteStatus,
            filedCount: filedCount,
            viewerLogin: account?.login,
            rosterAgentIds: assignRoster,
            people: people.map { RoomTicketAssignChoice(id: $0.userId, label: $0.label) },
            personNames: Dictionary(people.map { ($0.userId, $0.name) }, uniquingKeysWith: { first, _ in first }),
            comments: comments.mapValues { list in
                list.map { RoomTicketCommentRow(id: $0.id, authorId: $0.actorId, body: $0.body, createdAt: $0.createdAt) }
            },
            commentStatus: commentStatus,
            retryableComments: retryableComments
        )
    }
}

/// Hosts the Tickets tab for one room; the board polls only while this screen is visible.
struct RoomTicketsScreen: View {
    @StateObject private var coordinator: RoomTicketsCoordinator
    private let onOpenMessage: (@MainActor (Int64) -> Void)?
    private let startsFiling: Bool

    init(
        sessionId: String,
        transport: any RoomTicketsTransport,
        sender: (any RoomMessageSending)? = nil,
        writer: (any RoomTicketWriting)? = nil,
        leases: any TicketLeaseStoring = InMemoryTicketLeaseStore(),
        identity: (any AccountIdentityProviding)? = nil,
        assignRoster: [String] = [],
        extras: (any RoomTicketExtrasReading)? = nil,
        startsFiling: Bool = false,
        onOpenMessage: (@MainActor (Int64) -> Void)? = nil,
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        self.onOpenMessage = onOpenMessage
        self.startsFiling = startsFiling && writer != nil
        _coordinator = StateObject(wrappedValue: RoomTicketsCoordinator(
            sessionId: sessionId,
            transport: transport,
            sender: sender,
            writer: writer,
            leases: leases,
            identity: identity,
            canWriteTickets: writer != nil,
            assignRoster: assignRoster,
            extras: extras,
            onReauthenticationRequired: onReauthenticationRequired
        ))
    }

    var body: some View {
        RoomTicketsView(state: coordinator.state, startsFiling: startsFiling) { intent in
            if case .openSourceMessage(let sequence) = intent, let onOpenMessage {
                onOpenMessage(sequence)
            } else {
                coordinator.send(intent)
            }
        }
        .onAppear { coordinator.start() }
        .onDisappear { coordinator.stop() }
    }
}

/// One ticket opened from a link, over the room (the web's `?ticket=` drawer). It loads the room's board and shows that
/// ticket wherever its status or the list's filters would put it; the board polls while the sheet is open.
struct RoomTicketLinkScreen: View {
    @StateObject private var coordinator: RoomTicketsCoordinator
    @Environment(\.dismiss) private var dismiss
    private let onOpenMessage: @MainActor (Int64) -> Void

    init(
        sessionId: String,
        ticketId: String,
        transport: any RoomTicketsTransport,
        sender: (any RoomMessageSending)? = nil,
        writer: (any RoomTicketWriting)? = nil,
        leases: any TicketLeaseStoring = InMemoryTicketLeaseStore(),
        identity: (any AccountIdentityProviding)? = nil,
        assignRoster: [String] = [],
        extras: (any RoomTicketExtrasReading)? = nil,
        onOpenMessage: @escaping @MainActor (Int64) -> Void,
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        self.onOpenMessage = onOpenMessage
        _coordinator = StateObject(wrappedValue: RoomTicketsCoordinator(
            sessionId: sessionId,
            transport: transport,
            sender: sender,
            writer: writer,
            leases: leases,
            identity: identity,
            canWriteTickets: writer != nil,
            assignRoster: assignRoster,
            extras: extras,
            focusTicketId: ticketId,
            onReauthenticationRequired: onReauthenticationRequired
        ))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("pocket.tickets.link.done")
                    }
                }
        }
        .onAppear { coordinator.start() }
        .onDisappear { coordinator.stop() }
    }

    @ViewBuilder
    private var content: some View {
        let state = coordinator.state
        if let row = state.focusedTicket {
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
                canRetryComment: state.retryableComments.contains(row.id)
            ) { intent in
                if case .openSourceMessage(let sequence) = intent {
                    onOpenMessage(sequence)
                } else {
                    coordinator.send(intent)
                }
            }
        } else if let failure = state.failure {
            unavailable(failure.title, detail: failure.detail)
        } else if state.isLoading {
            ProgressView("Loading the ticket…")
                .navigationTitle("Ticket")
        } else {
            unavailable("Ticket not found", detail: "This ticket is not in this room, or you cannot see it.")
        }
    }

    private func unavailable(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .navigationTitle("Ticket")
    }
}
