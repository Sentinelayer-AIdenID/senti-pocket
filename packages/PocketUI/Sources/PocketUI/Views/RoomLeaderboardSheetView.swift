#if canImport(SwiftUI)
import SwiftUI

/// The room's leaderboard as a ranked list in a sheet: who is helping most, as the pinned board says, following its
/// edits while it is open. A row that moved is briefly highlighted, and the rows reorder with an animation unless
/// Reduce Motion is on. How the board works sits folded under the list, with a link to the message itself. When no row
/// of the board can be read: "Board unavailable", and the message, never its raw text.
struct RoomLeaderboardSheetView: View {
    let sheet: RoomChatLeaderboardSheet
    let onOpenMessage: () -> Void
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The rows that moved in the last update, highlighted for a moment.
    @State private var moved: Set<String> = []
    /// The board as last shown, to see which rows an update moved.
    @State private var shown: RoomLeaderboard?
    @State private var showsHowItWorks = false

    // Written out: the private state would make the memberwise one private to this file.
    init(sheet: RoomChatLeaderboardSheet, onOpenMessage: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.sheet = sheet
        self.onOpenMessage = onOpenMessage
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Leaderboard")
                .navigationBarTitleDisplayModeInlineIfAvailable()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                            .accessibilityIdentifier("pocket.room.leaderboard.done")
                    }
                }
        }
        .onAppear { shown = board }
        // However the sheet goes (Done, a swipe, the board unpinned), the room knows it is closed.
        .onDisappear(perform: onDone)
        .onChange(of: board) { highlightMoves(to: $0) }
        .accessibilityIdentifier("pocket.room.leaderboard.sheet")
    }

    private var board: RoomLeaderboard? {
        if case .board(let board) = sheet.content { return board }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        switch sheet.content {
        case .loading:
            ProgressView("Reading the board")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            VStack(spacing: 12) {
                Image(systemName: "trophy")
                    .font(.largeTitle)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .accessibilityHidden(true)
                Text("Board unavailable")
                    .font(.headline)
                    .foregroundStyle(PocketPalette.textPrimary)
                Text("The board's message can't be read as a list right now.")
                    .font(.subheadline)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .multilineTextAlignment(.center)
                postedBy
                openMessageButton
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("pocket.room.leaderboard.unavailable")
        case .board(let board):
            List {
                Section {
                    ForEach(board.rows) { row in
                        RoomLeaderboardRowView(row: row, isMoved: moved.contains(row.id))
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: board.header)
                            .accessibilityIdentifier("pocket.room.leaderboard.header")
                        postedBy
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 14) {
                        if let howItWorks = board.howItWorks {
                            DisclosureGroup(isExpanded: $showsHowItWorks) {
                                Text(verbatim: howItWorks)
                                    .font(.footnote)
                                    .foregroundStyle(PocketPalette.textSecondary)
                                    .padding(.top, 4)
                            } label: {
                                Text("How it works").font(.footnote.weight(.semibold))
                            }
                            .accessibilityIdentifier("pocket.room.leaderboard.howItWorks")
                        }
                        openMessageButton
                    }
                    .padding(.top, 8)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: board.rows.map(\.id))
        }
    }

    /// Who posted the board, by the id the room shows.
    @ViewBuilder
    private var postedBy: some View {
        if !sheet.postedBy.isEmpty {
            Text(verbatim: sheet.postedBy)
                .font(.caption)
                .foregroundStyle(PocketPalette.textSecondary)
                .textCase(nil)
                .accessibilityIdentifier("pocket.room.leaderboard.postedBy")
        }
    }

    private var openMessageButton: some View {
        Button(action: onOpenMessage) {
            Label("Open message", systemImage: "text.bubble")
                .font(.footnote.weight(.semibold))
        }
        .accessibilityHint("Shows the board's message in the room")
        .accessibilityIdentifier("pocket.room.leaderboard.openMessage")
    }

    /// Rows whose rank changed (or that are new) since the board last shown are highlighted for a moment.
    private func highlightMoves(to board: RoomLeaderboard?) {
        defer { shown = board }
        guard let before = shown, let board else { return }
        let ranks = Dictionary(before.rows.map { ($0.id, $0.rank) }, uniquingKeysWith: { first, _ in first })
        let changed = Set(board.rows.filter { ranks[$0.id] != $0.rank }.map(\.id))
        guard !changed.isEmpty else { return }
        moved = changed
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if moved == changed { moved = [] }
        }
    }
}

/// One ranked author: the rank (a medal for the first three), the id, a person or team chip, how many helpful
/// messages, the points and the movement badge. VoiceOver reads it as one line.
private struct RoomLeaderboardRowView: View {
    let row: RoomLeaderboard.Row
    let isMoved: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility text sizes the row stacks, so nothing is squeezed or cut.
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Text(verbatim: row.rankText)
                .font(row.rank <= 3 ? .title3 : .body.monospacedDigit().weight(.semibold))
                .foregroundStyle(PocketPalette.textSecondary)
                .frame(minWidth: 34, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: row.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PocketPalette.textPrimary)
                    .lineLimit(stacked ? 3 : 1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let chip = row.chip {
                        Text(verbatim: chip)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(row.isPerson ? PocketPalette.listening : PocketPalette.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(PocketPalette.inset, in: Capsule())
                    }
                    Text(verbatim: row.helpfulText)
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
            }
            if !stacked { Spacer(minLength: 6) }
            VStack(alignment: stacked ? .leading : .trailing, spacing: 3) {
                Text(verbatim: row.pointsText)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PocketPalette.textPrimary)
                if let move = row.moveText {
                    Text(verbatim: move)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(moveColor)
                }
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isMoved ? PocketPalette.warning.opacity(0.18) : nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityIdentifier("pocket.room.leaderboard.row.\(row.name)")
    }

    private var moveColor: Color {
        switch row.move {
        case .down: return PocketPalette.danger
        case .up: return PocketPalette.verified
        default: return PocketPalette.listening
        }
    }
}
#endif
