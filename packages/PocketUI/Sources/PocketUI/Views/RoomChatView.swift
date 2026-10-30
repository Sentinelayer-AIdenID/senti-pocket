#if canImport(SwiftUI)
import SwiftUI
import PocketContracts
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The live room: the same conversation the web shows, newest at the bottom, with jump-to-latest, an unread
/// divider and older history loaded on demand.
public struct RoomChatView: View {
    private let state: RoomChatPresentationState
    private let send: (RoomChatIntent) -> Void
    /// What is being read aloud (a `RoomReadAloud` id): its row shows a Stop button.
    private let readingAloudId: String?

    /// The reply being typed in each thread, kept while the room is open: closing the sheet does not lose it.
    @State private var threadDrafts: [Int64: String] = [:]
    @State private var readerAtBottom = true
    @State private var didInitialScroll = false
    /// A new list each time the room is put back at its newest rows (see `reopenAtLatest()`).
    @State private var listEpoch = 0
    /// A new list starts at its top, where "Load earlier messages" shows: until its first scroll down has landed, that
    /// is not the reader asking for older history.
    @State private var holdsOlderLoads = false
    @State private var anchorBeforeOlderLoad: String?
    /// A message the reader was taken to (a link, notification, search result or pin). It stays in place through
    /// pages loading above or below it and messages arriving, until the reader scrolls.
    @State private var heldAnchor: String?
    /// A checkpoint opened from its row: read it, listen to it.
    @State private var openCheckpoint: RoomChatMessageRow?
    /// A thread summary opened whole, and what reads it aloud.
    @State private var openSummary: OpenThreadSummary?
    /// Your own message being edited.
    @State private var editingRow: RoomChatMessageRow?
    /// A long message opened in full.
    @State private var longRow: RoomChatMessageRow?
    /// "Jump to latest" from a window further back: scroll to the bottom once the live room has loaded.
    @State private var scrollsToLatestWhenLoaded = false
    @State private var highlightedRowId: String?
    /// Background lines opened in place.
    @State private var expandedQuiet: Set<String> = []
    @State private var showsPresence = false
    /// The owner is renaming the room, and the name as typed.
    @State private var renaming = false
    @State private var renameDraft = ""
    /// A failed message the reader chose to edit: its text goes back into the composer.
    @State private var restoredDraft: RoomComposerRestore?

    /// What the composer's "+" offers besides mentioning: filing a ticket and searching, where the room has them.
    private let composerActions: RoomComposerActions

    /// Everyone who came to the room, for its people list.
    private let roster: RoomRoster

    public init(
        state: RoomChatPresentationState,
        readingAloudId: String? = nil,
        composerActions: RoomComposerActions = RoomComposerActions(),
        roster: RoomRoster = .empty,
        send: @escaping (RoomChatIntent) -> Void
    ) {
        self.state = state
        self.readingAloudId = readingAloudId
        self.composerActions = composerActions
        self.roster = roster
        self.send = send
    }

    /// The message the room's box is answering (swipe to reply), sent to its thread.
    @State private var replyTarget: RoomChatMessageRow?

    private func threadDraft(_ sequenceId: Int64) -> Binding<String> {
        Binding(get: { threadDrafts[sequenceId] ?? "" }, set: { threadDrafts[sequenceId] = $0 })
    }

    public var body: some View {
        Group {
            if state.isEmpty {
                emptyOrFailure
            } else {
                timeline
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RoomComposerBar(
                composer: state.composer,
                mentionCandidates: state.mentionCandidates,
                restored: restoredDraft,
                actions: composerActions,
                replying: replyTarget,
                onCancelReply: { replyTarget = nil },
                onIntent: send,
                draftKey: RoomComposerDraft.savedKey(sessionId: state.sessionId)
            ) { text in
                if let target = replyTarget {
                    send(target.replyIntent(text))
                    replyTarget = nil
                } else {
                    send(.sendMessage(text: text))
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { state.thread != nil },
            set: { presented in if !presented { send(.closeThread) } }
        )) {
            if let thread = state.thread {
                RoomThreadSheet(
                    thread: thread,
                    ownHandles: state.ownMentionHandles,
                    readingAloudId: readingAloudId,
                    mentionCandidates: state.mentionCandidates,
                    canReact: state.canReact,
                    actions: composerActions,
                    send: send,
                    draft: threadDraft(thread.parent.sequenceId)
                )
            }
        }
        .sheet(item: $openCheckpoint) { row in
            CheckpointSheet(row: row, send: send)
        }
        .sheet(item: $openSummary) { open in
            ThreadSummarySheet(summary: open.summary, isReading: readingAloudId == open.id) {
                if readingAloudId == open.id {
                    send(.stopReadingAloud)
                } else {
                    send(.readAloud(id: open.id, text: open.summary))
                }
            }
        }
        .sheet(item: $longRow) { row in
            LongMessageSheet(row: row, ownHandles: state.ownMentionHandles, send: send)
        }
        .sheet(item: $editingRow) { row in
            MessageEditSheet(original: row.text) { text in
                if let replyId = row.inlineReplyId {
                    send(.editReply(sequenceId: row.sequenceId, replyId: replyId, text: text))
                } else {
                    send(.editMessage(sequenceId: row.sequenceId, text: text))
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let notice = state.notice {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(PocketPalette.warning)
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.textPrimary)
                    Spacer(minLength: 4)
                    Button {
                        send(.dismissNotice)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("pocket.room.notice")
            }
        }
        .navigationTitle(state.title)
        .navigationBarTitleDisplayModeInlineIfAvailable()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // While the floating avatars say who is here the pill is its dot alone, so the title keeps its room;
                // the word is still read aloud, and spelled out in the "who is here" sheet.
                RoomConnectionPill(connection: state.connection, compact: state.presence != nil)
            }
            // The owner taps the room's name to rename it (Carter, #55354) or invite people; for anyone who can do
            // neither it is the plain title.
            if state.canRename || state.canInvite {
                ToolbarItem(placement: .principal) {
                    Menu {
                        if state.canRename {
                            Button {
                                renameDraft = state.title
                                renaming = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .accessibilityIdentifier("pocket.room.rename")
                        }
                        if state.canInvite {
                            Button {
                                send(.openInvite)
                            } label: {
                                Label("Invite people", systemImage: "person.badge.plus")
                            }
                            .accessibilityIdentifier("pocket.room.invite")
                        }
                    } label: {
                        Text(state.title)
                            .font(.headline)
                            .foregroundStyle(PocketPalette.textPrimary)
                            .lineLimit(1)
                    }
                    // The system's own chevron marks the menu; a second one of ours doubled it on iOS 26.
                    .menuIndicator(.visible)
                    .accessibilityLabel(state.title)
                    .accessibilityHint("Opens the room's menu")
                    .accessibilityIdentifier("pocket.room.title")
                }
            }
        }
        .alert("Rename this room", isPresented: $renaming) {
            TextField("Room name", text: $renameDraft)
                .accessibilityIdentifier("pocket.room.rename.field")
            Button("Save") { send(.renameRoom(title: renameDraft)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone in the room sees the new name, here and on the web. Up to \(RoomTitle.maximumLength) characters.")
        }
        .sheet(isPresented: $showsPresence) {
            RoomPresenceSheet(
                presence: state.presence,
                connection: state.connection,
                roster: roster,
                onInvite: state.canInvite ? {
                    showsPresence = false
                    // After this sheet has gone, so the invite sheet can come up.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { send(.openInvite) }
                } : nil
            )
            .onAppear { send(.peopleOpened) }
        }
        // A container, so the composer, the send button and every row keep their own identifiers and labels
        // (without it the screen's identifier replaced theirs).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.room.screen")
        .pocketCanvas()
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    olderHistoryHeader
                    ForEach(state.rows) { row in
                        rowView(row, proxy: proxy)
                            .id(row.id)
                    }
                    ForEach(state.pending) { pending in
                        RoomPendingRowView(
                            row: pending,
                            recovery: RoomPendingRecovery(canPost: state.composer.canPost),
                            onRetry: { send(.retrySend(clientId: pending.clientId)) },
                            onDiscard: { send(.discardSend(clientId: pending.clientId)) },
                            onEdit: {
                                restoredDraft = RoomComposerRestore(text: pending.text)
                                send(.discardSend(clientId: pending.clientId))
                            }
                        )
                        .id("pending:\(pending.clientId)")
                    }
                    newerHistoryFooter
                    if !state.composingAgents.isEmpty, !state.canLoadNewer {
                        RoomComposingLine(agents: state.composingAgents)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomId)
                        // The bottom of a window further back is not the live room's bottom.
                        .onAppear { if !state.canLoadNewer, heldAnchor == nil { setReaderAtBottom(true) } }
                        .onDisappear { setReaderAtBottom(false) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            // Dragging the messages lowers the keyboard with the finger, as in Messages.
            .scrollDismissesKeyboard(.interactively)
            // The reader scrolling lets go of a message they were taken to.
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
                if heldAnchor != nil { heldAnchor = nil }
            })
            .overlay(alignment: .bottomTrailing) {
                if !readerAtBottom || state.canLoadNewer {
                    jumpToLatestButton(proxy: proxy)
                }
            }
            // Who is here floats at the top center, under the top bar and the pins, over the messages (Carter, #55354,
            // #55424).
            .overlay(alignment: .top) {
                if let presence = state.presence {
                    RoomPeopleAvatars(presence: presence, models: roster.modelsById,
                                      signals: state.agentSignals(now: Date()),
                                      working: state.agentsWorking(now: Date()),
                                      boxes: roster.members.filter { $0.kind == .box && $0.status != .ended }.map(\.name)) {
                        showsPresence = true
                    }
                        .padding(.top, 4)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !state.pinned.isEmpty {
                    RoomPinnedStrip(
                        pinned: state.pinned,
                        limit: state.pinLimit,
                        canUnpin: state.canPin,
                        onOpen: { jump(to: $0, proxy: proxy) },
                        onUnpin: { send(.setPinned(sequenceId: $0, isPinned: false)) }
                    )
                }
            }
            .onAppear {
                scrollToInitialPosition(proxy)
                focus(onRow: focusRowId, proxy: proxy)
            }
            // The new value carries what the action needs: an `onChange(of:perform:)` action can still see the
            // view's previous `state`, where a focus set while the room is open is not there yet.
            .onChange(of: focusRowId) { rowId in focus(onRow: rowId, proxy: proxy) }
            .onChange(of: state.focusFallbackCount) { _ in
                heldAnchor = nil
                showLatest(proxy)
            }
            // A message the reader was taken to stays put while rows change around it. Otherwise, at the bottom,
            // stay at the bottom when rows above change size: an image preview loading, reactions or a reply count
            // arriving. A reader scrolled up is never moved.
            .onChange(of: state.rows) { _ in
                if let heldAnchor {
                    proxy.scrollTo(heldAnchor, anchor: .center)
                } else {
                    keepAtBottomIfThere(proxy)
                }
            }
            .onChange(of: state.attachmentPreviews.count) { _ in
                if let heldAnchor { proxy.scrollTo(heldAnchor, anchor: .center) } else { keepAtBottomIfThere(proxy) }
            }
            .onChange(of: state.lastMessageId) { _ in
                if !didInitialScroll {
                    scrollToInitialPosition(proxy)
                } else if readerAtBottom, heldAnchor == nil {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: state.pending.count) { count in
                // Sending always brings you to the bottom, where your message appears. At the bottom, a short scroll
                // on the next turn of the run loop. From up the history, the room is put back at its newest rows as a
                // new list, the way it opens, instead of scrolling or trimming under the reader.
                guard count > 0 else { return }
                if readerAtBottom {
                    heldAnchor = nil
                    DispatchQueue.main.async { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                } else {
                    reopenAtLatest()
                }
            }
            .onChange(of: state.firstMessageId) { _ in
                // Older rows were prepended: keep the row the reader was looking at in place.
                if let heldAnchor {
                    proxy.scrollTo(heldAnchor, anchor: .center)
                    anchorBeforeOlderLoad = nil
                } else if let anchor = anchorBeforeOlderLoad {
                    proxy.scrollTo(anchor, anchor: .top)
                    anchorBeforeOlderLoad = nil
                }
            }
            .onChange(of: state.canLoadNewer) { canLoadNewer in
                // Back in the live room after "Jump to latest": go to its newest message.
                guard !canLoadNewer, scrollsToLatestWhenLoaded else { return }
                scrollsToLatestWhenLoaded = false
                setReaderAtBottom(true)
                DispatchQueue.main.async { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            }
            // A list starts at its newest rows, not at its top (iOS 18 and later; before that, the first scroll takes
            // it there). Only where it starts: rows arriving or loading later move nothing.
            .modifier(StartsAtBottom())
            // The whole list, its handlers with it, so a new one opens as the room does.
            .id(listEpoch)
        }
    }

    /// Puts the room back at its newest rows as a new list, the way a room opens (which has never frozen), rather than
    /// scrolling down to them or trimming the rows under the reader. Carter's 10-30 freezes all began with the room
    /// moving a long way at a send; the last (14:53) came right after the trim to the newest rows, with the scroll still
    /// to come.
    private func reopenAtLatest() {
        heldAnchor = nil
        anchorBeforeOlderLoad = nil
        didInitialScroll = false
        holdsOlderLoads = true
        listEpoch += 1
    }

    @ViewBuilder
    private var olderHistoryHeader: some View {
        if state.isLoadingOlder {
            ProgressView("Loading earlier messages")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else if state.canLoadOlder {
            Button("Load earlier messages") { loadOlder() }
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .onAppear { if didInitialScroll, !holdsOlderLoads { loadOlder() } }
                .accessibilityIdentifier("pocket.room.loadOlder")
        } else {
            Text("Start of the room")
                .font(.footnote)
                .foregroundStyle(PocketPalette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func rowView(_ row: RoomChatRow, proxy: ScrollViewProxy) -> some View {
        switch row {
        case .dayHeader(_, let label):
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(PocketPalette.inset, in: Capsule())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        case .unreadDivider:
            HStack(spacing: 8) {
                Rectangle().fill(PocketPalette.danger).frame(height: 1)
                Text("New messages")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PocketPalette.danger)
                Rectangle().fill(PocketPalette.danger).frame(height: 1)
            }
            .padding(.vertical, 8)
            .accessibilityIdentifier("pocket.room.unreadDivider")
        case .message(let message):
            if message.startsTurn {
                RoomTurnBreak(date: message.date)
            }
            RoomMessageRowView(
                row: message,
                ownHandles: state.ownMentionHandles,
                isHighlighted: highlightedRowId == row.id,
                canReact: state.canReact,
                canReply: state.composer.canPost,
                canPin: state.canPin,
                isPinned: state.isPinned(message),
                pinsFull: state.pinned.count >= state.pinLimit,
                breakouts: state.breakouts,
                attachmentPreviews: state.attachmentPreviews,
                isReadingAloud: readingAloudId == message.readAloudId,
                isExpanded: expandedQuiet.contains(message.id),
                threadSummary: message.summaryThreadId.flatMap { state.threadSummaries[$0] },
                isReadingSummary: message.summaryReadAloudId.map { readingAloudId == $0 } ?? false,
                onOpenSummary: { summary, id in openSummary = OpenThreadSummary(id: id, summary: summary) },
                onOpenReplyTarget: { jump(to: $0, proxy: proxy) },
                onOpenCheckpoint: { openCheckpoint = $0 },
                onEdit: { editingRow = $0 },
                onToggleQuiet: {
                    if expandedQuiet.contains(message.id) {
                        expandedQuiet.remove(message.id)
                    } else {
                        expandedQuiet.insert(message.id)
                    }
                },
                onOpenLong: { longRow = $0 },
                onReply: { replyTarget = $0 },
                send: send
            )
            .onAppear { send(.messageOnScreen(id: message.id, isOnScreen: true)) }
            .onDisappear { send(.messageOnScreen(id: message.id, isOnScreen: false)) }
        }
    }

    /// Below a window further back: the next newer page loads when this comes into view (its identity follows the
    /// newest row, so it asks again after each page while it stays in view).
    @ViewBuilder
    private var newerHistoryFooter: some View {
        if state.canLoadNewer {
            Group {
                if state.isLoadingNewer {
                    ProgressView("Loading newer messages")
                } else {
                    Button("Load newer messages") { send(.loadNewer) }
                        .font(.footnote.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .id("newer-history:\(state.lastMessageId ?? "")")
            .onAppear { send(.loadNewer) }
        }
    }

    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
            heldAnchor = nil
            if state.canLoadNewer {
                // A window further back: load the live room first, then go to its newest message.
                scrollsToLatestWhenLoaded = true
                send(.jumpToLatest)
                return
            }
            // From up a long history, measuring every row on the way down froze the app (10-30): the room keeps
            // only its newest rows, then the jump is at once.
            if state.jumpDownKeepsLatest {
                send(.keepLatestForJumpDown)
                reopenAtLatest()
                return
            }
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                if state.unreadCount > 0 {
                    Text("\(state.unreadCount) new")
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .pocketFloating(in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(16)
        .accessibilityLabel(state.unreadCount > 0 ? "Jump to latest, \(state.unreadCount) new" : "Jump to latest")
        .accessibilityIdentifier("pocket.room.jumpToLatest")
    }

    private var emptyOrFailure: some View {
        VStack(spacing: 14) {
            if state.isLoadingInitial && state.failure == nil {
                ProgressView("Loading the room")
            } else {
                Image(systemName: state.failure == nil ? "bubble.left.and.bubble.right" : "exclamationmark.triangle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(state.failure == nil ? PocketPalette.accent : PocketPalette.warning)
                    .accessibilityHidden(true)
                Text(state.failure?.title ?? "No messages yet")
                    .font(.title3.bold())
                Text(state.failure?.detail ?? "Messages posted in this room will appear here as they arrive.")
                    .foregroundStyle(PocketPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if state.failure != nil {
                    Button("Try again") { send(.retry) }
                        .buttonStyle(.borderedProminent)
                        .tint(PocketPalette.accent)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadOlder() {
        guard state.canLoadOlder, !state.isLoadingOlder else { return }
        anchorBeforeOlderLoad = state.firstMessageId.map { "msg:\($0)" }
        send(.loadOlder)
    }

    private func scrollToInitialPosition(_ proxy: ScrollViewProxy) {
        guard !didInitialScroll, !state.isEmpty else { return }
        // A room opened at a message (a link or notification) is positioned by `focus(onRow:proxy:)` instead.
        guard state.focusSequenceId == nil else { return }
        didInitialScroll = true
        // Say where the reader is now: the bottom marker may never render when the first scroll lands elsewhere,
        // and a reader who is not at the bottom must not be pulled down by the next message.
        let opensAtDivider = state.rows.contains(.unreadDivider)
        setReaderAtBottom(!opensAtDivider)
        DispatchQueue.main.async {
            if opensAtDivider {
                proxy.scrollTo(RoomChatRow.unreadDivider.id, anchor: .top)
            } else {
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
            }
            // The list has left its top: from now on the header showing means the reader scrolled up to it.
            DispatchQueue.main.async { holdsOlderLoads = false }
        }
    }

    /// The reader's place, kept in step with the coordinator (which counts arrivals as unread while away).
    private func setReaderAtBottom(_ atBottom: Bool) {
        guard readerAtBottom != atBottom else { return }
        readerAtBottom = atBottom
        send(.readerAtBottom(atBottom))
    }

    /// A linked message could not be loaded: open as the room normally opens (the latest messages, or the unread
    /// divider), or, when already open, go to the latest messages, instead of staying in older history.
    private func showLatest(_ proxy: ScrollViewProxy) {
        guard didInitialScroll else {
            scrollToInitialPosition(proxy)
            return
        }
        setReaderAtBottom(true)
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
        }
    }

    /// The focused message's row once it is loaded; nil when nothing is focused or it has not loaded yet.
    private var focusRowId: String? {
        guard let focus = state.focusSequenceId else { return nil }
        return state.messageRow(for: focus)?.id
    }

    /// Brings the focused message's row into view, highlights it, and reports it handled.
    private func focus(onRow rowId: String?, proxy: ScrollViewProxy) {
        guard let rowId else { return }
        didInitialScroll = true
        // Reading a message elsewhere in the room: new messages must not pull the view down, and pages loading
        // around it must not move it, until the reader scrolls.
        setReaderAtBottom(false)
        heldAnchor = rowId
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(rowId, anchor: .center) }
            highlightedRowId = rowId
            send(.focusHandled)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if highlightedRowId == rowId { highlightedRowId = nil }
            }
        }
    }

    private func jump(to sequenceId: Int64, proxy: ScrollViewProxy) {
        guard let target = state.messageRow(for: sequenceId) else {
            // Not loaded: the room loads the window around it and the focus brings it into view.
            send(.jumpToMessage(sequenceId: sequenceId))
            return
        }
        setReaderAtBottom(false)
        heldAnchor = target.id
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(target.id, anchor: .center)
        }
        highlightedRowId = target.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if highlightedRowId == target.id { highlightedRowId = nil }
        }
    }

    /// Decided now, before layout can scroll the bottom marker out of view; scrolled after layout settles.
    private func keepAtBottomIfThere(_ proxy: ScrollViewProxy) {
        guard didInitialScroll, readerAtBottom, heldAnchor == nil, !state.canLoadNewer,
              state.focusSequenceId == nil else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomId, anchor: .bottom)
        }
    }

    private static let bottomId = "room-bottom"
}

/// A thread summary opened whole: its read-aloud id (so the sheet shows Stop while it is read) and its text.
private struct OpenThreadSummary: Identifiable {
    let id: String
    let summary: String
}

/// A scroll view that starts at its bottom, where the iOS version can say so.
private struct StartsAtBottom: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content
        }
    }
}

private struct RoomMessageRowView: View {
    let row: RoomChatMessageRow
    let ownHandles: Set<String>
    let isHighlighted: Bool
    var canReact = false
    var canReply = false
    var canPin = false
    var isPinned = false
    /// The room holds as many pins as it can: Pin waits until one is unpinned.
    var pinsFull = false
    var breakouts: [String: RoomBreakoutCard] = [:]
    var attachmentPreviews: [String: Data] = [:]
    var isReadingAloud = false
    /// A background line opened in place.
    var isExpanded = false
    /// What happened in this row's thread, summarized on the phone, for a box line or a thread's newest reply.
    var threadSummary: String?
    /// That summary is being read aloud.
    var isReadingSummary = false
    /// Open the whole summary: its text and what reads it aloud.
    var onOpenSummary: (String, String) -> Void = { _, _ in }
    let onOpenReplyTarget: (Int64) -> Void
    var onOpenCheckpoint: (RoomChatMessageRow) -> Void = { _ in }
    var onEdit: (RoomChatMessageRow) -> Void = { _ in }
    var onToggleQuiet: () -> Void = {}
    var onOpenLong: (RoomChatMessageRow) -> Void = { _ in }
    /// Reply to this row from the room's box, without leaving the room (Carter, #55074).
    var onReply: (RoomChatMessageRow) -> Void = { _ in }
    var send: (RoomChatIntent) -> Void = { _ in }
    /// How far the row follows a swipe to the right (swipe to reply, as in Messages).
    @State private var swipe: CGFloat = 0
    /// A double tap opens the same options as a long press.
    @State private var showsOptions = false

    var body: some View {
        switch row.kind {
        case .breakoutOpened(let childSessionId):
            RoomBreakoutCardView(card: breakouts[childSessionId], startedBy: row.authorName) {
                send(.openBreakout(childSessionId: childSessionId))
            }
            .padding(.vertical, 6)
        case .breakoutOutcome(let outcome):
            RoomBreakoutOutcomeView(
                outcome: outcome,
                breakoutTitle: breakouts[outcome.childSessionId]?.title,
                ownHandles: ownHandles
            ) {
                send(.openBreakout(childSessionId: outcome.childSessionId))
            }
            .padding(.vertical, 6)
        case .memberJoined:
            Text("\(row.authorName) joined the room")
                .font(.footnote)
                .foregroundStyle(PocketPalette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        case .checkpoint:
            Button {
                onOpenCheckpoint(row)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "flag.checkered")
                        .foregroundStyle(PocketPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Checkpoint")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PocketPalette.accent)
                        Text(row.text)
                            .font(.subheadline)
                            .foregroundStyle(PocketPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PocketPalette.textSecondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the checkpoint, to read or listen")
            .accessibilityIdentifier("pocket.room.checkpoint.\(row.sequenceId)")
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5)
            )
            // A checkpoint is a boundary in the room: the same wide break as a change of turn.
            .padding(.vertical, 12)
        case .message:
            if let call = row.call {
                // The call's card answers like a message (Carter, #55058): swipe to reply, its menu, a like, a thread.
                messageChrome(
                    VStack(alignment: .leading, spacing: 4) {
                        VoiceCallCardView(card: call, ownHandles: ownHandles)
                            .accessibilityIdentifier("pocket.room.call.\(row.id)")
                        messageFooter
                        if canReply || canReact { actionRow }
                    }
                    .padding(.vertical, 6)
                )
            } else if let box = row.box {
                RoomBoxLine(box: box, summary: threadSummary, isReadingSummary: isReadingSummary,
                            onListen: { listenToSummary() }, onOpenSummary: { openWholeSummary() }) {
                    send(.openThread(sequenceId: row.sequenceId))
                }
                    .padding(.vertical, 3)
                    .accessibilityIdentifier("pocket.room.box.\(row.sequenceId)")
            } else if row.isQuiet {
                VStack(alignment: .leading, spacing: 0) {
                    quietLine
                    if isExpanded { message }
                }
            } else {
                message
            }
        }
    }

    /// Background chatter as one small muted line (Carter, #55014): who and their first line. A tap opens it in place,
    /// and the line folds it back.
    private var quietLine: some View {
        Button(action: onToggleQuiet) {
            HStack(spacing: 6) {
                RoomAvatar(name: row.authorName, isHuman: false)
                    .scaleEffect(0.62)
                    .frame(width: 16, height: 16)
                Text(row.authorName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                if !isExpanded {
                    Text(RoomChatQuiet.line(row.text))
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if row.repeats > 1 {
                    Text("×\(row.repeats)")
                        .font(.caption2.monospacedDigit())
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(PocketPalette.textSecondary)
            .opacity(0.75)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.authorName): \(RoomChatQuiet.line(row.text))")
        .accessibilityHint(isExpanded ? "Folds it back to one line" : "Opens it")
        .accessibilityIdentifier("pocket.room.quiet.\(row.id)")
    }

    private var message: some View {
        messageChrome(
            Group {
                if row.isOwn {
                    ownMessage
                } else if row.isHuman {
                    personMessage
                } else {
                    agentMessage
                }
            }
        )
    }

    /// What every message answers to: swipe to reply, a long press or a double tap for its options, and the mark
    /// while it is read aloud.
    private func messageChrome<Content: View>(_ content: Content) -> some View {
        content
        .overlay(alignment: .topTrailing) {
            if isReadingAloud { RoomReadingAloudMark { send(.stopReadingAloud) } }
        }
        .offset(x: swipe)
        .background(alignment: .leading) {
            // Revealed by the swipe: the reply arrow, filled once letting go would open the reply.
            Image(systemName: swipe > Self.swipeToReply ? "arrowshape.turn.up.left.circle.fill" : "arrowshape.turn.up.left.circle")
                .font(.title3)
                .foregroundStyle(PocketPalette.accent)
                .opacity(Double(min(swipe / Self.swipeToReply, 1)))
                .padding(.leading, 4)
                .accessibilityHidden(true)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .local)
                .onChanged { value in
                    // Only a mostly sideways drag to the right: a scroll is never taken for a swipe.
                    guard value.translation.width > 0,
                          abs(value.translation.width) > abs(value.translation.height) * 1.8 else { return }
                    swipe = min(value.translation.width, Self.swipeToReply + 24)
                }
                .onEnded { _ in
                    if swipe > Self.swipeToReply { reply() }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { swipe = 0 }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(row.accessibilityId)
        .accessibilityAction(named: canReply ? "Reply" : "Open thread") { reply() }
        .contextMenu { messageMenu }
        // Simultaneous, so a single tap on a link or a button inside the message is never held back.
        .simultaneousGesture(TapGesture(count: 2).onEnded { showsOptions = true })
        .confirmationDialog("Message options", isPresented: $showsOptions, titleVisibility: .hidden) {
            ForEach(row.options(canReply: canReply, canReact: canReact, canPin: canPin, isPinned: isPinned, pinsFull: pinsFull, canEdit: canReply)) { option in
                Button(option.title) { perform(option) }
                    .disabled(!option.isEnabled)
            }
        }
    }

    private static let swipeToReply: CGFloat = 64

    /// Swipe or Reply: the room's box answers this row in place; someone who cannot post opens the thread to read.
    private func reply() {
        if canReply {
            onReply(row)
        } else {
            send(.openThread(sequenceId: row.sequenceId))
        }
    }

    /// The message's words; a very long one shows its start and a card that opens all of it (Carter, #55006).
    @ViewBuilder
    private var messageText: some View {
        if let long = LongMessage.shown(row.text) {
            VStack(alignment: .leading, spacing: 8) {
                ChatMarkdownView(text: long.preview, ownHandles: ownHandles)
                LongMessageCard(characters: long.characters) { onOpenLong(row) }
            }
        } else {
            ChatMarkdownView(text: row.text, ownHandles: ownHandles)
        }
    }

    /// What a reply answers, quoted above it: tap to open the thread (or the message it replies to).
    @ViewBuilder
    private var replyQuote: some View {
        if let reply = row.replyToSequenceId {
            Button {
                if row.isInlineReply {
                    send(.openThread(sequenceId: reply))
                } else {
                    onOpenReplyTarget(reply)
                }
            } label: {
                Label(quoteText(reply), systemImage: row.trail.map { $0.count > 1 } == true
                        ? "bubble.left.and.bubble.right" : "arrowshape.turn.up.left")
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .lineLimit(2)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(PocketPalette.separator)
                            .frame(width: 2)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.isInlineReply ? "\(quoteText(reply)). Opens the thread." : "Replying to message \(reply)")
            if let threadSummary, row.trail.map({ $0.count > 1 }) == true {
                HStack(alignment: .top, spacing: 0) {
                    Button { openWholeSummary() } label: {
                        ThreadSummaryText(text: threadSummary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the whole summary")
                    Spacer(minLength: 0)
                    ThreadSummaryListenButton(isReading: isReadingSummary) { listenToSummary() }
                }
                .padding(.leading, 10)
            }
        }
    }

    /// Opens this row's thread summary whole (Carter, 10-30: "clicking on the summary message can give you a pop up of
    /// the rest").
    private func openWholeSummary() {
        guard let threadSummary, let id = row.summaryReadAloudId else { return }
        onOpenSummary(threadSummary, id)
    }

    /// Reads this row's thread summary aloud, or stops it (Carter, on #55474: "a voice version of the summary").
    private func listenToSummary() {
        if isReadingSummary {
            send(.stopReadingAloud)
        } else if let threadSummary, let id = row.summaryReadAloudId {
            send(.readAloud(id: id, text: threadSummary))
        }
    }

    /// What the quote says: what the reply answers, and for a thread how many replies and who.
    private func quoteText(_ reply: Int64) -> String {
        let answers = row.replyContext ?? "Replying to #\(reply)"
        guard let trail = row.trail, trail.count > 1 else { return answers }
        return "\(trail.label) on \(answers)"
    }

    /// Edited mark, attachments, who viewed it and the reactions: the same under every kind of message.
    @ViewBuilder
    private var messageFooter: some View {
        if row.repeats > 1, let stack = row.repeatStack {
            Button {
                send(.toggleRepeats(stack: stack))
            } label: {
                Label("\(row.repeats) times, only the numbers changed · Show each", systemImage: "square.stack")
                    .font(.caption2)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pocket.room.repeats")
        } else if row.foldsRepeats, let stack = row.repeatStack {
            Button {
                send(.toggleRepeats(stack: stack))
            } label: {
                Label("Fold these alike notices into one", systemImage: "square.stack")
                    .font(.caption2)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pocket.room.repeats.fold")
        }
        if !row.work.isEmpty {
            RoomWorkLines(lines: row.work)
        }
        if !row.attachments.isEmpty {
            RoomAttachmentsView(chips: row.attachments, previews: attachmentPreviews, send: send)
        }
        if let reactions = row.reactions {
            RoomReactionBar(
                reactions: reactions,
                canReact: canReact,
                onReact: { send(row.reaction($0)) },
                onOpenThread: { send(.openThread(sequenceId: row.sequenceId)) }
            )
        }
    }

    private var bubbleFill: Color {
        isHighlighted ? PocketPalette.warning.opacity(0.22) : PocketPalette.humanBubble
    }

    /// Space above a row: tight inside one sender's run, wider where the sender changes (Carter, #55014). Where the
    /// room changes hands, the turn break above the row adds the rest.
    private var gapAbove: CGFloat { row.showsHeader ? 12 : 6 }

    /// Yours: a solid charcoal bubble with white text on the right, set apart from everything else, with your name
    /// over the first of a run (Carter: his name was missing on his own messages; #55014 for the contrast).
    private var ownMessage: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 4) {
                if row.showsHeader {
                    Text(row.authorName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PocketPalette.accentStrong)
                        .accessibilityIdentifier("pocket.room.ownName")
                }
                replyQuote
                messageText
                    .font(.body)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    // The bubble is dark in both appearances, so what is in it takes the dark colours.
                    .environment(\.colorScheme, .dark)
                    .background(PocketPalette.ownBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        if isHighlighted {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(PocketPalette.warning, lineWidth: 2)
                        }
                    }
                messageFooter
                if row.endsRun || row.isEdited {
                    HStack(spacing: 6) {
                        if row.isEdited { Text("edited") }
                        if let date = row.date { Text(date, style: .time) }
                        if let views = row.views { RoomReadTicks(views: views) }
                    }
                    .font(.caption2)
                    .foregroundStyle(PocketPalette.textSecondary)
                }
                if let views = row.views, row.endsRun {
                    RoomViewedLine(views: views)
                }
            }
        }
        .padding(.top, gapAbove)
    }

    /// Another person: a warm bubble on the left with their name.
    private var personMessage: some View {
        HStack(alignment: .top, spacing: 8) {
            RoomAvatar(name: row.authorName, isHuman: true)
                .opacity(row.showsHeader ? 1 : 0)
            VStack(alignment: .leading, spacing: 4) {
                if row.showsHeader { authorLine }
                replyQuote
                messageText
                    .font(.body)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(bubbleFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                if row.isEdited {
                    Text("edited").font(.caption2).foregroundStyle(PocketPalette.textSecondary)
                }
                messageFooter
                if let views = row.views, row.endsRun {
                    RoomViewedLine(views: views)
                }
            }
            Spacer(minLength: 32)
        }
        .padding(.top, gapAbove)
    }

    /// An agent: full width, structured text without a bubble (as the assistant apps answer), its name and avatar
    /// above, an edge in its own colour down the left (Carter, #55014), and the quiet action row under the last
    /// message of its run.
    private var agentMessage: some View {
        VStack(alignment: .leading, spacing: 5) {
            if row.showsHeader {
                HStack(spacing: 8) {
                    RoomAvatar(name: row.authorName, isHuman: false)
                    authorLine
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                replyQuote
                messageText
                    .font(.body)
                    .foregroundStyle(PocketPalette.textPrimary)
                if row.isEdited {
                    Text("edited").font(.caption2).foregroundStyle(PocketPalette.textSecondary)
                }
                messageFooter
                if row.endsRun {
                    if let views = row.views {
                        RoomViewedLine(views: views)
                    }
                    actionRow
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(RoomAvatar.tint(for: row.authorName).opacity(0.7))
                    .frame(width: 3)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHighlighted ? PocketPalette.warning.opacity(0.22) : Color.clear)
        )
        .padding(.top, gapAbove)
    }

    private var authorLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.authorName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(row.isHuman ? PocketPalette.accentStrong : PocketPalette.textPrimary)
                .lineLimit(1)
            if let date = row.date {
                Text(date, style: .time)
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            if let views = row.views {
                RoomReadTicks(views: views)
            }
            Spacer(minLength: 0)
        }
    }

    /// Copy, listen, like, dislike and more, as the assistant apps put under an answer: the row's own options, so a
    /// reply shown in the room acts on itself here too.
    private var actionRow: some View {
        let options = row.options(canReply: canReply, canReact: canReact, canPin: canPin, isPinned: isPinned, pinsFull: pinsFull, canEdit: canReply)
        // Reply when you can post, else the thread, never both.
        let shown = Self.actionRowKinds.compactMap { kind in options.first { $0.kind == kind } }
            .filter { $0.kind != .thread || !options.contains { $0.kind == .reply } }
        return HStack(spacing: 18) {
            ForEach(shown) { option in
                actionButton(option.kind == .thread ? "arrowshape.turn.up.left" : option.symbol, label: option.title) {
                    perform(option)
                }
            }
            Menu {
                messageMenu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PocketPalette.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More actions")
        }
        .padding(.top, 2)
    }

    private static let actionRowKinds: [RoomRowOption.Kind] = [.copy, .listen, .like, .dislike, .reply, .thread]

    private func perform(_ option: RoomRowOption) {
        if option.kind == .reply {
            onReply(row)
        } else if option.kind == .edit {
            onEdit(row)
        } else if option.kind == .copy {
            copyToPasteboard(row.text)
        } else if let intent = option.intent {
            send(intent)
        }
    }

    private func actionButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(PocketPalette.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The long-press menu, from the row's own options: a reply shown in the room acts on itself, never on the
    /// message it answers.
    private var messageMenu: some View {
        ForEach(row.options(canReply: canReply, canReact: canReact, canPin: canPin, isPinned: isPinned, pinsFull: pinsFull, canEdit: canReply)) { option in
            Button {
                perform(option)
            } label: {
                Label(option.title, systemImage: option.symbol)
            }
            .disabled(!option.isEnabled)
        }
    }
}

/// Who is working on a message, under it: live lines shimmer, finished ones fold into one line that opens to show
/// every step (as the assistant apps show their steps).
struct RoomWorkLines: View {
    let lines: [RoomChatWorkLine]
    @State private var showsAll = false

    var body: some View {
        let live = lines.filter(\.isLive)
        let finished = lines.filter { !$0.isLive }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(live) { line in
                LiveLine(text: "\(line.actorId) · \(line.text)", isLive: true)
            }
            if let newest = finished.last {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showsAll.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle")
                            .font(.caption2)
                        Text("\(newest.actorId) · \(newest.text)")
                            .font(.caption)
                            .lineLimit(1)
                        if finished.count > 1 {
                            Image(systemName: showsAll ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                    }
                    .foregroundStyle(PocketPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(finished.count < 2)
                .accessibilityLabel("\(newest.actorId): \(newest.text)")
                .accessibilityHint(finished.count > 1 ? (showsAll ? "Hides the earlier steps" : "Shows \(finished.count - 1) earlier steps") : "")
                if showsAll {
                    ForEach(finished.dropLast()) { line in
                        Text("\(line.actorId) · \(line.text)")
                            .font(.caption)
                            .foregroundStyle(PocketPalette.textSecondary)
                            .padding(.leading, 16)
                    }
                }
            }
        }
        .padding(.top, 2)
    }
}

/// A round avatar with initials, coloured from the name so each agent keeps its colour.
struct RoomAvatar: View {
    let name: String
    let isHuman: Bool

    private static let tints: [(Double, Double, Double)] = [
        (18, 85, 55), (189, 65, 40), (262, 45, 55), (215, 60, 50), (330, 55, 52), (38, 85, 48), (200, 30, 45)
    ]

    /// The colour this name always gets: its avatar, and an agent's edge down its messages.
    static func tint(for name: String) -> Color {
        let index = Int(name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % UInt32(tints.count))
        return PocketPalette.themed(light: tints[index], dark: tints[index])
    }

    var body: some View {
        Text(initials)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            // People are round, agents are rounded squares.
            .background(Self.tint(for: name), in: RoundedRectangle(cornerRadius: isHuman ? 13 : 7, style: .continuous))
            .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name.replacingOccurrences(of: "human-", with: "")
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let letters = parts.prefix(2).compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

/// Empties a composer after a send. A field that is still editing (dictation, or an autocorrection or a predictive word
/// in progress) can write its pending text back just after it is emptied, so a sent message stayed in the box: it is
/// emptied again on the next turn of the run loop, and a moment later if what came back is the sent text itself.
///
/// The keyboard stays where it is. It used to go down and come straight back on every send, which moved the whole room
/// twice under the keyboard while the new message arrived; both of Carter's freezes on 10-30 came right after a send,
/// on a phone (the simulator's keyboard never moves), so the bounce is gone.
@MainActor
private func emptyComposer(_ draft: Binding<String>, sent: String) {
    draft.wrappedValue = ""
    DispatchQueue.main.async {
        draft.wrappedValue = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if RoomComposerDraft.isWrittenBack(draft.wrappedValue, sent: sent) { draft.wrappedValue = "" }
        }
    }
}

/// A message's text, its tables as tab-separated rows (`ChatMarkdown.copyText`).
private func copyToPasteboard(_ text: String) {
    let text = ChatMarkdown.copyText(text)
    #if os(iOS)
    UIPasteboard.general.string = text
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

/// Reaction chips, the acknowledged and working lines, and the reply count under a message.
private struct RoomReactionBar: View {
    let reactions: RoomChatReactions
    let canReact: Bool
    let onReact: (String) -> Void
    let onOpenThread: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !reactions.chips.isEmpty || reactions.replyCount > 0 || reactions.isPinned {
                HStack(spacing: 6) {
                    if reactions.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(PocketPalette.warning)
                            .accessibilityLabel("Pinned")
                    }
                    ForEach(reactions.chips) { chip in
                        Button {
                            if chip.type == "like" { onReact(chip.isMine ? "unlike" : "like") }
                            else if chip.type == "dislike" { onReact(chip.isMine ? "undislike" : "dislike") }
                            else if chip.type == "ack" { onReact("ack") }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: chip.isMine ? chip.symbol + ".fill" : chip.symbol)
                                Text("\(chip.count)").monospacedDigit()
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(chip.isMine ? PocketPalette.accent.opacity(0.18) : PocketPalette.raised)
                            )
                            .overlay(Capsule().stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canReact || chip.type == "disregard")
                        .accessibilityLabel("\(chip.label), \(chip.count)\(chip.isMine ? ", yours" : "")")
                    }
                    if reactions.replyCount > 0 {
                        Button(action: onOpenThread) {
                            Label("\(reactions.replyCount) \(reactions.replyCount == 1 ? "reply" : "replies")", systemImage: "arrow.turn.down.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PocketPalette.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("pocket.room.openThread")
                    }
                }
            }
            if let acked = reactions.ackedBy {
                Text(acked).font(.caption2).foregroundStyle(PocketPalette.textSecondary)
            }
            if let working = reactions.working {
                Text(working).font(.caption2).foregroundStyle(PocketPalette.listening)
            }
        }
        .padding(.top, 2)
    }
}

/// The thread sheet: the parent message, its replies oldest first, and a reply box when you can post.
private struct RoomThreadSheet: View {
    let thread: RoomChatThreadState
    let ownHandles: Set<String>
    var readingAloudId: String?
    var mentionCandidates: [MentionCandidate] = []
    var canReact = false
    /// What the room's "+" offers, offered here too (Carter, 10-30: "everything I'd have in the chatbox ... inside a
    /// reply too").
    var actions = RoomComposerActions()
    let send: (RoomChatIntent) -> Void
    @Binding var draft: String
    /// The reply being answered (a reply to a reply nests under it); nil answers the message.
    @State private var answering: RoomChatReplyRow?
    /// "File as a ticket": the reply goes to the room's ticket keeper as a ticket request.
    @State private var ticketMode = false
    @FocusState private var isReplying: Bool
    /// Your own reply being edited.
    @State private var editingReply: RoomChatReplyRow?
    /// Where the reply text last changed (the field does not say where the caret is), for an @ anywhere in it.
    @State private var editOffset: Int?
    @State private var lastDraft = ""

    private var suggestions: [MentionCandidate] {
        guard let active = MentionSuggester.activeQuery(in: draft, at: editOffset ?? draft.count) else { return [] }
        return MentionSuggester.suggestions(for: active.query, among: mentionCandidates)
    }

    private func answer(_ reply: RoomChatReplyRow) {
        answering = reply
        let mention = "@\(reply.authorHandle) "
        if !draft.hasPrefix(mention) { draft = mention + draft }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(thread.parent.authorName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(thread.parent.isHuman ? PocketPalette.listening : PocketPalette.textPrimary)
                        ChatMarkdownView(text: thread.parent.text, ownHandles: ownHandles)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if thread.isLoading && thread.replies.isEmpty {
                        ProgressView("Loading replies").frame(maxWidth: .infinity)
                    }
                    if let failure = thread.failureText {
                        Text(failure).font(.footnote).foregroundStyle(PocketPalette.warning)
                    }
                    ForEach(thread.replies) { reply in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(reply.authorName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(reply.isHuman ? PocketPalette.listening : PocketPalette.textPrimary)
                                if let date = reply.date {
                                    Text(date, style: .time).font(.caption).foregroundStyle(PocketPalette.textSecondary)
                                }
                                if reply.isEdited {
                                    Text("edited").font(.caption2).foregroundStyle(PocketPalette.textSecondary)
                                }
                            }
                            ChatMarkdownView(text: reply.text, ownHandles: ownHandles)
                            if let views = reply.views {
                                RoomViewedLine(views: views)
                            }
                        }
                        .onAppear { send(.replyOnScreen(id: reply.id, isOnScreen: true)) }
                        .onDisappear { send(.replyOnScreen(id: reply.id, isOnScreen: false)) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .topTrailing) {
                            if readingAloudId == RoomReadAloud.reply(reply.id) {
                                RoomReadingAloudMark { send(.stopReadingAloud) }
                            }
                        }
                        .contentShape(Rectangle())
                        .contextMenu { replyMenu(reply) }
                        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                            // Swipe right to answer this reply, as in Messages.
                            if thread.canReply, value.translation.width > 60,
                               abs(value.translation.width) > abs(value.translation.height) * 1.8 {
                                answer(reply)
                            }
                        })
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(PocketPalette.separator).frame(width: 2)
                        }
                        .padding(.leading, CGFloat(reply.depth) * 16)
                        .accessibilityAction(named: "Reply") { answer(reply) }
                    }
                    ForEach(thread.pending) { pending in
                        RoomPendingRowView(
                            row: pending,
                            recovery: RoomPendingRecovery(canPost: thread.canReply),
                            onRetry: { send(.retrySend(clientId: pending.clientId)) },
                            onDiscard: { send(.discardSend(clientId: pending.clientId)) },
                            onEdit: {
                                draft = RoomComposerDraft.restoring(pending.text, into: draft)
                                send(.discardSend(clientId: pending.clientId))
                            }
                        )
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $editingReply) { reply in
                MessageEditSheet(original: reply.text) { text in
                    send(.editReply(sequenceId: thread.parent.sequenceId, replyId: reply.id, text: text))
                }
            }
            .navigationTitle(thread.replies.count == 1 ? "1 reply" : "\(thread.replies.count) replies")
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { send(.closeThread) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if thread.canReply {
                    VStack(alignment: .leading, spacing: 4) {
                    if let answering {
                        HStack(spacing: 6) {
                            Image(systemName: "arrowshape.turn.up.left")
                            Text("Replying to \(answering.authorName)")
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button {
                                self.answering = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Stop replying to \(answering.authorName)")
                        }
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                    if !suggestions.isEmpty {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(suggestions) { candidate in
                                    Button {
                                        draft = MentionSuggester.apply(candidate, to: draft, at: editOffset ?? draft.count)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: candidate.isAll ? "person.3.fill" : (candidate.isHuman ? "person.crop.circle.fill" : "cpu"))
                                                .foregroundStyle(candidate.isHuman || candidate.isAll ? PocketPalette.accent : PocketPalette.listening)
                                                .frame(width: 26)
                                            Text(candidate.isAll ? "@all" : "@\(candidate.handle)")
                                                .font(.subheadline.weight(.semibold))
                                            Text(candidate.isAll ? "Everyone in the room" : candidate.displayName)
                                                .font(.caption)
                                                .foregroundStyle(PocketPalette.textSecondary)
                                                .lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(candidate.isAll ? "Mention everyone" : "Mention \(candidate.displayName), @\(candidate.handle)")
                                    .accessibilityIdentifier("pocket.thread.mention.\(candidate.handle)")
                                }
                            }
                        }
                        .frame(maxHeight: min(CGFloat(suggestions.count) * 44, 200))
                    }
                    if let problem = thread.replyLengthProblem(for: draft) {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(PocketPalette.danger)
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                            .accessibilityIdentifier("pocket.thread.composer.tooLong")
                    }
                    if ticketMode {
                        HStack(spacing: 6) {
                            Image(systemName: "ticket")
                                .foregroundStyle(PocketPalette.accentStrong)
                                .accessibilityHidden(true)
                            Text("Describe what you want; it becomes a ticket.")
                                .font(.caption)
                                .foregroundStyle(PocketPalette.textSecondary)
                            Spacer(minLength: 4)
                            Button {
                                ticketMode = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(PocketPalette.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Not a ticket")
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("pocket.thread.composer.ticketMode")
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        Menu {
                            Button {
                                let separated = draft.isEmpty || draft.last?.isWhitespace == true
                                draft += separated ? "@" : " @"
                                isReplying = true
                            } label: {
                                Label("Mention someone", systemImage: "at")
                            }
                            Button {
                                ticketMode = true
                                isReplying = true
                            } label: {
                                Label("File as a ticket", systemImage: "ticket")
                            }
                            if actions.canSearch {
                                // Search opens over the room, so the thread steps aside first.
                                Button {
                                    send(.closeThread)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { send(.openSearch) }
                                } label: {
                                    Label("Search this room", systemImage: "magnifyingglass")
                                }
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(PocketPalette.textPrimary)
                                .frame(width: 36, height: 36)
                                .background(PocketPalette.raised, in: Circle())
                                .overlay(Circle().stroke(PocketPalette.separator.opacity(0.8), lineWidth: 0.5))
                        }
                        .accessibilityLabel("More")
                        .accessibilityIdentifier("pocket.thread.composer.plus")
                        .padding(.bottom, 1)
                        TextField(ticketMode ? "Describe the ticket" : "Reply", text: $draft, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.plain)
                            .focused($isReplying)
                            .onChange(of: draft) { new in
                                editOffset = MentionSuggester.editOffset(from: lastDraft, to: new)
                                lastDraft = new
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .accessibilityIdentifier("pocket.thread.composer")
                        Button {
                            let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard canSendReply else { return }
                            let text = ticketMode ? RoomComposerDraft.ticketRequest(typed) : typed
                            ticketMode = false
                            if let answering {
                                send(.sendReplyToReply(sequenceId: thread.parent.sequenceId, replyId: answering.id, text: text))
                            } else {
                                send(.sendReply(sequenceId: thread.parent.sequenceId, text: text))
                            }
                            emptyComposer($draft, sent: typed)
                            answering = nil
                        } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSendReply)
                        .accessibilityLabel("Send reply")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    }
                    .pocketFloating(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private var canSendReply: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && thread.replyLengthProblem(for: draft) == nil
    }

    /// The same choices as a message in the room: reply, react, listen, copy.
    @ViewBuilder
    private func replyMenu(_ reply: RoomChatReplyRow) -> some View {
        if thread.canReply {
            Button {
                answer(reply)
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
        }
        if canReact {
            Button {
                send(.reactToReply(sequenceId: thread.parent.sequenceId, replyId: reply.id, type: "like"))
            } label: {
                Label("Like", systemImage: "hand.thumbsup")
            }
            Button {
                send(.reactToReply(sequenceId: thread.parent.sequenceId, replyId: reply.id, type: "dislike"))
            } label: {
                Label("Dislike", systemImage: "hand.thumbsdown")
            }
            Button {
                send(.reactToReply(sequenceId: thread.parent.sequenceId, replyId: reply.id, type: "ack"))
            } label: {
                Label("Acknowledge", systemImage: "checkmark.circle")
            }
        }
        Button {
            send(.readAloud(id: RoomReadAloud.reply(reply.id), text: reply.text))
        } label: {
            Label("Listen", systemImage: "speaker.wave.2")
        }
        if reply.isOwn, thread.canReply {
            Button {
                editingReply = reply
            } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
        Button {
            copyToPasteboard(reply.text)
        } label: {
            Label("Copy text", systemImage: "doc.on.doc")
        }
    }
}

private struct RoomPendingRowView: View {
    let row: RoomChatPendingRow
    let recovery: RoomPendingRecovery
    let onRetry: () -> Void
    let onDiscard: () -> Void
    /// Puts the text back where it was typed, so a refused message can be changed and sent again.
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChatMarkdownView(text: row.displayText)
                .font(.body)
                .foregroundStyle(PocketPalette.textPrimary.opacity(row.isFailed ? 0.7 : 1))
            switch row.status {
            case .sending:
                Label("Sending…", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
            case .sent:
                Label("Sent", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
            case .failed(let reason, let canRetry):
                HStack(spacing: 12) {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(PocketPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    if canRetry {
                        Button("Retry", action: onRetry)
                            .font(.caption.weight(.semibold))
                            .accessibilityIdentifier("pocket.room.pending.retry")
                    }
                    switch recovery {
                    case .edit:
                        Button("Edit", action: onEdit)
                            .font(.caption.weight(.semibold))
                            .accessibilityIdentifier("pocket.room.pending.edit")
                    case .copy:
                        // Copies the full text, not the shortened display; the row stays until discarded.
                        Button("Copy") { copyToPasteboard(row.text) }
                            .font(.caption.weight(.semibold))
                            .accessibilityIdentifier("pocket.room.pending.copy")
                    }
                    Button("Discard", role: .destructive, action: onDiscard)
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("pocket.room.pending.discard")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PocketPalette.listening.opacity(0.08))
        )
        .padding(.top, 6)
        .accessibilityIdentifier("pocket.room.pending")
    }
}

private extension RoomChatPendingRow {
    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }
}

/// The composer: multi-line, grows to six lines, sends the trimmed text. Hidden when the room cannot take posts,
/// with the reason shown instead (for example a viewer membership).
/// Which of the composer's "+" actions the room offers.
public struct RoomComposerActions: Equatable, Sendable {
    public var canFileTicket: Bool
    public var canSearch: Bool

    public init(canFileTicket: Bool = false, canSearch: Bool = false) {
        self.canFileTicket = canFileTicket
        self.canSearch = canSearch
    }
}

private struct RoomComposerBar: View {
    let composer: RoomComposerState
    var mentionCandidates: [MentionCandidate] = []
    var restored: RoomComposerRestore?
    var actions = RoomComposerActions()
    /// The message this box answers, in its thread; nil writes to the room.
    var replying: RoomChatMessageRow?
    var onCancelReply: () -> Void = {}
    var onIntent: (RoomChatIntent) -> Void = { _ in }
    /// Where this room's unsent text is kept on the phone, so a crash or a relaunch never loses it.
    var draftKey: String?
    let send: (String) -> Void
    @State private var draft = ""
    /// The text just sent, for a moment: the keyboard can write it back into the emptied box (dictation, a pending
    /// correction), and that is not a paste.
    @State private var justSent: String?
    /// While a send settles, the sent text stays saved (see `sendDraft()`); which send that is.
    @State private var keepsSavedDraft = false
    @State private var sends = 0
    @FocusState private var isEditing: Bool
    /// "File as a ticket": what you type goes to the room as a ticket request, and the ticket keeper files it.
    @State private var ticketMode = false
    /// Where the text last changed (the field does not say where the caret is), for an @ anywhere in it.
    @State private var editOffset: Int?
    @State private var lastDraft = ""
    /// Long pastes, held above the field as attachments and sent after the typed words (Carter, #55006).
    @State private var pasted: [String] = []
    @State private var viewingPaste: PastedBlock?

    /// Sends what is in the box. The box empties first; the message goes to the room on the next turn of the run loop,
    /// so the emptied box, the new row and the scroll to it are not all laid out in one update (every freeze on 10-30
    /// began at a send). The text stays saved on the phone for a few seconds more, long enough to be on its way: if
    /// the app is closed before then, it is back in the box at the next launch.
    private func sendDraft() {
        let text = outgoing
        guard !text.isEmpty else { return }
        let message = ticketMode ? RoomComposerDraft.ticketRequest(text) : text
        ticketMode = false
        pasted = []
        justSent = text
        keepsSavedDraft = true
        sends += 1
        let sending = sends
        if let draftKey { UserDefaults.standard.set(text, forKey: draftKey) }
        emptyComposer($draft, sent: text)
        DispatchQueue.main.async { send(message) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if sends == sending { justSent = nil } }
        DispatchQueue.main.asyncAfter(deadline: .now() + RoomComposerDraft.savedAfterSend) {
            guard sends == sending else { return }
            keepsSavedDraft = false
            // Typing since is saved; the sent text itself goes when the room confirms it (`forgetSaved`).
            if !outgoing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { saveDraft() }
        }
    }

    private func saveDraft() {
        guard let draftKey, !keepsSavedDraft else { return }
        let text = outgoing
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: draftKey)
        } else {
            UserDefaults.standard.set(text, forKey: draftKey)
        }
    }

    private func restoreSavedDraft() {
        guard let draftKey, draft.isEmpty, pasted.isEmpty,
              let saved = UserDefaults.standard.string(forKey: draftKey), !saved.isEmpty else { return }
        // Set as it was, not as a paste: a long draft stays text in the box.
        lastDraft = saved
        draft = saved
    }

    private var suggestions: [MentionCandidate] {
        guard let active = MentionSuggester.activeQuery(in: draft, at: editOffset ?? draft.count) else { return [] }
        return MentionSuggester.suggestions(for: active.query, among: mentionCandidates)
    }

    private var outgoing: String { RoomComposerDraft.outgoing(draft, blocks: pasted) }

    var body: some View {
        // Read once per redraw: each walks the whole draft, and a long draft made typing lag (ticket 7674d10b).
        let outgoing = self.outgoing
        let problem = composer.lengthProblem(for: outgoing)
        let canSend = !outgoing.isEmpty && problem == nil
        let suggestions = self.suggestions
        if composer.canPost {
            VStack(alignment: .leading, spacing: 0) {
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(PocketPalette.danger)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .accessibilityIdentifier("pocket.room.composer.tooLong")
            } else if let note = composer.lengthNote(for: outgoing) {
                Text(note)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PocketPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .accessibilityIdentifier("pocket.room.composer.length")
            }
            if !suggestions.isEmpty {
                // Everyone who matches, people first: a list that scrolls, not a handful of chips.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions) { candidate in
                            Button {
                                draft = MentionSuggester.apply(candidate, to: draft, at: editOffset ?? draft.count)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: candidate.isAll ? "person.3.fill" : (candidate.isHuman ? "person.crop.circle.fill" : "cpu"))
                                        .font(.body)
                                        .foregroundStyle(candidate.isHuman || candidate.isAll ? PocketPalette.accent : PocketPalette.listening)
                                        .frame(width: 26)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(candidate.isAll ? "@all" : "@\(candidate.handle)")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(PocketPalette.textPrimary)
                                        Text(candidate.isAll ? "Everyone in the room" : candidate.displayName)
                                            .font(.caption)
                                            .foregroundStyle(PocketPalette.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(candidate.isAll ? "Mention everyone" : "Mention \(candidate.displayName), @\(candidate.handle)")
                            .accessibilityIdentifier("pocket.room.mention.\(candidate.handle)")
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(suggestions.count) * 48, 240))
                .padding(.top, 6)
                .overlay(alignment: .bottom) { Divider() }
            }
            if !pasted.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pasted.enumerated()), id: \.offset) { index, block in
                            PastedChip(
                                block: block,
                                onOpen: { viewingPaste = PastedBlock(index: index, text: block) },
                                onRemove: {
                                    pasted.remove(at: index)
                                    saveDraft()
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .accessibilityIdentifier("pocket.room.composer.pasted")
            }
            if let replying {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .foregroundStyle(PocketPalette.accent)
                        .accessibilityHidden(true)
                    (Text("Replying to \(replying.authorName)  ")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(PocketPalette.textPrimary)
                     + Text(RoomChatQuiet.line(replying.text))
                        .font(.caption)
                        .foregroundColor(PocketPalette.textSecondary))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        onCancelReply()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Not a reply")
                    .accessibilityIdentifier("pocket.room.composer.replying.cancel")
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pocket.room.composer.replying")
            }
            if ticketMode {
                HStack(spacing: 6) {
                    Image(systemName: "ticket")
                        .foregroundStyle(PocketPalette.accentStrong)
                        .accessibilityHidden(true)
                    Text("Describe what you want; it becomes a ticket.")
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                    Spacer(minLength: 4)
                    Button {
                        ticketMode = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Not a ticket")
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pocket.room.composer.ticketMode")
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button {
                        let separated = draft.isEmpty || draft.last?.isWhitespace == true
                        draft += separated ? "@" : " @"
                    } label: {
                        Label("Mention someone", systemImage: "at")
                    }
                    // Plain words become a ticket: the room's ticket keeper files it and replies with the link.
                    Button {
                        ticketMode = true
                        isEditing = true
                    } label: {
                        Label("File as a ticket", systemImage: "ticket")
                    }
                    if actions.canSearch {
                        Button {
                            onIntent(.openSearch)
                        } label: {
                            Label("Search this room", systemImage: "magnifyingglass")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(PocketPalette.raised, in: Circle())
                        .overlay(Circle().stroke(PocketPalette.separator.opacity(0.8), lineWidth: 0.5))
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("pocket.room.composer.plus")
                .padding(.bottom, 1)
                TextField(ticketMode ? "Describe the ticket" : (replying == nil ? "Message" : "Reply"), text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($isEditing)
                    .onChange(of: draft) { new in
                        if let sent = justSent, RoomComposerDraft.isWrittenBack(new, sent: sent) {
                            // The keyboard writing the sent text back: `emptyComposer` empties it again.
                            lastDraft = new
                            return
                        }
                        if let paste = RoomComposerDraft.pastedBlock(from: lastDraft, to: new) {
                            pasted.append(paste.block)
                            lastDraft = paste.draft
                            draft = paste.draft
                            saveDraft()
                            return
                        }
                        editOffset = MentionSuggester.editOffset(from: lastDraft, to: new)
                        lastDraft = new
                        saveDraft()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5)
                    )
                    .accessibilityIdentifier("pocket.room.composer")
                Button {
                    sendDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? PocketPalette.accent : PocketPalette.textSecondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("pocket.room.send")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            }
            // Lifted off the room (Carter, #55014): the room shows through its frosted glass as it scrolls under.
            .pocketFloating(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .onChange(of: restored) { request in
                guard let request else { return }
                draft = RoomComposerDraft.restoring(request.text, into: draft)
            }
            // What was being written here when the app last closed comes back (Carter, 10-30: "the crash happened
            // and I lost all the things I was saying").
            .onAppear(perform: restoreSavedDraft)
            // Swipe to reply and start typing at once: the keyboard comes up, and nothing in the room moves.
            .onChange(of: replying?.id) { id in
                if id != nil { isEditing = true }
            }
            .sheet(item: $viewingPaste) { item in
                PastedBlockSheet(
                    text: item.text,
                    onSave: { edited in
                        guard pasted.indices.contains(item.index) else { return }
                        if edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            pasted.remove(at: item.index)
                        } else {
                            pasted[item.index] = edited
                        }
                        saveDraft()
                    },
                    onUnattach: { edited in
                        guard pasted.indices.contains(item.index) else { return }
                        pasted.remove(at: item.index)
                        // Set as it is, not as a new paste: the text stays in the box.
                        let joined = RoomComposerDraft.unattaching(edited, into: draft)
                        lastDraft = joined
                        draft = joined
                        saveDraft()
                    },
                    onRemove: {
                        if pasted.indices.contains(item.index) { pasted.remove(at: item.index) }
                        saveDraft()
                    }
                )
            }
        } else if let reason = composer.disabledReason {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(PocketPalette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(12)
                .pocketFloating(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .accessibilityIdentifier("pocket.room.composerDisabled")
        }
    }
}

/// A long paste held in the composer.
private struct PastedBlock: Identifiable {
    let index: Int
    let text: String
    var id: Int { index }
}

/// A long paste above the field: what it is and how long, a tap to read it, and a way to take it out.
private struct PastedChip: View {
    let block: String
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.plaintext")
                        .foregroundStyle(PocketPalette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Pasted text")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PocketPalette.textPrimary)
                        Text("\(block.count.formatted()) characters")
                            .font(.caption2)
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pasted text, \(block.count) characters")
            .accessibilityHint("Shows it")
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove the pasted text")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(PocketPalette.separator.opacity(0.7), lineWidth: 0.5)
        )
    }
}

/// A held paste, read in full before it is sent.
/// A held paste, open (Carter, 10-30: "I should be able to click on a text that became attachment to add to it or
/// unattach it"): edit it in place, put it back into the message as text, or remove it.
private struct PastedBlockSheet: View {
    let text: String
    let onSave: (String) -> Void
    let onUnattach: (String) -> Void
    let onRemove: () -> Void
    @State private var edited = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $edited)
                    .font(.callout)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                Button {
                    onUnattach(edited)
                    dismiss()
                } label: {
                    Label("Put it in the message", systemImage: "text.insert")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(12)
                .accessibilityIdentifier("pocket.room.composer.paste.unattach")
            }
            .pocketCanvas()
            .navigationTitle("Pasted text")
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Remove", role: .destructive) {
                        onRemove()
                        dismiss()
                    }
                    .accessibilityIdentifier("pocket.room.composer.paste.remove")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(edited)
                        dismiss()
                    }
                    .accessibilityIdentifier("pocket.room.composer.paste.done")
                }
            }
        }
        .onAppear { edited = text }
    }
}

/// The card under a long message's start: how long it is, and a tap to read all of it.
struct LongMessageCard: View {
    let characters: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.title3)
                    .foregroundStyle(PocketPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Read the whole message")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                    Text("\(characters.formatted()) characters")
                        .font(.caption2)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(10)
            .background(PocketPalette.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Long message, \(characters) characters")
        .accessibilityHint("Opens all of it")
        .accessibilityIdentifier("pocket.room.longMessage")
    }
}

/// A long message in full, as a page over the room: read it, copy it, or listen to it.
struct LongMessageSheet: View {
    let row: RoomChatMessageRow
    let ownHandles: Set<String>
    let send: (RoomChatIntent) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ChatMarkdownView(text: row.text, ownHandles: ownHandles)
                    .font(.body)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .pocketCanvas()
            .navigationTitle(row.authorName)
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        copyToPasteboard(row.text)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        send(.readAloud(id: row.readAloudId, text: row.text))
                        dismiss()
                    } label: {
                        Label("Listen", systemImage: "speaker.wave.2")
                    }
                }
            }
        }
    }
}

/// Where the room changes hands, a person after an agent or an agent after a person: a hairline with the time, and
/// a wider gap than between two messages of one turn (Carter, #55014).
private struct RoomTurnBreak: View {
    let date: Date?

    var body: some View {
        HStack(spacing: 10) {
            line
            if let date {
                Text(date, style: .time)
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(PocketPalette.textSecondary)
                line
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
    }

    private var line: some View {
        Rectangle()
            .fill(PocketPalette.separator.opacity(0.7))
            .frame(height: 0.5)
    }
}

private struct RoomComposingLine: View {
    let agents: [String]

    var body: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(PocketPalette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .accessibilityIdentifier("pocket.room.composing")
    }

    private var label: String {
        switch agents.count {
        case 1: return "\(agents[0]) is preparing a reply…"
        case 2: return "\(agents[0]) and \(agents[1]) are preparing replies…"
        default: return "\(agents.count) agents are preparing replies…"
        }
    }
}

private struct RoomConnectionPill: View {
    let connection: RoomConnectionState
    /// The dot alone; the word is still read aloud.
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Self.color(for: connection))
                .frame(width: 7, height: 7)
            if !compact {
                Text(connection.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
        }
        // Never squeezed into a broken word: when the bar is tight, the room's title gives way instead.
        .fixedSize()
        .foregroundStyle(PocketPalette.textSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connection.label)
        .accessibilityIdentifier("pocket.room.connection")
    }

    static func color(for connection: RoomConnectionState) -> Color {
        switch connection {
        case .live: return PocketPalette.listening
        case .connecting, .reconnecting: return PocketPalette.warning
        case .paused: return PocketPalette.textSecondary
        }
    }
}

/// Inline Markdown for one chat line (bold, italic, code, links), with the web's link policy applied: a link whose
/// URL is not http(s) to a real host stays visible as text but is not tappable. Rows use `ChatMarkdownView`,
/// which adds block layout, pull-request chips and mentions on top of the same rules.
enum RoomChatText {
    static func attributed(_ text: String) -> AttributedString {
        ChatInlineMarkdown.attributed(text)
    }
}

extension View {
    /// An inline navigation title on iOS; other platforms keep their default.
    @ViewBuilder
    func navigationBarTitleDisplayModeInlineIfAvailable() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// ✓ or ✓✓ beside a message's time, like the web's read ticks: ✓✓ once someone other than the author has viewed
/// it. Tapping says who.
private struct RoomReadTicks: View {
    let views: RoomChatViews
    @State private var showsWho = false

    var body: some View {
        Button {
            showsWho.toggle()
        } label: {
            Text(views.ticks == .seen ? "✓✓" : "✓")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PocketPalette.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(views.seenBy)
        .accessibilityIdentifier("pocket.room.ticks")
        .overlay(alignment: .topLeading) {
            if showsWho {
                Text(views.seenBy)
                    .font(.caption2)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .fixedSize()
                    .offset(y: 18)
                    .onTapGesture { showsWho = false }
            }
        }
        .zIndex(showsWho ? 1 : 0)
    }
}

/// "Viewed by A, B and 2 more" under a message or reply, as the web shows it.
private struct RoomViewedLine: View {
    let views: RoomChatViews

    var body: some View {
        Text(views.line)
            .font(.caption2)
            .foregroundStyle(PocketPalette.textSecondary)
            .lineLimit(1)
            .accessibilityIdentifier("pocket.room.viewedBy")
    }
}

/// On the message or reply being read aloud: it shows that, and a tap stops the reading.
private struct RoomReadingAloudMark: View {
    let onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(PocketPalette.listening)
                .frame(width: 44, height: 44, alignment: .topTrailing)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop reading")
        .accessibilityIdentifier("pocket.room.readingAloud")
    }
}

/// The room's connection in words, then who is here: people first, then agents, active or idle.
private struct RoomPresenceSheet: View {
    let presence: RoomChatPresence?
    let connection: RoomConnectionState
    /// Everyone who came, when the room screen knows it; otherwise who is here now.
    var roster: RoomRoster = .empty
    /// Invite people, for the room's owner or an admin.
    var onInvite: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let onInvite {
                    Section {
                        Button(action: onInvite) {
                            Label("Invite people", systemImage: "person.badge.plus")
                        }
                        .accessibilityIdentifier("pocket.room.people.invite")
                    }
                }
                Section {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(RoomConnectionPill.color(for: connection))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(connection.label)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pocket.room.presence.connection")
                }
                if !roster.members.isEmpty {
                    // Agents and people apart, each with how many are online and offline (Carter, 10-30).
                    ForEach(roster.sides, id: \.title) { side in
                        Section {
                            ForEach(side.members) { member in
                                NavigationLink {
                                    RoomMemberDetail(member: member)
                                } label: {
                                    RoomMemberRow(member: member)
                                }
                                .accessibilityIdentifier("pocket.room.people.\(member.id)")
                            }
                        } header: {
                            Text("\(side.title) · \(side.online) online · \(side.offline) offline")
                                .accessibilityIdentifier("pocket.room.people.side.\(side.title.lowercased())")
                        }
                    }
                } else if let people = presence?.people, !people.isEmpty {
                    Section {
                        ForEach(people) { person in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(person.isIdle ? PocketPalette.textSecondary.opacity(0.5) : PocketPalette.verified)
                                    .frame(width: 8, height: 8)
                                    .accessibilityHidden(true)
                                Text(person.name)
                                Spacer(minLength: 0)
                                if !person.isHuman {
                                    Text("agent").font(.caption).foregroundStyle(PocketPalette.textSecondary)
                                }
                                if person.isIdle {
                                    Text("idle").font(.caption).foregroundStyle(PocketPalette.textSecondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .navigationTitle(presence?.label ?? "Who is here")
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}


/// Green for here, gray for idle, red for gone or ended.
private func rosterColor(_ status: RoomRoster.Status) -> Color {
    switch status {
    case .here: return PocketPalette.verified
    case .idle: return PocketPalette.textSecondary.opacity(0.5)
    case .gone, .ended: return PocketPalette.danger
    }
}

private func rosterAgo(_ date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func rosterSpan(_ seconds: TimeInterval?) -> String? {
    guard let seconds, seconds >= 60 else { return nil }
    let minutes = Int(seconds / 60)
    return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
}

/// One person, agent or box in the people list: who, what, and when they were last heard from.
private struct RoomMemberRow: View {
    let member: RoomRoster.Member

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(rosterColor(member.status))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.name).lineLimit(1)
                    Text(member.kind.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                Text([member.model, member.status == .ended ? "destroyed" : nil,
                      rosterAgo(member.lastSeen).map { "last \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(member.name), \(member.kind.rawValue), \(member.status.label)")
    }
}

/// Everything the room knows about one member (Carter: "what model and strength and how long they were here for
/// and whether they're still active or destroyed").
private struct RoomMemberDetail: View {
    let member: RoomRoster.Member

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Circle().fill(rosterColor(member.status)).frame(width: 10, height: 10)
                    Text(member.status == .ended ? "Destroyed" : member.status.label)
                }
                row("Kind", member.kind.rawValue)
                row("Model", member.model)
                row("Effort", member.effort)
                row("Job", member.job)
                row("Phase", member.phase)
            }
            Section("Time in the room") {
                row("First seen", rosterAgo(member.firstSeen))
                row("Last seen", rosterAgo(member.lastSeen))
                row("Here for", rosterSpan(member.timeHere))
                row("Messages", member.posts > 0 ? "\(member.posts)" : nil)
                row("Box ends", rosterAgo(member.expiresAt))
            }
        }
        .navigationTitle(member.name)
        .navigationBarTitleDisplayModeInlineIfAvailable()
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label).foregroundStyle(PocketPalette.textSecondary)
                Spacer(minLength: 12)
                Text(value).multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The room's pinned messages above the chat, like the web's strip: newest pin first, tap to jump to one.
private struct RoomPinnedStrip: View {
    let pinned: [RoomChatPinned]
    let limit: Int
    let canUnpin: Bool
    let onOpen: (Int64) -> Void
    let onUnpin: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Pinned", systemImage: "pin.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketPalette.warning)
                Text("\(min(pinned.count, limit))/\(limit)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pinned) { pin in
                        Button {
                            onOpen(pin.sequenceId)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                // One line each, as in a chat app's pinned bar: the chat keeps its room.
                                Text(pin.snippet)
                                    .font(.footnote)
                                    .foregroundStyle(PocketPalette.textPrimary)
                                    .lineLimit(1)
                                Text("Pinned by \(pin.pinnedBy)")
                                    .font(.caption2)
                                    .foregroundStyle(PocketPalette.textSecondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(width: 220, alignment: .leading)
                            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if canUnpin {
                                Button {
                                    onUnpin(pin.sequenceId)
                                } label: {
                                    Label("Unpin", systemImage: "pin.slash")
                                }
                            }
                        }
                        .accessibilityLabel("Pinned: \(pin.snippet)")
                        .accessibilityHint("Jumps to the message")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // The chat scrolls under the strip, so it needs an opaque bar beneath its tint.
        .background {
            ZStack {
                Rectangle().fill(.bar)
                PocketPalette.warning.opacity(0.08)
            }
        }
        .accessibilityIdentifier("pocket.room.pinned")
    }
}

/// A checkpoint, opened from its row (Carter: find the checkpoint, and have Pocket read it): its title and the
/// overview the web shows, the whole digest on demand, and Listen, which closes the sheet so the player shows.
private struct CheckpointSheet: View {
    let row: RoomChatMessageRow
    let send: (RoomChatIntent) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showsAll = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(row.text)
                        .font(.title3.bold())
                        .foregroundStyle(PocketPalette.textPrimary)
                    if let date = row.date {
                        Text("\(row.authorName) · \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                    if let summary = row.checkpointSummary {
                        let overview = CheckpointText.overview(summary)
                        ChatMarkdownView(text: overview.isEmpty ? summary : overview)
                        if overview != summary.trimmingCharacters(in: .whitespacesAndNewlines) {
                            DisclosureGroup("The whole digest", isExpanded: $showsAll) {
                                ChatMarkdownView(text: summary)
                                    .padding(.top, 6)
                            }
                            .font(.subheadline.weight(.semibold))
                            .tint(PocketPalette.accentStrong)
                        }
                    } else {
                        Text("This checkpoint has no summary.")
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Checkpoint")
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        send(.readAloud(id: "checkpoint:\(row.sequenceId)",
                                        text: CheckpointText.spoken(title: row.text, summary: row.checkpointSummary)))
                        dismiss()
                    } label: {
                        Label("Listen", systemImage: "speaker.wave.2.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PocketPalette.accentStrong)
                    .accessibilityIdentifier("pocket.checkpoint.listen")
                    Button {
                        send(.jumpToMessage(sequenceId: row.sequenceId))
                        dismiss()
                    } label: {
                        Label("Show in room", systemImage: "text.bubble")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .accessibilityIdentifier("pocket.checkpoint.sheet")
    }
}
/// Edits your own message or reply: the text as it is now, Save sends the new text (the room shows it as edited).
private struct MessageEditSheet: View {
    let original: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(original: String, onSave: @escaping (String) -> Void) {
        self.original = original
        self.onSave = onSave
        _text = State(initialValue: original)
    }

    private var canSave: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .padding(12)
                .accessibilityIdentifier("pocket.edit.text")
                .navigationTitle("Edit message")
                .navigationBarTitleDisplayModeInlineIfAvailable()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onSave(text)
                            dismiss()
                        }
                        .disabled(!canSave)
                        .accessibilityIdentifier("pocket.edit.save")
                    }
                }
                .onAppear { focused = true }
        }
    }
}
#endif
