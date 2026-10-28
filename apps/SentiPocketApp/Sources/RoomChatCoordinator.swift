import Foundation
import PocketSyncClient
import PocketUI
import PocketContracts

/// Owns one open room: the initial load, the live stream with reconnect and catch-up, the safety poll, older
/// history and unread tracking. Web parity (sentinelayer-web `useSessionLiveController.ts`): seed from the tail,
/// stream from the highest applied sequence, poll every 60s while the stream is up (15s while it is down), and
/// catch up on resume.
@MainActor
final class RoomChatCoordinator: ObservableObject {
    @Published private(set) var state: RoomChatPresentationState

    let sessionId: String
    private let title: String
    private let transport: any RoomTransport
    private let sender: (any RoomMessageSending)?
    private let identity: (any AccountIdentityProviding)?
    private var ownAuthorIds: Set<String>
    private var postingRefusedReason: String?
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let now: @Sendable () -> Date
    private let onReauthenticationRequired: @MainActor () -> Void

    /// A message you sent that the room has not shown yet. Keyed by its client id, which the API echoes back as
    /// `payload.clientMessageId` and uses to de-duplicate retries.
    private struct PendingSend {
        let clientId: String
        let text: String
        var status: RoomChatPendingRow.Status
        var sentAt: Date?
    }
    private var pending: [PendingSend] = []
    private var identityRequested = false

    // Replies and reactions (GET /actions projection), and the open thread.
    private let actionSender: (any RoomActionSending)?
    private var summaries: [Int64: RoomReactionSummary] = [:]
    private var lastActionsRefresh: Date?
    private var actionsRefreshInFlight = false
    private var openThreadSequence: Int64?
    private var threadReplies: [RoomReply] = []
    private var threadLoading = false
    private var threadFailure: String?
    /// A reply you sent that its thread has not shown yet. Kept per thread, so closing the sheet keeps it. Its nonce
    /// is minted once: a retry is the same request, which the API de-duplicates on its key.
    private struct PendingReply {
        let nonce: String
        let targetSequenceId: Int64
        let text: String
        var status: RoomChatPendingRow.Status
        /// You in its key, pinned at the first attempt, so a retry is byte-for-byte the same request.
        var actor: String?
        var clientId: String { "rp_" + nonce }
    }
    private var pendingReplies: [PendingReply] = []
    /// You in action keys, from your account (see `SignedInAccount.actorRef`).
    private var actorRef: String?
    /// A message to bring into view once (opened from a notification or link); cleared when the view shows it.
    private var focusTarget: Int64?
    /// Arrivals refresh reactions at most this often (the web polls about every 15s).
    static let actionsRefreshInterval: TimeInterval = 10
    static let viewerReason = "You're a viewer in this room: you can read it, but not post."
    /// How long an accepted message waits for its echo before the pending row is dropped (the next poll still
    /// brings it in).
    static let sentEchoGrace: TimeInterval = 20

    private var timeline = RoomTimeline()
    private var unread = RoomUnreadState()
    private var readerAtBottom = true
    private var lastAppliedSequence: Int64 = 0
    private var nextBeforeSequence: Int64?
    private var connection: RoomConnectionState = .connecting
    private var composing: [String: Date] = [:]
    private var failure: SessionLoadFailure?
    private var isLoadingInitial = false
    private var isLoadingOlder = false
    private var hasLoadedInitial = false
    private var dateCache: [String: Date] = [:]
    private var generation: UInt64 = 0
    private var liveTasks: [Task<Void, Never>] = []

    static let pageSize = 100
    static let composingLifetime: TimeInterval = 20
    static let pollWhileLive: TimeInterval = 60
    static let pollWhileDown: TimeInterval = 15

    init(
        sessionId: String,
        title: String,
        transport: any RoomTransport,
        sender: (any RoomMessageSending)? = nil,
        actionSender: (any RoomActionSending)? = nil,
        identity: (any AccountIdentityProviding)? = nil,
        membershipRole: String? = nil,
        focusSequenceId: Int64? = nil,
        ownAuthorIds: Set<String> = [],
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            guard seconds > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        now: @escaping @Sendable () -> Date = { Date() },
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        self.sessionId = sessionId
        self.title = title
        self.transport = transport
        self.sender = sender
        self.actionSender = actionSender
        self.identity = identity
        self.focusTarget = focusSequenceId
        // The web lets a viewer react but never post; the API refuses the post anyway.
        let refusedReason = membershipRole?.lowercased() == "viewer" ? Self.viewerReason : nil
        self.postingRefusedReason = refusedReason
        self.ownAuthorIds = Set(ownAuthorIds.map { $0.lowercased() })
        self.sleep = sleep
        self.now = now
        self.onReauthenticationRequired = onReauthenticationRequired
        // The very first frame already shows the right composer (or the viewer's reason), before any load.
        let initialComposer: RoomComposerState
        if sender == nil {
            initialComposer = .hidden
        } else if let reason = refusedReason {
            initialComposer = RoomComposerState(canPost: false, disabledReason: reason)
        } else {
            initialComposer = RoomComposerState(canPost: true, disabledReason: nil, maximumLength: HTTPRoomMessageSender.maximumLength)
        }
        self.state = RoomChatPresentationState(
            sessionId: sessionId,
            title: title,
            messages: [],
            isLoadingInitial: true,
            composer: initialComposer
        )
    }

    // MARK: - Lifecycle

    /// Opens the room (first time) or resumes it after `pause()`: catch up, then go live.
    func resume() {
        guard liveTasks.isEmpty, !failureIsTerminal else { return }
        learnOwnIdentityIfNeeded()
        generation &+= 1
        let current = generation
        liveTasks.append(Task { [weak self] in
            guard let self else { return }
            if !self.hasLoadedInitial {
                await self.loadInitial(current)
            } else {
                await self.catchUp(current)
            }
            guard current == self.generation, !self.failureIsTerminal else { return }
            if let target = self.focusTarget, self.timeline.index(ofSequence: target) == nil {
                self.loadOlder(until: target)
            }
            self.startLive(current)
            await self.refreshActions(force: true)
        })
    }

    /// Stops the stream and the poll (app backgrounded, screen closed). Loaded rows are kept.
    func pause() {
        generation &+= 1
        liveTasks.forEach { $0.cancel() }
        liveTasks.removeAll()
        if !failureIsTerminal { connection = .paused }
        publish()
    }

    func send(_ intent: RoomChatIntent) {
        switch intent {
        case .loadOlder:
            loadOlder()
        case .readerAtBottom(let atBottom):
            readerAtBottom = atBottom
            if atBottom, unread.unreadCount > 0 || unread.dividerSequence != nil {
                unread.readerReachedBottom()
                publish()
            }
        case .retry:
            failure = nil
            if !hasLoadedInitial { isLoadingInitial = true }
            publish()
            pause()
            resume()
        case .jumpToMessage(let sequenceId):
            loadOlder(until: sequenceId)
        case .sendMessage(let text):
            enqueueSend(text)
        case .retrySend(let clientId):
            if let index = pendingReplies.firstIndex(where: { $0.clientId == clientId }) {
                guard case .failed(_, true) = pendingReplies[index].status else { return }
                pendingReplies[index].status = .sending
                publish()
                deliverReply(clientId)
                return
            }
            guard let index = pending.firstIndex(where: { $0.clientId == clientId }),
                  case .failed(_, true) = pending[index].status else { return }
            pending[index].status = .sending
            publish()
            deliver(clientId)
        case .discardSend(let clientId):
            pending.removeAll { $0.clientId == clientId }
            pendingReplies.removeAll { $0.clientId == clientId }
            publish()
        case .react(let sequenceId, let type):
            react(type, on: sequenceId)
        case .openThread(let sequenceId):
            openThread(sequenceId)
        case .closeThread:
            // Unsent replies stay with their thread and show again when it reopens.
            openThreadSequence = nil
            threadReplies = []
            threadFailure = nil
            publish()
        case .sendReply(let sequenceId, let text):
            sendReply(text, to: sequenceId)
        case .focusHandled:
            guard focusTarget != nil else { return }
            focusTarget = nil
            publish()
        }
    }

    /// Brings a message into view and highlights it (a link to this room), paging back until it is loaded. A message
    /// newer than the loaded rows arrives through the live stream and is focused when it lands.
    func focus(on sequenceId: Int64) {
        focusTarget = sequenceId
        publish()
        if hasLoadedInitial, timeline.index(ofSequence: sequenceId) == nil,
           let oldest = timeline.oldestSequence, sequenceId < oldest {
            loadOlder(until: sequenceId)
        }
    }

    // MARK: - Replies and reactions

    private var canReact: Bool { actionSender != nil && !failureIsTerminal }

    /// Re-reads the room's reply and reaction projection. Unforced calls (after arrivals) are throttled.
    func refreshActions(force: Bool = false) async {
        guard !actionsRefreshInFlight, !failureIsTerminal else { return }
        if !force, let last = lastActionsRefresh, now().timeIntervalSince(last) < Self.actionsRefreshInterval { return }
        actionsRefreshInFlight = true
        defer { actionsRefreshInFlight = false }
        lastActionsRefresh = now()
        guard let page = try? await transport.roomActions(sessionId: sessionId, targetSequenceId: nil, limit: 500) else {
            return
        }
        // The projection covers the newest actions; keep older summaries it no longer includes.
        for (sequence, summary) in page.byTarget { summaries[sequence] = summary }
        publish()
    }

    private func react(_ type: String, on sequenceId: Int64) {
        guard let actionSender, canReact, RoomActionRequest.reactionTypes.contains(type) else { return }
        // Shown at once (display only: the refresh replaces it with the server's truth).
        applyOptimisticReaction(type, on: sequenceId, actor: ownAuthorIds.sorted().first ?? "you")
        let sessionId = self.sessionId
        Task { [weak self] in
            // Not sent while you are unknown; the refresh then just restores the server's truth.
            if let actor = await self?.resolvedActorRef() {
                do {
                    try await actionSender.sendAction(.reaction(type, sessionId: sessionId, sequenceId: sequenceId, actor: actor))
                } catch RoomSendError.reauthenticationRequired {
                    self?.onReauthenticationRequired()
                } catch {
                    // Fall through: the refresh below restores the server's truth.
                }
            }
            await self?.refreshActions(force: true)
        }
    }

    private func applyOptimisticReaction(_ type: String, on sequenceId: Int64, actor: String) {
        let current = summaries[sequenceId] ?? RoomReactionSummary(targetSequenceId: sequenceId)
        var counts = current.counts
        var actors = current.actorsByType
        var liked = current.likedByViewer
        var disliked = current.dislikedByViewer
        switch type {
        case "like" where !liked:
            counts["like", default: 0] += 1
            liked = true
        case "unlike" where liked:
            counts["like"] = max((counts["like"] ?? 1) - 1, 0)
            liked = false
        case "dislike" where !disliked:
            counts["dislike", default: 0] += 1
            disliked = true
        case "undislike" where disliked:
            counts["dislike"] = max((counts["dislike"] ?? 1) - 1, 0)
            disliked = false
        case "ack" where !(actors["ack"] ?? []).contains(actor):
            counts["ack", default: 0] += 1
            actors["ack"] = ((actors["ack"] ?? []) + [actor]).sorted()
        default:
            return
        }
        summaries[sequenceId] = RoomReactionSummary(
            targetSequenceId: sequenceId,
            counts: counts.filter { $0.value > 0 },
            actorsByType: actors,
            activeOwners: current.activeOwners,
            likedByViewer: liked,
            dislikedByViewer: disliked,
            replyTotal: current.replyTotal,
            latestReplies: current.latestReplies,
            hasMoreReplies: current.hasMoreReplies,
            isPinned: current.isPinned
        )
        publish()
    }

    private func openThread(_ sequenceId: Int64) {
        openThreadSequence = sequenceId
        threadReplies = summaries[sequenceId]?.latestReplies ?? []
        threadFailure = nil
        threadLoading = true
        publish()
        Task { [weak self] in await self?.loadThread(sequenceId) }
    }

    private func loadThread(_ sequenceId: Int64) async {
        do {
            let page = try await transport.roomActions(sessionId: sessionId, targetSequenceId: sequenceId, limit: 500)
            guard openThreadSequence == sequenceId else { return }
            threadReplies = page.replies.filter { $0.targetSequenceId == sequenceId }
            threadFailure = nil
        } catch {
            guard openThreadSequence == sequenceId else { return }
            threadFailure = "Replies could not be loaded. Pull to try again later."
        }
        threadLoading = false
        publish()
    }

    private func sendReply(_ raw: String, to sequenceId: Int64) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard actionSender != nil, postingRefusedReason == nil, !text.isEmpty else { return }
        let nonce = UUID().uuidString.lowercased()
        guard text.unicodeScalars.count <= RoomActionRequest.replyLimit else {
            // The reply box holds this before sending; this is the backstop. The full text is kept (only the row's
            // display is cut), so nothing typed is lost.
            pendingReplies.append(PendingReply(
                nonce: nonce,
                targetSequenceId: sequenceId,
                text: text,
                status: .failed(reason: "Too long for a reply (the limit is 4,000 characters).", canRetry: false)
            ))
            publish()
            return
        }
        pendingReplies.append(PendingReply(nonce: nonce, targetSequenceId: sequenceId, text: text, status: .sending))
        publish()
        deliverReply("rp_" + nonce)
    }

    /// Posts (or re-posts, with the same key) one pending reply.
    private func deliverReply(_ clientId: String) {
        guard let actionSender, let item = pendingReplies.first(where: { $0.clientId == clientId }) else { return }
        let sessionId = self.sessionId
        let pinned = item.actor
        Task { [weak self] in
            let resolved: String?
            if let pinned {
                resolved = pinned
            } else {
                resolved = await self?.resolvedActorRef()
            }
            guard let actor = resolved else {
                // Never sent under a placeholder name; the row offers Retry.
                self?.updateReply(clientId) {
                    $0.status = .failed(reason: RoomSendError.retryable(retryAfterSeconds: nil).userMessage, canRetry: true)
                }
                return
            }
            if pinned == nil, let index = self?.pendingReplies.firstIndex(where: { $0.clientId == clientId }) {
                self?.pendingReplies[index].actor = actor
            }
            let request = RoomActionRequest.reply(
                sessionId: sessionId, sequenceId: item.targetSequenceId, text: item.text, actor: actor, nonce: item.nonce
            )
            do {
                try await actionSender.sendAction(request)
                guard let self else { return }
                if self.openThreadSequence == item.targetSequenceId { await self.loadThread(item.targetSequenceId) }
                self.pendingReplies.removeAll { $0.clientId == clientId }
                self.publish()
                await self.refreshActions(force: true)
            } catch {
                guard let self else { return }
                let status = self.failedStatus(for: error)
                self.updateReply(clientId) { $0.status = status }
            }
        }
    }

    private func updateReply(_ clientId: String, _ change: (inout PendingReply) -> Void) {
        guard let index = pendingReplies.firstIndex(where: { $0.clientId == clientId }) else { return }
        change(&pendingReplies[index])
        publish()
    }

    /// How a failed write shows, with its side effects: sign in again, or no more posting for a viewer. Retry is
    /// offered only when the same request may simply not have landed.
    private func failedStatus(for error: Error) -> RoomChatPendingRow.Status {
        guard let error = error as? RoomSendError else {
            return .failed(reason: RoomSendError.retryable(retryAfterSeconds: nil).userMessage, canRetry: true)
        }
        switch error {
        case .reauthenticationRequired:
            onReauthenticationRequired()
            return .failed(reason: error.userMessage, canRetry: true)
        case .notAllowed:
            postingRefusedReason = Self.viewerReason
            return .failed(reason: error.userMessage, canRetry: false)
        case .retryable:
            return .failed(reason: error.userMessage, canRetry: true)
        case .rejected, .notConfigured:
            return .failed(reason: error.userMessage, canRetry: false)
        }
    }

    // MARK: - Sending

    private var composerState: RoomComposerState {
        guard sender != nil else { return .hidden }
        if let postingRefusedReason { return RoomComposerState(canPost: false, disabledReason: postingRefusedReason) }
        return RoomComposerState(canPost: true, disabledReason: nil, maximumLength: HTTPRoomMessageSender.maximumLength)
    }

    private func enqueueSend(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sender != nil, postingRefusedReason == nil, !text.isEmpty else { return }
        guard text.unicodeScalars.count <= HTTPRoomMessageSender.maximumLength else {
            // The composer refuses this before sending; this is the backstop. The full text is kept (only the row's
            // display is cut), so nothing typed is lost.
            pending.append(PendingSend(
                clientId: Self.makeClientId(),
                text: text,
                status: .failed(reason: "Too long to send (the limit is 64,000 characters).", canRetry: false)
            ))
            publish()
            return
        }
        let clientId = Self.makeClientId()
        pending.append(PendingSend(clientId: clientId, text: text, status: .sending))
        readerAtBottom = true
        unread.readerReachedBottom()
        publish()
        deliver(clientId)
    }

    /// Posts (or re-posts, with the same client id) one pending message.
    private func deliver(_ clientId: String) {
        guard let sender, let item = pending.first(where: { $0.clientId == clientId }) else { return }
        let sessionId = self.sessionId
        Task { [weak self] in
            do {
                try await sender.sendHumanMessage(sessionId: sessionId, text: item.text, clientId: clientId)
                guard let self else { return }
                self.updatePending(clientId) { $0.status = .sent; $0.sentAt = self.now() }
                // Pull the echo now instead of waiting for the stream or the next poll.
                await self.catchUp(self.generation)
                await self.sleep(Self.sentEchoGrace)
                self.pending.removeAll { $0.clientId == clientId && $0.status == .sent }
                self.publish()
            } catch {
                guard let self else { return }
                let status = self.failedStatus(for: error)
                self.updatePending(clientId) { $0.status = status }
            }
        }
    }

    private func updatePending(_ clientId: String, _ change: (inout PendingSend) -> Void) {
        guard let index = pending.firstIndex(where: { $0.clientId == clientId }) else { return }
        change(&pending[index])
        publish()
    }

    /// Drops pending rows the room has now shown, and learns your author id from your own echoed message.
    private func reconcilePending(with messages: [RoomMessage]) {
        guard !pending.isEmpty else { return }
        for message in messages {
            guard let clientId = message.clientMessageId,
                  pending.contains(where: { $0.clientId == clientId }) else { continue }
            pending.removeAll { $0.clientId == clientId }
            if !message.authorId.isEmpty { ownAuthorIds.insert(message.authorId.lowercased()) }
        }
    }

    private func learnOwnIdentityIfNeeded() {
        guard !identityRequested, let identity else { return }
        identityRequested = true
        Task { [weak self] in
            guard let account = await identity.currentAccount(), let self else { return }
            self.learn(account)
        }
    }

    private func learn(_ account: SignedInAccount) {
        actorRef = account.actorRef
        ownAuthorIds.insert(account.authorId)
        publish()
    }

    /// You in an action's key: your account (GitHub username, else account id), asked again if the first look
    /// failed, else the login in an author id you are known by. Never a shared placeholder: the API would take a
    /// second person's ack as the first one's duplicate. nil while you are unknown.
    private func resolvedActorRef() async -> String? {
        if let actorRef { return actorRef }
        if let identity, let account = await identity.currentAccount() {
            learn(account)
            return account.actorRef
        }
        return ownAuthorIds.sorted().first { $0.hasPrefix("human-") }.map { String($0.dropFirst("human-".count)) }
    }

    static func makeClientId() -> String {
        "hm_" + UUID().uuidString.lowercased()
    }

    // MARK: - Loading

    private func loadInitial(_ current: UInt64) async {
        isLoadingInitial = true
        publish()
        do {
            var page = try await transport.roomEventsBefore(
                sessionId: sessionId,
                beforeSequence: nil,
                limit: Self.pageSize
            )
            guard current == generation else { return }
            apply(page, older: true)
            // A tail made only of non-chat rows: keep paging back a little so the room does not open empty.
            var pages = 1
            while timeline.messages.isEmpty, page.hasMore, pages < 5,
                  let before = page.nextBeforeSequence ?? page.minSequence {
                page = try await transport.roomEventsBefore(
                    sessionId: sessionId,
                    beforeSequence: before,
                    limit: Self.pageSize
                )
                guard current == generation else { return }
                apply(page, older: true)
                pages += 1
            }
            hasLoadedInitial = true
            failure = nil
        } catch {
            guard current == generation else { return }
            record(error)
        }
        isLoadingInitial = false
        publish()
    }

    private func loadOlder(until targetSequence: Int64? = nil) {
        guard hasLoadedInitial, !isLoadingOlder, timeline.hasMoreOlder,
              nextBeforeSequence ?? timeline.oldestSequence != nil else { return }
        isLoadingOlder = true
        publish()
        Task { [weak self] in
            guard let self else { return }
            var pages = 0
            repeat {
                guard let before = self.nextBeforeSequence ?? self.timeline.oldestSequence else { break }
                do {
                    let page = try await self.transport.roomEventsBefore(
                        sessionId: self.sessionId,
                        beforeSequence: before,
                        limit: Self.pageSize
                    )
                    guard !self.failureIsTerminal else { break }
                    self.apply(page, older: true)
                } catch {
                    self.record(error)
                    break
                }
                pages += 1
            } while targetSequence.map { target in
                self.timeline.index(ofSequence: target) == nil
                    && (self.timeline.oldestSequence ?? 0) > target
                    && self.timeline.hasMoreOlder
            } ?? false && pages < 10
            self.isLoadingOlder = false
            self.publish()
        }
    }

    private func catchUp(_ current: UInt64) async {
        var rounds = 0
        while rounds < 5 {
            do {
                let page = try await transport.roomEventsAfter(
                    sessionId: sessionId,
                    fromSequence: lastAppliedSequence,
                    limit: 200
                )
                guard current == generation else { return }
                apply(page, older: false)
                publish()
                if page.rawCount < 200 { return }
            } catch {
                guard current == generation else { return }
                record(error)
                publish()
                return
            }
            rounds += 1
        }
    }

    // MARK: - Live

    private func startLive(_ current: UInt64) {
        liveTasks.append(Task { [weak self] in await self?.runStream(current) })
        liveTasks.append(Task { [weak self] in await self?.runSafetyPoll(current) })
    }

    private func runStream(_ current: UInt64) async {
        var backoff = RoomStreamBackoff()
        while !Task.isCancelled, current == generation {
            if connection != .live {
                connection = backoff.failures == 0 ? .connecting : .reconnecting
                publish()
            }
            var delivered = false
            var end: RoomStreamEnd = .closed
            for await event in transport.roomStream(sessionId: sessionId, fromSequence: lastAppliedSequence) {
                guard current == generation, !Task.isCancelled else { return }
                switch event {
                case .frame(let frame):
                    if handle(frame) { delivered = true }
                case .ended(let reason):
                    end = reason
                }
            }
            guard current == generation, !Task.isCancelled else { return }
            switch end {
            case .reauthenticationRequired:
                failure = .reauthenticationRequired
                stopForTerminalFailure()
                onReauthenticationRequired()
                return
            case .accessDenied:
                failure = .accessDenied
                stopForTerminalFailure()
                return
            case .closed, .retryable:
                break
            }
            guard let delay = backoff.delayAfter(end, deliveredEvents: delivered) else { return }
            if delay > 0 {
                connection = .reconnecting
                publish()
                await sleep(delay)
                guard current == generation, !Task.isCancelled else { return }
            }
            await catchUp(current)
        }
    }

    private func runSafetyPoll(_ current: UInt64) async {
        while !Task.isCancelled, current == generation {
            await sleep(connection == .live ? Self.pollWhileLive : Self.pollWhileDown)
            guard current == generation, !Task.isCancelled else { return }
            await catchUp(current)
            await refreshActions(force: true)
            pruneComposing()
        }
    }

    /// Applies one stream frame. Returns true when it carried a durable row.
    @discardableResult
    func handle(_ frame: RoomStreamFrame) -> Bool {
        switch frame {
        case .message(let message):
            connection = .live
            let result = timeline.merge([message])
            lastAppliedSequence = max(lastAppliedSequence, message.sequenceId)
            composing[message.authorId] = nil
            reconcilePending(with: [message])
            unread.noteArrivals(result.inserted, readerIsAtBottom: readerAtBottom, selfAuthorIds: ownAuthorIds)
            publish()
            Task { [weak self] in await self?.refreshActions() }
            return true
        case .nonDisplayable(let sequenceId):
            connection = .live
            lastAppliedSequence = max(lastAppliedSequence, sequenceId)
            return true
        case .composing(let agentId, _):
            connection = .live
            composing[agentId] = now()
            publish()
            return false
        case .control:
            if connection != .live {
                connection = .live
                publish()
            }
            return false
        case .serverError:
            return false
        }
    }

    // MARK: - State

    private func apply(_ page: RoomEventPage, older: Bool) {
        let result = timeline.merge(page.messages)
        reconcilePending(with: page.messages)
        if older {
            nextBeforeSequence = page.nextBeforeSequence ?? page.minSequence
            timeline.hasMoreOlder = page.hasMore && nextBeforeSequence != nil
        } else {
            unread.noteArrivals(result.inserted, readerIsAtBottom: readerAtBottom, selfAuthorIds: ownAuthorIds)
        }
        if let maxSequence = page.maxSequence {
            lastAppliedSequence = max(lastAppliedSequence, maxSequence)
        }
    }

    private func pruneComposing() {
        let cutoff = now().addingTimeInterval(-Self.composingLifetime)
        let before = composing.count
        composing = composing.filter { $0.value > cutoff }
        if composing.count != before { publish() }
    }

    private var failureIsTerminal: Bool {
        failure == .reauthenticationRequired || failure == .accessDenied
    }

    private func record(_ error: Error) {
        switch error as? SessionTransportError {
        case .reauthenticationRequired?, .notLoggedIn?:
            failure = .reauthenticationRequired
            onReauthenticationRequired()
        case .accessDenied?:
            failure = .accessDenied
        case .invalidData?, .invalidRequest?:
            failure = timeline.messages.isEmpty ? .invalidData : nil
        case .cancelled?:
            break
        case .rateLimited?, .service?:
            failure = timeline.messages.isEmpty ? .service : nil
        default:
            failure = timeline.messages.isEmpty ? .network : nil
        }
        if failureIsTerminal { stopForTerminalFailure() }
    }

    /// A signed-out or denied room stops every loop: no reconnect, no poll, and `resume()` will not reopen it.
    private func stopForTerminalFailure() {
        generation &+= 1
        liveTasks.forEach { $0.cancel() }
        liveTasks.removeAll()
        connection = .paused
        publish()
    }

    private func publish() {
        let inputs = timeline.messages.map { message -> RoomChatMessageInput in
            let date: Date?
            if let cached = dateCache[message.id] {
                date = cached
            } else {
                date = ParsedSessionTimestamp(message.timestamp).date
                if let date { dateCache[message.id] = date }
            }
            let summary = summaries[message.sequenceId]
            return RoomChatMessageInput(
                id: message.id,
                sequenceId: message.sequenceId,
                kind: Self.kind(message.kind),
                authorId: message.authorId,
                authorName: message.authorName,
                isHuman: message.isHuman,
                text: message.text,
                timestamp: message.timestamp,
                replyToSequenceId: message.replyToSequenceId,
                isEdited: message.isEdited,
                date: date,
                reactions: summary.map {
                    RoomChatReactions.make(
                        counts: $0.counts,
                        actorsByType: $0.actorsByType,
                        activeOwners: $0.activeOwners,
                        likedByViewer: $0.likedByViewer,
                        dislikedByViewer: $0.dislikedByViewer,
                        replyCount: $0.replyTotal,
                        isPinned: $0.isPinned
                    )
                }
            )
        }
        let threadInput = openThreadSequence.map { sequence in
            RoomChatThreadInput(
                sequenceId: sequence,
                replies: threadReplies.map { reply in
                    RoomChatReplyRow(
                        id: reply.id,
                        authorName: reply.isHuman ? String(reply.authorId.dropFirst("human-".count)) : reply.authorId,
                        isHuman: reply.isHuman,
                        isOwn: ownAuthorIds.contains(reply.authorId.lowercased()),
                        text: reply.text,
                        date: ParsedSessionTimestamp(reply.createdAt).date,
                        isEdited: reply.isEdited
                    )
                },
                pending: pendingReplies.filter { $0.targetSequenceId == sequence }.map {
                    RoomChatPendingRow(clientId: $0.clientId, text: $0.text, status: $0.status)
                },
                isLoading: threadLoading,
                failureText: threadFailure,
                canReply: actionSender != nil && postingRefusedReason == nil,
                maximumReplyLength: RoomActionRequest.replyLimit
            )
        }
        state = RoomChatPresentationState(
            sessionId: sessionId,
            title: title,
            messages: inputs,
            ownAuthorIds: ownAuthorIds,
            unreadDividerSequence: unread.dividerSequence,
            unreadCount: unread.unreadCount,
            isLoadingInitial: isLoadingInitial,
            canLoadOlder: hasLoadedInitial && timeline.hasMoreOlder,
            isLoadingOlder: isLoadingOlder,
            connection: connection,
            composingAgents: composing
                .filter { $0.value > now().addingTimeInterval(-Self.composingLifetime) }
                .keys
                .sorted(),
            failure: failure,
            pending: pending.map { RoomChatPendingRow(clientId: $0.clientId, text: $0.text, status: $0.status) },
            composer: composerState,
            canReact: canReact,
            thread: threadInput,
            focusSequenceId: focusTarget,
            mentionCandidates: mentionCandidates()
        )
    }

    /// Everyone who has posted in the loaded history, newest activity per person, for @-mention suggestions.
    private func mentionCandidates() -> [MentionCandidate] {
        guard sender != nil else { return [] }
        var latest: [String: (name: String, isHuman: Bool, date: Date?)] = [:]
        for message in timeline.messages
        where message.kind == .message && !message.authorId.isEmpty && !ownAuthorIds.contains(message.authorId.lowercased()) {
            let date = dateCache[message.id]
            latest[message.authorId] = (message.authorName, message.isHuman, date)
        }
        let ownHandles = Set(ownAuthorIds.map { $0.hasPrefix("human-") ? String($0.dropFirst("human-".count)) : $0 })
        return MentionSuggester.candidates(
            authors: latest.map { (id: $0.key, name: $0.value.name, isHuman: $0.value.isHuman, lastActive: $0.value.date) },
            ownHandles: ownHandles,
            now: now()
        )
    }

    private static func kind(_ kind: RoomMessageKind) -> RoomChatMessageInput.Kind {
        switch kind {
        case .message: return .message
        case .checkpoint: return .checkpoint
        case .memberJoined: return .memberJoined
        }
    }
}
