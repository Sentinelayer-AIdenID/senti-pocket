import Foundation
import PocketSyncClient
import PocketUI
import SwiftUI
import UIKit

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

/// What a new chat starts as: one of the phone's own kinds, sent as its `roomType` (none for general, the API's
/// default), or one of the server's ways to start, sent as its `templateId` alone. The server derives the room's type
/// from the template and refuses a `roomType` sent with a `templateId`.
enum RoomStart: Equatable, Sendable {
    case kind(RoomKind)
    case template(id: String)
}

/// Making a room from the phone.
protocol RoomCreating: Sendable {
    /// The new room's id.
    func create(title: String, start: RoomStart) async throws -> String
}

extension RoomCreating {
    /// A room of one of the phone's own kinds.
    func create(title: String, kind: RoomKind) async throws -> String {
        try await create(title: title, start: .kind(kind))
    }
}

extension HTTPRoomMessageSender: RoomCreating {
    func create(title: String, start: RoomStart) async throws -> String {
        try await createRoom(title: title, start: start)
    }
}

/// Making the chat a New agent starts in (sentinelayer-web `NewAgentDialog`): a private general room for four, under an
/// id and key named before it is sent. Sent again with the same ones it makes no second chat: the API replays the key,
/// and keeps one room per id for its owner.
protocol AgentChatCreating: Sendable {
    func createAgentChat(sessionId: String, title: String, idempotencyKey: String) async throws
    /// Names a chat made before the mint named its agent: its owner, who made it, renames it to the agent's name.
    func nameAgentChat(sessionId: String, title: String) async throws
}

extension HTTPRoomMessageSender: AgentChatCreating {
    func createAgentChat(sessionId: String, title: String, idempotencyKey: String) async throws {
        let made = try await createRoom(title: title, start: .kind(.general), maxMembers: NewAgentChat.maxMembers,
                                        sessionId: sessionId, idempotencyKey: idempotencyKey)
        // The agent is sent to the id kept with its start, so a chat made under any other is not the one.
        guard made == sessionId else { throw RoomSendError.rejected }
    }

    func nameAgentChat(sessionId: String, title: String) async throws {
        _ = try await setTitle(sessionId: sessionId, title: title)
    }
}

/// A card under New chat's "Start with": Blank, or one of the server's ways to start.
enum NewChatChoice: Hashable, Identifiable {
    case blank
    case template(RoomTemplate)

    /// The symbol a way to start shows when this phone has none of the name the server sent.
    static let plainSymbol = "bubble.left.and.bubble.right"

    /// The cards, Blank first, then the server's ways to start in its order. Nil where the server offers none (a 404,
    /// no answer yet, or an empty list): New chat then shows the phone's own kinds, as before.
    static func startWith(_ offered: [RoomTemplate]?) -> [NewChatChoice]? {
        guard let offered, !offered.isEmpty else { return nil }
        return [.blank] + offered.map(NewChatChoice.template)
    }

    var id: String {
        switch self {
        case .blank: return "blank"
        case .template(let template): return "template." + template.id
        }
    }

    var name: String {
        switch self {
        case .blank: return "Blank"
        case .template(let template): return template.name
        }
    }

    var detail: String {
        switch self {
        case .blank: return "An empty chat. Bring people and agents in when you need them."
        case .template(let template): return template.summary
        }
    }

    /// The SF Symbol drawn: the server's where this phone has it, else a plain one.
    var symbol: String {
        switch self {
        case .blank:
            return "square.and.pencil"
        case .template(let template):
            guard let name = template.symbol, UIImage(systemName: name) != nil else { return Self.plainSymbol }
            return name
        }
    }

    /// What Senti says it can do there, where the server wrote it.
    var firstMessage: String? {
        if case .template(let template) = self { return template.firstMessage }
        return nil
    }

    /// What the chat is created as. Blank is a general chat with no template, as every chat was before.
    var start: RoomStart {
        switch self {
        case .blank: return .kind(.general)
        case .template(let template): return .template(id: template.id)
        }
    }

    /// The chat's name when none is typed.
    var untitled: String {
        switch self {
        case .blank: return "New chat"
        case .template(let template): return template.name
        }
    }
}

/// New chat. Where the server offers ways to start: "Start with" (Blank first, then the server's), then the name. Where
/// it offers none: what the room is for and its name on one page, as before.
struct NewRoomSheet: View {
    let creator: any RoomCreating
    var onCreated: (_ sessionId: String, _ title: String) -> Void
    var onClose: () -> Void

    /// The cards under Start with, as offered when the sheet opened: a list read later never changes a sheet in use.
    /// Nil shows the phone's own kinds.
    @State private var choices: [NewChatChoice]?
    /// The card picked, whose name step is on screen.
    @State private var path: [NewChatChoice]
    @State private var kind: RoomKind = .general
    @State private var name = ""
    @State private var working = false
    @State private var problem: String?

    /// - Parameters:
    ///   - templates: the server's ways to start; nil or empty where it offers none.
    ///   - picked: the card whose name step shows first (the DEBUG preview's screenshots); it must be one of the cards.
    init(creator: any RoomCreating, templates: [RoomTemplate]? = nil, picked: NewChatChoice? = nil,
         onCreated: @escaping (_ sessionId: String, _ title: String) -> Void, onClose: @escaping () -> Void) {
        self.creator = creator
        self.onCreated = onCreated
        self.onClose = onClose
        let choices = NewChatChoice.startWith(templates)
        _choices = State(initialValue: choices)
        var path: [NewChatChoice] = []
        if let picked, choices?.contains(picked) == true { path = [picked] }
        _path = State(initialValue: path)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let choices {
                    startWith(choices)
                } else {
                    kindForm
                }
            }
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: NewChatChoice.self) { choice in
                nameStep(choice)
            }
        }
        .onChange(of: path) { _ in problem = nil }
    }

    /// Start with: a card for each way to start, Blank first. A card opens its name step.
    private func startWith(_ choices: [NewChatChoice]) -> some View {
        List {
            Section {
                ForEach(choices) { choice in
                    NavigationLink(value: choice) {
                        NewChatChoiceCard(choice: choice)
                    }
                    .accessibilityIdentifier("pocket.newChat.start.\(choice.id)")
                }
            } header: {
                Text("Start with")
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onClose() }
            }
        }
    }

    /// A card's name step: what it is and what Senti opens with, then the chat's name.
    private func nameStep(_ choice: NewChatChoice) -> some View {
        Form {
            Section {
                NewChatChoiceCard(choice: choice)
            }
            if let first = choice.firstMessage {
                Section {
                    Text(first)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Senti opens with")
                }
            }
            Section {
                TextField(choice.untitled, text: $name)
                    .submitLabel(.done)
                    .accessibilityLabel("Chat name")
                    .accessibilityIdentifier("pocket.newRoom.name")
            } header: {
                Text("Name")
            } footer: {
                Text("Private: only you, until you invite people or agents.")
            }
            problemSection
        }
        .navigationTitle("New chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                createButton { await create(start: choice.start, untitled: choice.untitled) }
            }
        }
    }

    /// Where the server offers no ways to start: what the room is for, then its name, on one page.
    private var kindForm: some View {
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
                TextField(kind == .general ? "Chat name" : "\(kind.name) room", text: $name)
                    .submitLabel(.done)
                    .accessibilityIdentifier("pocket.newRoom.name")
            } header: {
                Text("Name")
            } footer: {
                Text("Private: only you, until you invite people or agents.")
            }
            problemSection
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onClose() }
            }
            ToolbarItem(placement: .confirmationAction) {
                createButton { await create(start: .kind(kind), untitled: "\(kind.name) room") }
            }
        }
    }

    private func createButton(_ action: @escaping () async -> Void) -> some View {
        Button(working ? "Creating…" : "Create") { Task { await action() } }
            .disabled(working)
            .accessibilityIdentifier("pocket.newRoom.create")
    }

    @ViewBuilder
    private var problemSection: some View {
        if let problem {
            Section {
                Text(problem).foregroundStyle(.red)
            }
        }
    }

    private func create(start: RoomStart, untitled: String) async {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title = RoomTitle.cleaned(typed.isEmpty ? untitled : typed) else {
            problem = "That name can't be used. Use up to \(RoomTitle.maximumLength) characters, not starting with #, >, * or -."
            return
        }
        working = true
        problem = nil
        defer { working = false }
        do {
            let sessionId = try await creator.create(title: title, start: start)
            onCreated(sessionId, title)
        } catch RoomSendError.reauthenticationRequired {
            problem = "Sign in again to start a chat."
        } catch RoomSendError.notAllowed {
            problem = "This account can't start chats right now."
        } catch RoomSendError.rejected {
            // A refused way to start was most likely taken off the server's list since the sheet opened.
            if case .template = start {
                problem = "That way to start isn't offered right now. Go back and pick another."
            } else {
                problem = "The chat couldn't be started. Check your connection and try again."
            }
        } catch {
            problem = "The chat couldn't be started. Check your connection and try again."
        }
    }
}

/// A card's symbol, its name and what it is for. At the largest text sizes the symbol sits above the words, so they
/// keep the width.
private struct NewChatChoiceCard: View {
    let choice: NewChatChoice
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            Image(systemName: choice.symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(minWidth: 28, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.name)
                    .foregroundStyle(.primary)
                if !choice.detail.isEmpty {
                    Text(choice.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The server's ways to start a chat, read when the app starts and again (at most every few minutes) when New chat
/// opens; a sheet uses what was read when it opened. Kept by the root, not watched: nothing draws from it but New chat
/// as it opens. Nil where the server offers none (a 404 or 403, or an empty list) or has not answered: New chat then
/// shows the phone's own kinds, and nothing about it is an error.
@MainActor
final class RoomTemplatesCenter {
    /// How old a read may be when New chat opens before it is read again.
    static let freshness: TimeInterval = 300

    private(set) var templates: [RoomTemplate]?
    private let client: (any RoomTemplatesServing)?
    private let onReauthenticationRequired: @MainActor () -> Void
    private var readAt: Date?
    /// Which read is the newest: an older one that lands late never puts back what it saw.
    private var readRevision = 0

    /// - Parameter client: nil (a preview) never asks, and New chat shows the phone's own kinds.
    init(client: (any RoomTemplatesServing)?, onReauthenticationRequired: @escaping @MainActor () -> Void = {}) {
        self.client = client
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    /// Reads again unless the last answer is younger than `age` seconds.
    func refresh(ifOlderThan age: TimeInterval) async {
        if let readAt, Date().timeIntervalSince(readAt) < age { return }
        await refresh()
    }

    /// Reads the ways to start. A 404 or 403 means none are offered: any shown before go. A failure that says nothing
    /// either way keeps what was read last.
    func refresh() async {
        guard let client else { return }
        readRevision += 1
        let revision = readRevision
        do {
            let read = try await client.templates()
            guard revision == readRevision else { return }
            readAt = Date()
            templates = read.isEmpty ? nil : read
        } catch RoomTemplatesError.unavailable {
            guard revision == readRevision else { return }
            readAt = Date()
            templates = nil
        } catch RoomTemplatesError.reauthenticationRequired {
            onReauthenticationRequired()
        } catch {
        }
    }
}
