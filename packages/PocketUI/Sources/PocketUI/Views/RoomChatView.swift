#if canImport(SwiftUI)
import SwiftUI
import PocketContracts

/// The live room: the same conversation the web shows, newest at the bottom, with jump-to-latest, an unread
/// divider and older history loaded on demand.
public struct RoomChatView: View {
    private let state: RoomChatPresentationState
    private let send: (RoomChatIntent) -> Void

    @State private var readerAtBottom = true
    @State private var didInitialScroll = false
    @State private var anchorBeforeOlderLoad: String?
    @State private var highlightedRowId: String?

    public init(state: RoomChatPresentationState, send: @escaping (RoomChatIntent) -> Void) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        Group {
            if state.isEmpty {
                emptyOrFailure
            } else {
                timeline
            }
        }
        .navigationTitle(state.title)
        .navigationBarTitleDisplayModeInlineIfAvailable()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RoomConnectionPill(connection: state.connection)
            }
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
                    if !state.composingAgents.isEmpty {
                        RoomComposingLine(agents: state.composingAgents)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomId)
                        .onAppear {
                            readerAtBottom = true
                            send(.readerAtBottom(true))
                        }
                        .onDisappear {
                            readerAtBottom = false
                            send(.readerAtBottom(false))
                        }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .overlay(alignment: .bottomTrailing) {
                if !readerAtBottom {
                    jumpToLatestButton(proxy: proxy)
                }
            }
            .onAppear { scrollToInitialPosition(proxy) }
            .onChange(of: state.lastMessageId) { _ in
                if !didInitialScroll {
                    scrollToInitialPosition(proxy)
                } else if readerAtBottom {
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
                isHighlighted: highlightedRowId == row.id,
                onOpenReplyTarget: { jump(to: $0, proxy: proxy) }
            )
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
        didInitialScroll = true
        DispatchQueue.main.async {
            if state.rows.contains(.unreadDivider) {
                proxy.scrollTo(RoomChatRow.unreadDivider.id, anchor: .top)
            } else {
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
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
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(target.id, anchor: .center)
        }
        highlightedRowId = target.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if highlightedRowId == target.id { highlightedRowId = nil }
        }
    }

    private static let bottomId = "room-bottom"
}

private struct RoomMessageRowView: View {
    let row: RoomChatMessageRow
    let isHighlighted: Bool
    let onOpenReplyTarget: (Int64) -> Void

    var body: some View {
        switch row.kind {
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
            .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            Text(RoomChatText.attributed(row.text))
                .font(.body)
                .foregroundStyle(PocketPalette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if row.isEdited {
                Text("edited")
                    .font(.caption2)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHighlighted ? PocketPalette.warning.opacity(0.18) : (row.isOwn ? PocketPalette.listening.opacity(0.08) : Color.clear))
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pocket.room.message.\(row.sequenceId)")
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

/// Inline Markdown for chat bodies (bold, italic, code, links), with the web's link policy applied: a link whose
/// URL is not http(s) to a real host stays visible as text but is not tappable.
enum RoomChatText {
    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        let blocked = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link, !RoomLinkPolicy.isAllowed(url) else { return nil }
            return run.range
        }
        for range in blocked {
            attributed[range].link = nil
        }
        return attributed
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
#endif
