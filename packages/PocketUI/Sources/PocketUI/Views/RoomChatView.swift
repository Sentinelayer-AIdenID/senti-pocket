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

    /// The reply being typed in each thread, kept while the room is open: closing the sheet does not lose it.
    @State private var threadDrafts: [Int64: String] = [:]
    @State private var readerAtBottom = true
    @State private var didInitialScroll = false
    @State private var anchorBeforeOlderLoad: String?
    @State private var highlightedRowId: String?
    @State private var showsPresence = false
    /// A failed message the reader chose to edit: its text goes back into the composer.
    @State private var restoredDraft: RoomComposerRestore?

    public init(state: RoomChatPresentationState, send: @escaping (RoomChatIntent) -> Void) {
        self.state = state
        self.send = send
    }

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
            RoomComposerBar(composer: state.composer, mentionCandidates: state.mentionCandidates, restored: restoredDraft) { text in
                send(.sendMessage(text: text))
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
                    send: send,
                    draft: threadDraft(thread.parent.sequenceId)
                )
            }
        }
        .navigationTitle(state.title)
        .navigationBarTitleDisplayModeInlineIfAvailable()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RoomConnectionPill(connection: state.connection)
            }
            if let presence = state.presence {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsPresence = true
                    } label: {
                        Label(presence.label, systemImage: "person.2")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .italic(!presence.isAvailable)
                    }
                    .disabled(presence.people.isEmpty)
                    .accessibilityIdentifier("pocket.room.presence")
                }
            }
        }
        .sheet(isPresented: $showsPresence) {
            RoomPresenceSheet(presence: state.presence)
        }
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
                    if !state.composingAgents.isEmpty {
                        RoomComposingLine(agents: state.composingAgents)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomId)
                        .onAppear { setReaderAtBottom(true) }
                        .onDisappear { setReaderAtBottom(false) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .overlay(alignment: .bottomTrailing) {
                if !readerAtBottom {
                    jumpToLatestButton(proxy: proxy)
                }
            }
            .onAppear {
                scrollToInitialPosition(proxy)
                focusIfNeeded(proxy)
            }
            .onChange(of: state.focusSequenceId) { _ in focusIfNeeded(proxy) }
            .onChange(of: state.focusFallbackCount) { _ in showLatest(proxy) }
            // At the bottom, stay at the bottom when rows above change size: an image preview loading, reactions
            // or a reply count arriving. A reader scrolled up is never moved.
            .onChange(of: state.rows) { _ in keepAtBottomIfThere(proxy) }
            .onChange(of: state.attachmentPreviews.count) { _ in keepAtBottomIfThere(proxy) }
            .onChange(of: state.rows.count) { _ in focusIfNeeded(proxy) }
            .onChange(of: state.lastMessageId) { _ in
                if !didInitialScroll {
                    scrollToInitialPosition(proxy)
                } else if readerAtBottom {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: state.pending.count) { count in
                // Sending always brings you to the bottom, where your message appears.
                if count > 0 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: state.firstMessageId) { _ in
                // Older rows were prepended: keep the row the reader was looking at in place.
                if let anchor = anchorBeforeOlderLoad {
                    proxy.scrollTo(anchor, anchor: .top)
                    anchorBeforeOlderLoad = nil
                }
            }
        }
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
                .onAppear { if didInitialScroll { loadOlder() } }
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
            RoomMessageRowView(
                row: message,
                ownHandles: state.ownMentionHandles,
                isHighlighted: highlightedRowId == row.id,
                canReact: state.canReact,
                canReply: state.composer.canPost,
                breakouts: state.breakouts,
                attachmentPreviews: state.attachmentPreviews,
                onOpenReplyTarget: { jump(to: $0, proxy: proxy) },
                send: send
            )
            .onAppear { send(.messageOnScreen(id: message.id, isOnScreen: true)) }
            .onDisappear { send(.messageOnScreen(id: message.id, isOnScreen: false)) }
        }
    }

    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Button {
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
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(PocketPalette.separator, lineWidth: 0.5))
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
        // A room opened at a message (a link or notification) is positioned by `focusIfNeeded` instead.
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

    /// Brings the focused message into view once it is loaded, highlights it, and reports it handled.
    private func focusIfNeeded(_ proxy: ScrollViewProxy) {
        guard let focus = state.focusSequenceId else { return }
        let target = state.rows.first { row in
            if case .message(let message) = row { return message.sequenceId == focus }
            return false
        }
        guard let target else { return }
        didInitialScroll = true
        // Reading a message elsewhere in the room: new messages must not pull the view down. If the bottom is in
        // view after the scroll, the bottom marker says so.
        setReaderAtBottom(false)
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target.id, anchor: .center) }
            highlightedRowId = target.id
            send(.focusHandled)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if highlightedRowId == target.id { highlightedRowId = nil }
            }
        }
    }

    private func jump(to sequenceId: Int64, proxy: ScrollViewProxy) {
        let target = state.rows.first { row in
            if case .message(let message) = row { return message.sequenceId == sequenceId }
            return false
        }
        guard let target else {
            send(.jumpToMessage(sequenceId: sequenceId))
            return
        }
        setReaderAtBottom(false)
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
        guard didInitialScroll, readerAtBottom, state.focusSequenceId == nil else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomId, anchor: .bottom)
        }
    }

    private static let bottomId = "room-bottom"
}

private struct RoomMessageRowView: View {
    let row: RoomChatMessageRow
    let ownHandles: Set<String>
    let isHighlighted: Bool
    var canReact = false
    var canReply = false
    var breakouts: [String: RoomBreakoutCard] = [:]
    var attachmentPreviews: [String: Data] = [:]
    let onOpenReplyTarget: (Int64) -> Void
    var send: (RoomChatIntent) -> Void = { _ in }

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
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5)
            )
            .padding(.vertical, 6)
        case .message:
            message
        }
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 4) {
            if row.showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.authorName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(row.isHuman ? PocketPalette.listening : PocketPalette.textPrimary)
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
                .padding(.top, 10)
            }
            if let reply = row.replyToSequenceId {
                Button {
                    onOpenReplyTarget(reply)
                } label: {
                    Label("Replying to #\(reply)", systemImage: "arrowshape.turn.up.left")
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                .buttonStyle(.plain)
            }
            ChatMarkdownView(text: row.text, ownHandles: ownHandles)
                .font(.body)
                .foregroundStyle(PocketPalette.textPrimary)
            if !row.attachments.isEmpty {
                RoomAttachmentsView(chips: row.attachments, previews: attachmentPreviews, send: send)
            }
            if row.isEdited {
                Text("edited")
                    .font(.caption2)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            if let views = row.views {
                RoomViewedLine(views: views)
            }
            if let reactions = row.reactions {
                RoomReactionBar(
                    reactions: reactions,
                    canReact: canReact,
                    onReact: { send(.react(sequenceId: row.sequenceId, type: $0)) },
                    onOpenThread: { send(.openThread(sequenceId: row.sequenceId)) }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHighlighted ? PocketPalette.warning.opacity(0.18) : (row.isOwn ? PocketPalette.listening.opacity(0.08) : Color.clear))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.room.message.\(row.sequenceId)")
        .contextMenu { messageMenu }
    }

    @ViewBuilder
    private var messageMenu: some View {
        Button {
            send(.openThread(sequenceId: row.sequenceId))
        } label: {
            Label(canReply ? "Reply in thread" : "Open thread", systemImage: "bubble.left.and.bubble.right")
        }
        if canReact {
            let liked = row.reactions?.chips.contains { $0.type == "like" && $0.isMine } == true
            let disliked = row.reactions?.chips.contains { $0.type == "dislike" && $0.isMine } == true
            Button {
                send(.react(sequenceId: row.sequenceId, type: liked ? "unlike" : "like"))
            } label: {
                Label(liked ? "Remove like" : "Like", systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            Button {
                send(.react(sequenceId: row.sequenceId, type: disliked ? "undislike" : "dislike"))
            } label: {
                Label(disliked ? "Remove dislike" : "Dislike", systemImage: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
            Button {
                send(.react(sequenceId: row.sequenceId, type: "ack"))
            } label: {
                Label("Acknowledge", systemImage: "checkmark.circle")
            }
        }
        Button {
            copyToPasteboard(row.text)
        } label: {
            Label("Copy text", systemImage: "doc.on.doc")
        }
    }
}

private func copyToPasteboard(_ text: String) {
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
    let send: (RoomChatIntent) -> Void
    @Binding var draft: String

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
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(PocketPalette.separator).frame(width: 2)
                        }
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
                    if let problem = thread.replyLengthProblem(for: draft) {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(PocketPalette.danger)
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                            .accessibilityIdentifier("pocket.thread.composer.tooLong")
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Reply", text: $draft, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .accessibilityIdentifier("pocket.thread.composer")
                        Button {
                            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard canSendReply else { return }
                            send(.sendReply(sequenceId: thread.parent.sequenceId, text: text))
                            draft = ""
                        } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSendReply)
                        .accessibilityLabel("Send reply")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    }
                    .background(.bar)
                }
            }
        }
    }

    private var canSendReply: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && thread.replyLengthProblem(for: draft) == nil
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
private struct RoomComposerBar: View {
    let composer: RoomComposerState
    var mentionCandidates: [MentionCandidate] = []
    var restored: RoomComposerRestore?
    let send: (String) -> Void
    @State private var draft = ""

    private var suggestions: [MentionCandidate] {
        guard let active = MentionSuggester.activeQuery(in: draft) else { return [] }
        return MentionSuggester.suggestions(for: active.query, among: mentionCandidates)
    }

    var body: some View {
        if composer.canPost {
            VStack(alignment: .leading, spacing: 0) {
            if let problem = composer.lengthProblem(for: draft) {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(PocketPalette.danger)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .accessibilityIdentifier("pocket.room.composer.tooLong")
            }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions) { candidate in
                            Button {
                                draft = MentionSuggester.apply(candidate, to: draft)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: candidate.isAll ? "person.3" : (candidate.isHuman ? "person" : "cpu"))
                                    Text(candidate.isAll ? "@all · Everyone" : "@\(candidate.handle)")
                                }
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(PocketPalette.raised, in: Capsule())
                                .overlay(Capsule().stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("pocket.room.mention.\(candidate.handle)")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5)
                    )
                    .accessibilityIdentifier("pocket.room.composer")
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    send(text)
                    draft = ""
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            }
            .background(.bar)
            .onChange(of: restored) { request in
                guard let request else { return }
                draft = RoomComposerDraft.restoring(request.text, into: draft)
            }
        } else if let reason = composer.disabledReason {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(PocketPalette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.bar)
                .accessibilityIdentifier("pocket.room.composerDisabled")
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && composer.lengthProblem(for: draft) == nil
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

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(connection.label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(PocketPalette.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pocket.room.connection")
    }

    private var color: Color {
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

private extension View {
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

/// Who is here: people first, then agents, active or idle.
private struct RoomPresenceSheet: View {
    let presence: RoomChatPresence?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(presence?.people ?? []) { person in
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

#endif
