#if canImport(SwiftUI)
import SwiftUI

/// The list of what waits on your decision: each ask with its room, who asked and how long ago, its choices as
/// buttons, and words where it takes them. Tapping the title opens the ticket in its room.
public struct WaitingOnYouView: View {
    private let state: WaitingOnYouState
    private let send: (WaitingOnYouIntent) -> Void
    private let onDone: () -> Void
    /// Words typed per ask, kept until the ask leaves the list (so a failed send keeps them for the retry).
    @State private var drafts: [String: String] = [:]
    /// Asks whose "Custom" box is open.
    @State private var customOpen: Set<String> = []

    public init(state: WaitingOnYouState, send: @escaping (WaitingOnYouIntent) -> Void, onDone: @escaping () -> Void) {
        self.state = state
        self.send = send
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack {
            List {
                if let notice = state.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.warning)
                        .accessibilityIdentifier("pocket.waiting.notice")
                }
                if state.rows.isEmpty {
                    Text(state.isLoading ? "Looking…" : "Nothing is waiting on you.")
                        .foregroundStyle(PocketPalette.textSecondary)
                        .accessibilityIdentifier("pocket.waiting.empty")
                }
                ForEach(state.rows) { row in
                    rowView(row)
                        .listRowBackground(PocketPalette.raised)
                }
            }
            .scrollContentBackground(.hidden)
            .pocketCanvas()
            .refreshable { send(.refresh) }
            // Words typed for an answer stay until it has gone (its ask leaves the list), so a failed send keeps
            // them for the retry (warden, #270).
            .onChange(of: state.rows.map(\.askKey)) { keys in
                drafts = drafts.filter { keys.contains($0.key) }
                customOpen = customOpen.filter { keys.contains($0) }
            }
            .navigationTitle(state.total > 0 ? "Waiting on you · \(state.total)" : "Waiting on you")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }

    private func rowView(_ row: WaitingOnYouRow) -> some View {
        let isSending = state.sending.contains(row.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(row.roomTitle.isEmpty ? "Room" : row.roomTitle)
                    .lineLimit(1)
                if let askedBy = row.askedBy {
                    Text("· \(askedBy)").lineLimit(1)
                }
                Spacer(minLength: 4)
                if let askedAt = row.askedAt {
                    Text(PocketSidePanel.compactAge(of: askedAt))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(PocketPalette.textSecondary)

            Button { send(.open(id: row.id)) } label: {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PocketPalette.textPrimary)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the ticket in its room")

            if !row.question.isEmpty {
                Text(row.question)
                    .font(.subheadline)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !row.options.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(row.options, id: \.self) { option in
                            Button(option) { send(.answer(id: row.id, choice: option, detail: "")) }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("pocket.waiting.option.\(row.id).\(option)")
                        }
                        if row.custom {
                            Button("Custom") { startWriting(row.askKey) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .disabled(isSending)
            }

            if row.options.isEmpty || customOpen.contains(row.askKey) {
                HStack(spacing: 8) {
                    TextField(row.options.isEmpty ? "Your answer" : "Say what you want instead", text: binding(for: row.askKey),
                              axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        let text = (drafts[row.askKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        send(row.options.isEmpty
                             ? .answer(id: row.id, choice: text, detail: "")
                             : .answer(id: row.id, choice: "Custom", detail: text))
                    }
                    .disabled(isSending || (drafts[row.askKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if isSending {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.waiting.row.\(row.id)")
    }

    private func startWriting(_ id: String) {
        customOpen.insert(id)
    }

    /// Each ask keeps its own words, so writing one never locks or fills another (warden, #270).
    private func binding(for id: String) -> Binding<String> {
        Binding(get: { drafts[id] ?? "" }, set: { drafts[id] = $0 })
    }
}
#endif
