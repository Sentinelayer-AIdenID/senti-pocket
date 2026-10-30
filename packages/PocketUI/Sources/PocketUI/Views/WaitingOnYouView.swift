#if canImport(SwiftUI)
import SwiftUI

/// The list of what waits on your decision: each ask with its room, who asked and how long ago, its choices as
/// buttons, and words where it takes them. Tapping the title opens the ticket in its room.
public struct WaitingOnYouView: View {
    private let state: WaitingOnYouState
    private let send: (WaitingOnYouIntent) -> Void
    private let onDone: () -> Void
    @State private var writing: String?
    @State private var words = ""

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
                            Button("Custom") { startWriting(row.id) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .disabled(isSending)
            }

            if writing == row.id || (row.options.isEmpty && writing == nil) {
                HStack(spacing: 8) {
                    TextField(row.options.isEmpty ? "Your answer" : "Say what you want instead", text: binding(for: row.id),
                              axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
                        send(row.options.isEmpty
                             ? .answer(id: row.id, choice: text, detail: "")
                             : .answer(id: row.id, choice: "Custom", detail: text))
                        words = ""
                        writing = nil
                    }
                    .disabled(isSending || words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (writing != nil && writing != row.id))
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
        if writing != id { words = "" }
        writing = id
    }

    /// One text box at a time: typing into an open question's box makes it the one being written.
    private func binding(for id: String) -> Binding<String> {
        Binding(get: { writing == nil || writing == id ? words : "" },
                set: { words = $0; writing = id })
    }
}
#endif
