#if canImport(SwiftUI)
import SwiftUI

/// A breakout's card in its parent room: what it is about, who is in it, how much has been said, and whether you
/// can open it. The card never shows breakout messages; they live in the breakout's own room.
struct RoomBreakoutCardView: View {
    let card: RoomBreakoutCard?
    let startedBy: String
    let open: () -> Void

    private var details: String? {
        let parts = [card?.participantsLine, card?.messagesLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(PocketPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Breakout")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PocketPalette.accent)
                        if card?.isLocked == true {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(PocketPalette.textSecondary)
                                .accessibilityLabel("Locked to agents")
                        }
                        if card?.isOpen == false {
                            Text("Closed")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(PocketPalette.textSecondary)
                        }
                        Spacer(minLength: 0)
                        if let unread = card?.unreadCount, unread > 0 {
                            Text(unread > 99 ? "99+ new" : "\(unread) new")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(PocketPalette.accent, in: Capsule())
                        }
                    }
                    Text(card?.title ?? "Breakout")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                        .lineLimit(2)
                    if let details {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(PocketPalette.textSecondary)
                            .lineLimit(1)
                    }
                    Text(card == nil ? "Loading…" : (card?.canRead == false ? "You can't open this breakout." : "Started by \(startedBy)"))
                        .font(.caption2)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                if card?.canRead == true {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(PocketPalette.accent.opacity(0.35), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .disabled(card?.canRead != true)
        .accessibilityIdentifier("pocket.room.breakout")
    }
}

/// A breakout's published outcome: the text, who acknowledged it, who disagreed and who has not answered.
struct RoomBreakoutOutcomeView: View {
    let outcome: RoomBreakoutOutcomeCard
    let breakoutTitle: String?
    let ownHandles: Set<String>
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(breakoutTitle.map { "Outcome · \($0)" } ?? "Breakout outcome", systemImage: "checkmark.seal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.accent)
            ChatMarkdownView(text: outcome.text, ownHandles: ownHandles)
            if !outcome.acknowledgements.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(outcome.acknowledgements) { ack in
                            Label(ack.name, systemImage: Self.symbol(ack.state))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Self.color(ack.state))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Self.color(ack.state).opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
            HStack {
                Text(outcome.acknowledgementSummary)
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                Spacer(minLength: 8)
                Button("Open breakout", action: open)
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("pocket.room.breakout.outcome.open")
            }
            Text("Posted by \(outcome.authorName)")
                .font(.caption2)
                .foregroundStyle(PocketPalette.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PocketPalette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("pocket.room.breakout.outcome")
    }

    private static func symbol(_ state: RoomBreakoutOutcomeCard.Acknowledgement.State) -> String {
        switch state {
        case .ack: return "checkmark.circle.fill"
        case .disagree: return "xmark.circle.fill"
        case .missing: return "ellipsis.circle"
        }
    }

    private static func color(_ state: RoomBreakoutOutcomeCard.Acknowledgement.State) -> Color {
        switch state {
        case .ack: return PocketPalette.accent
        case .disagree: return PocketPalette.danger
        case .missing: return PocketPalette.textSecondary
        }
    }
}

/// Every breakout started from a room, open ones first.
public struct RoomBreakoutsView: View {
    private let cards: [RoomBreakoutCard]
    private let open: (String) -> Void

    public init(cards: [RoomBreakoutCard], open: @escaping (String) -> Void) {
        self.cards = cards
        self.open = open
    }

    public var body: some View {
        List {
            if cards.isEmpty {
                Text("No breakouts yet. A breakout is a side conversation started from this room; its outcome comes back here.")
                    .font(.subheadline)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            ForEach(RoomBreakoutOrdering.sorted(cards)) { card in
                RoomBreakoutCardView(card: card, startedBy: card.participantsLine ?? "this room") {
                    open(card.childSessionId)
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Breakouts")
        .accessibilityIdentifier("pocket.room.breakouts")
    }
}
#endif
