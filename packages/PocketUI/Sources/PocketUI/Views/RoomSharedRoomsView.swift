#if canImport(SwiftUI)
import SwiftUI

/// See all, from a card's "Rooms you share": every room you share with them, newest first by their latest activity, a
/// page at a time as the list scrolls (ticket ab3c079b).
public struct RoomSharedRoomsView: View {
    private let state: RoomSharedRoomsState
    private let onLoadMore: () -> Void
    private let onRetry: () -> Void
    private let onClose: () -> Void

    public init(state: RoomSharedRoomsState, onLoadMore: @escaping () -> Void, onRetry: @escaping () -> Void,
                onClose: @escaping () -> Void) {
        self.state = state
        self.onLoadMore = onLoadMore
        self.onRetry = onRetry
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(state.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(row.title, systemImage: "bubble.left.and.bubble.right")
                            .font(.body)
                            .foregroundStyle(PocketPalette.textPrimary)
                            .lineLimit(2)
                        if let date = row.lastActive {
                            Text("Last active \(date, style: .relative) ago")
                                .font(.caption)
                                .foregroundStyle(PocketPalette.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pocket.sharedRooms.row")
                }
                if case .failed(let text) = state.phase {
                    HStack(spacing: 8) {
                        Text(text)
                            .font(.footnote)
                            .foregroundStyle(PocketPalette.textSecondary)
                        Button("Retry", action: onRetry)
                            .font(.footnote.weight(.semibold))
                            .accessibilityIdentifier("pocket.sharedRooms.retry")
                    }
                } else if state.canLoadMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .onAppear(perform: onLoadMore)
                        .accessibilityLabel("Loading more rooms")
                }
            }
            .listStyle(.plain)
            .navigationTitle(state.title)
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("pocket.sharedRooms.done")
                }
            }
        }
        .accessibilityIdentifier("pocket.sharedRooms")
    }
}

#endif
