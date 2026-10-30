#if canImport(SwiftUI)
import SwiftUI

/// Search the room's messages, then jump to one. Opened from the room title's menu.
public struct RoomSearchView: View {
    private let state: RoomSearchPresentationState
    private let send: (RoomSearchIntent) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    public init(state: RoomSearchPresentationState, send: @escaping (RoomSearchIntent) -> Void) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        NavigationStack {
            List {
                if state.isSearching {
                    HStack {
                        Spacer()
                        ProgressView("Searching")
                        Spacer()
                    }
                }
                if let message = state.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .accessibilityIdentifier("pocket.search.message")
                }
                ForEach(state.rows) { row in
                    Button {
                        send(.open(sequenceId: row.sequenceId))
                        dismiss()
                    } label: {
                        RoomSearchRowView(row: row, query: state.query)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pocket.search.result.\(row.sequenceId)")
                }
                if state.hasMore {
                    Button {
                        send(.loadMore)
                    } label: {
                        if state.isLoadingMore {
                            ProgressView()
                        } else {
                            Text("Older matches")
                        }
                    }
                    .disabled(state.isLoadingMore)
                    .accessibilityIdentifier("pocket.search.more")
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search messages")
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .searchable(text: $text, prompt: "Words, names or agents")
            .onSubmit(of: .search) { send(.submit(text)) }
            // Matches come as you type, once you pause (Carter: like lifting your hand for a second).
            .onChange(of: text) { send(.typed($0)) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct RoomSearchRowView: View {
    let row: RoomSearchRow
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let author = row.author {
                    Text(author)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(row.isHuman ? PocketPalette.listening : PocketPalette.textPrimary)
                }
                if let date = row.date {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                Spacer(minLength: 0)
                Text("#\(row.sequenceId)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            snippet
                .font(.footnote)
                .foregroundStyle(PocketPalette.textPrimary)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// The match is marked, as on the web's result list.
    private var snippet: Text {
        guard let parts = RoomSearchPresentationState.highlight(row.snippet, query: query) else { return Text(row.snippet) }
        return Text(parts.before) + Text(parts.match).bold().foregroundColor(PocketPalette.accent) + Text(parts.after)
    }
}
#endif
