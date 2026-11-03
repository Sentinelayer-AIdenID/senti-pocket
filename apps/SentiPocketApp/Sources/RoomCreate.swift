import Foundation
import PocketUI
import SwiftUI

/// What kind of room to start (the API's `roomType`): Carter, #55287, "we can start creating rooms optimized just for
/// specific things like study together etc and they can choose it from the left menu ... I wanna make it possible for
/// just MBA students or people who don't code to use this".
enum RoomKind: String, CaseIterable, Identifiable, Sendable {
    case general
    case study
    case research
    case conference

    var id: String { rawValue }

    var name: String {
        switch self {
        case .general: return "General"
        case .study: return "Study together"
        case .research: return "Research"
        case .conference: return "Meetings"
        }
    }

    var detail: String {
        switch self {
        case .general: return "Anything: a project, a team, a question. Bring agents when you need them."
        case .study: return "Learn with friends and agents: notes, explanations, practice questions."
        case .research: return "Dig into a topic: sources, findings, and a written answer you can check."
        case .conference: return "Calls and meetings: an agenda, live notes, and the follow-ups."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "bubble.left.and.bubble.right"
        case .study: return "book"
        case .research: return "magnifyingglass"
        case .conference: return "person.3"
        }
    }
}

/// Making a room from the phone.
protocol RoomCreating: Sendable {
    /// The new room's id.
    func create(title: String, kind: RoomKind) async throws -> String
}

extension HTTPRoomMessageSender: RoomCreating {
    func create(title: String, kind: RoomKind) async throws -> String {
        try await createRoom(title: title, roomType: kind.rawValue)
    }
}

/// The New room sheet: what the room is for, then its name.
struct NewRoomSheet: View {
    let creator: any RoomCreating
    var onCreated: (_ sessionId: String, _ title: String) -> Void
    var onClose: () -> Void

    @State private var kind: RoomKind = .general
    @State private var name = ""
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(RoomKind.allCases) { option in
                        Button {
                            kind = option
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: option.symbol)
                                    .frame(width: 24)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.name).foregroundStyle(.primary)
                                    Text(option.detail).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if option == kind {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityIdentifier("pocket.newRoom.kind.\(option.rawValue)")
                        .accessibilityAddTraits(option == kind ? .isSelected : [])
                    }
                } header: {
                    Text("What is it for?")
                }
                Section {
                    TextField(kind == .general ? "Room name" : "\(kind.name) room", text: $name)
                        .submitLabel(.done)
                        .accessibilityIdentifier("pocket.newRoom.name")
                } header: {
                    Text("Name")
                } footer: {
                    Text("Private: only you, until you invite people or agents.")
                }
                if let problem {
                    Section {
                        Text(problem).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onClose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "Creating…" : "Create") { Task { await create() } }
                        .disabled(working)
                        .accessibilityIdentifier("pocket.newRoom.create")
                }
            }
        }
    }

    private func create() async {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title = RoomTitle.cleaned(typed.isEmpty ? "\(kind.name) room" : typed) else {
            problem = "That name can't be used. Use up to \(RoomTitle.maximumLength) characters, not starting with #, >, * or -."
            return
        }
        working = true
        problem = nil
        defer { working = false }
        do {
            let sessionId = try await creator.create(title: title, kind: kind)
            onCreated(sessionId, title)
        } catch RoomSendError.reauthenticationRequired {
            problem = "Sign in again to make a room."
        } catch RoomSendError.notAllowed {
            problem = "This account can't make rooms right now."
        } catch {
            problem = "The room couldn't be made. Check your connection and try again."
        }
    }
}
