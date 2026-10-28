#if canImport(SwiftUI)
import SwiftUI

public enum RoomTicketsIntent: Equatable, Sendable {
    case setShowsArchived(Bool)
    case search(String)
    case refresh
    case openSourceMessage(sequenceId: Int64)
}

/// The room's Tickets tab: Active / Archived (N), search across all tickets, ranked by impact. Tapping a ticket
/// opens its full Markdown body.
public struct RoomTicketsView: View {
    private let state: RoomTicketsPresentationState
    private let send: (RoomTicketsIntent) -> Void
    @State private var query = ""

    public init(state: RoomTicketsPresentationState, send: @escaping (RoomTicketsIntent) -> Void) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        List {
            Section {
                Picker("Tickets", selection: Binding(
                    get: { state.showsArchived },
                    set: { send(.setShowsArchived($0)) }
                )) {
                    Text("Active (\(state.activeCount))").tag(false)
                    Text("Archived (\(state.archivedCount))").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(!state.query.isEmpty)
                .accessibilityIdentifier("pocket.tickets.archivedToggle")
            }
            .listRowBackground(Color.clear)

            if let failure = state.failure {
                Section {
                    Text(failure.detail).foregroundStyle(PocketPalette.warning)
                }
            } else if state.isStale {
                Section {
                    Label("Showing the last tickets loaded; updates will resume.", systemImage: "arrow.clockwise")
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
            }

            if state.rows.isEmpty && !state.isLoading && state.failure == nil {
                Text(state.query.isEmpty ? (state.showsArchived ? "No archived tickets." : "No open tickets.") : "No tickets match.")
                    .foregroundStyle(PocketPalette.textSecondary)
            }

            ForEach(state.rows) { row in
                NavigationLink {
                    RoomTicketDetailView(row: row, send: send)
                } label: {
                    RoomTicketRowView(row: row)
                }
                .accessibilityIdentifier("pocket.tickets.row.\(row.id)")
            }
        }
        .overlay {
            if state.isLoading && state.rows.isEmpty {
                ProgressView("Loading tickets")
            }
        }
        .searchable(text: $query, prompt: "Search tickets")
        .onChange(of: query) { send(.search($0)) }
        .refreshable { send(.refresh) }
        .navigationTitle("Tickets")
        .accessibilityIdentifier("pocket.tickets.screen")
    }
}

private struct RoomTicketRowView: View {
    let row: RoomTicketRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let label = row.priorityLabel {
                    Text(label)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoomTicketPalette.priority(row.priority).opacity(0.18), in: Capsule())
                        .foregroundStyle(RoomTicketPalette.priority(row.priority))
                }
                Text(row.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Text(row.statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RoomTicketPalette.status(row.status))
                if let assignee = row.assignee {
                    Label(RoomTicketRow.displayName(assignee), systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                Spacer(minLength: 0)
                if let date = row.updatedDate {
                    Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// One ticket: its title, status, people and dates, and the full body rendered as Markdown.
public struct RoomTicketDetailView: View {
    let row: RoomTicketRow
    let send: (RoomTicketsIntent) -> Void

    public init(row: RoomTicketRow, send: @escaping (RoomTicketsIntent) -> Void) {
        self.row = row
        self.send = send
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(row.title)
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let label = row.priorityLabel {
                        Text(label)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoomTicketPalette.priority(row.priority).opacity(0.18), in: Capsule())
                            .foregroundStyle(RoomTicketPalette.priority(row.priority))
                    }
                    Text(row.statusLabel)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoomTicketPalette.status(row.status).opacity(0.15), in: Capsule())
                        .foregroundStyle(RoomTicketPalette.status(row.status))
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let assignee = row.assignee {
                        Label("Assigned to \(RoomTicketRow.displayName(assignee))", systemImage: "person")
                    }
                    if !row.createdBy.isEmpty {
                        Label("Requested by \(RoomTicketRow.displayName(row.createdBy))", systemImage: "person.wave.2")
                    }
                    if let created = row.createdDate {
                        Label {
                            Text("Filed ") + Text(created, format: .relative(presentation: .named, unitsStyle: .wide))
                        } icon: {
                            Image(systemName: "clock")
                        }
                    }
                }
                .font(.footnote)
                .foregroundStyle(PocketPalette.textSecondary)

                if let sequence = row.sourceSequenceId {
                    Button {
                        send(.openSourceMessage(sequenceId: sequence))
                    } label: {
                        Label("From message #\(sequence)", systemImage: "text.bubble")
                            .font(.footnote.weight(.semibold))
                    }
                }

                Divider()
                ChatMarkdownView(text: row.body.isEmpty ? "_No description._" : row.body)
                    .font(.body)
                Text("Ticket \(row.id)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(PocketPalette.textSecondary)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(row.priorityLabel ?? "Ticket")
        .accessibilityIdentifier("pocket.tickets.detail")
    }
}

enum RoomTicketPalette {
    static func priority(_ priority: Int?) -> Color {
        switch priority {
        case 0: return PocketPalette.danger
        case 1: return PocketPalette.warning
        case 2: return PocketPalette.accent
        default: return PocketPalette.textSecondary
        }
    }

    static func status(_ status: String) -> Color {
        switch status {
        case "done": return PocketPalette.textSecondary
        case "blocked": return PocketPalette.danger
        case "in_review": return PocketPalette.recommendation
        case "working", "accepted": return PocketPalette.listening
        default: return PocketPalette.accent
        }
    }
}
#endif
