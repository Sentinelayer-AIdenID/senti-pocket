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

    /// The reply being typed in each thread, kept while the room is open: closing the sheet does not lose it. A
    /// reference, so typing never draws the room again: each keystroke in a thread used to (#62423).
    @State private var threadDrafts = RoomThreadDraftStore()
    /// Opens a profile card from an avatar, where direct messages are on.
    @Environment(\.roomProfileOpener) private var profileOpener
    /// The pickers and viewers a thread opens over itself.
    @Environment(\.roomSheetMediaHost) private var sheetMediaHost
    @Environment(\.roomReadAloudBar) private var readAloudBar
    /// Where the typing line is said: VoiceOver.
    @Environment(\.roomAnnouncer) private var announcer
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
    /// ... or to the New messages line, when the jump button had messages waiting.
    @State private var scrollsToLineWhenLoaded = false
    /// The next new list opens at the New messages line, not at the latest (`goToFirstUnseen`).
    @State private var reopensAtLine = false
    @State private var highlightedRowId: String?
    /// Background lines opened in place.
    @State private var expandedQuiet: Set<String> = []
    /// Threads whose answer is minimized to its one line, by the message they answer (Carter, #58637).
    @State private var minimizedThreads: Set<Int64> = []
    /// Threads whose file parts are shown (by the thread's root sequence); otherwise they fold behind the file's card.
    @State private var shownFileParts: Set<Int64> = []
    @State private var showsPresence = false
    /// The People sheet's state when the room screen holds it (its People button opens it too); else the view's own.
    private let showsPeople: Binding<Bool>?
    @Environment(\.roomPeopleExtras) private var peopleExtras

    private var peopleShown: Binding<Bool> { showsPeople ?? $showsPresence }
    /// The owner is renaming the room, and the name as typed.
    @State private var renaming = false
    @State private var renameDraft = ""
    /// A failed message the reader chose to edit: its text goes back into the composer.
    @State private var restoredDraft: RoomComposerRestore?
    /// Something held for the AI consent question: a send from the room's box, an edit about to open, or the room's own
    /// writes (`RoomChatPresentationState.consentRequested`).
    @State private var consentHeld: AIConsentHeld?

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
        showsPeople: Binding<Bool>? = nil,
        send: @escaping (RoomChatIntent) -> Void
    ) {
        self.showsPeople = showsPeople
        self.state = state
        self.readingAloudId = readingAloudId
        self.composerActions = composerActions
        self.roster = roster
        self.media = media
        self.send = send
    }

    /// The message the room's box is answering (swipe to reply), sent to its thread.
    @State private var replyTarget: RoomChatMessageRow?

    public var body: some View {
        let _ = RenderTrace.built(.roomBody)
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
                media: media,
                asksAIConsent: state.asksAIConsent,
                askAIConsent: { consentHeld = $0 }
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
                    canReport: state.canReport,
                    canBlock: state.canBlock,
                    report: state.report,
                    asksAIConsent: state.asksAIConsent,
                    consentRequested: state.consentRequested,
                    // The thread's own tray: files picked here never show in, or go with, the room's box.
                    media: media?.threadBoard(thread.parent.sequenceId),
                    previews: state.attachmentPreviews,
                    mediaHost: sheetMediaHost,
                    readAloudBar: readAloudBar,
                    draftKey: state.draftKey,
                    draftStore: threadDrafts,
                    send: send
                )
                // Another thread opened in its place is another reply box, with its own text.
                .id(thread.parent.sequenceId)
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
        // A report opened from the room; one opened in a thread shows over the thread (`RoomThreadSheet`).
        .sheet(isPresented: Binding(
            get: { state.report != nil && state.thread == nil },
            set: { presented in if !presented { send(.closeReport) } }
        )) {
            if let report = state.report {
                RoomReportSheet(report: report, send: send)
            }
        }
        .aiConsentPrompt($consentHeld) { send(.allowAIAgents) }
        // A reaction, a pin or an edit held for the answer: the room asks, and Not now lets them go. In a thread, the
        // thread asks.
        .onChange(of: state.consentRequested) { requested in
            guard requested, state.thread == nil, consentHeld == nil else { return }
            consentHeld = AIConsentHeld({}, onDecline: { send(.declineAIAgents) })
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
        .sheet(isPresented: peopleShown) {
            RoomPresenceSheet(
                presence: state.presence,
                connection: state.connection,
                roster: roster,
                canInvite: state.canInvite,
                extras: peopleExtras,
                onProfile: profileOpener.map { opener -> (RoomProfileTarget) -> Void in
                    return { target in
                        peopleShown.wrappedValue = false
                        // After this sheet has gone, so the profile card can come up.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { opener(target) }
                    }
                },
                ownAuthorIds: profileOpener?.ownAuthorIds ?? [],
                opensEveryone: profileOpener?.opensEveryone ?? false
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
                    // A row's id is the loop's own (`RoomChatRow.id`), which every scroll to a row targets. No `.id`
                    // of the same value on the row: with one, the list kept every row it made as it opened and built
                    // them all again at each update (in CI 404 of 404 at every redraw and arrival), as master did.
                    ForEach(state.rows) { row in
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
                            },
                            onLatest: { goToLatestFromWindow() }
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
                        // Before iOS 18 the marker says where the reader is (from iOS 18 the scroll view's geometry does,
                        // exactly: a lazy list draws the marker while it is still out of sight under the composer). The
                        // bottom of a window further back is not the live room's bottom. The marker only reports: the
                        // reader's place changes after layout (`markerSeen`).
                        .onAppear {
                            if !bottomWatch.readsGeometry, !state.canLoadNewer, heldAnchor == nil { markerSeen(true) }
                        }
                        .onDisappear { if !bottomWatch.readsGeometry { markerSeen(false) } }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            // Dragging the messages lowers the keyboard with the finger, as in Messages.
            .scrollDismissesKeyboard(.interactively)
            // Photos or files sent at the bottom are followed there, like a typed message; sent from up the room, the
            // reader keeps their place and the arrow shows. Told by the board, not watched: an upload never redraws the
            // room.
            .onAppear {
                media?.onNewOutgoing = {
                    guard followsBottom else { return }
                    heldAnchor = nil
                    scrollToBottomSoon(proxy)
                }
            }
            // The reader scrolling lets go of a message they were taken to, and of the unread line being placed.
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
                bottomWatch.readerScrolled = true
                if bottomWatch.lineHeld { RoomScrollTrace.lineHold("let go: the reader's drag") }
                bottomWatch.lineHeld = false
                if heldAnchor != nil { heldAnchor = nil }
            }.onEnded { _ in
                // Let go with the end in view and nothing moving: no new reading would say the reader is at the bottom.
                DispatchQueue.main.async { recheckPlace(proxy) }
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
                                      isPaused: peopleShown.wrappedValue) {
                        peopleShown.wrappedValue = true
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
                    proxy.scrollTo(heldAnchor, anchor: .center)
                } else {
                    followToBottom(proxy)
                }
            }
            .onChange(of: state.attachmentPreviews.count) { _ in
                if let heldAnchor { proxy.scrollTo(heldAnchor, anchor: .center) } else { followToBottom(proxy) }
            }
            // The typing line comes or goes under the last message: the reader at the bottom stays there and sees it
            // whole, and is still at the bottom when the reply comes in under it.
            .onChange(of: state.composingAgents) { _ in followToBottom(proxy) }
            // VoiceOver hears the line once, when it shows and when its words change: never because its row was built
            // again (scrolled back to, or the list made anew).
            .onChange(of: shownComposingWords) { words in
                if !words.isEmpty { announcer.say(words) }
            }
            .onChange(of: state.lastMessageId) { _ in
                if !didInitialScroll {
                    scrollToInitialPosition(proxy)
                } else {
                    followToBottom(proxy, eased: true)
                }
            }
            // VoiceOver hears what arrives below a reader up the room, at most every few seconds.
            .onChange(of: state.unreadCount) { count in announceArrivals(count) }
            .onChange(of: state.pending.count) { count in
                // Sending at the bottom follows your message there. Sending from up the room never moves you (Carter,
                // #61581): the message is sent and shows at the bottom, and the arrow takes you there when you choose.
                // (It used to put the room back at its newest rows as a new list, which is how a long scroll at a send
                // stopped freezing the app; with no move at a send there is no scroll to make.)
                guard count > 0, followsBottom else { return }
                heldAnchor = nil
                scrollToBottomSoon(proxy)
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
                // Back in the live room after the jump button or "Sent · ↓ latest": go to its first new message when
                // there were some, else to its newest.
                guard !canLoadNewer, scrollsToLatestWhenLoaded else { return }
                scrollsToLatestWhenLoaded = false
                let toLine = scrollsToLineWhenLoaded
                scrollsToLineWhenLoaded = false
                if toLine {
                    DispatchQueue.main.async {
                        guard state.rows.contains(.unreadDivider) else {
                            setReaderAtBottom(true)
                            proxy.scrollTo(Self.bottomId, anchor: .bottom)
                            return
                        }
                        send(.newMessagesShown)
                        proxy.scrollTo(RoomChatRow.unreadDivider.id, anchor: Self.unreadLineAnchor)
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openLanding) { recheckPlace(proxy) }
                    }
                } else {
                    setReaderAtBottom(true)
                    DispatchQueue.main.async { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                }
            }
            // A list starts at its newest rows, not at its top (iOS 18 and later; before that, the first scroll takes
            // it there). Only where it starts: rows arriving or loading later move nothing.
            .modifier(StartsAtBottom())
            // Where the reader is, from the scroll view's own geometry (iOS 18 and later).
            .modifier(RoomScrollReading { readingSeen($0, proxy: proxy) })
            .modifier(RoomReaderScrolling { moving in
                let wasMoving = bottomWatch.readerMoving
                bottomWatch.readerMoving = moving
                if moving, bottomWatch.lineHeld {
                    RoomScrollTrace.lineHold("let go: the reader moving the list")
                    bottomWatch.lineHeld = false
                }
                guard wasMoving, !moving else { return }
                // The reader's drag and its coast are over: the reader's place again, and a follow held back while
                // the list moved is made now (`RoomReaderPlace.Tracker.rested`).
                DispatchQueue.main.async {
                    let held = bottomWatch.tracker.rested()
                    recheckPlace(proxy)
                    if held { followToBottom(proxy) }
                }
            })
            // The whole list, its handlers with it, so a new one opens as the room does.
            .id(listEpoch)
        }
    }

    /// Puts the room back at its newest rows as a new list, the way a room opens (which has never frozen), rather than
    /// scrolling down to them or trimming the rows under the reader: the jump button's way down from up a long history.
    /// Carter's 10-30 freezes all began with the room moving a long way at a send; the last (14:53) came right after the
    /// trim to the newest rows, with the scroll still to come. A send no longer moves the room at all.
    private func reopenAtLatest(atLine: Bool = false) {
        reopensAtLine = atLine
        // A list opened anew is one the reader has not dragged: its line is placed again once its rows are measured.
        bottomWatch.readerScrolled = false
        bottomWatch.lineHeld = false
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
                .accessibilityIdentifier("pocket.room.start")
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
            canReport: state.canReport,
            canBlock: state.canBlock,
            asksAIConsent: state.asksAIConsent,
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
            onEdit: { row in
                // Asked before the editor opens, so an edit is never written to be dropped.
                if state.asksAIConsent {
                    consentHeld = AIConsentHeld({ editingRow = row }, onDecline: { send(.declineAIAgents) })
                } else {
                    editingRow = row
                }
            },
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
                // A window further back: load the live room first, then go to its first new message, or its newest.
                scrollsToLineWhenLoaded = state.unreadCount > 0
                goToLatestFromWindow()
                return
            }
            if state.unreadCount > 0, state.rows.contains(.unreadDivider) {
                goToFirstUnseen(proxy)
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
            // Landed with the end in view: the reading says so even if the last frame of the scroll did not.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.openLanding) { recheckPlace(proxy) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                if let badge = RoomJumpToLatest.badge(newCount: state.unreadCount) {
                    Text(badge)
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .pocketFloating(in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(16)
        .accessibilityLabel(RoomJumpToLatest.accessibilityLabel(newCount: state.unreadCount))
        .accessibilityIdentifier("pocket.room.jumpToLatest")
    }

    /// With messages waiting, the jump button takes the reader to the first of them, read from its top under the New
    /// messages line, as the web room's does (Carter, #61581: never skip what arrived). The count is taken, so the
    /// button goes plain and takes them on to the latest; the line stays until it has been seen. From up a long history
    /// the list opens again at the line (as a room opens at its unread line), instead of scrolling a long way down.
    private func goToFirstUnseen(_ proxy: ScrollViewProxy) {
        send(.newMessagesShown)
        if state.jumpDownKeepsLatest {
            send(.keepFromNewMessagesLine)
            reopenAtLatest(atLine: true)
            return
        }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(RoomChatRow.unreadDivider.id, anchor: Self.unreadLineAnchor)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openLanding) { recheckPlace(proxy) }
    }

    /// From a window further back, the live room's newest page loads, then the room goes to its newest message (or
    /// the New messages line, `scrollsToLineWhenLoaded`): the jump button, and "Sent · ↓ latest".
    private func goToLatestFromWindow() {
        heldAnchor = nil
        scrollsToLatestWhenLoaded = true
        send(.jumpToLatest)
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
        let position = reopensAtLine && state.rows.contains(.unreadDivider)
            ? RoomOpenPosition.unreadLine : state.openPosition(reopening: listEpoch > 0)
        RoomScrollTrace.lineHold("open: \(position) (reopens at the line \(reopensAtLine), the line in the rows "
            + "\(state.rows.contains(.unreadDivider)), list \(listEpoch))")
        reopensAtLine = false
        guard position == .latest || position == .unreadLine else { return }
        didInitialScroll = true
        // Say where the reader is now: the bottom marker may never render when the first scroll lands elsewhere,
        // and a reader who is not at the bottom must not be pulled down by the next message.
        let opensAtLine = position == .unreadLine
        setReaderAtBottom(!opensAtLine)
        DispatchQueue.main.async {
            if opensAtLine {
                proxy.scrollTo(RoomChatRow.unreadDivider.id, anchor: Self.unreadLineAnchor)
                bottomWatch.holdLine()
            } else {
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
            }
            // The list has left its top: from now on the header showing means the reader scrolled up to it.
            DispatchQueue.main.async { holdsOlderLoads = false }
            if opensAtLine {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.openLanding) {
                    placeLineAgain(proxy)
                    DispatchQueue.main.async { recheckPlace(proxy) }
                }
            }
        }
    }

    /// Rows are measured only as they come into view, so the first scroll places the line from estimated heights, and
    /// in a room of rows of very different heights (review packets, a long contract) those estimates move as soon as
    /// the rows are measured: on the 375-point simulator the line once ended below the fold, the bottom out of view.
    /// Once the rows around it are measured, the line is placed again, unless the reader has moved the list. With
    /// little below the line, that placement ends at the room's end, and the bottom marker (from iOS 18, the scroll
    /// view's last reading, `recheckPlace`) reports from it, so the reader counts as at the bottom (the hosted tests
    /// check both, on the 375-point SE too).
    private func placeLineAgain(_ proxy: ScrollViewProxy) {
        guard bottomWatch.isActive, !bottomWatch.readerScrolled, heldAnchor == nil,
              state.rows.contains(.unreadDivider) else { return }
        proxy.scrollTo(RoomChatRow.unreadDivider.id, anchor: Self.unreadLineAnchor)
    }

    /// The line the room opened at, placed again after the room's height changed (rows measured, so the estimates for
    /// those above it changed): on the frame after, never in the layout pass that changed it. Let go once the reader
    /// moves the list, the room is at its bottom, or it has been placed `RoomBottomWatch.lineHoldLimit` times.
    private func placeHeldLine(_ proxy: ScrollViewProxy) {
        bottomWatch.linePlaceQueued = false
        guard bottomWatch.lineHeld else { return }
        let letGo: String? = !bottomWatch.isActive ? "the room put away"
            : bottomWatch.readerScrolled ? "the reader's drag"
            : bottomWatch.readerMoving ? "the reader moving the list"
            : heldAnchor != nil ? "a message the reader was taken to"
            : !state.rows.contains(.unreadDivider) ? "no line in the rows"
            : bottomWatch.linePlacements >= RoomBottomWatch.lineHoldLimit ? "the \(RoomBottomWatch.lineHoldLimit)-placement cap"
            : nil
        if let letGo {
            RoomScrollTrace.lineHold("let go: \(letGo)")
            bottomWatch.lineHeld = false
            return
        }
        let height = bottomWatch.reading.map(RoomBottomWatch.height) ?? bottomWatch.lineHeldHeight
        // At the bottom, the room follows what arrives there: this placement is skipped, not the hold. A new list
        // starts at its end before its scroll to the line, so its first readings count the reader at the bottom; the
        // next change in the room's height tries again.
        guard !bottomWatch.atBottom else {
            RoomScrollTrace.lineHold("skipped at the bottom (height \(Int(height)))")
            return
        }
        bottomWatch.linePlacements += 1
        bottomWatch.lineHeldHeight = height
        RoomScrollTrace.lineHold("placed #\(bottomWatch.linePlacements) (height \(Int(height)))")
        proxy.scrollTo(RoomChatRow.unreadDivider.id, anchor: Self.unreadLineAnchor)
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
        bottomWatch.tracker.set(atBottom: atBottom)
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
            if !bottomWatch.readsGeometry { bottomWatch.tracker.set(atBottom: atBottom) }
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
        if bottomWatch.lineHeld { RoomScrollTrace.lineHold("let go: the arrow to the latest") }
        bottomWatch.lineHeld = false
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

    /// The typing line's words while it shows, or none.
    private var shownComposingWords: String {
        state.canLoadNewer ? "" : RoomComposingWords.line(state.composingAgents)
    }

    /// Whether the room follows its bottom: from iOS 18 the scroll view's own geometry, read as it changes; before, the
    /// place the bottom marker settled.
    private var followsBottom: Bool {
        bottomWatch.readsGeometry ? bottomWatch.atBottom : readerAtBottom
    }

    /// A reader at the bottom follows it as it moves away (a message arriving, a row or a preview growing, the keyboard
    /// rising). Decided now; scrolled on the next turn. A reader up the room is never moved. An arrival is followed with
    /// a short ease, as before.
    private func followToBottom(_ proxy: ScrollViewProxy, eased: Bool = false) {
        guard didInitialScroll, followsBottom, heldAnchor == nil, !state.canLoadNewer,
              state.focusSequenceId == nil else { return }
        scrollToBottomSoon(proxy, eased: eased)
    }

    /// One short scroll to the bottom on the next turn of the run loop, however many asked for it in this turn, and at
    /// most `RoomBottomWatch.followLimit` a second, plus one when the second is up: a room whose end kept moving can
    /// never keep it scrolling, and the last thing that arrived is still followed.
    private func scrollToBottomSoon(_ proxy: ScrollViewProxy, eased: Bool = false) {
        // Every follow comes here: none while the reader moves the list; held, and made once it rests.
        if bottomWatch.readsGeometry, !bottomWatch.tracker.mayFollow(readerMoving: bottomWatch.readerMoving) { return }
        guard !bottomWatch.followQueued else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard bottomWatch.mayFollow(at: now) else {
            guard !bottomWatch.trailingFollowQueued else { return }
            bottomWatch.trailingFollowQueued = true
            DispatchQueue.main.asyncAfter(deadline: .now() + bottomWatch.nextFollow(at: now)) {
                bottomWatch.trailingFollowQueued = false
                followToBottom(proxy)
            }
            return
        }
        bottomWatch.followQueued = true
        DispatchQueue.main.async {
            bottomWatch.followQueued = false
            // The reader may have left the bottom since this was asked for, or started moving the list.
            guard followsBottom else { return }
            if bottomWatch.readsGeometry, !bottomWatch.tracker.mayFollow(readerMoving: bottomWatch.readerMoving) { return }
            // Where the follow lands is taken as a new reading, even if it looks like the last one taken: in a lazy
            // list the scroll to the end goes by the rows' estimated heights, and can stop short of an end that is
            // still below (seen in a burst of 40 at 60 a second), which would otherwise never be followed again.
            bottomWatch.sightBeforeFollow = bottomWatch.takenSight
            bottomWatch.takenSight = nil
            RoomScrollTrace.followMade()
            guard eased else {
                let before = bottomWatch.reading
                if !RoomScrollTrace.followMovesNothing { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
                // A follow that moved nothing gives no new reading, and nothing would follow again: where it landed
                // is read two frames on, whatever it shows (`followLanded`).
                RoomNextFrame.run { RoomNextFrame.run { followLanded(from: before, proxy) } }
                return
            }
            bottomWatch.easedFollowUntil = ProcessInfo.processInfo.systemUptime + Self.followEase
            withAnimation(.easeOut(duration: Self.followEase)) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            // Anything that arrived while it eased is followed once it has landed.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.followEase + 0.05) { recheckPlace(proxy) }
        }
    }

    /// How long an arrival's follow eases.
    static let followEase: TimeInterval = 0.2

    /// Where a placed follow landed, two frames on (`scrollToBottomSoon`). One that moved nothing while the end is still
    /// out of view gives the room no new reading, and it would never follow again, saying the reader is at the bottom
    /// with the end far below (at the largest text size, tall reports arriving at once: 5,597 pt in CI, for 7.6 s).
    /// Once a chain, such a follow is tried again by the last row's id; if that moves nothing too, the reader is no
    /// longer taken to be at the bottom, and the arrow shows. Otherwise the reader's place is read as usual.
    private func followLanded(from before: RoomReaderPlace.Reading?, _ proxy: ScrollViewProxy) {
        guard bottomWatch.isActive, bottomWatch.readsGeometry, let now = bottomWatch.reading else { return }
        if now.endInView { bottomWatch.stallRetried = false }
        let movedNothing = before.map { abs($0.offset - now.offset) < 0.5 } ?? false
        guard movedNothing, !now.endInView, followsBottom else {
            recheckPlace(proxy)
            return
        }
        if !bottomWatch.stallRetried, let last = state.rows.last {
            bottomWatch.stallRetried = true
            RoomScrollTrace.stallRetried()
            // The retry is the room's own scroll: where it lands is judged from there, not from how far down the list
            // had been (by the bottom's 120-point rule, a retry that landed 754 pt up was taken for the reader leaving).
            bottomWatch.tracker.set(atBottom: true)
            switch RoomScrollTrace.injectedRetry {
            case .none: proxy.scrollTo(last.id, anchor: .bottom)
            case .movesNothing: break
            case .landsAbove: if let first = state.rows.first { proxy.scrollTo(first.id, anchor: .top) }
            }
            RoomNextFrame.run { RoomNextFrame.run { followLanded(from: now, proxy) } }
            return
        }
        RoomScrollTrace.followGaveUp()
        setReaderAtBottom(false)
    }

    /// A reading of the scroll view, while the list is laid out (iOS 18 and later). Acting on it here (a follow, the
    /// reader's place) would change the list again in the same frame, and SwiftUI warns ("tried to update multiple
    /// times per frame"); within one keyboard opening it lays the list out several times, the end leaving view and
    /// coming back in a millisecond. So the reading is only kept, and when what it shows differs from the last one
    /// taken, it is taken on the next frame the screen draws, once, however many came before; a follow it makes lands
    /// in a frame of its own.
    private func readingSeen(_ reading: RoomReaderPlace.Reading, proxy: ScrollViewProxy) {
        let sight = bottomWatch.see(reading)
        if bottomWatch.lineMoved(by: reading) { RoomNextFrame.run { placeHeldLine(proxy) } }
        guard bottomWatch.isActive, sight != bottomWatch.takenSight, !bottomWatch.readingQueued else { return }
        bottomWatch.readingQueued = true
        bottomWatch.queuedOnlyAfterFollow = bottomWatch.takenSight == nil && sight == bottomWatch.sightBeforeFollow
        RoomNextFrame.run { placeFromReading(proxy) }
    }

    /// The last reading, taken after its frame: the reader's place, exactly (`RoomReaderPlace.Tracker`). The end of
    /// the room in view is the reader at the bottom (not the end of a window further back, and not while a message the
    /// reader was taken to holds them); the list moving up from where it was at the bottom is the reader leaving; the
    /// end moving away from a reader at the bottom is followed (not while the room's own eased follow is on its way).
    private func placeFromReading(_ proxy: ScrollViewProxy) {
        if bottomWatch.readingQueued { RoomScrollTrace.readingTaken() }
        let onlyAfterFollow = bottomWatch.readingQueued && bottomWatch.queuedOnlyAfterFollow
        bottomWatch.readingQueued = false
        bottomWatch.queuedOnlyAfterFollow = false
        guard bottomWatch.isActive, bottomWatch.readsGeometry, let reading = bottomWatch.reading else { return }
        let moving = bottomWatch.readerMoving
        bottomWatch.takenSight = bottomWatch.tracker.see(reading, readerMoving: moving)
        switch bottomWatch.tracker.read(reading, mayBeAtBottom: !state.canLoadNewer && heldAnchor == nil,
                                        readerMoving: moving) {
        case .none:
            break
        case .endInView:
            placeLands(true)
        case .leftBottom:
            placeLands(false)
        case .mayHaveLeft:
            // Not by the reader's hand: taken again on the next frame, and the reader leaves only if it still shows.
            RoomNextFrame.run { recheckPlace(proxy) }
        case .endMovedAway:
            guard ProcessInfo.processInfo.systemUptime >= bottomWatch.easedFollowUntil else { return }
            if onlyAfterFollow { RoomScrollTrace.shortLandingRetaken() }
            followToBottom(proxy)
        }
    }

    /// The reader's place by the last reading, now: after a scroll of the room's own that lands with the end already
    /// in view and so moves no reading (little below the unread line, a room that fits on the screen, the jump button),
    /// after an eased follow, and when the reader lets go of the list.
    private func recheckPlace(_ proxy: ScrollViewProxy) {
        guard !bottomWatch.readingQueued else { return }
        placeFromReading(proxy)
    }

    /// A reading moved the reader's place: it lands through the settle and is told to the coordinator, coming back on
    /// the next turn and leaving once it has held for `RoomBottomSettle.leaveDelay` (0.1 s), with the settle's flap
    /// breaker over both, as the marker's did (`RoomBottomFlapTests` pin that leaving never lands in the pass that moved
    /// the list). Following stops at once (the tracker); only what the coordinator is told waits, so an arrival in that
    /// 0.1 s is not counted for the arrow.
    private func placeLands(_ atBottom: Bool) {
        guard bottomWatch.isActive, let check = bottomWatch.settle.marker(shown: atBottom) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + check.after) { landBottom(check) }
    }

    /// VoiceOver hears what arrives below a reader up the room ("3 new messages"), at most every
    /// `announcementSpacing` seconds; what arrives in between is said once the time is up.
    private func announceArrivals(_ count: Int) {
        #if os(iOS)
        guard count > 0, UIAccessibility.isVoiceOverRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wait = bottomWatch.lastAnnouncement + Self.announcementSpacing - now
        guard wait > 0 else {
            bottomWatch.lastAnnouncement = now
            if let words = RoomJumpToLatest.arrivalAnnouncement(newCount: count) {
                UIAccessibility.post(notification: .announcement, argument: words)
            }
            return
        }
        guard !bottomWatch.announcementQueued else { return }
        bottomWatch.announcementQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            bottomWatch.announcementQueued = false
            announceArrivals(state.unreadCount)
        }
        #endif
    }

    static let announcementSpacing: TimeInterval = 5

    private static let bottomId = "room-bottom"
}

/// What the room keeps about its bottom marker without redrawing for it: the settled place, and whether the room is on
/// screen to take it.
private final class RoomBottomWatch {
    var settle = RoomBottomSettle()
    var isActive = true
    /// The reader has dragged the list since it opened.
    var readerScrolled = false
    /// The room opened at the New messages line and keeps it there while its rows are measured (`placeHeldLine`).
    var lineHeld = false
    /// The room's height (as its reading gives it) when the line was last placed; a placement waits for the next frame.
    var lineHeldHeight: CGFloat = 0
    var linePlaceQueued = false
    var linePlacements = 0
    /// At most this many placements of one held line.
    static let lineHoldLimit = 30

    /// The room's height as a reading gives it, less the insets and the height that can be read, which do not change
    /// as it scrolls: what moves when rows are measured or arrive.
    static func height(_ reading: RoomReaderPlace.Reading) -> CGFloat {
        reading.offset + reading.distanceToEnd
    }

    /// The room opened at the line: hold it from here, from the room's height now.
    func holdLine() {
        lineHeld = true
        linePlaceQueued = false
        linePlacements = 0
        lineHeldHeight = reading.map(Self.height) ?? 0
        RoomScrollTrace.lineHold("armed (height \(Int(lineHeldHeight)), at the bottom \(atBottom), "
            + "a reading \(reading != nil))")
    }

    /// Whether a reading shows the room's height changed while the line is held, and no placement is waiting yet.
    func lineMoved(by reading: RoomReaderPlace.Reading) -> Bool {
        guard lineHeld, abs(Self.height(reading) - lineHeldHeight) > 0.5 else { return false }
        guard !linePlaceQueued else { return false }
        RoomScrollTrace.lineHold("height \(Int(lineHeldHeight)) to \(Int(Self.height(reading))): a placement queued")
        linePlaceQueued = true
        return true
    }
    /// From iOS 18 the scroll view's geometry says where the reader is (`RoomReaderPlace`); before, the bottom marker.
    let readsGeometry: Bool = {
        if #available(iOS 18.0, macOS 15.0, *) { return true }
        return false
    }()
    /// The reader's place as the geometry and the room's own decisions say it now, ahead of `settle` landing it: what a
    /// message arriving follows.
    var tracker = RoomReaderPlace.Tracker()
    var atBottom: Bool { tracker.atBottom }
    /// The scroll view's last reading (iOS 18 and later), recorded while the list is laid out.
    var reading: RoomReaderPlace.Reading?

    /// A reading, while the list is laid out: kept, and what it is (`RoomReaderPlace.Tracker.see`). Nothing here
    /// changes what SwiftUI shows.
    func see(_ reading: RoomReaderPlace.Reading) -> RoomReaderPlace.Sight {
        self.reading = reading
        return tracker.see(reading, readerMoving: readerMoving)
    }
    /// The reader is dragging the list, or it is coasting from their drag (iOS 18 and later).
    var readerMoving = false
    /// A reading is to be taken on the next frame; what the last one taken showed.
    var readingQueued = false
    var takenSight: RoomReaderPlace.Sight?
    /// What the last reading taken showed when a follow set it aside, and whether the reading waiting for the next
    /// frame shows the same: it is taken only because the follow set the last one aside (a follow that stopped short).
    var sightBeforeFollow: RoomReaderPlace.Sight?
    var queuedOnlyAfterFollow = false
    /// This follow chain already tried a follow that moved nothing again (`followLanded`).
    var stallRetried = false
    /// A scroll to the bottom is waiting for the next turn of the run loop, or for the follow limit's second to pass.
    var followQueued = false
    var trailingFollowQueued = false
    /// The room's own eased follow is on its way until then.
    var easedFollowUntil: TimeInterval = 0
    /// VoiceOver last heard "N new messages" then; one more is waiting.
    var lastAnnouncement: TimeInterval = -.greatestFiniteMagnitude
    var announcementQueued = false
    /// When the last follows were made, within the last second.
    private var follows: [TimeInterval] = []
    static let followLimit = 20

    /// Whether another follow may be made now, and notes it if so.
    func mayFollow(at now: TimeInterval) -> Bool {
        follows.removeAll { now - $0 >= 1 }
        guard follows.count < Self.followLimit else { return false }
        follows.append(now)
        return true
    }

    /// How long until another follow may be made.
    func nextFollow(at now: TimeInterval) -> TimeInterval {
        max(0, (follows.first ?? now) + 1 - now)
    }
}

/// Runs work when the screen next draws a frame (a turn of the run loop can come several times within one frame).
private enum RoomNextFrame {
    #if os(iOS)
    private final class Link: NSObject {
        var link: CADisplayLink?
        var work: [() -> Void] = []

        @objc func tick() {
            link?.invalidate()
            link = nil
            let due = work
            work = []
            due.forEach { $0() }
        }
    }

    private static let shared = Link()
    #endif

    static func run(_ body: @escaping () -> Void) {
        #if os(iOS)
        shared.work.append(body)
        guard shared.link == nil else { return }
        let link = CADisplayLink(target: shared, selector: #selector(Link.tick))
        link.add(to: .main, forMode: .common)
        shared.link = link
        #else
        DispatchQueue.main.async(execute: body)
        #endif
    }
}

/// A thread summary opened whole: its read-aloud id (so the sheet shows Stop while it is read) and the summary.
private struct OpenThreadSummary: Identifiable {
    let id: String
    let summary: SummaryReading
}

/// Reads the scroll view's geometry as it changes (iOS 18 and later): how far the end of the room is below what can be
/// read, and how far the list is scrolled (`RoomReaderPlace`). The container is what can be read, between the insets
/// (the navigation bar above, the composer below); the offset is the scroll view's own, so what can be read starts
/// `contentInsets.top` below it. Each reading goes to `seen` as the list is laid out; the value SwiftUI watches never
/// changes, so its callback never runs (`RoomChatView.readingSeen` says why).
private struct RoomScrollReading: ViewModifier {
    let seen: (RoomReaderPlace.Reading) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                RoomScrollTrace.whileReadingGeometry {
                    seen(RoomReaderPlace.Reading(
                        distanceToEnd: geometry.contentSize.height
                            - (geometry.contentOffset.y + geometry.contentInsets.top + geometry.containerSize.height),
                        offset: geometry.contentOffset.y,
                        visibleHeight: geometry.containerSize.height
                    ))
                }
                return true
            } action: { _, _ in }
        } else {
            content
        }
    }
}

/// Whether the reader is moving the list: dragging it, or its coast from their drag (iOS 18 and later). Not the room's
/// own scrolls, nor SwiftUI settling the list's rows.
private struct RoomReaderScrolling: ViewModifier {
    let moving: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: moving(true)
                default: moving(false)
                }
            }
        } else {
            content
        }
    }
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
    /// Someone else's message offers Report and Block.
    var canReport = false
    var canBlock = false
    /// The room asks the AI consent before an edit opens (`onEdit`): the row is drawn again when that changes, so its
    /// Edit asks as the room does now.
    var asksAIConsent = false
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
    /// Where the row's own sideways scrolls sit (a strip of photos), in the row's space: a drag that starts on one
    /// scrolls it and is never a swipe to reply (#336: dragging a strip back to its first photo opened a reply).
    @State private var sideScrolls: [CGRect] = []
    /// A double tap opens the same options as a long press.
    @State private var showsOptions = false
    /// Blocking this row's author, while the row asks to be sure (the question points at this message).
    @State private var blocking: RoomBlockTarget?

    var body: some View {
        RenderTrace.row(row.sequenceId)
        return rowBody.modifier(RoomLikeHaptic(placed: row.ownTaps.placed))
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
            if row.hidesAsBlocked {
                // Someone you blocked: one line in its place, and Show opens this one.
                RoomBlockedLine(identifier: "pocket.room.blocked.\(row.id)") {
                    send(.revealBlocked(key: RoomBlocking.revealKey(row)))
                }
            } else if let call = row.call {
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
            // In the row's own named space, the one its sideways scrolls are measured in.
            DragGesture(minimumDistance: 24, coordinateSpace: .named(RoomRowSideScrolls.space))
                .onChanged { value in
                    // Only a mostly sideways drag to the right: a scroll is never taken for a swipe, nor a drag that
                    // starts on a strip of photos (it scrolls the strip).
                    guard value.translation.width > 0,
                          abs(value.translation.width) > abs(value.translation.height) * 1.8,
                          !sideScrolls.contains(where: { $0.contains(value.startLocation) }) else { return }
                    swipe = min(value.translation.width, Self.swipeToReply + 24)
                }
                .onEnded { _ in
                    if swipe > Self.swipeToReply { reply() }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { swipe = 0 }
                }
        )
        // The row's own space, named on the row around its swipe and its strips; their frames are kept in the row's
        // own state, set only when they change.
        .coordinateSpace(name: RoomRowSideScrolls.space)
        .onPreferenceChange(RoomRowSideScrolls.self) { areas in
            if sideScrolls != areas { sideScrolls = areas }
        }
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
                Button(option.title, role: option.isDestructive ? .destructive : nil) { perform(option) }
                    .disabled(!option.isEnabled)
            }
        }
        .roomBlockConfirmation($blocking, send: send)
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
        // Who the server chose for an @any in it, or that nobody was free: a line of its own, which VoiceOver reads
        // after the message.
        if let line = row.addressedLine {
            Text(line)
                .font(.caption2)
                .foregroundStyle(PocketPalette.textSecondary)
                .accessibilityLabel(line)
                .accessibilityIdentifier("pocket.room.addressed.\(row.sequenceId)")
        }
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
                ownTaps: row.ownTaps,
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
            // The name opens their profile and messages, as the avatar does.
            RoomProfileName(senderId: row.authorId, name: row.authorName, isHuman: row.isHuman) {
                Text(row.authorName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(row.isHuman ? PocketPalette.accentStrong : PocketPalette.textPrimary)
                    .lineLimit(1)
            }
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
                actionButton(option.kind == .thread ? "arrowshape.turn.up.left" : option.symbol, label: option.title,
                             pops: row.ownTaps.pops(option.kind.rawValue)) {
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
                    canEdit: canReply, canAddEmoji: canAddEmoji, canReport: canReport, canBlock: canBlock)
    }

    private func perform(_ option: RoomRowOption) {
        if option.kind == .reply {
            onReply(row)
        } else if option.kind == .emoji {
            onAddReaction(row)
        } else if option.kind == .edit {
            onEdit(row)
        } else if option.kind == .block {
            // Once the menu that offered it has gone, so the question is never dropped.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                blocking = row.blockTarget
            }
        } else if option.kind == .copy {
            copyToPasteboard(row.text)
        } else if let intent = option.intent {
            send(intent)
        }
    }

    /// An action button. A thumb pops once for each like or dislike of yours placed with it (`pops`).
    private func actionButton(_ symbol: String, label: String, pops: Int = 0,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .modifier(RoomThumbPop(pops: pops))
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
            Button(role: option.isDestructive ? .destructive : nil) {
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

/// A like or dislike thumb pops once for each like or dislike of yours placed (`RoomOwnTaps`): never for taking one
/// back, never for a count that changed on its own. Not with Reduce Motion on; on iOS 16 the thumb only changes.
private struct RoomThumbPop: ViewModifier {
    let pops: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            if reduceMotion {
                content
            } else {
                content.symbolEffect(.bounce, value: pops)
            }
        } else {
            content
        }
    }
}

/// A reaction's count rolls to its new number, whoever changed it (your tap, or a refresh); with Reduce Motion on it
/// just changes.
private struct RoomCountRoll: ViewModifier {
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            if #available(iOS 17.0, macOS 14.0, *) {
                content
                    .contentTransition(.numericText(value: Double(count)))
                    .animation(.snappy(duration: 0.3), value: count)
            } else {
                content
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: count)
            }
        }
    }
}

/// A light tap of the hand when your own like or dislike is placed (`RoomOwnTaps.placed`): never for a take-back,
/// never for a refresh. iOS 17 and later.
private struct RoomLikeHaptic: ViewModifier {
    let placed: Int

    #if os(iOS)
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.sensoryFeedback(.impact(weight: .light), trigger: placed) { old, new in new > old }
        } else {
            content
        }
    }
    #else
    func body(content: Content) -> some View {
        content
    }
    #endif
}

/// Reaction chips, the acknowledged and working lines, and the reply count under a message.
private struct RoomReactionBar: View {
    let reactions: RoomChatReactions
    /// The message's sequence, for the emoji chips' identifiers.
    let sequenceId: Int64
    let canReact: Bool
    var canAddEmoji = false
    /// Your own likes and dislikes placed here: their thumbs pop (`RoomOwnTaps`).
    var ownTaps = RoomOwnTaps()
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
                                    .modifier(RoomThumbPop(pops: ownTaps.pops(chip.type)))
                                if let count = chip.shownCount {
                                    Text("\(count)").monospacedDigit()
                                        .modifier(RoomCountRoll(count: count))
                                }
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
                        .accessibilityLabel(chip.accessibilityLabel)
                        .accessibilityIdentifier("pocket.room.reaction.\(sequenceId).\(chip.type)")
                    }
                    ForEach(Array(reactions.emojiChips.enumerated()), id: \.element.id) { index, chip in
                        Button {
                            onEmoji(chip)
                        } label: {
                            HStack(spacing: 4) {
                                Text(chip.emoji)
                                    .font(.subheadline)
                                Text("\(chip.count)").monospacedDigit()
                                    .modifier(RoomCountRoll(count: chip.count))
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
    /// Someone else's reply offers Report and Block.
    var canReport = false
    var canBlock = false
    /// The room's report sheet: one opened here shows over the thread.
    var report: RoomReportState?
    /// The first reply asks your OK to share with AI first (`RoomChatPresentationState.asksAIConsent`).
    var asksAIConsent = false
    /// The room's writes from this thread (a reaction, an edit) wait for that answer: the thread asks.
    var consentRequested = false
    /// Photos, videos and files for a reply, where the room takes them (Carter, 11-04: replies carry photos and files
    /// like messages): the thread's own tray (`RoomMediaBoard.threadBoard`), sent from here as a reply.
    var media: RoomMediaBoard?
    /// Photo previews the room has loaded, for the replies' photos.
    var previews: [String: Data] = [:]
    /// The pickers and viewers, hosted by this sheet (the room under it cannot present them).
    var mediaHost: RoomSheetMediaHost?
    /// The read-aloud bar, at the top of the thread while something is read: reading a reply keeps the thread open and
    /// in view, with the bar over it (Carter, #62471).
    var readAloudBar: RoomReadAloudBarHost?
    /// The room's saved-text key for this account: the reply being written is kept on the phone under it
    /// (`RoomReplyDrafts`); nil keeps none.
    var draftKey: String?
    /// The text typed in each thread while the room is open, so closing the sheet keeps it. Typing writes it without
    /// drawing anything else.
    let draftStore: RoomThreadDraftStore
    let send: (RoomChatIntent) -> Void
    /// The reply being answered (a reply to a reply nests under it); nil answers the message.
    @State private var answering: RoomChatReplyRow?
    /// The reply whose author the reader chose to block, while its row asks to be sure.
    @State private var blockingReply: RoomChatReplyRow?
    /// A reply, an edit about to open, or the thread's writes, held for the AI consent question.
    @State private var consentHeld: AIConsentHeld?
    /// Your own reply being edited.
    @State private var editingReply: RoomChatReplyRow?
    /// What the thread puts in its reply box (a reply answered, an unsent reply taken back): the box's text is its
    /// own, so the sheet hands it the change.
    @State private var composerInbox = RoomThreadComposerInbox()

    private func answer(_ reply: RoomChatReplyRow) {
        answering = reply
        let mention = "@\(reply.authorHandle) "
        composerInbox.edit { $0.hasPrefix(mention) ? $0 : mention + $0 }
    }

    var body: some View {
        NavigationStack {
            RoomThreadRepliesList(
                thread: thread,
                ownHandles: ownHandles,
                readingAloudId: readingAloudId,
                canReact: canReact,
                canReport: canReport,
                canBlock: canBlock,
                media: media,
                previews: previews,
                blockingReplyId: blockingReply?.id,
                send: send,
                onAnswer: { answer($0) },
                onEdit: { reply in
                    // Asked before the editor opens, so an edit is never written to be dropped.
                    if asksAIConsent {
                        consentHeld = AIConsentHeld({ editingReply = reply }, onDecline: { send(.declineAIAgents) })
                    } else {
                        editingReply = reply
                    }
                },
                onBlock: { blockingReply = $0 },
                onEditPending: { pending in
                    composerInbox.edit { RoomComposerDraft.restoring(pending.text, into: $0) }
                    send(.discardSend(clientId: pending.clientId))
                }
            )
            .sheet(item: $editingReply) { reply in
                MessageEditSheet(original: reply.text) { text in
                    send(.editReply(sequenceId: thread.parent.sequenceId, replyId: reply.id, text: text))
                }
            }
            .sheet(isPresented: Binding(
                get: { report != nil },
                set: { presented in if !presented { send(.closeReport) } }
            )) {
                if let report {
                    RoomReportSheet(report: report, send: send)
                }
            }
            .aiConsentPrompt($consentHeld) { send(.allowAIAgents) }
            .onChange(of: consentRequested) { requested in
                guard requested, consentHeld == nil else { return }
                consentHeld = AIConsentHeld({}, onDecline: { send(.declineAIAgents) })
            }
            .navigationTitle(thread.title)
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { send(.closeThread) }
                }
            }
            .background { mediaHost?.content() }
            // The read-aloud bar (#363): its own slot, one line.
            .safeAreaInset(edge: .top, spacing: 0) { readAloudBar?.content() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if thread.canReply {
                    RoomThreadComposer(
                        thread: thread,
                        mentionCandidates: mentionCandidates,
                        actions: actions,
                        asksAIConsent: asksAIConsent,
                        media: media,
                        draftKey: draftKey,
                        draftStore: draftStore,
                        inbox: composerInbox,
                        answering: $answering,
                        consentHeld: $consentHeld,
                        send: send
                    )
                }
            }
        }
    }
}

/// Hands the thread's reply box a change to what it holds, from the sheet around it.
final class RoomThreadComposerInbox {
    /// Set by the box while it shows: applies a change to its text.
    fileprivate var apply: ((String) -> String) -> Void = { _ in }

    func edit(_ change: (String) -> String) { apply(change) }
}

/// The thread's reply box. What is typed is its own: a keystroke draws the box alone, never the sheet, the thread's
/// replies or the room (typing in a long thread lagged, #62423).
private struct RoomThreadComposer: View {
    let thread: RoomChatThreadState
    let mentionCandidates: [MentionCandidate]
    /// What the room's "+" offers, offered here too.
    let actions: RoomComposerActions
    let asksAIConsent: Bool
    let media: RoomMediaBoard?
    let draftKey: String?
    let draftStore: RoomThreadDraftStore
    let inbox: RoomThreadComposerInbox
    /// The reply being answered (a reply to a reply nests under it); nil answers the message.
    @Binding var answering: RoomChatReplyRow?
    /// A reply held for the AI consent question.
    @Binding var consentHeld: AIConsentHeld?
    let send: (RoomChatIntent) -> Void
    /// What is typed in the reply box: the box's own, so a keystroke draws the box alone.
    @State private var draft = ""
    /// A sent reply's text stays saved until the server has it (the coordinator lets it go then); typing meanwhile is
    /// saved once that has had time to happen, as in the room's box.
    @State private var keepsSavedDraft = false
    @State private var sends = 0
    /// The reply the restored text answered, until its row is loaded to answer it again.
    @State private var restoringAnswer: String?
    /// "File as a ticket": the reply goes to the room's ticket keeper as a ticket request.
    @State private var ticketMode = false
    @State private var isReplying = false
    /// Where the reply text last changed (the field does not say where the caret is), for an @ anywhere in it.
    @State private var editOffset: Int?
    @State private var lastDraft = ""
    /// The reply just sent, for a moment, and what the keyboard wrote back of it into the emptied box (see
    /// `emptyComposer`).
    @State private var replySent: String?
    @State private var replyWrittenBack = RoomComposerWriteBack()
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
        guard !keepsSavedDraft, let drafts else { return }
        let text = draft
        let sequenceId = thread.parent.sequenceId
        // Kept under the reply it answers, chosen or restored (whose row may be on a page not yet read).
        let reply = answeringId
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

    /// The restored text answered a reply: answer it again once its row is loaded (the message, if it is gone). A long
    /// thread opens on its newest page: while older pages are there to read, the reply may be on one of them, and a
    /// send still answers it.
    private func answerRestoredReply() {
        guard let id = restoringAnswer else { return }
        if let row = thread.replies.first(where: { $0.id == id }) {
            answering = row
            restoringAnswer = nil
        } else if !thread.isLoading, !thread.hasOlder {
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

    var body: some View {
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
        } else if restoringAnswer != nil {
            // Kept text answers a reply not loaded yet (on an older page): it still answers it, and can stop.
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left")
                Text("Replying to an earlier reply")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    restoringAnswer = nil
                    saveDraft()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop replying to the earlier reply")
            }
            .font(.caption)
            .foregroundStyle(PocketPalette.textSecondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .accessibilityIdentifier("pocket.thread.composer.restoredAnswer")
        }
        // Read once: each row looks at the one before it for its box's label.
        let suggestions = self.suggestions
        if !suggestions.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, candidate in
                        VStack(alignment: .leading, spacing: 0) {
                            if let group = MentionSuggester.groupStarting(at: index, in: suggestions) {
                                MentionGroupHeader(group: group)
                            }
                            Button {
                                draft = MentionSuggester.apply(candidate, to: draft,
                                                               at: editOffset ?? draft.count)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: candidate.symbol)
                                        .foregroundStyle(
                                            candidate.isHuman || candidate.isAll || candidate.isAny
                                                ? PocketPalette.accent : PocketPalette.listening
                                        )
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
                            .accessibilityLabel(candidate.spokenChoice)
                            .accessibilityIdentifier("pocket.thread.mention.\(candidate.handle)")
                        }
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
                    draftStore[thread.parent.sequenceId] = new
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
        .onAppear {
            inbox.apply = { change in draft = change(draft) }
            if draft.isEmpty {
                lastDraft = draftStore[thread.parent.sequenceId]
                draft = lastDraft
            }
            restoreDraft()
        }
        // Closing the thread writes what typing had not yet saved.
        .onDisappear { draftWriter.flush() }
        .onChange(of: thread.replies.count) { _ in answerRestoredReply() }
        .onChange(of: thread.isLoading) { _ in answerRestoredReply() }
        .onChange(of: answering?.id) { _ in saveDraft() }
    }

    private var canSendReply: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && thread.replyLengthProblem(for: draft) == nil
    }

    /// The reply the box answers: the one chosen, or the one restored text answered before its row has loaded, so
    /// sending early still answers it (never the message instead).
    private var answeringId: String? { RoomReplyDrafts.answering(chosen: answering?.id, restoring: restoringAnswer) }

    /// Sends what is in the reply box: with files in the tray, the words and the files as one reply (its card shows
    /// here while they upload); otherwise the words, or the ticket they describe. Never a reply with neither. Before
    /// this account's first write the room asks its OK to share with AI, before the box empties: Not now leaves what
    /// you wrote, your files and who it answers, as they were.
    private func sendReply(allowed: Bool = false) {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let answeringId = self.answeringId
        let hasFiles = media?.tray.isEmpty == false
        let canSend = hasFiles ? thread.replyLengthProblem(for: draft) == nil : canSendReply
        if asksAIConsent, !allowed, canSend {
            consentHeld = AIConsentHeld({ sendReply(allowed: true) }, onDecline: { send(.declineAIAgents) })
            return
        }
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
}


/// Where a thread's shown replies start (`RoomThreadRepliesList`): a lazy list scrolled to a row builds every row
/// before it, so the thread shows its replies from a first one, kept by id.
enum RoomThreadShownStart {
    /// Where in `replies` the shown ones start: the first reply shown, or where the thread opens (a few before the
    /// reply it was opened at, a long thread's newest, else its first).
    static func index(in replies: [RoomChatReplyRow], shownFrom: String?, focus: String?, hasOlder: Bool,
                      focusMissing: Bool) -> Int {
        if let shownFrom, let index = replies.firstIndex(where: { $0.id == shownFrom }) { return index }
        if let focus, let index = replies.firstIndex(where: { $0.id == focus }) {
            return max(0, index - RoomThreadRepliesList.shownBeforeFocus)
        }
        if hasOlder || focusMissing { return max(0, replies.count - RoomThreadRepliesList.newestShown) }
        return 0
    }

    /// The first reply shown once a page of later replies landed: the same one, unless the oldest replies went to make
    /// room (a thread holds 1,000 at most) and took it. It is then the first one kept: falling back to the newest 30
    /// would hide most of each later page.
    static func afterLaterPage(shownFrom: String?, firstBefore: String?, replies: [RoomChatReplyRow]) -> String? {
        guard let first = replies.first?.id, first != firstBefore else { return shownFrom }
        if let shownFrom, replies.contains(where: { $0.id == shownFrom }) { return shownFrom }
        return first
    }
}

/// A thread's message and its replies, oldest first, in a lazy list: it builds the replies in sight. The reply box is
/// a view of its own (`RoomThreadComposer`), so typing never draws it again: it used to draw every reply again at each
/// keystroke (#62423, a thread of 106 long replies). A long thread opens at its newest page, and scrolling up to its
/// top loads the page before. Opened at a reply (its notification), it shows that reply, marked a moment.
private struct RoomThreadRepliesList: View {
    let thread: RoomChatThreadState
    let ownHandles: Set<String>
    var readingAloudId: String?
    var canReact = false
    var canReport = false
    var canBlock = false
    var media: RoomMediaBoard?
    var previews: [String: Data] = [:]
    /// The reply whose author is being blocked, while its row asks to be sure.
    var blockingReplyId: String?
    let send: (RoomChatIntent) -> Void
    /// Answer this reply from the box.
    let onAnswer: (RoomChatReplyRow) -> Void
    /// Edit your own reply (the sheet asks the AI consent first when it must).
    let onEdit: (RoomChatReplyRow) -> Void
    /// Block this reply's author (it asks first), or nil once asked.
    let onBlock: (RoomChatReplyRow?) -> Void
    /// Put an unsent reply's text back in the box.
    let onEditPending: (RoomChatPendingRow) -> Void
    /// The thread's file parts are shown; otherwise they fold behind the file's card.
    @State private var showsFileParts = false
    /// The reply the thread was opened at, marked for a moment once it is in view.
    @State private var flashing: String?
    /// The reply already brought into view: a later read never pulls the reader back to it.
    @State private var shownFocus: String?
    /// The thread has come to rest where it opens: until then, its top is not the reader scrolling up.
    @State private var settled = false
    /// The oldest reply shown when a page of older ones was asked for: the reader stays on it as they arrive above.
    @State private var anchorBeforeOlder: String?
    /// The replies' first and last when a page of later ones was asked for: when the oldest go to make room, the reader
    /// stays on the last.
    @State private var laterAsked: (first: String?, last: String?)?
    /// The first reply shown: the replies before it wait above, shown a few at a time as the reader scrolls up. A lazy
    /// list scrolled to a row builds every row before it (the thread opened at reply 600 of 1,000 built 602), so the
    /// thread opens with its first shown reply near where it opens, and the scroll builds only the rows near it.
    @State private var shownFrom: String?
    /// A scroll asked for, made once what it scrolls to is in the list (set with the first reply shown).
    @State private var scrollRequest: ThreadScrollRequest?

    /// Replies shown before the one a thread opens at.
    static let shownBeforeFocus = 10
    /// The newest replies a long thread opens with.
    static let newestShown = 30
    /// Replies shown at once above the first, as the reader scrolls up.
    static let shownAtOnce = 30

    /// The replies the thread shows (file parts fold behind their file's card).
    private var replies: [RoomChatReplyRow] { thread.replies.filter { showsFileParts || $0.filePartOf == nil } }

    /// Where in `replies` the shown ones start: the first reply shown, or where the thread opens (a few before the
    /// reply it was opened at, a long thread's newest, else its first).
    private func shownStart(in replies: [RoomChatReplyRow]) -> Int {
        RoomThreadShownStart.index(in: replies, shownFrom: shownFrom, focus: thread.focusReplyId,
                                   hasOlder: thread.hasOlder, focusMissing: thread.focusMissing)
    }

    var body: some View {
        let _ = RenderTrace.built(.threadList)
        let _ = RenderTrace.explainsThreadList ? Self._printChanges() : ()
        let replies = self.replies
        let start = shownStart(in: replies)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if thread.parent.hidesAsBlocked {
                            RoomBlockedLine(identifier: "pocket.thread.blocked.parent") {
                                send(.revealBlocked(key: RoomBlocking.revealKey(thread.parent)))
                            }
                        } else {
                            Text(thread.parent.authorName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(thread.parent.isHuman ? PocketPalette.listening : PocketPalette.textPrimary)
                            if thread.parent.filePartOf == nil || showsFileParts {
                                ChatMarkdownView(text: thread.parent.text, ownHandles: ownHandles)
                            }
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
                    if start > 0 || thread.hasOlder {
                        olderRow
                    }
                    ForEach(Array(replies[start...])) { reply in
                        if reply.hidesAsBlocked {
                            RoomBlockedLine(identifier: "pocket.thread.blocked.\(reply.id)") {
                                send(.revealBlocked(key: RoomBlocking.revealKey(reply: reply.id)))
                            }
                            .id(Self.replyAnchor(reply.id))
                            .padding(.leading, 12 + CGFloat(reply.depth) * 16)
                        } else {
                            replyRow(reply)
                        }
                    }
                    if thread.hasLater {
                        laterRow
                    }
                    if thread.hasNewer {
                        newestRow
                    }
                    ForEach(thread.pending) { pending in
                        RoomPendingRowView(
                            row: pending,
                            recovery: RoomPendingRecovery(canPost: thread.canReply),
                            onRetry: { send(.retrySend(clientId: pending.clientId)) },
                            onDiscard: { send(.discardSend(clientId: pending.clientId)) },
                            onEdit: { onEditPending(pending) }
                        )
                    }
                    // This thread's replies with files on their way, each with its pictures and progress.
                    if let media {
                        RoomMediaOutgoingList(board: media, thread: thread.parent.sequenceId)
                    }
                    Color.clear.frame(height: 1).id(Self.endAnchor)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            // The reply it was opened at is further back than one search reads: say so, and go on when asked.
            .safeAreaInset(edge: .top, spacing: 0) {
                if thread.focusMissing {
                    jumpToReplyRow
                }
            }
            // Where it opens, once its replies are read: the reply it was opened at (its notification), a long
            // thread's newest reply, or its top.
            .onAppear { if !thread.isLoading { arrive(proxy) } }
            .onChange(of: thread.isLoading) { loading in if !loading { arrive(proxy) } }
            .onChange(of: thread.replies.count) { _ in
                // A page of older replies keeps the reader where they were; a reply found further back comes into view
                // (after, so it wins).
                keepPlace(proxy)
                showFocusedReply(proxy)
            }
            .onChange(of: thread.focusMissing) { missing in if missing { scroll(to: Self.endAnchor, anchor: .bottom) } }
            .onChange(of: thread.isLoadingLater) { loading in if !loading { keepPlaceAfterLater() } }
            // Back at the newest replies (the shown ones were a long way back): the thread shows them from its end.
            .onChange(of: thread.hasNewer) { newer in
                guard !newer else { return }
                shownFrom = nil
                scroll(to: Self.endAnchor, anchor: .bottom)
            }
            // Made once the rows it scrolls to are in the list: the first reply shown is set in the same update.
            .onChange(of: scrollRequest) { request in
                guard let request else { return }
                DispatchQueue.main.async { proxy.scrollTo(request.target, anchor: request.anchor) }
            }
        }
    }

    private func scroll(to target: String, anchor: UnitPoint) {
        scrollRequest = ThreadScrollRequest(target: target, anchor: anchor)
    }

    private static let endAnchor = "thread.end"

    private static func replyAnchor(_ id: String) -> String { "reply:" + id }

    /// Where the thread opens, once: the reply it was opened at; a long thread's newest reply; else its top. The first
    /// reply shown is kept from here on (by its id), so replies arriving below never move the ones on screen.
    private func arrive(_ proxy: ScrollViewProxy) {
        guard !settled else { return }
        let replies = self.replies
        let start = shownStart(in: replies)
        if shownFrom == nil, replies.indices.contains(start) { shownFrom = replies[start].id }
        if thread.focusReplyId != nil, !thread.focusMissing {
            showFocusedReply(proxy)
        } else if thread.hasOlder || thread.focusMissing {
            scroll(to: Self.endAnchor, anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled = true }
    }

    /// Brings the reply the thread was opened at into view once it is loaded, once, and marks it a moment. The replies
    /// shown start a few before it, so the scroll builds the rows near it, never all those above it.
    private func showFocusedReply(_ proxy: ScrollViewProxy) {
        let replies = self.replies
        guard let focus = thread.focusReplyId, focus != shownFocus,
              let index = replies.firstIndex(where: { $0.id == focus }) else { return }
        shownFocus = focus
        shownFrom = replies[max(0, index - Self.shownBeforeFocus)].id
        // Straight there, the mark shows where: an animated scroll would build every reply it passes.
        scroll(to: Self.replyAnchor(focus), anchor: .center)
        flashing = focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut(duration: 0.4)) {
                if flashing == focus { flashing = nil }
            }
        }
    }

    /// Above the first reply shown: reached by scrolling up, it shows the replies loaded above it, a few at a time, and
    /// once all are shown it loads the page before.
    private var olderRow: some View {
        HStack(spacing: 8) {
            if thread.isLoadingOlder {
                ProgressView()
                Text("Loading earlier replies…")
            } else {
                Button("Load earlier replies") { showEarlier() }
                    .accessibilityIdentifier("pocket.thread.older")
            }
        }
        .font(.footnote)
        .foregroundStyle(PocketPalette.textSecondary)
        .frame(maxWidth: .infinity)
        .onAppear { if settled { showEarlier() } }
    }

    /// Shows the replies above the first shown, `shownAtOnce` of them, keeping the reader on the reply they were at; with
    /// none above, loads the page before.
    private func showEarlier() {
        let replies = self.replies
        let start = shownStart(in: replies)
        if start > 0 {
            let first = replies[start].id
            shownFrom = replies[max(0, start - Self.shownAtOnce)].id
            scroll(to: Self.replyAnchor(first), anchor: .top)
        } else if thread.hasOlder, !thread.isLoadingOlder {
            anchorBeforeOlder = replies.first?.id
            send(.loadOlderReplies(sequenceId: thread.parent.sequenceId))
        }
    }

    /// The older page arrived above: the reader stays on the reply they were at, with the newest of the page shown
    /// above it.
    private func keepPlace(_ proxy: ScrollViewProxy) {
        guard let anchor = anchorBeforeOlder else { return }
        anchorBeforeOlder = nil
        let replies = self.replies
        guard let index = replies.firstIndex(where: { $0.id == anchor }) else { return }
        shownFrom = replies[max(0, index - Self.shownAtOnce)].id
        scroll(to: Self.replyAnchor(anchor), anchor: .top)
    }

    /// Below the newest reply loaded when the thread was opened at a reply short of its newest (one read around it):
    /// reached by scrolling down, it loads the page after. A page that could not be read says so here too, where the
    /// reader is.
    private var laterRow: some View {
        VStack(spacing: 4) {
            if thread.isLoadingLater {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading later replies…")
                }
            } else {
                if let failure = thread.failureText {
                    Text(failure).foregroundStyle(PocketPalette.warning)
                }
                Button("Load later replies") { showLater() }
                    .accessibilityIdentifier("pocket.thread.later")
            }
        }
        .font(.footnote)
        .foregroundStyle(PocketPalette.textSecondary)
        .frame(maxWidth: .infinity)
        .onAppear { if settled { showLater() } }
    }

    /// Asks for the page after the newest reply loaded, noting where the replies start and end as it is asked.
    private func showLater() {
        guard !thread.isLoadingLater else { return }
        let replies = self.replies
        laterAsked = (first: replies.first?.id, last: replies.last?.id)
        send(.loadLaterReplies(sequenceId: thread.parent.sequenceId))
    }

    /// A page of later replies landed below. When the oldest went to make room and took the first reply shown, the
    /// first shown is the first one kept (`RoomThreadShownStart.afterLaterPage`), and the reader stays on the reply
    /// they were at.
    private func keepPlaceAfterLater() {
        guard let asked = laterAsked else { return }
        laterAsked = nil
        let replies = self.replies
        let kept = RoomThreadShownStart.afterLaterPage(shownFrom: shownFrom, firstBefore: asked.first, replies: replies)
        guard kept != shownFrom else { return }
        shownFrom = kept
        if let last = asked.last, replies.contains(where: { $0.id == last }) {
            scroll(to: Self.replyAnchor(last), anchor: .bottom)
        }
    }

    /// Below the replies shown when they are a long way back (the newest were let go): reads the newest again.
    private var newestRow: some View {
        Button {
            send(.jumpToNewestReplies(sequenceId: thread.parent.sequenceId))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                Text("Newest replies")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(PocketPalette.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pocket.thread.newest")
    }

    /// The reply this thread was opened at is further back than one search reads: one tap reads on.
    private var jumpToReplyRow: some View {
        Button {
            send(.continueToReply(sequenceId: thread.parent.sequenceId))
        } label: {
            HStack(spacing: 8) {
                if thread.isLoadingOlder {
                    ProgressView()
                    Text("Looking for the reply…")
                } else {
                    Image(systemName: "arrow.up.circle")
                    Text("Jump to the reply")
                }
                Spacer(minLength: 0)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(PocketPalette.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PocketPalette.raised)
        }
        .buttonStyle(.plain)
        .disabled(thread.isLoadingOlder)
        .accessibilityIdentifier("pocket.thread.jumpToReply")
    }

    /// One reply in the thread, with its menu and swipe to answer.
    private func replyRow(_ reply: RoomChatReplyRow) -> some View {
        RenderTrace.builtThreadReply(reply.id)
        return VStack(alignment: .leading, spacing: 3) {
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
            // Who the server chose for an @any in it, or that nobody was free, as under a message.
            if let line = reply.addressedLine {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .accessibilityLabel(line)
                    .accessibilityIdentifier("pocket.thread.addressed.\(reply.id)")
            }
            if let views = reply.views {
                RoomViewedLine(views: views)
            }
        }
        .id(Self.replyAnchor(reply.id))
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(flashing == reply.id ? PocketPalette.accent.opacity(0.18) : Color.clear)
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
                onAnswer(reply)
            }
        })
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(PocketPalette.separator).frame(width: 2)
        }
        .padding(.leading, CGFloat(reply.depth) * 16)
        .accessibilityAction(named: "Reply") { onAnswer(reply) }
        // Asked at the reply, so the question points at it.
        .roomBlockConfirmation(Binding(
            get: {
                blockingReplyId == reply.id ? reply.reportTarget(inThread: thread.parent.sequenceId).map { RoomBlockTarget($0) } : nil
            },
            set: { if $0 == nil { onBlock(nil) } }
        ), send: send)
    }

    /// The same choices as a message in the room: reply, react, listen, copy.
    @ViewBuilder
    private func replyMenu(_ reply: RoomChatReplyRow) -> some View {
        if thread.canReply {
            Button {
                onAnswer(reply)
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
                onEdit(reply)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
        Button {
            copyToPasteboard(reply.text)
        } label: {
            Label("Copy text", systemImage: "doc.on.doc")
        }
        if let target = reply.reportTarget(inThread: thread.parent.sequenceId) {
            if canReport {
                Button {
                    send(.openReport(target))
                } label: {
                    Label("Report…", systemImage: "exclamationmark.bubble")
                }
            }
            if canBlock, !reply.isAuthorBlocked, reply.authorId.lowercased() != RoomBlocking.serverAuthor {
                Button(role: .destructive) {
                    // Once the menu has gone, so the question is never dropped.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onBlock(reply) }
                } label: {
                    Label("Block \(reply.authorName)", systemImage: "hand.raised")
                }
            }
        }
    }
}

/// A scroll the thread's list asks for: to a row's id, at an anchor. Each one asked for is new, even to the same row.
private struct ThreadScrollRequest: Equatable {
    let target: String
    let anchor: UnitPoint
    let token = UUID()
}

/// The reply typed in each thread while the room is open, by the thread's message. A reference: typing writes it, and
/// nothing is drawn again for it.
final class RoomThreadDraftStore {
    private var texts: [Int64: String] = [:]

    subscript(thread: Int64) -> String {
        get { texts[thread] ?? "" }
        set { texts[thread] = newValue.isEmpty ? nil : newValue }
    }
}

private struct RoomPendingRowView: View {
    let row: RoomChatPendingRow
    let recovery: RoomPendingRecovery
    let onRetry: () -> Void
    let onDiscard: () -> Void
    /// Puts the text back where it was typed, so a refused message can be changed and sent again.
    let onEdit: () -> Void
    /// Goes to the room's latest messages, where a message sent from an older stretch shows.
    var onLatest: () -> Void = {}

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
            case .sentBelow:
                Button(action: onLatest) {
                    Label("Sent · ↓ latest", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PocketPalette.accent)
                .accessibilityLabel("Sent. Shown with the latest messages")
                .accessibilityHint("Goes to the latest messages")
                .accessibilityIdentifier("pocket.room.pending.latest")
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
    /// The first send in a room with AI agents asks your OK first (`RoomChatPresentationState.asksAIConsent`); the
    /// room asks, and the send goes after OK.
    var asksAIConsent = false
    var askAIConsent: (AIConsentHeld) -> Void = { _ in }
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
    private func sendDraft(allowed: Bool = false) {
        let text = outgoing
        // In a room with AI agents the first send asks your OK, before the box empties: Not now keeps what you wrote,
        // your files and who you were answering, as they were.
        if asksAIConsent, !allowed, !text.isEmpty || media?.tray.isEmpty == false {
            askAIConsent(AIConsentHeld({ sendDraft(allowed: true) }, onDecline: { onIntent(.declineAIAgents) }))
            return
        }
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
                        // One view per row: a box's label goes in with its first agent.
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, candidate in
                            VStack(alignment: .leading, spacing: 0) {
                                if let group = MentionSuggester.groupStarting(at: index, in: suggestions) {
                                    MentionGroupHeader(group: group)
                                }
                                Button {
                                    draft = MentionSuggester.apply(candidate, to: draft, at: editOffset ?? draft.count)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: candidate.symbol)
                                            .font(.body)
                                            .foregroundStyle(candidate.isHuman || candidate.isAll || candidate.isAny
                                                ? PocketPalette.accent : PocketPalette.listening)
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
                                .accessibilityLabel(candidate.spokenChoice)
                                .accessibilityIdentifier("pocket.room.mention.\(candidate.handle)")
                            }
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
        // Said to VoiceOver by the room (`shownComposingWords`), not here: a row in a lazy list appears again each
        // time it is scrolled back to.
        Text(RoomComposingWords.line(agents))
            .font(.caption)
            .foregroundStyle(PocketPalette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .accessibilityIdentifier("pocket.room.composing")
    }
}

/// Says the room's typing line to VoiceOver. A test sets its own to hear what is said.
public struct RoomAnnouncer {
    public let say: @MainActor (String) -> Void

    public init(say: @escaping @MainActor (String) -> Void) {
        self.say = say
    }

    /// VoiceOver, when it is running.
    public static let voiceOver = RoomAnnouncer { RoomComposingWords.announce($0) }
}

private struct RoomAnnouncerKey: EnvironmentKey {
    static let defaultValue = RoomAnnouncer.voiceOver
}

public extension EnvironmentValues {
    /// Where the room's typing line is said (`RoomAnnouncer.voiceOver` unless set).
    var roomAnnouncer: RoomAnnouncer {
        get { self[RoomAnnouncerKey.self] }
        set { self[RoomAnnouncerKey.self] = newValue }
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
    /// Invite people shows for the room's owner or an admin (`RoomChatPresentationState.canInvite`), with what the app
    /// gives it (`RoomPeopleExtras.invite`).
    var canInvite = false
    /// What the app adds: Invite people, and the agent requests for whoever decides them.
    var extras: RoomPeopleExtras?
    /// Opens a member's profile from their avatar.
    var onProfile: ((RoomProfileTarget) -> Void)?
    var ownAuthorIds: Set<String> = []
    /// Every member's profile opens (their messages), not only those a direct message can reach.
    var opensEveryone = false
    @Environment(\.dismiss) private var dismiss

    /// The member's profile: anyone's where profiles show messages; otherwise their card, unless it is you, the room's
    /// voice or a box that ended.
    private func profileTarget(_ member: RoomRoster.Member) -> RoomProfileTarget? {
        guard onProfile != nil else { return nil }
        if opensEveryone {
            guard RoomProfile.showsMember(senderId: member.id) else { return nil }
        } else {
            guard member.status != .ended, RoomProfile.opens(senderId: member.id, ownAuthorIds: ownAuthorIds) else { return nil }
        }
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
                // Invite people first (Carter, #62868: inviting someone was a hunt).
                if let invite = shownInvite {
                    Section {
                        invite()
                    } header: {
                        Text("Invite people")
                    }
                    .accessibilityIdentifier("pocket.room.people.invite")
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
                // The agent requests last, for the room's owner or an admin.
                if let requests = extras?.requests {
                    Section {
                        requests()
                    }
                    .accessibilityIdentifier("pocket.room.people.requests")
                }
            }
            // Invite people's sheets, presented from here once, never from its rows.
            .background { if shownInvite != nil { extras?.presenters?() } }
            .navigationTitle("People")
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { extras?.shown?(sections) }
    }

    private var shownInvite: (() -> AnyView)? { canInvite ? extras?.invite : nil }

    /// The sheet's sections, in order.
    var sections: [String] {
        (shownInvite == nil ? [] : ["invite"]) + ["members"] + (extras?.requests == nil ? [] : ["requests"])
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
            && lhs.isMinimized == rhs.isMinimized && lhs.canReport == rhs.canReport && lhs.canBlock == rhs.canBlock
            && lhs.asksAIConsent == rhs.asksAIConsent
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
/// The label over a box's agents in the @-mention picker ("Box 3f2a").
struct MentionGroupHeader: View {
    let group: MentionGroup

    var body: some View {
        Text(group.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PocketPalette.textSecondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("pocket.mention.group.\(group.id)")
    }
}
#endif
