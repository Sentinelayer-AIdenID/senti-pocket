#if canImport(SwiftUI)
import SwiftUI

/// The web's ticket limits (sentinelayer-api `SessionTicketCreatePayload` / `SessionTicketUpdatePayload`).
enum RoomTicketLimits {
    static let title = 200
    static let body = 8_000
    static let assignee = 64
    /// The picker tag for typing any other id, as the web's "Another id…".
    static let otherTag = "__other__"
    static let unassignTag = "__unassign__"
}

/// Filing a ticket in this room (web "New ticket": title, description, assignee). The sheet closes once the room has
/// the ticket; a failure stays on screen with the fields kept, and filing the same fields again is never a duplicate.
struct RoomTicketFileSheet: View {
    let status: String?
    let filedCount: Int
    let assignChoices: [RoomTicketAssignChoice]
    let send: (RoomTicketsIntent) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var assignee = ""
    @State private var otherId = ""
    @State private var openedAtCount: Int?
    @State private var submitted = false

    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var target: String? {
        let id = assignee == RoomTicketLimits.otherTag ? otherId.trimmingCharacters(in: .whitespaces) : assignee
        return id.isEmpty ? nil : id
    }
    private var canFile: Bool {
        !cleanTitle.isEmpty && cleanTitle.count <= RoomTicketLimits.title && details.count <= RoomTicketLimits.body
            && (target?.count ?? 0) <= RoomTicketLimits.assignee
            && !(assignee == RoomTicketLimits.otherTag && target == nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What needs doing", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .accessibilityIdentifier("pocket.ticket.file.title")
                } header: {
                    Text("Title")
                } footer: {
                    if cleanTitle.count > RoomTicketLimits.title {
                        Text("\(cleanTitle.count) of \(RoomTicketLimits.title) characters.")
                            .foregroundStyle(PocketPalette.warning)
                    }
                }
                Section {
                    TextField("Details, in Markdown", text: $details, axis: .vertical)
                        .lineLimit(4...12)
                        .accessibilityIdentifier("pocket.ticket.file.body")
                } header: {
                    Text("Description")
                } footer: {
                    if details.count > RoomTicketLimits.body {
                        Text("\(details.count) of \(RoomTicketLimits.body) characters.")
                            .foregroundStyle(PocketPalette.warning)
                    }
                }
                Section("Assign to") {
                    Picker("Assign to", selection: $assignee) {
                        Text("Nobody yet").tag("")
                        ForEach(assignChoices) { choice in
                            Text(choice.label).tag(choice.id)
                        }
                        Text("Another id…").tag(RoomTicketLimits.otherTag)
                    }
                    .accessibilityIdentifier("pocket.ticket.file.assignee")
                    if assignee == RoomTicketLimits.otherTag {
                        TextField("An agent id, or a person's user id", text: $otherId)
                            .ticketIdEntry()
                    }
                }
                if submitted, let status {
                    Section {
                        Text(status)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(PocketPalette.accent)
                            .accessibilityIdentifier("pocket.ticket.file.status")
                    }
                }
            }
            .navigationTitle("New ticket")
            .ticketSheetInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("File") {
                        submitted = true
                        send(.fileTicket(title: cleanTitle, body: details, assignee: target))
                    }
                    .disabled(!canFile)
                    .accessibilityIdentifier("pocket.ticket.file.submit")
                }
            }
            .onAppear { openedAtCount = filedCount }
            .onChange(of: filedCount) { count in
                if let openedAtCount, count > openedAtCount { dismiss() }
            }
        }
    }
}

/// Assign, reassign or unassign (web "Assign to": you, the room's agents, or any other id). The result shows on the
/// ticket, and an agent assignee is @-mentioned in the room so its listener wakes.
struct RoomTicketAssignSheet: View {
    let row: RoomTicketRow
    let choices: [RoomTicketAssignChoice]
    let viewerId: String?
    let assign: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection = ""
    @State private var otherId = ""

    private var target: String? {
        switch selection {
        case RoomTicketLimits.unassignTag: return nil
        case RoomTicketLimits.otherTag:
            let id = otherId.trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : id
        default: return selection.isEmpty ? nil : selection
        }
    }

    private var ready: Bool {
        switch selection {
        case "": return false
        case RoomTicketLimits.unassignTag: return row.assignee != nil
        case RoomTicketLimits.otherTag: return target != nil && (target?.count ?? 0) <= RoomTicketLimits.assignee
        default: return selection.lowercased() != row.assignee?.lowercased()
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(row.assignee == nil ? "Assign to" : "Reassign to", selection: $selection) {
                        if row.assignee == nil { Text("Choose…").tag("") }
                        if let current = row.assignee, !choices.contains(where: { $0.id.lowercased() == current.lowercased() }) {
                            Text("\(RoomTicketRow.actorLabel(current, viewerId: viewerId)) (assigned)").tag(current)
                        }
                        ForEach(choices) { choice in
                            Text(choice.label).tag(choice.id)
                        }
                        Text("Another id…").tag(RoomTicketLimits.otherTag)
                        if row.assignee != nil { Text("Unassign").tag(RoomTicketLimits.unassignTag) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("pocket.ticket.assign.picker")
                    if selection == RoomTicketLimits.otherTag {
                        TextField("An agent id, or a person's user id", text: $otherId)
                            .ticketIdEntry()
                    }
                } footer: {
                    Text("Everyone sees the assignment in the room, and an agent is @-mentioned so it wakes.")
                }
            }
            .navigationTitle(row.assignee == nil ? "Assign" : "Reassign")
            .ticketSheetInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selection == RoomTicketLimits.unassignTag ? "Unassign" : (row.assignee == nil ? "Assign" : "Reassign")) {
                        assign(target)
                        dismiss()
                    }
                    .disabled(!ready)
                    .accessibilityIdentifier("pocket.ticket.assign.submit")
                }
            }
            .onAppear { selection = row.assignee ?? "" }
        }
    }
}

/// Editing a ticket's title and description, the raw Markdown in. Only the fields you changed are sent, with the
/// version you edited, so a change made meanwhile is refused and refreshed rather than overwritten.
struct RoomTicketEditSheet: View {
    let row: RoomTicketRow
    let save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""

    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { cleanTitle != row.title || details != row.body }
    private var valid: Bool {
        !cleanTitle.isEmpty && cleanTitle.count <= RoomTicketLimits.title && details.count <= RoomTicketLimits.body
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .accessibilityIdentifier("pocket.ticket.edit.title")
                }
                Section {
                    TextField("Details, in Markdown", text: $details, axis: .vertical)
                        .lineLimit(6...20)
                        .font(.body.monospaced())
                        .accessibilityIdentifier("pocket.ticket.edit.body")
                } header: {
                    Text("Description")
                } footer: {
                    if details.count > RoomTicketLimits.body {
                        Text("\(details.count) of \(RoomTicketLimits.body) characters.")
                            .foregroundStyle(PocketPalette.warning)
                    }
                }
            }
            .navigationTitle("Edit ticket")
            .ticketSheetInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(cleanTitle, details)
                        dismiss()
                    }
                    .disabled(!changed || !valid)
                    .accessibilityIdentifier("pocket.ticket.edit.save")
                }
            }
            .onAppear {
                title = row.title
                details = row.body
            }
        }
    }
}
private extension View {
    @ViewBuilder
    func ticketSheetInlineTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// An id is typed as it is: no capitals, no corrections.
    @ViewBuilder
    func ticketIdEntry() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
#endif
