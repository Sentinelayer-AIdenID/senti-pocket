#if canImport(SwiftUI)
import SwiftUI

/// Someone's profile, from their avatar or name in the room, the people ring or the people list: their card on top
/// (Message and Block, where they apply), how their posts come in when the API knows, a box's live steps and its
/// Flight record, then their messages, newest first, a page at a time. Tapping a message closes the sheet and brings
/// it into view in the room.
public struct RoomMemberSheetView: View {
    private let card: RoomProfileCardState
    private let messages: RoomMemberMessagesState
    private let box: FlightRecordState.Box?
    private let onMessage: () -> Void
    /// Block, with the message it names (the newest in the list): the card offers it only once there is one.
    private let onBlock: ((Int64) -> Void)?
    private let onClose: () -> Void
    private let onOpenMessage: (Int64) -> Void
    private let onLoadMore: () -> Void
    private let onRetry: () -> Void
    private let onOpenFlight: (() -> Void)?
    /// See all on the card's "Rooms you share".
    private let onSeeAllRooms: (() -> Void)?

    /// The most of a box's steps shown here; its Flight record has them all.
    static let stepsShown = 5

    public init(card: RoomProfileCardState, messages: RoomMemberMessagesState, box: FlightRecordState.Box? = nil,
                onMessage: @escaping () -> Void, onBlock: ((Int64) -> Void)? = nil, onClose: @escaping () -> Void,
                onOpenMessage: @escaping (Int64) -> Void, onLoadMore: @escaping () -> Void,
                onRetry: @escaping () -> Void, onOpenFlight: (() -> Void)? = nil,
                onSeeAllRooms: (() -> Void)? = nil) {
        self.card = card
        self.messages = messages
        self.box = box
        self.onMessage = onMessage
        self.onBlock = onBlock
        self.onClose = onClose
        self.onOpenMessage = onOpenMessage
        self.onLoadMore = onLoadMore
        self.onRetry = onRetry
        self.onOpenFlight = onOpenFlight
        self.onSeeAllRooms = onSeeAllRooms
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RoomProfileCardView(state: card, onMessage: onMessage, onBlock: messages.blockAction(onBlock),
                                    onSeeAllRooms: onSeeAllRooms, onClose: onClose)
                if let line = messages.connectionLine {
                    Label(line, systemImage: connectionSymbol)
                        .font(.subheadline)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)
                        .accessibilityIdentifier("pocket.member.connection")
                }
                if let box {
                    boxSection(box)
                }
                // The work they were given and how it went (assigned, accepted, open or blocked, and its review) goes
                // here, between who they are and what they said, once its contract is out.
                messagesSection
            }
        }
        .background(PocketPalette.canvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.member.sheet")
    }

    private var connectionSymbol: String {
        switch messages.connection {
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .box: return "shippingbox"
        case .app: return "iphone"
        case .web: return "globe"
        case .cli: return "terminal"
        case nil: return "circle"
        }
    }

    /// A box at work: what it is on, its newest steps, and its Flight record.
    private func boxSection(_ box: FlightRecordState.Box) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(PocketPalette.accent)
                    .accessibilityHidden(true)
                Text(box.isWorking ? "Working now" : box.phase.capitalized)
                    .font(.headline)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            if let job = box.job {
                Text(job)
                    .font(.subheadline)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .lineLimit(3)
            }
            if box.lines.isEmpty, let current = box.current {
                Text(current)
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .lineLimit(3)
            }
            ForEach(box.lines.prefix(Self.stepsShown)) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: line.isCommand ? "terminal" : "text.bubble")
                        .font(.caption2)
                        .foregroundStyle(tone(line.tone))
                        .accessibilityHidden(true)
                    Text(line.text)
                        .font(line.isCommand ? .caption.monospaced() : .caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
            if let onOpenFlight {
                Button(action: onOpenFlight) {
                    Label("Flight record", systemImage: "airplane")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
                .accessibilityHint("Opens the room's Flight record")
                .accessibilityIdentifier("pocket.member.flight")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.member.box")
    }

    private func tone(_ tone: FlightRecordState.Tone) -> Color {
        switch tone {
        case .neutral: return PocketPalette.textSecondary
        case .ok: return PocketPalette.listening
        case .fail: return PocketPalette.danger
        }
    }

    private var messagesSection: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text("Messages")
                .font(.headline)
                .foregroundStyle(PocketPalette.textPrimary)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            if let line = messages.emptyLine(name: card.target.name) {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier(emptyLineIdentifier)
            }
            // One view per message (the message and its divider in one stack), as the room and the side panel have it,
            // so the lazy list never builds its items to count their views.
            ForEach(messages.listedRows) { row in
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        onOpenMessage(row.sequenceId)
                    } label: {
                        rowLabel(row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows it in the room")
                    .accessibilityIdentifier("pocket.member.message.\(row.sequenceId)")
                    // The list reads its next page as its last row comes into view, unless pages stopped bringing
                    // their messages: then "Load older" reads on.
                    .onAppear {
                        if row.id == messages.rows.last?.id, messages.canLoadMore, messages.phase == .idle,
                           !messages.olderNeedsTap { onLoadMore() }
                    }
                    Divider().padding(.leading, 20)
                }
            }
            switch messages.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .accessibilityLabel("Loading messages")
                    .accessibilityIdentifier("pocket.member.loading")
            case .failed(let text):
                HStack(spacing: 12) {
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry", action: onRetry)
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("pocket.member.retry")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            case .idle:
                if messages.showsLoadOlder {
                    Button(action: onLoadMore) {
                        Label("Load older", systemImage: "arrow.down.circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .accessibilityHint("Reads their older messages")
                    .accessibilityIdentifier("pocket.member.loadOlder")
                }
            }
        }
        .padding(.bottom, 24)
    }

    private var emptyLineIdentifier: String {
        if messages.isBlocked { return "pocket.member.blocked" }
        return messages.isPrivate ? "pocket.member.private" : "pocket.member.empty"
    }

    private func rowLabel(_ row: RoomMemberMessageRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.shownText)
                .font(.body)
                .foregroundStyle(PocketPalette.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            HStack(spacing: 8) {
                if let date = row.date {
                    Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                }
                if row.attachments > 0, !row.text.isEmpty {
                    Label("\(row.attachments)", systemImage: "paperclip")
                        .accessibilityLabel(row.attachments == 1 ? "1 file" : "\(row.attachments) files")
                }
            }
            .font(.caption)
            .foregroundStyle(PocketPalette.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
#endif
