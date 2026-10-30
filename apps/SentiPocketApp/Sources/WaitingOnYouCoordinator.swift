import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI

/// What waits on your decision across your rooms (ticket 931e1d2e): read from the server's one list, so the phone and
/// the web agree on what is waiting and how much; answered with the same chat line the web posts, so an answer here
/// clears it there too (Carter, 10-30: "if someone calls me or I call or I message and I take care of it, it disappears
/// from that list"). An answer leaves the list at once and stays gone until the server agrees or brings it back.
@MainActor
final class WaitingOnYouCoordinator: ObservableObject {
    @Published private(set) var state = WaitingOnYouState()

    private let transport: any WaitingTransport
    private let sender: any RoomMessageSending
    private let onReauthenticationRequired: @MainActor () -> Void
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let now: @Sendable () -> Date

    private var items: [SentiWaitingItem] = []
    private var total = 0
    /// Asks answered here that the server may not have caught up with, by ask (a ticket can ask again).
    private var answered: Set<String> = []
    /// Each answer keeps the id it was first sent with, so a retry after a timed-out send never posts twice.
    private var pending: [String: (line: String, clientId: String)] = [:]
    private var pollTask: Task<Void, Never>?

    static let pollInterval: TimeInterval = 60

    init(
        transport: any WaitingTransport,
        sender: any RoomMessageSending,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        now: @escaping @Sendable () -> Date = { Date() },
        onReauthenticationRequired: @escaping @MainActor () -> Void = {}
    ) {
        self.transport = transport
        self.sender = sender
        self.sleep = sleep
        self.now = now
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                await self.sleep(Self.pollInterval)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        if items.isEmpty { state.isLoading = true }
        do {
            let page = try await transport.waiting(limit: 50)
            // The signal model's name never shows, here or in the answer posted (warden, #270).
            items = page.items.map { $0.redacted(TicketSignal.hideModelName) }
            total = page.total
            // The server's word wins once it no longer lists an answered ask.
            answered = answered.filter { key in items.contains { $0.askKey == key } }
            state.isAvailable = true
            state.notice = nil
        } catch SessionTransportError.accessDenied {
            // An older server without the list answers 404, which the shared fetch reads as access denied; so does a
            // server that will not show it to this sign-in. Either way the side panel leaves it out.
            state.isAvailable = false
        } catch SessionTransportError.service(let status) where status == 404 || status == 405 {
            state.isAvailable = false
        } catch SessionTransportError.reauthenticationRequired {
            onReauthenticationRequired()
        } catch SessionTransportError.cancelled {
        } catch {
            if state.isAvailable { state.notice = "Could not update. Pull to try again." }
        }
        state.isLoading = false
        publish()
    }

    func send(_ intent: WaitingOnYouIntent) -> SentiLink? {
        switch intent {
        case .refresh:
            Task { await refresh() }
        case .open(let id):
            guard let item = items.first(where: { $0.ticketId == id }) else { return nil }
            return SentiLink(sessionId: item.roomId, ticketId: item.ticketId)
        case .answer(let id, let choice, let detail):
            answer(id, choice: choice, detail: detail)
        }
        return nil
    }

    private func answer(_ id: String, choice: String, detail: String) {
        guard let item = items.first(where: { $0.ticketId == id && !answered.contains($0.askKey) }),
              !state.sending.contains(id),
              !choice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let key = item.askKey
        let line = item.answerLine(choice, detail: detail)
        // The same answer again (a retry) keeps its id; a different answer is a new message.
        let clientId = pending[key].flatMap { $0.line == line ? $0.clientId : nil } ?? "hm_" + UUID().uuidString.lowercased()
        pending[key] = (line, clientId)
        state.sending.insert(id)
        state.notice = nil
        publish()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sender.sendHumanMessage(sessionId: item.roomId, text: line, clientId: clientId)
                self.pending[key] = nil
                self.answered.insert(key)
            } catch RoomSendError.reauthenticationRequired {
                self.onReauthenticationRequired()
            } catch RoomSendError.notAllowed {
                // Said plainly, with no retry to offer (warden, #270).
                self.pending[key] = nil
                self.state.notice = "You can't post in that room any more, so your answer to \"\(item.title)\" was not sent."
            } catch RoomSendError.rejected {
                self.pending[key] = nil
                self.state.notice = "Senti did not accept your answer to \"\(item.title)\". Open the ticket to answer there."
            } catch {
                self.state.notice = "Your answer to \"\(item.title)\" did not go. Tap it again to retry."
            }
            self.state.sending.remove(id)
            self.publish()
        }
    }

    private func publish() {
        let shown = items.filter { !answered.contains($0.askKey) }
        state.rows = shown.map { item in
            WaitingOnYouRow(
                id: item.ticketId,
                roomId: item.roomId,
                roomTitle: item.roomTitle,
                title: item.title.isEmpty ? "(untitled)" : item.title,
                question: item.question,
                options: item.options,
                custom: item.custom,
                askedAt: ParsedSessionTimestamp(item.askedAt).date,
                askedBy: item.askedBy.flatMap { UUID(uuidString: $0) == nil ? $0 : nil }
            )
        }
        state.total = max(0, total - (items.count - shown.count))
    }
}
