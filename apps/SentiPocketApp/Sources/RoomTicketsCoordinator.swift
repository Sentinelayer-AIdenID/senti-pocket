import Foundation
import SwiftUI
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

    static let pollInterval: TimeInterval = 30

    init(
        sessionId: String,
        transport: any RoomTicketsTransport,
        sender: (any RoomMessageSending)? = nil,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        self.sessionId = sessionId
        self.transport = transport
        self.sender = sender
        self.sleep = sleep
        self.onReauthenticationRequired = onReauthenticationRequired
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
        }
    }

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
            var status = "Answer sent to the room."
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
        let tickets = (board?.tickets.values).map(Array.init) ?? []
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
                    isVerifiedDone: ticket.isVerifiedDone
                )
            },
            showsArchived: showsArchived,
            query: query,
            isLoading: isLoading,
            isStale: isStale,
            failure: failure,
            canAnswerDecisions: sender != nil,
            decisionStatus: decisionStatus,
            retryableDecisions: retryableDecisions
        )
    }
}

/// Hosts the Tickets tab for one room; the board polls only while this screen is visible.
struct RoomTicketsScreen: View {
    @StateObject private var coordinator: RoomTicketsCoordinator

    init(
        sessionId: String,
        transport: any RoomTicketsTransport,
        sender: (any RoomMessageSending)? = nil,
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        _coordinator = StateObject(wrappedValue: RoomTicketsCoordinator(
            sessionId: sessionId,
            transport: transport,
            sender: sender,
            onReauthenticationRequired: onReauthenticationRequired
        ))
    }

    var body: some View {
        RoomTicketsView(state: coordinator.state) { coordinator.send($0) }
            .onAppear { coordinator.start() }
            .onDisappear { coordinator.stop() }
    }
}
