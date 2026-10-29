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
    private let ownAuthorIds: Set<String>
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let now: @Sendable () -> Date
    private let onReauthenticationRequired: @MainActor () -> Void

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
        self.ownAuthorIds = Set(ownAuthorIds.map { $0.lowercased() })
        self.sleep = sleep
        self.now = now
        self.onReauthenticationRequired = onReauthenticationRequired
        self.state = RoomChatPresentationState(
            sessionId: sessionId,
            title: title,
            messages: [],
            isLoadingInitial: true
        )
    }

    // MARK: - Lifecycle

    /// Opens the room (first time) or resumes it after `pause()`: catch up, then go live.
    func resume() {
        guard liveTasks.isEmpty, !failureIsTerminal else { return }
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
            self.startLive(current)
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
        }
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
            unread.noteArrivals(result.inserted, readerIsAtBottom: readerAtBottom, selfAuthorIds: ownAuthorIds)
            publish()
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
                date: date
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
            failure: failure
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
