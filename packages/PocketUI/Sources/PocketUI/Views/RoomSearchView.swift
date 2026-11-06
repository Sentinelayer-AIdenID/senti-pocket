#if canImport(SwiftUI)
import SwiftUI

/// Search everything the room holds, then open it (Carter, #55006): its messages, its people (and what each wrote),
/// and the tickets, pull requests, files, checkpoints, links and code it shared. Tabs narrow it to one kind.
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
                scopeTabs
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                if let from = state.from {
                    fromChip(from)
                        .listRowSeparator(.hidden)
                }
                if !state.people.isEmpty {
                    Section {
                        ForEach(state.scope == .all ? Array(state.people.prefix(3)) : state.people) { person in
                            Button {
                                send(.from(person))
                            } label: {
                                personRow(person)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows what they wrote")
                            .accessibilityIdentifier("pocket.search.person.\(person.id)")
                        }
                    } header: {
                        if state.scope == .all { Text("People") }
                    }
                }
                if state.scope.searchesMessages {
                    messagesSection
                }
                artifactSections
                if state.isReadingArtifacts, state.scope != .messages, state.scope != .people {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Reading the room's tickets and files…")
                            .font(.footnote)
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search")
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .searchable(text: $text, prompt: "Words, names, tickets or files")
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

    /// All, Messages, People, then each kind of shared thing, as pills that scroll sideways.
    private var scopeTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RoomSearchScope.tabs, id: \.self) { scope in
                    let selected = state.scope == scope
                    Button {
                        send(.scope(scope))
                    } label: {
                        Text(scope.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(selected ? Color.white : PocketPalette.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selected ? PocketPalette.accent : PocketPalette.inset, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("pocket.search.scope.\(scope.title)")
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func fromChip(_ person: RoomSearchPerson) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(PocketPalette.accent)
            Text("From \(person.name)")
                .font(.footnote.weight(.semibold))
            Spacer(minLength: 4)
            Button {
                send(.from(nil))
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Everyone, not only \(person.name)")
        }
        .accessibilityIdentifier("pocket.search.from")
    }

    private func personRow(_ person: RoomSearchPerson) -> some View {
        HStack(spacing: 10) {
            RoomAvatar(name: person.name, isHuman: person.isHuman)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PocketPalette.textPrimary)
                Text(person.isHuman ? "Person · see what they wrote" : "Agent · see what it wrote")
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.textSecondary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var messagesSection: some View {
        Section {
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
        } header: {
            if state.scope == .all, !state.people.isEmpty || !state.artifacts.isEmpty { Text("Messages") }
        }
    }

    /// The shared things that match, a section per kind; under All, the first three of each.
    @ViewBuilder
    private var artifactSections: some View {
        ForEach(RoomArtifact.Kind.allCases, id: \.self) { kind in
            let matches = state.artifacts.filter { $0.kind == kind }
            if !matches.isEmpty {
                Section(kind.title) {
                    ForEach(state.scope == .all ? Array(matches.prefix(3)) : matches) { artifact in
                        Button {
                            send(.openArtifact(artifact))
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: kind.symbol)
                                    .foregroundStyle(PocketPalette.accent)
                                    .frame(width: 22)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(artifact.title)
                                        .font(.subheadline)
                                        .foregroundStyle(PocketPalette.textPrimary)
                                        .lineLimit(2)
                                    if let detail = artifact.detail {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(PocketPalette.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("pocket.search.artifact.\(artifact.id)")
                    }
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
