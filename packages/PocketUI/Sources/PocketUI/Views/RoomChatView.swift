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
    /// Opens a profile card from an avatar, where direct messages are on.
    @Environment(\.roomProfileOpener) private var profileOpener
    /// The pickers and viewers a thread opens over itself.
    @Environment(\.roomSheetMediaHost) private var sheetMediaHost
    @State private var readerAtBottom = true
    /// The reader's place as the bottom marker reports it, settled outside layout, and whether the room is on screen
    /// to take it (see `RoomBottomSettle`). A reference, so keeping it never redraws the room.
    @State private var bottomWatch = RoomBottomWatch()
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
    /// The row the emoji picker is open for.
    @State private var reactingRow: RoomChatMessageRow?
    /// A long message opened in full.
    @State private var longRow: RoomChatMessageRow?
    /// "Jump to latest" from a window further back: scroll to the bottom once the live room has loaded.
    @State private var scrollsToLatestWhenLoaded = false
    @State private var highlightedRowId: String?
    /// Background lines opened in place.
    @State private var expandedQuiet: Set<String> = []
    /// Threads whose answer is minimized to its one line, by the message they answer (Carter, #58637).
    @State private var minimizedThreads: Set<Int64> = []
    /// Threads whose file parts are shown (by the thread's root sequence); otherwise they fold behind the file's card.
    @State private var shownFileParts: Set<Int64> = []
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

    /// Photos, videos and files on their way, where the room can take them: the composer's paperclip and tray, and the
    /// messages being sent. Read by those parts alone, so an upload never redraws the room.
    private let media: RoomMediaBoard?

    public init(
        state: RoomChatPresentationState,
        readingAloudId: String? = nil,
        composerActions: RoomComposerActions = RoomComposerActions(),
        roster: RoomRoster = .empty,
        media: RoomMediaBoard? = nil,
        send: @escaping (RoomChatIntent) -> Void
    ) {
        self.state = state
        self.readingAloudId = readingAloudId
        self.composerActions = composerActions
        self.roster = roster
        self.media = media
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
                hasRunningBox: state.hasRunningBox,
                replying: replyTarget,
                onCancelReply: { replyTarget = nil },
                onIntent: send,
                draftKey: state.draftKey,
                media: media
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
                    // The thread's own tray: files picked here never show in, or go with, the room's box.
                    media: media?.threadBoard(thread.parent.sequenceId),
                    previews: state.attachmentPreviews,
                    mediaHost: sheetMediaHost,
                    draftKey: state.draftKey,
                    send: send,
                    draft: threadDraft(thread.parent.sequenceId)
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { state.leaderboardSheet != nil },
            set: { presented in if !presented { send(.closeLeaderboard) } }
        )) {
            if let sheet = state.leaderboardSheet {
                RoomLeaderboardSheetView(
                    sheet: sheet,
                    onOpenMessage: {
                        // The sheet closes, and the room brings the board's message into view, loaded or not.
                        send(.closeLeaderboard)
                        send(.jumpToMessage(sequenceId: sheet.sequenceId))
                    },
                    onDone: { send(.closeLeaderboard) }
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
                    send(.readAloud(id: open.id, text: open.summary.prose))
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
        .sheet(item: $reactingRow) { row in
            RoomEmojiPickerSheet(recent: RoomEmojiPicker.recent()) { emoji in
                RoomEmojiPicker.noteUsed(emoji)
                send(row.emojiReaction(emoji, isOn: true))
                reactingRow = nil
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
                } : nil,
                onProfile: profileOpener.map { opener -> (RoomProfileTarget) -> Void in
                    return { target in
                        showsPresence = false
                        // After this sheet has gone, so the profile card can come up.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { opener(target) }
                    }
                },
                ownAuthorIds: profileOpener?.ownAuthorIds ?? []
            )
            .onAppear { send(.peopleOpened) }
        }
        // A room on its way off screen never writes the reader's place or tells the coordinator: its list is being
        // taken down, and the marker leaving with it is not the reader scrolling (one freeze came right after "room
        // closed").
        .onAppear { bottomWatch.isActive = true }
        .onDisappear { bottomWatch.isActive = false }
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
                    // One view per row, always. Unwrapped, a row made none (a folded file part), one, two (a turn break
                    // and its message) or more (file cards), and a lazy list that cannot tell how many builds every row
                    // of the room, on screen or not, at every layout pass, to count them. Carter's phone froze inside
                    // that walk (11-04 and 11-05: 12 to 13.5 s in a lazy list's placement, going item by item). Wrapped,
                    // the list builds only the rows it shows. Spacing 0, as the list's own, so nothing moves.
                    // A row's id is the loop's own, which every scroll to a row targets: `RoomRowScrollId`, a type
                    // no other view in the room has, so a scroll finds the row among the loop's ids and never looks
                    // through the string ids of the rows' own content (file cards, a thread's replies). No `.id` of the
                    // same value on the row: with one, the list kept every row it made as it opened and built them all
                    // again at each update (in CI 404 of 404 at every redraw and arrival), as master did.
                    ForEach(state.rows, id: \.scrollId) { row in
                        VStack(alignment: .leading, spacing: 0) {
                            rowView(row, proxy: proxy)
                        }
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
                    if let media {
                        RoomMediaOutgoingList(board: media)
                    }
                    newerHistoryFooter
                    if !state.composingAgents.isEmpty, !state.canLoadNewer {
                        RoomComposingLine(agents: state.composingAgents)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomId)
                        // The bottom of a window further back is not the live room's bottom. The marker only reports:
                        // the reader's place changes after layout (`markerSeen`).
                        .onAppear { if !state.canLoadNewer, heldAnchor == nil { markerSeen(true) } }
                        .onDisappear { markerSeen(false) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            // Dragging the messages lowers the keyboard with the finger, as in Messages.
            .scrollDismissesKeyboard(.interactively)
            // Sending photos or files brings you to the bottom, where the message appears, like a typed one. Told by the
            // board, not watched: an upload never redraws the room.
            .onAppear {
                media?.onNewOutgoing = {
                    if readerAtBottom {
                        heldAnchor = nil
                        DispatchQueue.main.async { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                    } else {
                        reopenAtLatest()
                    }
                }
            }
            // The reader scrolling lets go of a message they were taken to, and of the unread line being placed.
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
                bottomWatch.readerScrolled = true
                if heldAnchor != nil { heldAnchor = nil }
            })
            .overlay(alignment: .bottomTrailing) {
                if !readerAtBottom || state.canLoadNewer {
                    jumpToLatestButton(proxy: proxy)
                }
            }
            // The list starts below who is here, so the ring never covers the first message (Carter, #61679); rows
            // scrolled up pass under it. Always the same height, so the ring coming or changing shape moves nothing.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: RoomPeopleAvatars.reservedHeight)
            }
            // Who is here floats at the top center, under the top bar and the pins, over the messages (Carter, #55354,
            // #55424).
            .overlay(alignment: .top) {
                if let presence = state.presence {
                    RoomPeopleAvatars(presence: presence, models: roster.modelsById,
                                      signals: state.agentSignals(now: Date()),
                                      working: state.agentsWorking(now: Date()),
                                      boxes: roster.members.filter { $0.kind == .box && $0.status != .ended }.map(\.name),
                                      activeCount: roster.members.isEmpty ? nil : roster.activeCount,
                                      activeKeys: roster.members.isEmpty ? nil : roster.activeKeys,
                                      isPaused: showsPresence) {
                        showsPresence = true
                    }
                        .padding(.top, RoomPeopleAvatars.topGap)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !state.pinned.isEmpty {
                    RoomPinnedStrip(
                        pinned: state.pinned,
                        limit: state.pinLimit,
                        canUnpin: state.canPin,
                        leaderboard: state.leaderboard,
                        onOpenLeaderboard: { send(.openLeaderboard) },
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
                    proxy.scrollTo(row: heldAnchor, anchor: .center)
                } else {
                    keepAtBottomIfThere(proxy)
                }
            }
            .onChange(of: state.attachmentPreviews.count) { _ in
                if let heldAnchor { proxy.scrollTo(row: heldAnchor, anchor: .center) } else { keepAtBottomIfThere(proxy) }
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
                    proxy.scrollTo(row: heldAnchor, anchor: .center)
                    anchorBeforeOlderLoad = nil
                } else if let anchor = anchorBeforeOlderLoad {
                    proxy.scrollTo(row: anchor, anchor: .top)
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
        let _ = RenderTrace.built(.roomRow)
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
            // A part of a file posted as base64 folds behind the file's card, unless its thread's parts are shown.
            if message.filePartOf.map(shownFileParts.contains) ?? true {
                messageRow(message, proxy: proxy)
            }
            ForEach(message.files) { card in
                RoomFileCardView(card: card, showsParts: shownFileParts.contains(card.thread)) {
                    if shownFileParts.contains(card.thread) {
                        shownFileParts.remove(card.thread)
                    } else {
                        shownFileParts.insert(card.thread)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: RoomChatMessageRow, proxy: ScrollViewProxy) -> some View {
        if message.startsTurn {
            RoomTurnBreak(date: message.date)
        }
        RoomMessageRowView(
            row: message,
            ownHandles: state.ownMentionHandles,
            isHighlighted: highlightedRowId == RoomChatRow.message(message).id,
            canReact: state.canReact,
            canAddEmoji: state.canAddEmoji,
            canReply: state.composer.canPost,
            canPin: state.canPin,
            isPinned: state.isPinned(message),
            pinsFull: state.pinned.count >= state.pinLimit,
            breakouts: state.breakouts,
            attachmentPreviews: RoomMessageRowView.previews(of: message, in: state.attachmentPreviews),
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
            onAddReaction: { reactingRow = $0 },
            isMinimized: message.isInlineReply && message.replyToSequenceId.map { minimizedThreads.contains($0) } == true,
            onToggleMinimized: {
                guard let thread = message.replyToSequenceId else { return }
                if minimizedThreads.contains(thread) {
                    minimizedThreads.remove(thread)
                } else {
                    minimizedThreads.insert(thread)
                }
            },
            send: send
        )
        // Drawn again only when what it shows changed (`RoomMessageRowView.==`).
        .equatable()
        .onAppear { send(.messageOnScreen(id: message.id, isOnScreen: true)) }
        .onDisappear { send(.messageOnScreen(id: message.id, isOnScreen: false)) }
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
        let position = state.openPosition(reopening: listEpoch > 0)
        guard position == .latest || position == .unreadLine else { return }
        didInitialScroll = true
        // Say where the reader is now: the bottom marker may never render when the first scroll lands elsewhere,
        // and a reader who is not at the bottom must not be pulled down by the next message.
        let opensAtLine = position == .unreadLine
        setReaderAtBottom(!opensAtLine)
        DispatchQueue.main.async {
            if opensAtLine {
                proxy.scrollTo(row: RoomChatRow.unreadDivider.id, anchor: Self.unreadLineAnchor)
            } else {
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
            }
            // The list has left its top: from now on the header showing means the reader scrolled up to it.
            DispatchQueue.main.async { holdsOlderLoads = false }
            if opensAtLine {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.openLanding) { placeLineAgain(proxy) }
            }
        }
    }

    /// Rows are measured only as they come into view, so the first scroll places the line from estimated heights, and
    /// in a room of rows of very different heights (review packets, a long contract) those estimates move as soon as
    /// the rows are measured: on the 375-point simulator the line once ended below the fold, the bottom out of view.
    /// Once the rows around it are measured, the line is placed again, unless the reader has moved the list. With
    /// little below the line, that placement ends at the room's end, and the bottom marker reports from it as from any
    /// scroll, so the reader counts as at the bottom (the hosted tests check both, on the 375-point SE too).
    private func placeLineAgain(_ proxy: ScrollViewProxy) {
        guard bottomWatch.isActive, !bottomWatch.readerScrolled, heldAnchor == nil,
              state.rows.contains(.unreadDivider) else { return }
        proxy.scrollTo(row: RoomChatRow.unreadDivider.id, anchor: Self.unreadLineAnchor)
    }

    /// Where the unread line sits when the room opens at it: a little below the top, under the people floating there,
    /// with the end of what was read just above it.
    static let unreadLineAnchor = UnitPoint(x: 0.5, y: 0.15)
    /// Long enough for the scroll that opened the room to have been laid out.
    static let openLanding: TimeInterval = 0.3

    /// The room's own decision about the reader's place (it opened at the unread line, the reader was taken to a
    /// message, the latest is shown), at once and kept in step with the coordinator, which counts arrivals as unread
    /// while away. A marker report still waiting no longer lands, and a closing room decides nothing.
    private func setReaderAtBottom(_ atBottom: Bool) {
        guard bottomWatch.isActive else { return }
        bottomWatch.settle.set(atBottom)
        guard readerAtBottom != atBottom else { return }
        readerAtBottom = atBottom
        send(.readerAtBottom(atBottom))
    }

    /// The bottom marker came into view or left it. This runs during layout, where writing the reader's place redrew
    /// the room, the redraw moved the marker, and the marker wrote the place back, until iOS ended the app (664,848 row
    /// draws in 40 s). So it only reports, and the place lands on a later turn of the run loop once the report has held
    /// (`RoomBottomSettle`).
    private func markerSeen(_ shown: Bool) {
        guard bottomWatch.isActive, let check = bottomWatch.settle.marker(shown: shown) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + check.after) { landBottom(check) }
    }

    /// A marker report lands, or, when a hold ends (`check` nil), the marker's latest one.
    private func landBottom(_ check: RoomBottomSettle.Check?) {
        guard bottomWatch.isActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let landing = check.map { bottomWatch.settle.land($0, at: now) } ?? bottomWatch.settle.landLatest(at: now)
        switch landing {
        case .none:
            break
        case .changed(let atBottom):
            readerAtBottom = atBottom
            send(.readerAtBottom(atBottom))
        case .held(let until):
            // Once a hold, for the freeze recorder: how many rows the room had and how long its longest message was.
            send(.bottomFlapHeld(rows: state.rows.count, longestText: longestText))
            DispatchQueue.main.asyncAfter(deadline: .now() + max(until - now, 0)) { landBottom(nil) }
        }
    }

    /// The longest message loaded, in characters, for the freeze recorder.
    private var longestText: Int {
        state.rows.reduce(0) { longest, row in
            guard case .message(let message) = row else { return longest }
            return max(longest, message.text.count)
        }
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
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(row: rowId, anchor: .center) }
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
            proxy.scrollTo(row: target.id, anchor: .center)
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

    /// The bottom marker's id, of a type of its own: a scroll to it finds it without looking through the rows, whose
    /// file cards and pending rows carry string ids (with a string here, an arrival's scroll to the bottom could build
    /// every row of the room once to look).
    private static let bottomId = RoomBottomMarkerId()
}

/// The type of the room's bottom marker id, which no other view in the room has.
private struct RoomBottomMarkerId: Hashable {}

/// The type of a room row's id in the room's loop, which no other view in the room has (the rows' own content, file
/// cards, a thread's replies, pending rows, carry string ids). A scroll to a row by a string looked its id up through
/// those, building every row of the room once to do it.
private struct RoomRowScrollId: Hashable {
    let rowId: String
}

private extension RoomChatRow {
    /// This row's id in the room's loop (`RoomRowScrollId`).
    var scrollId: RoomRowScrollId { RoomRowScrollId(rowId: id) }
}

private extension ScrollViewProxy {
    /// Scrolls to the room's row with this id (`RoomChatRow.id`), by its id in the room's loop.
    func scrollTo(row rowId: String, anchor: UnitPoint) {
        scrollTo(RoomRowScrollId(rowId: rowId), anchor: anchor)
    }
}

/// What the room keeps about its bottom marker without redrawing for it: the settled place, and whether the room is on
/// screen to take it.
private final class RoomBottomWatch {
    var settle = RoomBottomSettle()
    var isActive = true
    /// The reader has dragged the list since it opened.
    var readerScrolled = false
}

/// A thread summary opened whole: its read-aloud id (so the sheet shows Stop while it is read) and the summary.
private struct OpenThreadSummary: Identifiable {
    let id: String
    let summary: SummaryReading
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

/// What a message's menu shows above it: who wrote it, its first 8 lines, and one line for what it carries (a photo's
/// thumbnail or a "Photo", "Video" or file name label, and how many more), in a card 320 points wide at any text size.
/// Never the row itself: a long message, a big file card or many images make no second copy here. Read by VoiceOver as
/// one element, the author then the text.
struct RoomMessageMenuPreview: View {
    let row: RoomChatMessageRow
    let ownHandles: Set<String>
    /// The first photo's preview bytes, when loaded.
    var thumbnail: Data?

    /// The most lines of the message the preview shows.
    static let textLines = 8

    /// What the message carries, as one line: the first item's name, and how many more.
    static func carried(_ row: RoomChatMessageRow) -> (symbol: String, label: String)? {
        let names = row.attachments.filter { !$0.isRemoved }.map { chip -> (String, String) in
            switch chip.kind {
            case .image: return ("photo", "Photo")
            case .video: return ("video", "Video")
            default: return ("doc", chip.filename)
            }
        } + row.files.map { ("doc.zipper", $0.name) }
        guard let first = names.first else { return nil }
        return (first.0, names.count > 1 ? "\(first.1) and \(names.count - 1) more" : first.1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.authorName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.textSecondary)
                .lineLimit(1)
            if !row.text.isEmpty {
                Text(ChatInlineMarkdown.attributed(row.text, ownHandles: ownHandles))
                    .font(.subheadline)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .lineLimit(Self.textLines)
            }
            if let carried = Self.carried(row) {
                HStack(spacing: 8) {
                    if let thumbnail, let image = RoomImageData.image(from: thumbnail) {
                        image.resizable().scaledToFill().frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: carried.symbol).foregroundStyle(PocketPalette.textSecondary)
                    }
                    Text(carried.label)
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .lineLimit(1)
                }
            } else if row.text.isEmpty {
                Text("Message").font(.subheadline).foregroundStyle(PocketPalette.textSecondary)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(PocketPalette.raised)
        .accessibilityElement(children: .combine)
    }
}

private struct RoomMessageRowView: View {
    let row: RoomChatMessageRow
    let ownHandles: Set<String>
    let isHighlighted: Bool
    var canReact = false
    /// The emoji picker is offered.
    var canAddEmoji = false
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
    var threadSummary: SummaryReading?
    /// That summary is being read aloud.
    var isReadingSummary = false
    /// Open the whole summary: the summary and what reads it aloud.
    var onOpenSummary: (SummaryReading, String) -> Void = { _, _ in }
    let onOpenReplyTarget: (Int64) -> Void
    var onOpenCheckpoint: (RoomChatMessageRow) -> Void = { _ in }
    var onEdit: (RoomChatMessageRow) -> Void = { _ in }
    var onToggleQuiet: () -> Void = {}
    var onOpenLong: (RoomChatMessageRow) -> Void = { _ in }
    /// Reply to this row from the room's box, without leaving the room (Carter, #55074).
    var onReply: (RoomChatMessageRow) -> Void = { _ in }
    /// Open the emoji picker for this row.
    var onAddReaction: (RoomChatMessageRow) -> Void = { _ in }
    /// A thread's answer shown in the room, minimized to the line over it: what it answers and who replied.
    var isMinimized = false
    var onToggleMinimized: () -> Void = {}
    var send: (RoomChatIntent) -> Void = { _ in }
    /// How far the row follows a swipe to the right (swipe to reply, as in Messages).
    @State private var swipe: CGFloat = 0
    /// A double tap opens the same options as a long press.
    @State private var showsOptions = false

    var body: some View {
        RenderTrace.row(row.sequenceId)
        return rowBody
    }

    @ViewBuilder
    private var rowBody: some View {
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
            // Who joined, by the name the server gives; never the server itself.
            Text("\(row.text.isEmpty ? "Someone" : row.text) joined the room")
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
                        VoiceCallCardView(card: call, ownHandles: ownHandles,
                                          openAttachment: { send(.openAttachment(attachmentId: $0)) })
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
        // The menu shows a preview of its own, never the row lifted out of the list: at the largest text size a row
        // can be taller than the screen, and lifting it set the room laying itself out again without end
        // (FreezePathsUITests path 4 at AX5: the main thread 100% busy for 15 s; with the preview, 0.8%).
        .contextMenu { messageMenu } preview: {
            RoomMessageMenuPreview(row: row, ownHandles: ownHandles,
                                   thumbnail: row.attachments.lazy.compactMap { attachmentPreviews[$0.attachmentId] }.first)
        }
        // Simultaneous, so a single tap on a link or a button inside the message is never held back.
        .simultaneousGesture(TapGesture(count: 2).onEnded { showsOptions = true })
        .confirmationDialog("Message options", isPresented: $showsOptions, titleVisibility: .hidden) {
            ForEach(rowOptions) { option in
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
            HStack(alignment: .top, spacing: 6) {
                quoteButton(reply)
                if row.isInlineReply {
                    Spacer(minLength: 0)
                    minimizeButton
                }
            }
            if let threadSummary, !isMinimized, row.trail.map({ $0.count > 1 }) == true {
                HStack(alignment: .top, spacing: 0) {
                    Button { openWholeSummary() } label: {
                        ThreadSummaryText(summary: threadSummary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the whole summary")
                    Spacer(minLength: 0)
                    ThreadSummaryListenButton(isReading: isReadingSummary) { listenToSummary() }
                }
                .padding(.leading, 10)
            }
            if let receipt = row.trail?.receipt {
                receiptChip(receipt, thread: reply)
            }
        }
    }

    /// What the row answers, as a line: opens the thread, or the message a plain reply answers.
    private func quoteButton(_ reply: Int64) -> some View {
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
    }

    /// Minimizes the answer to the line over it, or shows it again (Carter, #58637: "I should still be able to minimize
    /// the reply that answered me").
    private var minimizeButton: some View {
        Button(action: onToggleMinimized) {
            Image(systemName: isMinimized ? "chevron.down" : "chevron.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.textSecondary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMinimized ? "Show the reply" : "Minimize the reply")
        .accessibilityIdentifier("pocket.room.reply.minimize.\(row.id)")
    }

    /// The room's own receipt in this thread (the ticket keeper's tickets), as one small line that opens the thread.
    private func receiptChip(_ receipt: String, thread: Int64) -> some View {
        Button {
            send(.openThread(sequenceId: thread))
        } label: {
            Text(receipt)
                .font(.caption2)
                .foregroundStyle(PocketPalette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(PocketPalette.raised, in: Capsule())
                .overlay(Capsule().stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(.leading, 10)
        .accessibilityHint("Opens the thread")
        .accessibilityIdentifier("pocket.room.reply.receipt.\(row.id)")
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
            send(.readAloud(id: id, text: threadSummary.prose))
        }
    }

    /// What the quote says: what the reply answers, and for a thread how many replies and who.
    private func quoteText(_ reply: Int64) -> String {
        let answers = row.replyContext ?? "Replying to #\(reply)"
        guard let trail = row.trail, trail.count > 1 else { return answers }
        return "\(trail.label) on \(answers)"
    }

    /// Edited mark, attachments, who viewed it and the reactions: the same under every kind of message.
    private var messageFooter: some View { footer(showsAttachments: true) }

    /// A message's files, over its words (Carter, #58637: "put image attachment at the top of the message on the
    /// right"): yours on the right with your bubble, everyone else's on the left.
    @ViewBuilder
    private func attachmentsOnTop(alignment: HorizontalAlignment) -> some View {
        if !row.attachments.isEmpty {
            RoomAttachmentsView(chips: row.attachments, previews: attachmentPreviews, alignment: alignment, send: send)
        }
    }

    @ViewBuilder
    private func footer(showsAttachments: Bool) -> some View {
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
        if showsAttachments, !row.attachments.isEmpty {
            RoomAttachmentsView(chips: row.attachments, previews: attachmentPreviews, send: send)
        }
        if let reactions = row.reactions {
            RoomReactionBar(
                reactions: reactions,
                sequenceId: row.sequenceId,
                canReact: canReact,
                canAddEmoji: canAddEmoji,
                onReact: { send(row.reaction($0)) },
                onEmoji: { send(row.emojiToggle($0)) },
                onAddReaction: { onAddReaction(row) },
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
                if !isMinimized {
                    attachmentsOnTop(alignment: .trailing)
                    // A reply of photos or files alone has no words, and no empty bubble.
                    if !row.text.isEmpty {
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
                    }
                    footer(showsAttachments: false)
                }
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
            RoomProfileAvatar(senderId: row.authorId, name: row.authorName, isHuman: true)
                .opacity(row.showsHeader ? 1 : 0)
                .allowsHitTesting(row.showsHeader)
                .accessibilityHidden(!row.showsHeader)
            VStack(alignment: .leading, spacing: 4) {
                if row.showsHeader { authorLine }
                replyQuote
                if !isMinimized {
                    attachmentsOnTop(alignment: .leading)
                    if !row.text.isEmpty {
                        messageText
                            .font(.body)
                            .foregroundStyle(PocketPalette.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(bubbleFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    if row.isEdited {
                        Text("edited").font(.caption2).foregroundStyle(PocketPalette.textSecondary)
                    }
                    footer(showsAttachments: false)
                }
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
                    RoomProfileAvatar(senderId: row.authorId, name: row.authorName, isHuman: false)
                    authorLine
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                replyQuote
                if !isMinimized {
                    attachmentsOnTop(alignment: .leading)
                    if !row.text.isEmpty {
                        messageText
                            .font(.body)
                            .foregroundStyle(PocketPalette.textPrimary)
                    }
                    if row.isEdited {
                        Text("edited").font(.caption2).foregroundStyle(PocketPalette.textSecondary)
                    }
                    footer(showsAttachments: false)
                }
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
        let options = rowOptions
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

    private static let actionRowKinds: [RoomRowOption.Kind] = [.copy, .listen, .like, .dislike, .emoji, .reply, .thread]

    /// This row's options, for its action row, its long-press menu and its double-tap options.
    private var rowOptions: [RoomRowOption] {
        row.options(canReply: canReply, canReact: canReact, canPin: canPin, isPinned: isPinned, pinsFull: pinsFull,
                    canEdit: canReply, canAddEmoji: canAddEmoji)
    }

    private func perform(_ option: RoomRowOption) {
        if option.kind == .reply {
            onReply(row)
        } else if option.kind == .emoji {
            onAddReaction(row)
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
        ForEach(rowOptions) { option in
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
    var size: CGFloat = 26

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
            .font(.system(size: (size * 0.42).rounded(), weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            // People are round, agents are rounded squares.
            .background(Self.tint(for: name),
                        in: RoundedRectangle(cornerRadius: isHuman ? size / 2 : (size * 0.27).rounded(), style: .continuous))
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
private func emptyComposer(_ draft: Binding<String>, clears: @escaping (String) -> Bool) {
    draft.wrappedValue = ""
    DispatchQueue.main.async {
        draft.wrappedValue = ""
        // Only the write-back the box's onChange saw land straight in the emptied box, still exactly as it landed
        // (`RoomComposerWriteBack`): what was typed since is kept (#298 review).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if clears(draft.wrappedValue) { draft.wrappedValue = "" }
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
    /// The message's sequence, for the emoji chips' identifiers.
    let sequenceId: Int64
    let canReact: Bool
    var canAddEmoji = false
    let onReact: (String) -> Void
    /// An emoji chip was tapped.
    var onEmoji: (RoomChatReactions.EmojiChip) -> Void = { _ in }
    var onAddReaction: () -> Void = {}
    let onOpenThread: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !reactions.chips.isEmpty || !reactions.emojiChips.isEmpty || reactions.replyCount > 0
                || reactions.isPinned {
                RoomReactionFlow(spacing: 6) {
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
                    ForEach(Array(reactions.emojiChips.enumerated()), id: \.element.id) { index, chip in
                        Button {
                            onEmoji(chip)
                        } label: {
                            HStack(spacing: 4) {
                                Text(chip.emoji)
                                    .font(.subheadline)
                                Text("\(chip.count)").monospacedDigit()
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(chip.isMine ? PocketPalette.accent.opacity(0.18) : PocketPalette.raised)
                            )
                            .overlay(Capsule().stroke(
                                chip.isMine ? PocketPalette.accent.opacity(0.7) : PocketPalette.separator.opacity(0.6),
                                lineWidth: chip.isMine ? 1 : 0.5
                            ))
                            .modifier(RoomReactionTapArea())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canReact)
                        .accessibilityLabel(chip.accessibilityLabel(canReact: canReact))
                        .accessibilityIdentifier("pocket.room.emoji.\(sequenceId).\(index)")
                    }
                    // Beside the emoji already there; the action row and the menu offer it too.
                    if canAddEmoji, !reactions.emojiChips.isEmpty {
                        Button(action: onAddReaction) {
                            Image(systemName: "face.smiling")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PocketPalette.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(PocketPalette.raised))
                                .overlay(Capsule().stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5))
                                .modifier(RoomReactionTapArea())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add reaction")
                        .accessibilityIdentifier("pocket.room.emoji.\(sequenceId).add")
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

/// A compact chip with a full-size tap area: at least 44 by 44 points, the chip drawn in its middle.
private struct RoomReactionTapArea: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// Reaction chips in lines, as many as fit on each, every line's chips centred on it: one line until a message has
/// more reactions than the width holds.
private struct RoomReactionFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(of: subviews, width: proposal.width ?? .infinity)
        return CGSize(
            width: lines.map(\.width).max() ?? 0,
            height: lines.map(\.height).reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0))
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(of: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private func lines(of subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var lines: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = lines.last, last.width + spacing + size.width <= width {
                lines[lines.count - 1] = (last.indices + [index], last.width + spacing + size.width,
                                          max(last.height, size.height))
            } else {
                lines.append(([index], size.width, size.height))
            }
        }
        return lines
    }
}

/// The emoji picker: your recently used reactions over a grid of common ones. Picking one reacts with it.
private struct RoomEmojiPickerSheet: View {
    let recent: [String]
    let onPick: (String) -> Void

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add reaction")
                .font(.headline)
                .foregroundStyle(PocketPalette.textPrimary)
            if !recent.isEmpty {
                Text("Recently used")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketPalette.textSecondary)
                LazyVGrid(columns: Self.columns, spacing: 4) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { index, emoji in
                        pick(emoji, identifier: "pocket.room.emoji.recent.\(index)")
                    }
                }
                Text("Common")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(Array(RoomEmojiPicker.common.enumerated()), id: \.offset) { index, emoji in
                    pick(emoji, identifier: "pocket.room.emoji.common.\(index)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.medium, .large])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.room.emoji.picker")
    }

    private func pick(_ emoji: String, identifier: String) -> some View {
        Button {
            onPick(emoji)
        } label: {
            Text(emoji)
                .font(.system(size: 30))
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
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
    /// Photos, videos and files for a reply, where the room takes them (Carter, 11-04: replies carry photos and files
    /// like messages): the thread's own tray (`RoomMediaBoard.threadBoard`), sent from here as a reply.
    var media: RoomMediaBoard?
    /// Photo previews the room has loaded, for the replies' photos.
    var previews: [String: Data] = [:]
    /// The pickers and viewers, hosted by this sheet (the room under it cannot present them).
    var mediaHost: RoomSheetMediaHost?
    /// The room's saved-text key for this account: the reply being written is kept on the phone under it
    /// (`RoomReplyDrafts`); nil keeps none.
    var draftKey: String?
    let send: (RoomChatIntent) -> Void
    @Binding var draft: String
    /// A sent reply's text stays saved until the server has it (the coordinator lets it go then); typing meanwhile is
    /// saved once that has had time to happen, as in the room's box.
    @State private var keepsSavedDraft = false
    @State private var sends = 0
    /// The reply the restored text answered, until its row is loaded to answer it again.
    @State private var restoringAnswer: String?
    /// The reply being answered (a reply to a reply nests under it); nil answers the message.
    @State private var answering: RoomChatReplyRow?
    /// "File as a ticket": the reply goes to the room's ticket keeper as a ticket request.
    @State private var ticketMode = false
    @State private var isReplying = false
    /// Your own reply being edited.
    @State private var editingReply: RoomChatReplyRow?
    /// Where the reply text last changed (the field does not say where the caret is), for an @ anywhere in it.
    @State private var editOffset: Int?
    @State private var lastDraft = ""
    /// The reply just sent, for a moment, and what the keyboard wrote back of it into the emptied box (see
    /// `emptyComposer`).
    @State private var replySent: String?
    @State private var replyWrittenBack = RoomComposerWriteBack()
    /// The thread's file parts are shown; otherwise they fold behind the file's card.
    @State private var showsFileParts = false
    /// Writes the reply box's text a moment after typing pauses, not on every keystroke.
    @State private var draftWriter = RoomDraftDebouncer()

    /// The + page's actions besides files (Carter, #58635).
    private var plusActions: [RoomComposerMore] {
        var items = [
            RoomComposerMore(id: "mention", title: "Mention someone", detail: "Adds an @ to your reply", symbolName: "at") {
                let separated = draft.isEmpty || draft.last?.isWhitespace == true
                draft += separated ? "@" : " @"
                isReplying = true
            },
            RoomComposerMore(id: "ticket", title: "File as a ticket",
                             detail: "The ticket keeper files your words and replies with the link", symbolName: "ticket") {
                ticketMode = true
                isReplying = true
            }
        ]
        if self.actions.canSearch {
            // Search opens over the room, so the thread steps aside first.
            items.append(RoomComposerMore(id: "search", title: "Search this room", detail: "Messages, people and files",
                                            symbolName: "magnifyingglass") {
                send(.closeThread)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { send(.openSearch) }
            })
        }
        return items
    }

    private var suggestions: [MentionCandidate] {
        // No offset means the edit ended at the end: look back over the last word only, never counting the draft.
        let query = editOffset.map { MentionSuggester.activeQuery(in: draft, at: $0)?.query } ?? MentionSuggester.queryAtEnd(of: draft)
        guard let query else { return [] }
        return MentionSuggester.suggestions(for: query, among: mentionCandidates)
    }

    private var drafts: RoomReplyDrafts? { draftKey.map { RoomReplyDrafts(base: $0) } }

    /// Keeps the box's text on the phone as it is typed, for whatever it answers now: once typing pauses
    /// (`RoomDraftDebouncer`), and at once when the thread closes or the reply is sent.
    private func saveDraft() {
        guard !keepsSavedDraft, restoringAnswer == nil, let drafts else { return }
        let text = draft
        let sequenceId = thread.parent.sequenceId
        let reply = answering?.id
        draftWriter.schedule { drafts.save(text, thread: sequenceId, reply: reply) }
    }

    /// What was being written in this thread, back in the box when it opens (after the room was left, rebuilt or the
    /// app relaunched), answering the reply it answered.
    private func restoreDraft() {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let saved = drafts?.restore(thread: thread.parent.sequenceId) else { return }
        restoringAnswer = saved.reply
        lastDraft = saved.text
        draft = saved.text
        answerRestoredReply()
    }

    /// The restored text answered a reply: answer it again once its row is loaded (the message, if it is gone).
    private func answerRestoredReply() {
        guard let id = restoringAnswer else { return }
        if let row = thread.replies.first(where: { $0.id == id }) {
            answering = row
            restoringAnswer = nil
        } else if !thread.isLoading {
            restoringAnswer = nil
        }
    }

    /// A send leaves the sent text saved until the server has it; what is typed after it is saved once that has had
    /// time to happen.
    private func holdSavedDraftWhileSending() {
        // What was typed last is saved before the box empties, so a failed send keeps all of it.
        draftWriter.flush()
        keepsSavedDraft = true
        sends += 1
        let sending = sends
        DispatchQueue.main.asyncAfter(deadline: .now() + RoomComposerDraft.savedAfterSend) {
            guard sends == sending else { return }
            keepsSavedDraft = false
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { saveDraft() }
        }
    }

    private func answer(_ reply: RoomChatReplyRow) {
        answering = reply
        let mention = "@\(reply.authorHandle) "
        if !draft.hasPrefix(mention) { draft = mention + draft }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(thread.parent.authorName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(thread.parent.isHuman ? PocketPalette.listening : PocketPalette.textPrimary)
                        if thread.parent.filePartOf == nil || showsFileParts {
                            ChatMarkdownView(text: thread.parent.text, ownHandles: ownHandles)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    ForEach(thread.parent.files) { card in
                        RoomFileCardView(card: card, showsParts: showsFileParts) { showsFileParts.toggle() }
                    }

                    if thread.isLoading && thread.replies.isEmpty {
                        ProgressView("Loading replies").frame(maxWidth: .infinity)
                    }
                    if let failure = thread.failureText {
                        Text(failure).font(.footnote).foregroundStyle(PocketPalette.warning)
                    }
                    ForEach(thread.replies.filter { showsFileParts || $0.filePartOf == nil }) { reply in
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
                            if !reply.text.isEmpty {
                                ChatMarkdownView(text: reply.text, ownHandles: ownHandles)
                            }
                            if !reply.attachments.isEmpty {
                                RoomAttachmentsView(chips: reply.attachments, previews: previews, send: send)
                            }
                            if let views = reply.views {
                                RoomViewedLine(views: views)
                            }
                        }
                        .id(Self.replyAnchor(reply.id))
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(thread.focusReplyId == reply.id ? PocketPalette.accent.opacity(0.12) : Color.clear)
                                .padding(-4)
                        )
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
                    // This thread's replies with files on their way, each with its pictures and progress.
                    if let media {
                        RoomMediaOutgoingList(board: media, thread: thread.parent.sequenceId)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            // Opened at a reply (its notification): it comes into view once the replies are loaded.
            .onAppear {
                showFocusedReply(proxy)
                restoreDraft()
            }
            // Closing the thread writes what typing had not yet saved.
            .onDisappear { draftWriter.flush() }
            .onChange(of: thread.replies.count) { _ in
                showFocusedReply(proxy)
                answerRestoredReply()
            }
            .onChange(of: thread.isLoading) { _ in answerRestoredReply() }
            .onChange(of: answering?.id) { _ in saveDraft() }
            }
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
            .background { mediaHost?.content() }
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
                    if let media {
                        RoomMediaTray(board: media)
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        // Files go with a reply as with a message (never with a ticket).
                        RoomComposerPlusButton(board: ticketMode ? nil : media, more: plusActions,
                                               identifier: "pocket.thread.composer.plus")
                            .padding(.bottom, 1)
                        ComposerTextField(placeholder: ticketMode ? "Describe the ticket" : "Reply", text: $draft,
                                          isFocused: $isReplying, identifier: "pocket.thread.composer")
                            .onChange(of: draft) { new in
                                replyWrittenBack.changed(from: lastDraft, to: new, sent: replySent)
                                editOffset = MentionSuggester.editOffsetUnlessAtEnd(from: lastDraft, to: new)
                                lastDraft = new
                                saveDraft()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        if let media {
                            // Sends once there are words or files; never with neither.
                            RoomMediaSendButton(board: media, canSendText: canSendReply,
                                                hasProblem: thread.replyLengthProblem(for: draft) != nil,
                                                label: "Send reply", identifier: "pocket.thread.send") {
                                sendReply()
                            }
                        } else {
                            Button {
                                sendReply()
                            } label: {
                                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                            }
                            .buttonStyle(.plain)
                            .disabled(!canSendReply)
                            .accessibilityLabel("Send reply")
                            .accessibilityIdentifier("pocket.thread.send")
                        }
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

    /// The reply the box answers: the one chosen, or the one restored text answered before its row has loaded, so
    /// sending early still answers it (never the message instead).
    private var answeringId: String? { RoomReplyDrafts.answering(chosen: answering?.id, restoring: restoringAnswer) }

    /// Sends what is in the reply box: with files in the tray, the words and the files as one reply (its card shows
    /// here while they upload); otherwise the words, or the ticket they describe. Never a reply with neither.
    private func sendReply() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let answeringId = self.answeringId
        if let media, !media.tray.isEmpty {
            guard thread.replyLengthProblem(for: draft) == nil else { return }
            ticketMode = false
            restoringAnswer = nil
            let target = RoomMediaReplyTarget(sequenceId: thread.parent.sequenceId, replyId: answeringId,
                                              name: answering?.authorName ?? thread.parent.authorName)
            if !typed.isEmpty {
                holdSavedDraftWhileSending()
                replySent = typed
                replyWrittenBack.sent()
                emptyComposer($draft) { replyWrittenBack.clears($0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if replySent == typed { replySent = nil }
                }
            }
            answering = nil
            media.perform(.sendReply(text: typed, to: target))
            return
        }
        guard canSendReply else { return }
        let text = ticketMode ? RoomComposerDraft.ticketRequest(typed) : typed
        ticketMode = false
        restoringAnswer = nil
        holdSavedDraftWhileSending()
        if let answeringId {
            send(.sendReplyToReply(sequenceId: thread.parent.sequenceId, replyId: answeringId, text: text))
        } else {
            send(.sendReply(sequenceId: thread.parent.sequenceId, text: text))
        }
        replySent = typed
        replyWrittenBack.sent()
        emptyComposer($draft) { replyWrittenBack.clears($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if replySent == typed { replySent = nil }
        }
        answering = nil
    }

    private static func replyAnchor(_ id: String) -> String { "reply:" + id }

    /// Brings the reply the thread was opened at into view, once it is loaded.
    private func showFocusedReply(_ proxy: ScrollViewProxy) {
        guard let focus = thread.focusReplyId, thread.replies.contains(where: { $0.id == focus }) else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(Self.replyAnchor(focus), anchor: .center) }
        }
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

/// What the room's composer says before you type. A box hears only what @-names it or answers it in its thread (Carter,
/// #61679, keeping that rule), so where a running box is in the room the composer says how to reach it; a room of
/// people keeps "Message".
enum RoomComposerPlaceholder {
    static let reachAgents = "@name to reach an agent"

    static func text(ticketMode: Bool, replying: Bool, hasRunningBox: Bool) -> String {
        if ticketMode { return "Describe the ticket" }
        if replying { return "Reply" }
        return hasRunningBox ? reachAgents : "Message"
    }
}

private struct RoomComposerBar: View {
    let composer: RoomComposerState
    var mentionCandidates: [MentionCandidate] = []
    var restored: RoomComposerRestore?
    var actions = RoomComposerActions()
    /// A box still running is in the room: the placeholder says how to reach it.
    var hasRunningBox = false
    /// The message this box answers, in its thread; nil writes to the room.
    var replying: RoomChatMessageRow?
    var onCancelReply: () -> Void = {}
    var onIntent: (RoomChatIntent) -> Void = { _ in }
    /// Where this room's unsent text is kept on the phone, so a crash or a relaunch never loses it.
    var draftKey: String?
    /// Photos, videos and files for the next message, where the room takes them.
    var media: RoomMediaBoard?
    let send: (String) -> Void
    @State private var draft = ""
    /// The text just sent, for a moment: the keyboard can write it back into the emptied box (dictation, a pending
    /// correction), and that is not a paste.
    @State private var justSent: String?
    /// The sent text as the keyboard wrote it back into the emptied box, if it did: the only text the send's delayed
    /// cleanup empties.
    @State private var writtenBack = RoomComposerWriteBack()
    /// While a send settles, the sent text stays saved (see `sendDraft()`); which send that is.
    @State private var keepsSavedDraft = false
    @State private var sends = 0
    @State private var isEditing = false
    /// "File as a ticket": what you type goes to the room as a ticket request, and the ticket keeper files it.
    @State private var ticketMode = false
    /// Where the text last changed (the field does not say where the caret is), for an @ anywhere in it.
    @State private var editOffset: Int?
    @State private var lastDraft = ""
    /// Long pastes, held above the field as attachments and sent after the typed words (Carter, #55006).
    @State private var pasted: [String] = []
    @State private var viewingPaste: PastedBlock?

    /// The + page's actions besides files (Carter, #58635).
    private var plusActions: [RoomComposerMore] {
        var items = [
            RoomComposerMore(id: "mention", title: "Mention someone", detail: "Adds an @ to your message", symbolName: "at") {
                let separated = draft.isEmpty || draft.last?.isWhitespace == true
                draft += separated ? "@" : " @"
                isEditing = true
            },
            // Plain words become a ticket: the room's ticket keeper files it and replies with the link.
            RoomComposerMore(id: "ticket", title: "File as a ticket",
                             detail: "The ticket keeper files your words and replies with the link", symbolName: "ticket") {
                ticketMode = true
                isEditing = true
            }
        ]
        if self.actions.canSearch {
            items.append(RoomComposerMore(id: "search", title: "Search this room", detail: "Messages, people and files",
                                            symbolName: "magnifyingglass") { onIntent(.openSearch) })
        }
        return items
    }

    /// Sends what is in the box. The box empties first; the message goes to the room on the next turn of the run loop,
    /// so the emptied box, the new row and the scroll to it are not all laid out in one update (every freeze on 10-30
    /// began at a send). The text stays saved on the phone for a few seconds more, long enough to be on its way: if
    /// the app is closed before then, it is back in the box at the next launch.
    private func sendDraft() {
        let text = outgoing
        if !text.isEmpty || media?.tray.isEmpty == false { onIntent(.sendTapped(characters: text.count)) }
        if let media, !media.tray.isEmpty {
            sendWithMedia(media, text: text)
            return
        }
        guard !text.isEmpty else { return }
        let message = ticketMode ? RoomComposerDraft.ticketRequest(text) : text
        ticketMode = false
        pasted = []
        justSent = text
        writtenBack.sent()
        keepsSavedDraft = true
        sends += 1
        let sending = sends
        if let draftKey { UserDefaults.standard.set(text, forKey: draftKey) }
        emptyComposer($draft) { writtenBack.clears($0) }
        DispatchQueue.main.async { send(message) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if sends == sending { justSent = nil } }
        DispatchQueue.main.asyncAfter(deadline: .now() + RoomComposerDraft.savedAfterSend) {
            guard sends == sending else { return }
            keepsSavedDraft = false
            // Typing since is saved; the sent text itself goes when the room confirms it (`forgetSaved`).
            if !outgoing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { saveDraft() }
        }
    }

    /// Sends the tray as one message, with what was typed: or, swiped to reply, as one reply in that message's thread.
    /// The words go with the files (never as a ticket), and it shows at once with each file's picture while they
    /// upload.
    private func sendWithMedia(_ media: RoomMediaBoard, text: String) {
        pasted = []
        ticketMode = false
        let target = replying.map {
            RoomMediaReplyTarget(sequenceId: $0.sequenceId, replyId: $0.inlineReplyId, name: $0.authorName)
        }
        if replying != nil { onCancelReply() }
        if let draftKey { UserDefaults.standard.removeObject(forKey: draftKey) }
        if !text.isEmpty {
            justSent = text
            writtenBack.sent()
            sends += 1
            let sending = sends
            emptyComposer($draft) { writtenBack.clears($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if sends == sending { justSent = nil } }
        }
        DispatchQueue.main.async {
            if let target {
                media.perform(.sendReply(text: text, to: target))
            } else {
                media.perform(.send(text: text))
            }
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
        // No offset means the edit ended at the end: look back over the last word only, never counting the draft.
        let query = editOffset.map { MentionSuggester.activeQuery(in: draft, at: $0)?.query } ?? MentionSuggester.queryAtEnd(of: draft)
        guard let query else { return [] }
        return MentionSuggester.suggestions(for: query, among: mentionCandidates)
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
            if let media {
                RoomMediaTray(board: media)
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
                RoomComposerPlusButton(board: ticketMode ? nil : media, more: plusActions,
                                       identifier: "pocket.room.composer.plus")
                    .padding(.bottom, 1)
                ComposerTextField(placeholder: RoomComposerPlaceholder.text(ticketMode: ticketMode, replying: replying != nil,
                                                                            hasRunningBox: hasRunningBox),
                                  text: $draft, isFocused: $isEditing, identifier: "pocket.room.composer")
                    .onChange(of: draft) { new in
                        writtenBack.changed(from: lastDraft, to: new, sent: justSent)
                        if writtenBack.text != nil {
                            // The keyboard writing the sent text back into the emptied box: `emptyComposer` empties
                            // exactly this again. Words typed after a send never land here in one change.
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
                        editOffset = MentionSuggester.editOffsetUnlessAtEnd(from: lastDraft, to: new)
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
                if let media {
                    RoomMediaSendButton(board: media, canSendText: canSend, hasProblem: problem != nil) {
                        sendDraft()
                    }
                } else {
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
    /// Opens a member's profile card from their avatar, where direct messages are on.
    var onProfile: ((RoomProfileTarget) -> Void)?
    var ownAuthorIds: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    /// The member's card, unless it is you, the room's voice or a box that ended.
    private func profileTarget(_ member: RoomRoster.Member) -> RoomProfileTarget? {
        guard onProfile != nil, member.status != .ended,
              RoomProfile.opens(senderId: member.id, ownAuthorIds: ownAuthorIds) else { return nil }
        return RoomProfileTarget(senderId: member.id, name: member.name, isAgent: member.kind != .person)
    }

    @ViewBuilder
    private func memberAvatar(_ member: RoomRoster.Member) -> some View {
        if let target = profileTarget(member), let onProfile {
            Button {
                onProfile(target)
            } label: {
                RoomAvatar(name: member.name, isHuman: member.kind == .person)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(member.name)'s profile")
            .accessibilityIdentifier("pocket.room.people.\(member.id).profile")
        }
    }

    /// The ring's number: who is here and active, counted as the ring counts them.
    private var online: String {
        guard presence?.isAvailable != false else { return "?" }
        if !roster.members.isEmpty { return String(roster.activeCount) }
        return String(presence?.people.filter { !$0.isIdle }.count ?? 0)
    }

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
                // The ring's own count leads, then the whole room's line; the connection is a quiet note beside them
                // (Carter, #59940: the list did not read as the ring's).
                Section {
                    HStack(spacing: 10) {
                        RoomOnlineCountPill(online: online)
                            // The room's line beside it says the same number aloud.
                            .accessibilityHidden(!roster.members.isEmpty)
                        if !roster.members.isEmpty {
                            Text(roster.summary)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                                .accessibilityIdentifier("pocket.room.people.summary")
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(RoomConnectionPill.color(for: connection))
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(connection.label)
                                .font(.caption)
                                .foregroundStyle(PocketPalette.textSecondary)
                        }
                        .fixedSize()
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pocket.room.presence.connection")
                    }
                }
                if !roster.members.isEmpty {
                    // People, live agents and agents in boxes apart, each with its counts.
                    ForEach(roster.sides, id: \.title) { side in
                        Section {
                            ForEach(side.members) { member in
                                HStack(spacing: 10) {
                                    memberAvatar(member)
                                    NavigationLink {
                                        RoomMemberDetail(member: member)
                                    } label: {
                                        RoomMemberRow(member: member)
                                    }
                                    .accessibilityIdentifier("pocket.room.people.\(member.id)")
                                }
                            }
                        } header: {
                            Text(side.header)
                                .accessibilityIdentifier("pocket.room.people.side.\(side.title.lowercased())")
                        }
                    }
                    // Boxes that ended are gone for good: listed last and folded, out of every count.
                    if !roster.endedBoxes.isEmpty {
                        Section {
                            DisclosureGroup("Ended boxes · \(roster.endedBoxes.count)") {
                                ForEach(roster.endedBoxes) { member in
                                    NavigationLink {
                                        RoomMemberDetail(member: member)
                                    } label: {
                                        RoomMemberRow(member: member)
                                    }
                                }
                            }
                            .accessibilityIdentifier("pocket.room.people.ended")
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
            .navigationTitle("Who is here")
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
    /// The room's leaderboard among the pins, if it keeps one.
    let leaderboard: RoomChatPinned?
    /// Opens the leaderboard as a list in a sheet.
    let onOpenLeaderboard: () -> Void
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
                Spacer(minLength: 8)
                if let leaderboard {
                    leaderboardButton(leaderboard)
                }
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

    /// The room's leaderboard, in the strip's first row, right under the room's title: the navigation bar of a
    /// 375-point phone shows two buttons and folds the rest into its overflow menu, where a trophy would be lost. It
    /// opens the board as a ranked list in a sheet, never as a jump to its message.
    private func leaderboardButton(_ board: RoomChatPinned) -> some View {
        Button {
            onOpenLeaderboard()
        } label: {
            Label("Leaderboard", systemImage: "trophy.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.warning)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(PocketPalette.raised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Leaderboard")
        .accessibilityHint("Shows who is helping most in this room")
        .accessibilityIdentifier("pocket.room.leaderboard")
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

/// A message row is drawn again only when what it shows changed: its row, the room's settings it reads, its own
/// previews, its highlight, reading aloud and fold. Its actions are closures, which SwiftUI cannot compare, so without
/// this every row the list had made was drawn again at every update of the room: an arrival, a presence beat, the side
/// panel opening. With an accessibility client reading the screen (VoiceOver, Voice Control, a UI test) the list keeps
/// every row it made, so a busy room's main thread never came to rest and each read of the screen timed out.
/// The actions still reach the room: they send intents, and set the list's own state, through references that stay.
extension RoomMessageRowView: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.ownHandles == rhs.ownHandles && lhs.isHighlighted == rhs.isHighlighted
            && lhs.canReact == rhs.canReact && lhs.canAddEmoji == rhs.canAddEmoji && lhs.canReply == rhs.canReply
            && lhs.canPin == rhs.canPin && lhs.isPinned == rhs.isPinned && lhs.pinsFull == rhs.pinsFull
            && lhs.breakouts == rhs.breakouts && lhs.attachmentPreviews == rhs.attachmentPreviews
            && lhs.isReadingAloud == rhs.isReadingAloud && lhs.isExpanded == rhs.isExpanded
            && lhs.threadSummary == rhs.threadSummary && lhs.isReadingSummary == rhs.isReadingSummary
            && lhs.isMinimized == rhs.isMinimized
    }

    /// The previews of this row's own attachments: another row's preview arriving leaves it as it is.
    static func previews(of row: RoomChatMessageRow, in previews: [String: Data]) -> [String: Data] {
        guard !row.attachments.isEmpty, !previews.isEmpty else { return [:] }
        var own: [String: Data] = [:]
        for chip in row.attachments {
            if let data = previews[chip.attachmentId] { own[chip.attachmentId] = data }
        }
        return own
    }
}
#endif
