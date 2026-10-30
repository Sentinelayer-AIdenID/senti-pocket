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
    /// The room's name; its owner can rename it.
    private var title: String
    private let canRename: Bool
    /// Thread summaries written on the phone (Carter, #55474), by parent sequence, with the reply count each was
    /// written for; a thread is summarized again only once it has grown.
    private var threadSummaries: [Int64: (replies: Int, text: String)] = [:]
    private var summarizing: Int64?
    private let summarizer: (any ThreadSummarizing)?
    private let canInvite: Bool
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
    /// Who answered in threads, as of each one's newest reply: most agent and box output is replies, so they are
    /// offered for @ like anyone who posted.
    private var replyAuthors: [String: (name: String, isHuman: Bool, date: Date?)] = [:]
    /// Threaded replies by action id (newest revision), shown in the room at their own time. Bounded to the newest.
    private var inlineReplies: [String: RoomReply] = [:]
    /// Agents' "working on" updates by action id, and how long one stays current.
    private var workingOn: [String: RoomWorkingOn] = [:]
    private var workingOnStaleAfter: TimeInterval = 900
    static let inlineReplyLimit = 1_500
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
        /// The reply it answers, for a reply to a reply (it nests under it).
        var toReply: String? = nil
        let text: String
        var status: RoomChatPendingRow.Status
        /// You in its key, pinned at the first attempt, so a retry is byte-for-byte the same request.
        var actor: String?
        var clientId: String { "rp_" + nonce }
    }
    private var pendingReplies: [PendingReply] = []
    /// You in action keys, from your account (see `SignedInAccount.actorRef`).
    private var actorRef: String?
    /// Your account id and login, which read receipts name you by.
    private var accountId: String?
    private var ownLogin: String?
    /// Read receipts and presence, when the room is wired for them.
    private var receiptsTracker: RoomReceiptsTracker?
    /// The room's pinned messages (newest first) and how many it may hold.
    private var pinned: [RoomPinnedMessage] = []
    private var pinLimit = 10
    /// A message to bring into view once (opened from a notification or link); cleared when the view shows it.
    private var focusTarget: Int64?
    /// Links whose message could not be loaded; each one sends the reader to the latest messages.
    private var focusFallbackCount = 0
    /// Arrivals refresh reactions at most this often (the web polls about every 15s).
    static let actionsRefreshInterval: TimeInterval = 10
    /// How often an open room reads replies (the web polls about every 15s).
    static let actionsPollInterval: TimeInterval = 15
    /// How often replies are read while a voice room is open: an answer in a thread is read aloud soon after.
    static let voiceActionsPollInterval: TimeInterval = 3

    /// A voice room listening in: each live message as it arrives, and each reply the first time it is read.
    var onLiveMessages: (@MainActor ([RoomMessage]) -> Void)?
    var onNewReplies: (@MainActor ([RoomReply]) -> Void)?
    /// While a voice room is open, replies are read every few seconds.
    var readsRepliesOften = false {
        didSet {
            guard readsRepliesOften, !oldValue else { return }
            Task { [weak self] in await self?.refreshActions(force: true) }
        }
    }
    /// Replies seen before any were read are not news.
    private var hasReadReplies = false
    /// The room on screen sounding and vibrating: your message sent, a message or reply arriving, a mention of you.
    var onFeedback: (@MainActor (RoomFeedbackEvent) -> Void)?
    /// Something to tell the person once (an edit that did not save).
    private var notice: String?
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
    private var isLoadingNewer = false
    private var isLoadingWindow = false
    /// While the rows are a window further back: the highest sequence the newer pages have read (it may be a
    /// non-chat event), where the next newer page starts.
    private var nextAfterSequence: Int64?
    private var hasLoadedInitial = false
    private var dateCache: [String: Date] = [:]
    /// Breakouts started from this room, by child room id, as this viewer may see them (GET .../breakouts).
    private var breakouts: [String: RoomBreakout] = [:]
    private var breakoutsRefreshInFlight = false
    /// Small image previews by attachment id, newest last (bounded; memory only, never written to disk).
    private var previews: [String: Data] = [:]
    private var previewOrder: [String] = []
    private var previewsInFlight: Set<String> = []
    private let attachmentFetcher: any AttachmentFileFetching
    /// Owners and admins can read the member list, so they can mention people who have not posted yet.
    private let readsMembers: Bool
    private var members: [RoomMember] = []
    /// The room's member directory (every member may read it), read once per open, for @-mentions.
    private let directory: (any RoomTicketExtrasReading)?
    private var directoryPeople: [RoomDirectoryMember] = []
    private var readDirectory = false
    static let previewLimitBytes = 10 * 1024 * 1024
    static let previewCacheSize = 40
    private var generation: UInt64 = 0
    private var liveTasks: [Task<Void, Never>] = []

    static let pageSize = 100
    /// Each side of a jump to an older message: this many messages up to it and this many events after it.
    static let windowPageSize = 50
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
        canRename: Bool = false,
        canInvite: Bool = false,
        summarizer: (any ThreadSummarizing)? = nil,
        focusSequenceId: Int64? = nil,
        ownAuthorIds: Set<String> = [],
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            guard seconds > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        now: @escaping @Sendable () -> Date = { Date() },
        attachmentFetcher: any AttachmentFileFetching = URLSessionAttachmentFetcher(),
        receipts: (any RoomReceiptsClient)? = nil,
        directory: (any RoomTicketExtrasReading)? = nil,
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        self.attachmentFetcher = attachmentFetcher
        self.directory = directory
        self.sessionId = sessionId
        self.title = title
        self.canRename = canRename && sender is any RoomTitleSetting
        self.canInvite = canInvite && sender is any RoomInviting
        self.summarizer = summarizer
        self.transport = transport
        self.sender = sender
        self.actionSender = actionSender
        self.identity = identity
        self.focusTarget = focusSequenceId
        // The web lets a viewer react but never post; the API refuses the post anyway.
        let refusedReason = membershipRole?.lowercased() == "viewer" ? Self.viewerReason : nil
        self.readsMembers = ["owner", "admin"].contains(membershipRole?.lowercased() ?? "")
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
            composer: initialComposer,
            canRename: canRename && sender is any RoomTitleSetting,
            canInvite: canInvite && sender is any RoomInviting
        )
        if let receipts {
            receiptsTracker = RoomReceiptsTracker(
                sessionId: sessionId,
                client: receipts,
                sleep: sleep,
                now: now,
                onChange: { [weak self] in self?.publish() }
            )
        }
    }

    // MARK: - Lifecycle

    /// Opens the room (first time) or resumes it after `pause()`: catch up, then go live.
    func resume() {
        guard liveTasks.isEmpty, !failureIsTerminal else { return }
        learnOwnIdentityIfNeeded()
        receiptsTracker?.start()
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
            self.pursueFocus()
            self.startLive(current)
            await self.refreshActions(force: true)
            await self.refreshBreakouts()
            await self.refreshMembers()
            await self.readMemberDirectory()
        })
    }

    /// Stops the stream and the poll (app backgrounded, screen closed). Loaded rows are kept.
    func pause() {
        generation &+= 1
        liveTasks.forEach { $0.cancel() }
        liveTasks.removeAll()
        receiptsTracker?.stop()
        if !failureIsTerminal { connection = .paused }
        publish()
    }

    /// Stacks of alike notices opened to show each one (by their first notice's id).
    private var expandedRepeats: Set<String> = []

    func send(_ intent: RoomChatIntent) {
        switch intent {
        case .loadOlder:
            loadOlder()
        case .loadNewer:
            loadNewer()
        case .jumpToLatest:
            jumpToLatest()
        case .keepLatestForJumpDown:
            if historyTooLongToJumpDown {
                readerAtBottom = false
                keepLatestForTheJumpDown()
                publish()
            }
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
            // A pinned message or a reply's parent: loaded like a link, then brought into view.
            focus(on: sequenceId)
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
        case .editMessage(let sequenceId, let text):
            editMessage(sequenceId, text: text)
        case .editReply(let sequenceId, let replyId, let text):
            editReply(replyId, in: sequenceId, text: text)
        case .dismissNotice:
            notice = nil
            publish()
        case .renameRoom(let name):
            rename(to: name)
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
        case .sendReplyToReply(let sequenceId, let replyId, let text):
            sendReply(text, to: sequenceId, toReply: replyId)
        case .reactToReply(let sequenceId, let replyId, let type):
            reactToReply(type, on: replyId, in: sequenceId)
        case .focusHandled:
            guard focusTarget != nil else { return }
            focusTarget = nil
            publish()
        case .openBreakout, .openAttachment, .readAloud, .stopReadingAloud, .openTickets, .openSearch, .peopleOpened, .openInvite:
            break   // the room screen navigates or presents
        case .setPinned(let sequenceId, let isPinned):
            setPinned(isPinned, on: sequenceId)
        case .messageOnScreen(let id, let isOnScreen):
            guard let message = timeline.messages.first(where: { $0.id == id }),
                  message.kind == .message, message.eventType == "session_message",
                  let target = RoomViewTarget(kind: .message, id: message.id, revision: message.revision) else { return }
            receiptsTracker?.setOnScreen(target, isOnScreen)
        case .toggleRepeats(let stack):
            if expandedRepeats.contains(stack) {
                expandedRepeats.remove(stack)
            } else {
                expandedRepeats.insert(stack)
            }
            publish()
        case .replyOnScreen(let id, let isOnScreen):
            guard let reply = threadReplies.first(where: { $0.id == id }),
                  let target = RoomViewTarget(kind: .reply, id: reply.id, revision: reply.revision) else { return }
            receiptsTracker?.setOnScreen(target, isOnScreen)
        case .attachmentAppeared(let attachmentId):
            loadPreview(attachmentId)
        }
    }

    /// Brings a message into view and highlights it: a link, a notification, a search result, a pinned message or a
    /// reply's parent. One further back than the loaded rows is loaded as a window around it in one step, however far
    /// back it is. One newer than the loaded rows arrives through the live stream and is focused when it lands.
    func focus(on sequenceId: Int64) {
        focusTarget = sequenceId
        publish()
        pursueFocus()
    }

    /// Loads what the focused message needs: the window around it when it is outside the loaded rows. A message
    /// newer than anything the room has seen arrives live. Anything else cannot be shown and is let go.
    private func pursueFocus() {
        guard let target = focusTarget, hasLoadedInitial, !isLoadingWindow,
              timeline.index(ofSequence: target) == nil else { return }
        let isOlder = timeline.oldestSequence.map { target < $0 } ?? (target <= lastAppliedSequence)
        if isOlder, timeline.hasMoreOlder {
            loadWindow(endingAt: target)
        } else if timeline.hasMoreNewer, target > (timeline.newestSequence ?? 0) {
            // The rows are a window further back: a later message is loaded the same way, or reached in the live
            // room when it is newer than anything the room has shown.
            if target <= lastAppliedSequence { loadWindow(endingAt: target) } else { jumpToLatest() }
        } else {
            dropFocusIfUnreachable(target)
        }
    }

    /// Loads the room around a message outside the loaded rows: the page of messages up to it and the page of events
    /// after it, two requests whatever the distance, so a link lands in one step in a room of any size. A window that
    /// reaches the loaded rows joins them; otherwise it replaces them, newer messages load as the reader scrolls down,
    /// and "Jump to latest" returns to the live room. A target that is not a chat row lands on its nearest message.
    private func loadWindow(endingAt target: Int64) {
        guard !isLoadingWindow else { return }
        isLoadingWindow = true
        publish()
        let current = generation
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoadingWindow = false
                self.publish()
            }
            do {
                let before = try await self.transport.roomEventsBefore(
                    sessionId: self.sessionId,
                    beforeSequence: target + 1,
                    limit: Self.windowPageSize
                )
                let after = try await self.transport.roomEventsAfter(
                    sessionId: self.sessionId,
                    fromSequence: target,
                    limit: Self.windowPageSize
                )
                guard current == self.generation, self.focusTarget == target, !self.failureIsTerminal else { return }
                let window = before.messages + after.messages
                guard !window.isEmpty else {
                    self.letFocusGo(target)
                    return
                }
                let readThrough = max(target, after.maxSequence ?? target)
                // The window joins the loaded rows only when it touches them on the side it comes from; otherwise
                // it stands alone, never stitched to them over a hole.
                let comesFromNewer = self.timeline.hasMoreNewer && target > (self.timeline.newestSequence ?? .max)
                if comesFromNewer, let newest = self.timeline.newestSequence,
                   !before.hasMore || (before.minSequence ?? .max) <= newest {
                    // Just below a window further back: it extends that window downwards.
                    let oldest = self.timeline.oldestSequence
                    self.timeline.merge(window, trimming: .oldest)
                    self.noteOldestTrimmed(was: oldest)
                    self.noteNewerRead(through: readThrough)
                } else if !comesFromNewer, let oldest = self.timeline.oldestSequence,
                          after.rawCount < Self.windowPageSize || readThrough >= oldest {
                    // Just above the loaded rows (the page after it reaches them, or reaches the end of the room):
                    // it extends them upwards.
                    self.timeline.merge(window, trimming: .newest)
                    self.noteNewestTrimmed()
                    self.nextBeforeSequence = before.nextBeforeSequence ?? before.minSequence
                    self.timeline.hasMoreOlder = before.hasMore && self.nextBeforeSequence != nil
                    if self.timeline.hasMoreNewer, readThrough > (self.nextAfterSequence ?? .max) {
                        self.noteNewerRead(through: readThrough)
                    }
                } else {
                    self.timeline.replace(with: window, hasMoreOlder: before.hasMore, hasMoreNewer: true)
                    self.nextBeforeSequence = before.nextBeforeSequence ?? before.minSequence
                    self.timeline.hasMoreOlder = before.hasMore && self.nextBeforeSequence != nil
                    self.noteNewerRead(through: readThrough)
                    self.readerAtBottom = false
                }
                self.reconcilePending(with: window)
                if self.timeline.index(ofSequence: target) == nil {
                    let nearest = self.timeline.messages.last { $0.sequenceId < target }
                        ?? self.timeline.messages.first { $0.sequenceId > target }
                    self.focusTarget = nearest?.sequenceId
                }
            } catch {
                guard current == self.generation else { return }
                self.record(error)
                if self.focusTarget == target { self.letFocusGo(target) }
            }
        }
    }

    /// The next newer page below a window further back. Once it reaches what the live room has shown, the window has
    /// joined the live room again.
    private func loadNewer() {
        guard hasLoadedInitial, timeline.hasMoreNewer, !isLoadingNewer, !isLoadingWindow else { return }
        let from = nextAfterSequence ?? timeline.newestSequence ?? lastAppliedSequence
        isLoadingNewer = true
        publish()
        let current = generation
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoadingNewer = false
                self.publish()
            }
            do {
                var from = from
                // A short page that still stops before what the stream has shown was answered before those
                // messages existed: read on at once (a few times) rather than go live without them.
                for _ in 0..<3 {
                    let page = try await self.transport.roomEventsAfter(
                        sessionId: self.sessionId,
                        fromSequence: from,
                        limit: Self.pageSize
                    )
                    guard current == self.generation, self.timeline.hasMoreNewer else { return }
                    let oldest = self.timeline.oldestSequence
                    self.timeline.merge(page.messages, trimming: .oldest)
                    self.timeline.applyEdits(page.edits)
                    self.noteOldestTrimmed(was: oldest)
                    self.reconcilePending(with: page.messages)
                    from = max(from, page.maxSequence ?? from)
                    self.noteNewerRead(through: from)
                    if !self.timeline.hasMoreNewer || page.rawCount >= Self.pageSize { break }
                }
            } catch {
                guard current == self.generation else { return }
                self.record(error)
            }
        }
    }

    /// Leaves a window further back for the live room: its newest page, as the room opens.
    private func jumpToLatest() {
        guard timeline.hasMoreNewer, !isLoadingWindow else { return }
        isLoadingWindow = true
        publish()
        let current = generation
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoadingWindow = false
                self.publish()
            }
            do {
                let page = try await self.transport.roomEventsBefore(
                    sessionId: self.sessionId,
                    beforeSequence: nil,
                    limit: Self.pageSize
                )
                guard current == self.generation, !self.failureIsTerminal else { return }
                self.timeline.replace(with: page.messages, hasMoreOlder: page.hasMore, hasMoreNewer: false)
                self.nextBeforeSequence = page.nextBeforeSequence ?? page.minSequence
                self.timeline.hasMoreOlder = page.hasMore && self.nextBeforeSequence != nil
                self.nextAfterSequence = nil
                self.reconcilePending(with: page.messages)
                self.readerAtBottom = true
                self.unread.readerReachedBottom()
                // The newest page may have been answered before messages the stream has since shown (counted while
                // the window was further back, never inserted): read on from where the page stops.
                if let readThrough = page.maxSequence, readThrough < self.lastAppliedSequence {
                    self.lastAppliedSequence = readThrough
                    await self.catchUp(current)
                }
                self.pursueFocus()
            } catch {
                guard current == self.generation else { return }
                self.record(error)
            }
        }
    }

    /// Rows below a window further back have been read through `readThrough`. The window joins the live room only
    /// once that reaches everything the stream has shown; anything sooner would leave out messages that arrived
    /// while the page was on its way.
    private func noteNewerRead(through readThrough: Int64) {
        if readThrough >= lastAppliedSequence {
            timeline.hasMoreNewer = false
            nextAfterSequence = nil
        } else {
            timeline.hasMoreNewer = true
            nextAfterSequence = readThrough
        }
    }

    /// Loading older history over the capacity let go of the newest rows: they load again below the window.
    private func noteNewestTrimmed() {
        guard timeline.hasMoreNewer, let newest = timeline.newestSequence else { return }
        nextAfterSequence = min(nextAfterSequence ?? newest, newest)
    }

    /// Newer rows over the capacity let go of the oldest: older pages start again from the oldest row kept.
    private func noteOldestTrimmed(was oldest: Int64?) {
        if let oldest, timeline.oldestSequence != oldest { nextBeforeSequence = nil }
    }

    private func letFocusGo(_ target: Int64) {
        guard focusTarget == target else { return }
        focusTarget = nil
        focusFallbackCount += 1
        publish()
    }

    /// A linked message still not loaded although the room has reached its sequence (before the start of the room,
    /// not a chat row, or gone) is let go, and the view takes the reader to the latest messages. Newer than anything
    /// seen, it may still arrive live.
    private func dropFocusIfUnreachable(_ target: Int64) {
        let seenThrough = max(timeline.newestSequence ?? 0, lastAppliedSequence)
        guard focusTarget == target, timeline.index(ofSequence: target) == nil, target <= seenThrough else { return }
        focusTarget = nil
        focusFallbackCount += 1
        publish()
    }

    // MARK: - Replies and reactions

    private var canReact: Bool { actionSender != nil && !failureIsTerminal }
    /// Pinning is a contributor's action (the API refuses viewers).
    private var canPin: Bool { actionSender != nil && postingRefusedReason == nil && !failureIsTerminal }

    /// Pins or unpins a message for everyone in the room. Shown at once; the refresh then brings the room's list.
    private func setPinned(_ isPinned: Bool, on sequenceId: Int64) {
        guard let actionSender, canPin else { return }
        let alreadyPinned = pinned.contains { $0.targetSequenceId == sequenceId }
        guard isPinned != alreadyPinned else { return }
        // The room holds a limited number of pins; the API refuses one more.
        if isPinned, pinned.count >= pinLimit { return }
        if isPinned {
            pinned.insert(RoomPinnedMessage(
                id: "pending-pin-\(sequenceId)",
                targetSequenceId: sequenceId,
                pinnedBy: ownAuthorIds.sorted().first ?? "you"
            ), at: 0)
        } else {
            pinned.removeAll { $0.targetSequenceId == sequenceId }
        }
        publish()
        let sessionId = self.sessionId
        Task { [weak self] in
            // Never sent under a placeholder name; the refresh then restores the room's list.
            if let actor = await self?.resolvedActorRef() {
                do {
                    try await actionSender.sendAction(.pin(isPinned, sessionId: sessionId, sequenceId: sequenceId, actor: actor))
                } catch RoomSendError.reauthenticationRequired {
                    self?.onReauthenticationRequired()
                } catch {
                    // Fall through: the refresh below restores the room's list.
                }
            }
            await self?.refreshActions(force: true)
        }
    }

    /// One line for a pinned message: its first line, spaces collapsed, cut at 120 characters.
    private static func pinSnippet(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 120 ? String(collapsed.prefix(120)) + "…" : collapsed
    }

    /// Re-reads the room's reply and reaction projection. Unforced calls (after arrivals) are throttled.
    // MARK: - Attachments

    private func attachment(_ attachmentId: String) -> RoomAttachment? {
        for message in timeline.messages.reversed() {
            if let match = message.attachments.first(where: { $0.attachmentId == attachmentId }) { return match }
        }
        return nil
    }

    /// Loads a small preview for an image that came into view: images up to 10 MB with a known size only.
    private func loadPreview(_ attachmentId: String) {
        guard previews[attachmentId] == nil, !previewsInFlight.contains(attachmentId), !failureIsTerminal,
              let attachment = attachment(attachmentId), attachment.kind == .image,
              let size = attachment.sizeBytes, size <= Int64(Self.previewLimitBytes) else { return }
        previewsInFlight.insert(attachmentId)
        let sessionId = self.sessionId
        let transport = self.transport
        let fetcher = self.attachmentFetcher
        Task { [weak self] in
            defer { self?.previewsInFlight.remove(attachmentId) }
            guard let link = try? await transport.attachmentDownload(sessionId: sessionId, attachmentId: attachmentId),
                  let data = try? await fetcher.data(from: link.url, maximumBytes: Self.previewLimitBytes),
                  let preview = AttachmentFiles.preview(from: data),
                  let self else { return }
            self.storePreview(preview, for: attachmentId)
        }
    }

    private func storePreview(_ data: Data, for attachmentId: String) {
        previews[attachmentId] = data
        previewOrder.removeAll { $0 == attachmentId }
        previewOrder.append(attachmentId)
        while previewOrder.count > Self.previewCacheSize {
            previews[previewOrder.removeFirst()] = nil
        }
        publish()
    }

    /// Downloads an attachment for full-size viewing. Each open asks the API for a fresh link (links expire in
    /// minutes and must not be reused), built from this room and the attachment id.
    func prepareAttachment(_ attachmentId: String) async throws -> URL {
        guard let attachment = attachment(attachmentId) else { throw AttachmentFetchError.failed }
        do {
            let link = try await transport.attachmentDownload(sessionId: sessionId, attachmentId: attachmentId)
            return try await attachmentFetcher.file(from: link.url, filename: attachment.filename)
        } catch let error as SessionTransportError {
            if error == .reauthenticationRequired || error == .notLoggedIn { onReauthenticationRequired() }
            throw error
        }
    }

    /// Re-reads the room's people (owners and admins only). A failed read keeps the list already loaded.
    func refreshMembers() async {
        guard readsMembers, sender != nil, !failureIsTerminal,
              let page = try? await transport.roomMembers(sessionId: sessionId) else { return }
        guard page.members != members else { return }
        members = page.members
        publish()
    }

    /// The member directory, read once per open: three restarts when membership changes mid-read, then nothing on
    /// any failure (the suggestions keep the people seen in the room).
    func readMemberDirectory() async {
        guard let directory, sender != nil, !readDirectory, !failureIsTerminal else { return }
        readDirectory = true
        for _ in 0..<4 {
            var people: [RoomDirectoryMember] = []
            var cursor: String?
            do {
                for _ in 0..<10 {
                    let page = try await directory.memberDirectory(sessionId: sessionId, cursor: cursor)
                    people += page.members
                    guard page.hasMore, let next = page.nextCursor else { break }
                    cursor = next
                }
                directoryPeople = people
                publish()
                return
            } catch RoomTicketExtrasError.directoryChanged {
                continue
            } catch {
                return
            }
        }
    }

    /// Re-reads the breakouts started from this room. A failed read keeps the cards already shown.
    func refreshBreakouts() async {
        guard !breakoutsRefreshInFlight, !failureIsTerminal else { return }
        breakoutsRefreshInFlight = true
        defer { breakoutsRefreshInFlight = false }
        guard let page = try? await transport.roomBreakouts(parentSessionId: sessionId, cursor: nil, limit: 50) else {
            return
        }
        for breakout in page.items { breakouts[breakout.childSessionId] = breakout }
        publish()
    }

    /// A breakout card arrived for a room this phone has not described yet: read its descriptor now.
    private func refreshBreakoutsIfNeeded(for messages: [RoomMessage]) {
        let unknown = messages.contains { message in
            guard let child = message.breakout?.childSessionId else { return false }
            return breakouts[child] == nil
        }
        guard unknown else { return }
        Task { [weak self] in await self?.refreshBreakouts() }
    }

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
        noteReplyAuthors(page.replies)
        // Replies not seen before go to a voice room listening in (none on the first read: those are history).
        let unseen = page.replies.filter { inlineReplies[$0.id] == nil }
        if hasReadReplies, !unseen.isEmpty {
            onNewReplies?(unseen)
            arrivalFeedback(unseen.map { ($0.authorId, $0.text) })
        }
        hasReadReplies = true
        // Replies stay as rows too (newest revision wins), the newest few thousand.
        for reply in page.replies {
            if let known = inlineReplies[reply.id], known.revision >= reply.revision { continue }
            inlineReplies[reply.id] = reply
        }
        for update in page.workingOn { workingOn[update.id] = update }
        workingOnStaleAfter = page.workingOnStaleAfter
        if workingOn.count > Self.inlineReplyLimit {
            let keep = workingOn.values.sorted { $0.createdAt > $1.createdAt }.prefix(Self.inlineReplyLimit)
            workingOn = Dictionary(keep.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        if inlineReplies.count > Self.inlineReplyLimit {
            let keep = inlineReplies.values.sorted { $0.createdAt > $1.createdAt }.prefix(Self.inlineReplyLimit)
            inlineReplies = Dictionary(keep.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        // The pinned list is the room's whole current list.
        pinned = page.pinned
        pinLimit = page.pinLimit
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
        // A reply shown in the room can answer a message further back than the loaded rows: load the room around
        // that message, and the thread opens on it once it is there.
        if timeline.index(ofSequence: sequenceId) == nil { focus(on: sequenceId) }
    }

    private func noteReplyAuthors(_ replies: [RoomReply]) {
        for reply in replies where !reply.authorId.isEmpty {
            let id = reply.authorId.lowercased()
            let date = ParsedSessionTimestamp(reply.createdAt).date
            if let known = replyAuthors[id]?.date, let date, known >= date { continue }
            let name = reply.isHuman ? String(reply.authorId.dropFirst("human-".count)) : reply.authorId
            replyAuthors[id] = (name, reply.isHuman, date)
        }
    }

    private func loadThread(_ sequenceId: Int64) async {
        do {
            let page = try await transport.roomActions(sessionId: sessionId, targetSequenceId: sequenceId, limit: 500)
            guard openThreadSequence == sequenceId else { return }
            threadReplies = page.replies.filter { $0.targetSequenceId == sequenceId }
            threadFailure = nil
            noteReplyAuthors(threadReplies)
        } catch {
            guard openThreadSequence == sequenceId else { return }
            threadFailure = "Replies could not be loaded. Pull to try again later."
        }
        threadLoading = false
        publish()
    }

    private func sendReply(_ raw: String, to sequenceId: Int64, toReply: String? = nil) {
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
            noteReplyFailedOutOfSight(sequenceId)
            return
        }
        pendingReplies.append(PendingReply(
            nonce: nonce, targetSequenceId: sequenceId, toReply: toReply, text: text, status: .sending
        ))
        publish()
        deliverReply("rp_" + nonce)
    }

    /// A reaction on a reply in a thread (the API takes the reply as `targetActionId`); the thread then re-reads.
    private func reactToReply(_ type: String, on replyId: String, in sequenceId: Int64) {
        guard let actionSender, canReact, RoomActionRequest.reactionTypes.contains(type) else { return }
        let sessionId = self.sessionId
        Task { [weak self] in
            guard let actor = await self?.resolvedActorRef() else { return }
            do {
                try await actionSender.sendAction(.reaction(
                    type, sessionId: sessionId, sequenceId: sequenceId, actor: actor, toReply: replyId
                ))
            } catch RoomSendError.reauthenticationRequired {
                self?.onReauthenticationRequired()
            } catch {
                // The re-read below shows the server's truth.
            }
            guard let self, self.openThreadSequence == sequenceId else { return }
            await self.loadThread(sequenceId)
        }
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
                sessionId: sessionId, sequenceId: item.targetSequenceId, toReply: item.toReply, text: item.text,
                actor: actor, nonce: item.nonce
            )
            do {
                try await actionSender.sendAction(request)
                guard let self else { return }
                self.onFeedback?(.sent)
                if self.openThreadSequence == item.targetSequenceId { await self.loadThread(item.targetSequenceId) }
                self.pendingReplies.removeAll { $0.clientId == clientId }
                self.publish()
                await self.refreshActions(force: true)
            } catch {
                guard let self else { return }
                let status = self.failedStatus(for: error)
                self.updateReply(clientId) { $0.status = status }
                self.noteReplyFailedOutOfSight(item.targetSequenceId)
            }
        }
    }

    /// A reply written from the room's box fails where its thread is not open: the room says so once.
    private func noteReplyFailedOutOfSight(_ sequenceId: Int64) {
        guard openThreadSequence != sequenceId else { return }
        notice = "Your reply did not send. Open its thread to try again."
        publish()
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
        // Sending from a window further back returns to the live room, where the message appears.
        jumpToLatest()
        keepLatestForTheJumpDown()
        pending.append(PendingSend(clientId: clientId, text: text, status: .sending))
        readerAtBottom = true
        unread.readerReachedBottom()
        publish()
        deliver(clientId)
    }

    /// Rows kept when the reader goes back down from up the history: the most a jump to the bottom crosses.
    static let rowsKeptForTheJumpDown = 60

    /// The live room holds more rows than a jump to the bottom should cross.
    private var historyTooLongToJumpDown: Bool {
        !timeline.hasMoreNewer && timeline.messages.count > Self.rowsKeptForTheJumpDown
    }

    /// Going to the bottom of a long loaded history (a send, or Jump to latest) made iOS measure every row in between on
    /// the main thread: Carter's freezes on 10-30 (07:39, 08:06, 13:43) all came after loading older messages and then
    /// sending, and the freeze recorder caught the last one "right after sendMessage (497 rows)", stuck 16.9 s. Before
    /// that jump, only the newest rows are kept; older ones load again when the reader scrolls up.
    private func keepLatestForTheJumpDown() {
        guard !readerAtBottom, historyTooLongToJumpDown else { return }
        let oldest = timeline.oldestSequence
        if timeline.keepNewest(Self.rowsKeptForTheJumpDown) {
            noteOldestTrimmed(was: oldest)
            CrashReporter.shared.note("kept the newest \(Self.rowsKeptForTheJumpDown) rows before jumping down")
        }
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
                self.onFeedback?(.sent)
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
        accountId = account.accountId
        ownLogin = account.login
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

    /// One page further back, when the reader scrolls to the top. (A message being sought loads as a window.)
    private func loadOlder() {
        guard hasLoadedInitial, !isLoadingOlder, !isLoadingWindow, timeline.hasMoreOlder,
              let before = nextBeforeSequence ?? timeline.oldestSequence else { return }
        isLoadingOlder = true
        let oldestAtRequest = timeline.oldestSequence
        publish()
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.transport.roomEventsBefore(
                    sessionId: self.sessionId,
                    beforeSequence: before,
                    limit: Self.pageSize
                )
                // If the oldest rows were let go meanwhile (a send or Jump from up the history), this page no longer
                // meets the rows kept and would leave a silent gap above them: it is dropped, and the next scroll up
                // asks again from the oldest row kept (warden, #253).
                if !self.failureIsTerminal, self.timeline.oldestSequence == oldestAtRequest {
                    self.apply(page, older: true)
                }
            } catch {
                self.record(error)
            }
            self.isLoadingOlder = false
            self.publish()
            // A link that arrived while this page was loading is pursued now.
            self.pursueFocus()
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
                pursueFocus()
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
        liveTasks.append(Task { [weak self] in await self?.runActionsPoll(current) })
    }

    /// Replies are actions, which the stream does not carry: read them every few seconds while the room is open, as
    /// the web does, so a reply shows in the room without waiting for the next message.
    private func runActionsPoll(_ current: UInt64) async {
        while !Task.isCancelled, current == generation {
            await sleep(readsRepliesOften ? Self.voiceActionsPollInterval : Self.actionsPollInterval)
            guard current == generation, !Task.isCancelled else { return }
            await refreshActions(force: readsRepliesOften)
        }
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
            await refreshBreakouts()
            await refreshMembers()
            pruneComposing()
        }
    }

    /// Applies one stream frame. Returns true when it carried a durable row.
    @discardableResult
    func handle(_ frame: RoomStreamFrame) -> Bool {
        switch frame {
        case .message(let message):
            connection = .live
            noteLiveArrivals([message])
            lastAppliedSequence = max(lastAppliedSequence, message.sequenceId)
            composing[message.authorId] = nil
            reconcilePending(with: [message])
            publish()
            pursueFocus()
            Task { [weak self] in await self?.refreshActions() }
            refreshBreakoutsIfNeeded(for: [message])
            return true
        case .edited(let message, let sequenceId):
            connection = .live
            lastAppliedSequence = max(lastAppliedSequence, sequenceId)
            if !timeline.applyEdits([message]).isEmpty { publish() }
            return true
        case .nonDisplayable(let sequenceId):
            connection = .live
            lastAppliedSequence = max(lastAppliedSequence, sequenceId)
            // A linked event that is not a chat row has now passed.
            pursueFocus()
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
        reconcilePending(with: page.messages)
        if older {
            // Over the capacity, an older page lets go of the newest rows, never of the page just loaded.
            timeline.merge(page.messages, trimming: .newest)
            noteNewestTrimmed()
            nextBeforeSequence = page.nextBeforeSequence ?? page.minSequence
            timeline.hasMoreOlder = page.hasMore && nextBeforeSequence != nil
        } else {
            noteLiveArrivals(page.messages)
        }
        // After the page's own rows, so an edit of a message in the same page lands on it (Carter, #55371: an edit
        // made elsewhere showed neither its text nor "edited" until the room was reopened).
        timeline.applyEdits(page.edits)
        if let maxSequence = page.maxSequence {
            lastAppliedSequence = max(lastAppliedSequence, maxSequence)
        }
    }

    /// Live messages join the rows when the rows are the live tail. Below a window further back they wait, counted
    /// as unread, until the reader pages down to them or jumps to the latest.
    private func noteLiveArrivals(_ messages: [RoomMessage]) {
        if timeline.hasMoreNewer {
            let fresh = messages.filter { $0.sequenceId > lastAppliedSequence }
            unread.noteArrivals(fresh, readerIsAtBottom: false, selfAuthorIds: ownAuthorIds)
            if !fresh.isEmpty { onLiveMessages?(fresh) }
            arrivalFeedback(fresh.filter { $0.kind == .message }.map { ($0.authorId, $0.text) })
        } else {
            let oldest = timeline.oldestSequence
            let result = timeline.merge(messages)
            noteOldestTrimmed(was: oldest)
            unread.noteArrivals(result.inserted, readerIsAtBottom: readerAtBottom, selfAuthorIds: ownAuthorIds)
            if !result.inserted.isEmpty { onLiveMessages?(result.inserted) }
            arrivalFeedback(result.inserted.filter { $0.kind == .message }.map { ($0.authorId, $0.text) })
        }
    }

    /// A message or reply from someone else arrived in the room on screen: a mention of you sounds the chime, anything
    /// else the soft pop. Your own (echoes of what you sent) make no sound; the send already did.
    private func arrivalFeedback(_ arrivals: [(authorId: String, text: String)]) {
        guard let onFeedback else { return }
        let others = arrivals.filter { !$0.authorId.isEmpty && !ownAuthorIds.contains($0.authorId.lowercased()) }
        guard !others.isEmpty else { return }
        let handles = state.ownMentionHandles
        let mentioned = !handles.isEmpty && others.contains { arrival in
            !Set(ChatReferences.mentionHandles(in: arrival.text)).isDisjoint(with: handles)
        }
        onFeedback(mentioned ? .mentioned : .received)
    }

    /// The owner's new name for the room (Carter, #55354), shown once the API has saved it. The room list picks it up
    /// from the room screen.
    private func rename(to raw: String) {
        guard canRename, let setter = sender as? any RoomTitleSetting else { return }
        guard let name = RoomTitle.cleaned(raw) else {
            notice = "That name can't be used. Use up to \(RoomTitle.maximumLength) characters, not starting with #, >, * or -."
            publish()
            return
        }
        guard name != title else { return }
        let sessionId = self.sessionId
        Task { [weak self] in
            do {
                let saved = try await setter.setTitle(sessionId: sessionId, title: name)
                guard let self else { return }
                self.title = saved
                self.publish()
            } catch RoomSendError.reauthenticationRequired {
                self?.onReauthenticationRequired()
            } catch RoomSendError.notAllowed {
                self?.notice = "Only the room's owner can rename it."
                self?.publish()
            } catch {
                self?.notice = "The new name did not save. Check your connection and try again."
                self?.publish()
            }
        }
    }

    /// Writes the next thread summary the room lacks, one at a time and off the main thread: the thread with the most
    /// replies first, and again only once it has grown. A phone without the on-device model writes none.
    private func summarizeNextThread(_ replies: [RoomChatMessageInput]) {
        guard let summarizer, summarizing == nil, !liveTasks.isEmpty else { return }
        var byThread: [Int64: [RoomChatMessageInput]] = [:]
        for reply in replies { byThread[reply.sequenceId, default: []].append(reply) }
        let due = byThread
            .filter { $0.value.count >= ThreadSummaryInput.minimumReplies && threadSummaries[$0.key]?.replies != $0.value.count }
            .max { $0.value.count < $1.value.count }
        guard let (parent, thread) = due else { return }
        summarizing = parent
        let lines = ThreadSummaryInput.lines(thread)
        let count = thread.count
        Task.detached(priority: .utility) { [weak self] in
            let text = await summarizer.summarize(thread: lines)
            await MainActor.run {
                guard let self else { return }
                self.summarizing = nil
                // Remembered even when there is none, so a phone without the model doesn't ask again for this count.
                self.threadSummaries[parent] = (count, text ?? "")
                if text != nil { self.publish() }
            }
        }
    }

    /// Your own message with new text (web `editSessionMessage`): saved against the revision you saw, then shown at
    /// once as edited; the room's own edit event agrees with it.
    private func editMessage(_ sequenceId: Int64, text raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let editor = sender as? any RoomMessageEditing,
              let message = timeline.messages.first(where: { $0.sequenceId == sequenceId }),
              ownAuthorIds.contains(message.authorId.lowercased()), !text.isEmpty, text != message.text else { return }
        let sessionId = self.sessionId
        Task { [weak self] in
            do {
                try await editor.editMessage(sessionId: sessionId, messageId: message.id, isReply: false, text: text,
                                             expectedRevision: message.revision)
                guard let self else { return }
                self.timeline.merge([RoomMessage(
                    id: message.id, sequenceId: message.sequenceId, kind: message.kind, authorId: message.authorId,
                    authorName: message.authorName, isHuman: message.isHuman, text: text, timestamp: message.timestamp,
                    replyToSequenceId: message.replyToSequenceId, clientMessageId: message.clientMessageId,
                    revision: message.revision + 1, isEdited: true, breakout: message.breakout,
                    attachments: message.attachments, eventType: message.eventType, channel: message.channel,
                    checkpointSummary: message.checkpointSummary
                )])
                self.publish()
            } catch RoomSendError.reauthenticationRequired {
                self?.onReauthenticationRequired()
            } catch {
                self?.notice = "That edit did not save. The message may have changed since; open it and try again."
                self?.publish()
            }
        }
    }

    /// Your own reply with new text, in its thread or shown in the room.
    private func editReply(_ replyId: String, in sequenceId: Int64, text raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let editor = sender as? any RoomMessageEditing,
              let reply = inlineReplies[replyId] ?? threadReplies.first(where: { $0.id == replyId }),
              ownAuthorIds.contains(reply.authorId.lowercased()), !text.isEmpty, text != reply.text else { return }
        let sessionId = self.sessionId
        Task { [weak self] in
            do {
                try await editor.editMessage(sessionId: sessionId, messageId: reply.id, isReply: true, text: text,
                                             expectedRevision: reply.revision)
                guard let self else { return }
                let edited = RoomReply(id: reply.id, targetSequenceId: reply.targetSequenceId,
                                       targetActionId: reply.targetActionId, authorId: reply.authorId, text: text,
                                       createdAt: reply.createdAt, revision: reply.revision + 1, isEdited: true)
                if self.inlineReplies[reply.id] != nil { self.inlineReplies[reply.id] = edited }
                if let index = self.threadReplies.firstIndex(where: { $0.id == reply.id }) { self.threadReplies[index] = edited }
                self.publish()
            } catch RoomSendError.reauthenticationRequired {
                self?.onReauthenticationRequired()
            } catch {
                self?.notice = "That edit did not save. The reply may have changed since; open it and try again."
                self?.publish()
            }
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
        let work = workLines()
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
                kind: Self.kind(of: message),
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
                },
                attachments: message.attachments.map(Self.chip),
                views: message.eventType == "session_message"
                    ? views(of: message.id, at: message.revision, author: viewAuthor(message.authorId, isHuman: message.isHuman))
                    : nil,
                work: work[message.sequenceId] ?? [],
                isVoiceTurn: message.channel == "voice",
                checkpointSummary: message.checkpointSummary
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
                        isEdited: reply.isEdited,
                        views: views(of: reply.id, at: reply.revision, author: viewAuthor(reply.authorId, isHuman: reply.isHuman)),
                        authorHandle: reply.isHuman ? String(reply.authorId.dropFirst("human-".count)) : reply.authorId,
                        parentReplyId: reply.targetActionId
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
        let replyInputs = inlineReplyInputs()
        state = RoomChatPresentationState(
            sessionId: sessionId,
            title: title,
            messages: inputs,
            ownAuthorIds: ownAuthorIds,
            unreadDividerSequence: unread.dividerSequence,
            unreadCount: unread.unreadCount,
            isLoadingInitial: isLoadingInitial,
            notice: notice,
            canLoadOlder: hasLoadedInitial && timeline.hasMoreOlder,
            isLoadingOlder: isLoadingOlder || isLoadingWindow,
            canLoadNewer: hasLoadedInitial && timeline.hasMoreNewer,
            isLoadingNewer: isLoadingNewer,
            jumpDownKeepsLatest: hasLoadedInitial && historyTooLongToJumpDown,
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
            focusFallbackCount: focusFallbackCount,
            focusSequenceId: focusTarget,
            mentionCandidates: mentionCandidates(),
            breakouts: breakouts.mapValues(Self.card),
            attachmentPreviews: previews,
            presence: presenceState,
            pinned: pinned.map { pin in
                let message = timeline.messages.first { $0.sequenceId == pin.targetSequenceId }
                let by = pin.pinnedBy.lowercased().hasPrefix("human-") ? String(pin.pinnedBy.dropFirst("human-".count)) : pin.pinnedBy
                return RoomChatPinned(
                    sequenceId: pin.targetSequenceId,
                    snippet: message.map { Self.pinSnippet($0.text) } ?? "Message #\(pin.targetSequenceId)",
                    pinnedBy: by
                )
            },
            canPin: canPin,
            pinLimit: pinLimit,
            canRename: canRename,
            canInvite: canInvite,
            threadSummaries: threadSummaries.compactMapValues { $0.text.isEmpty ? nil : $0.text },
            replies: replyInputs,
            expandedRepeats: expandedRepeats
        )
        summarizeNextThread(replyInputs)
    }

    /// Each message's "working on" lines, oldest first, with whether each is still live (not done, and newer than
    /// the room's staleness window). Only an agent's newest line per message is live.
    private func workLines() -> [Int64: [RoomChatWorkLine]] {
        let cutoff = now().addingTimeInterval(-workingOnStaleAfter)
        var byMessage: [Int64: [RoomWorkingOn]] = [:]
        for update in workingOn.values { byMessage[update.targetSequenceId, default: []].append(update) }
        return byMessage.mapValues { updates in
            let ordered = updates.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            let newestByActor = Dictionary(ordered.map { ($0.actorId, $0.id) }, uniquingKeysWith: { _, last in last })
            return ordered.map { update in
                let at = ParsedSessionTimestamp(update.createdAt).date
                return RoomChatWorkLine(
                    id: update.id,
                    actorId: update.actorId,
                    text: update.note,
                    at: at,
                    isLive: !update.isDone && newestByActor[update.actorId] == update.id && (at.map { $0 > cutoff } ?? false)
                )
            }
        }
    }

    /// Each agent's newest "working on" line in the room, for the Flight record.
    func latestWork() -> [String: RoomChatWorkLine] {
        var latest: [String: RoomWorkingOn] = [:]
        for update in workingOn.values where (latest[update.actorId]?.createdAt ?? "") < update.createdAt {
            latest[update.actorId] = update
        }
        return latest.mapValues { update in
            RoomChatWorkLine(id: update.id, actorId: update.actorId, text: update.note,
                             at: ParsedSessionTimestamp(update.createdAt).date, isLive: !update.isDone)
        }
    }

    /// Threaded replies shown in the room at their own time, as the web shows them (most agent and box output is
    /// replies). Only within the loaded stretch of the room: never before its oldest row, and, below a window further
    /// back, never after its newest.
    private func inlineReplyInputs() -> [RoomChatMessageInput] {
        guard !inlineReplies.isEmpty, let first = timeline.messages.first else { return [] }
        let floor = dateCache[first.id] ?? ParsedSessionTimestamp(first.timestamp).date
        let ceiling: Date? = timeline.hasMoreNewer
            ? timeline.messages.last.flatMap { dateCache[$0.id] ?? ParsedSessionTimestamp($0.timestamp).date }
            : nil
        return inlineReplies.values.compactMap { reply in
            guard let date = ParsedSessionTimestamp(reply.createdAt).date else { return nil }
            if let floor, date < floor { return nil }
            if let ceiling, date > ceiling { return nil }
            return RoomChatMessageInput(
                id: "reply-\(reply.id)",
                sequenceId: reply.targetSequenceId,
                kind: .message,
                authorId: reply.authorId,
                authorName: reply.isHuman ? String(reply.authorId.dropFirst("human-".count)) : reply.authorId,
                isHuman: reply.isHuman,
                text: reply.text,
                timestamp: reply.createdAt,
                replyToSequenceId: reply.targetSequenceId,
                isEdited: reply.isEdited,
                date: date,
                inlineReplyId: reply.id
            )
        }
    }

    // MARK: - Read receipts and presence

    /// The read line and ticks for a message or reply, once the room has read its views at the revision shown.
    private func views(of id: String, at revision: Int64, author: String?) -> RoomChatViews? {
        guard let tracker = receiptsTracker, let summary = tracker.summaries[id.lowercased()],
              summary.revision == revision else { return nil }
        return RoomChatViews.make(
            viewedCount: summary.viewedCount,
            viewers: summary.viewers.map {
                RoomChatViews.Viewer(isHuman: $0.isHuman, actorId: $0.actorId, viewedAt: ParsedSessionTimestamp($0.viewedAt).date)
            },
            selfViewed: summary.selfViewed,
            authorActorId: author,
            ownAccountId: accountId,
            ownName: ownLogin,
            names: tracker.names,
            time: { $0.formatted(date: .omitted, time: .shortened) }
        )
    }

    /// The author as viewers carry them: your account id for your own row, the agent id for an agent's. Another
    /// person's account id is not known here, so their own view is not left out of the ticks.
    private func viewAuthor(_ authorId: String, isHuman: Bool) -> String? {
        if ownAuthorIds.contains(authorId.lowercased()) { return accountId }
        return isHuman ? nil : authorId
    }

    private var presenceState: RoomChatPresence? {
        guard let presence = receiptsTracker?.presence else { return nil }
        return RoomChatPresence.make(
            isAvailable: presence.isAvailable,
            humansOnline: presence.humansOnline,
            people: presence.participants.map {
                RoomChatPresence.Person(
                    id: $0.id,
                    name: $0.isHuman ? ($0.displayName ?? RoomChatViews.unnamedPerson) : $0.id,
                    isHuman: $0.isHuman,
                    isIdle: $0.isIdle
                )
            }
        )
    }

    /// Everyone in the room for @-mention suggestions: the people in its member directory, the agents here now, and
    /// everyone who posted in the loaded history, newest activity per person.
    private func mentionCandidates() -> [MentionCandidate] {
        guard sender != nil else { return [] }
        var latest: [String: (name: String, isHuman: Bool, date: Date?)] = [:]
        // People in the room's directory (every member can read it), under their login: the handle that notifies.
        for person in directoryPeople {
            guard let login = person.githubLogin?.lowercased(), !login.isEmpty,
                  !ownAuthorIds.contains("human-\(login)") else { continue }
            latest["human-\(login)"] = (person.name, true, nil)
        }
        // Agents here now, whether or not they posted in what is loaded.
        for person in receiptsTracker?.presence?.participants ?? [] where !person.isHuman && !person.id.isEmpty {
            let id = person.id.lowercased()
            if latest[id] == nil, !ownAuthorIds.contains(id) { latest[id] = (person.id, false, nil) }
        }
        // People in the room who have not posted yet (owners and admins see the member list), under their login.
        for member in members where !ownAuthorIds.contains("human-\(member.login)") {
            latest["human-\(member.login)"] = (member.displayName, true, member.lastActiveAt.flatMap { ParsedSessionTimestamp($0).date })
        }
        for message in timeline.messages
        where message.kind == .message && !message.authorId.isEmpty && !ownAuthorIds.contains(message.authorId.lowercased()) {
            let date = dateCache[message.id]
            latest[message.authorId.lowercased()] = (message.authorName, message.isHuman, date)
        }
        // Who answered in threads, as of their newest reply or post, whichever is later.
        for (id, author) in replyAuthors where !ownAuthorIds.contains(id) {
            let known = latest[id]
            if let knownDate = known?.date, let date = author.date, knownDate >= date { continue }
            latest[id] = (known?.name ?? author.name, author.isHuman, author.date ?? known?.date)
        }
        let ownHandles = Set(ownAuthorIds.map { $0.hasPrefix("human-") ? String($0.dropFirst("human-".count)) : $0 })
        return MentionSuggester.candidates(
            authors: latest.map { (id: $0.key, name: $0.value.name, isHuman: $0.value.isHuman, lastActive: $0.value.date) },
            ownHandles: ownHandles,
            now: now()
        )
    }

    private static func kind(of message: RoomMessage) -> RoomChatMessageInput.Kind {
        switch message.kind {
        case .message: return .message
        case .checkpoint: return .checkpoint
        case .memberJoined: return .memberJoined
        case .breakoutOpened:
            return .breakoutOpened(childSessionId: message.breakout?.childSessionId ?? "")
        case .breakoutOutcome:
            guard let breakout = message.breakout, let outcome = breakout.outcome else { return .message }
            return .breakoutOutcome(RoomBreakoutOutcomeCard(
                childSessionId: breakout.childSessionId,
                text: outcome.text,
                authorName: principalName(outcome.authorId.isEmpty ? message.authorId : outcome.authorId),
                acknowledgements: outcome.acknowledgements.map { ack in
                    RoomBreakoutOutcomeCard.Acknowledgement(
                        name: principalName(ack.principalId),
                        state: {
                            switch ack.state {
                            case .ack: return .ack
                            case .disagree: return .disagree
                            case .missing: return .missing
                            }
                        }()
                    )
                }
            ))
        }
    }

    /// People are shown by login without the server's `human-` prefix; agents by their id.
    private static func principalName(_ principalId: String) -> String {
        principalId.hasPrefix("human-") ? String(principalId.dropFirst("human-".count)) : principalId
    }

    private static func chip(_ attachment: RoomAttachment) -> RoomAttachmentChip {
        let kind: RoomAttachmentChip.Kind
        switch attachment.kind {
        case .markdown: kind = .markdown
        case .json: kind = .json
        case .image: kind = .image
        case .pdf: kind = .pdf
        case .other: kind = .other
        }
        return RoomAttachmentChip(
            attachmentId: attachment.attachmentId,
            filename: attachment.filename,
            kind: kind,
            sizeBytes: attachment.sizeBytes,
            summary: attachment.summary,
            processingStatus: attachment.summaryStatus
        )
    }

    private static func card(_ breakout: RoomBreakout) -> RoomBreakoutCard {
        RoomBreakoutCard(
            childSessionId: breakout.childSessionId,
            title: breakout.title,
            participantNames: breakout.participants?.map { $0.name ?? principalName($0.id) },
            messageCount: breakout.messageCount,
            unreadCount: breakout.unreadCount,
            isLocked: breakout.isLocked,
            isOpen: breakout.isOpen,
            canRead: breakout.canRead,
            canPost: breakout.canPost,
            createdDate: ParsedSessionTimestamp(breakout.createdAt).date
        )
    }
}
