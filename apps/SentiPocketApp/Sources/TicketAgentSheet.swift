import Foundation
import PocketSyncClient
import PocketUI
import SwiftUI

/// Starts of an agent whose outcome is not known yet, kept on the phone per account, room and ticket (or the room's
/// New agent) with the key the mint knows them by. Checking again sends the same start under the same key, so it can
/// only return that agent, even after the sheet closed, the app was killed, or the person signed out and in again.
///
/// The mint keeps a key for 24 hours from its first use, and a replay does not extend that. So a start keeps the time it
/// was first kept (never refreshed by a check), is sent again only within `checkHorizon` of it (an hour inside the
/// mint's day, for clock skew), and is forgotten after `maxAge`. One start per ticket, and one New agent start per room:
/// while one is unresolved, a new start for it takes it up instead of replacing it (#298 review).
///
/// A New agent started in a new chat keeps that chat before the chat is made (sentinelayer-web `keepMintStart` keeps its
/// `room`): its id and the create's key go unchanged with every try, and the API keeps one room per id for its owner, so
/// the chat is made at most once, even across a kill. It stays kept for the next start until an agent starts. New chats
/// are kept in a file of their own, so the starts' file stays as the release before New agent reads it.
struct MintStartLedger: Sendable {
    /// The chat a New agent goes to when it starts in a new chat.
    struct NewChat: Codable, Equatable, Sendable {
        let sessionId: String
        let title: String
        /// The create's `Idempotency-Key`, the same on every try.
        let createKey: String
        /// The API answered that it is made.
        var made: Bool
    }

    struct Entry: Codable, Equatable {
        let request: MintUpRequest
        /// When this start was first kept; never moved by a check.
        let createdAt: Date
    }

    /// A New agent's new chat, with when a start was last kept with it: it outlives each of its starts.
    private struct KeptChat: Codable {
        let chat: NewChat
        let keptAt: Date
    }

    enum Refusal: Error, Equatable {
        /// Another start for this ticket (or the room's New agent) is still unresolved, or another new chat is kept.
        case anotherStartPending
    }

    static let maxAge: TimeInterval = 24 * 60 * 60
    static let checkHorizon: TimeInterval = 23 * 60 * 60

    let url: URL
    /// New agents' new chats, beside the starts.
    var chatsURL: URL { url.deletingPathExtension().appendingPathExtension("new-chats.json") }
    private let now: @Sendable () -> Date

    init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    static var standard: MintStartLedger? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        return MintStartLedger(url: base.appendingPathComponent("mint-starts.json"))
    }

    /// `ticketId` nil: the room's New agent.
    func entry(account: String, sessionId: String, ticketId: String?) -> Entry? {
        load()[Self.key(account, sessionId, ticketId)]
    }

    func pending(account: String, sessionId: String, ticketId: String?) -> MintUpRequest? {
        entry(account: account, sessionId: sessionId, ticketId: ticketId)?.request
    }

    /// The room's New agent's new chat, made or about to be.
    func chat(account: String, sessionId: String) -> NewChat? {
        loadChats()[Self.key(account, sessionId, nil)]?.chat
    }

    /// Whether the start may still be sent again: the mint still knows its key.
    func isCheckable(_ entry: Entry) -> Bool {
        now().timeIntervalSince(entry.createdAt) < Self.checkHorizon
    }

    /// Writes the start to the phone before it is sent, and throws if it could not: a start that is not kept is not
    /// sent, since after a kill its key would be lost. The same start kept again keeps its first time; a different start
    /// for a ticket with one still unresolved is refused. A start in a new chat writes its chat first, and a new chat
    /// already kept stays the one: a start naming another is refused.
    func keep(_ request: MintUpRequest, chat: NewChat? = nil, account: String, sessionId: String, ticketId: String?) throws {
        var all = load()
        let slot = Self.key(account, sessionId, ticketId)
        if let existing = all[slot] {
            guard existing.request == request else { throw Refusal.anotherStartPending }
            return
        }
        if let chat {
            var chats = loadChats()
            let kept = chats[slot]?.chat
            if let kept, kept.sessionId != chat.sessionId { throw Refusal.anotherStartPending }
            chats[slot] = KeptChat(chat: kept ?? chat, keptAt: now())
            try saveChats(chats)
            guard loadChats()[slot]?.chat.sessionId == chat.sessionId else { throw CocoaError(.fileWriteUnknown) }
        }
        all[slot] = Entry(request: request, createdAt: now())
        try save(all)
        guard pending(account: account, sessionId: sessionId, ticketId: ticketId) == request else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Records that the room's new chat is made, so a next try goes straight to the mint. Throws when that could not be
    /// written: then the agent is not sent, and the next try asks the API for the same chat again first.
    func chatMade(account: String, sessionId: String) throws {
        var chats = loadChats()
        let slot = Self.key(account, sessionId, nil)
        guard let kept = chats[slot] else { throw CocoaError(.fileWriteUnknown) }
        var chat = kept.chat
        chat.made = true
        chats[slot] = KeptChat(chat: chat, keptAt: kept.keptAt)
        try saveChats(chats)
        guard loadChats()[slot]?.chat.made == true else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Forgets the start; a new chat kept for it stays, for the next start.
    func forget(account: String, sessionId: String, ticketId: String?) {
        var all = load()
        guard all.removeValue(forKey: Self.key(account, sessionId, ticketId)) != nil else { return }
        // A start left behind by a failed write comes back as unconfirmed, and checking it again is safe.
        try? save(all)
    }

    /// Forgets the room's new chat: an agent started.
    func forgetChat(account: String, sessionId: String) {
        var chats = loadChats()
        guard chats.removeValue(forKey: Self.key(account, sessionId, nil)) != nil else { return }
        try? saveChats(chats)
    }

    /// A ticket's start keeps the slot it always had; the room's New agent has the slot of an empty ticket id, which no
    /// ticket has.
    private static func key(_ account: String, _ sessionId: String, _ ticketId: String?) -> String {
        [account, sessionId, ticketId ?? ""].joined(separator: "|")
    }

    private func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        let oldest = now().addingTimeInterval(-Self.maxAge)
        return all.filter { $0.value.createdAt >= oldest }
    }

    private func save(_ all: [String: Entry]) throws {
        try JSONEncoder().encode(all).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func loadChats() -> [String: KeptChat] {
        guard let data = try? Data(contentsOf: chatsURL),
              let all = try? JSONDecoder().decode([String: KeptChat].self, from: data) else { return [:] }
        let oldest = now().addingTimeInterval(-Self.maxAge)
        return all.filter { $0.value.keptAt >= oldest }
    }

    private func saveChats(_ all: [String: KeptChat]) throws {
        try JSONEncoder().encode(all).write(to: chatsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// What the mint takes in a start (respawn `/up`): a name of letters, digits, `_`, `.` and `-` up to 48 characters
/// (it drops anything else), and a job of up to 20,000 characters, counted as the mint counts them (UTF-16).
enum MintStartLimits {
    static let nameLength = 48
    static let jobLength = 20_000
    private static let nameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")

    /// The name the mint will use; empty when it will make one.
    static func name(_ typed: String) -> String {
        String(String.UnicodeScalarView(typed.unicodeScalars.filter { nameCharacters.contains($0) }.prefix(nameLength)))
    }

    static func jobFits(_ job: String) -> Bool {
        job.utf16.count <= jobLength
    }
}

/// Starting an agent on the mint (sentinelayer-web `MintForm` in `NewAgentDialog`): a model and effort from the mint's
/// list, a name, and a job. For a ticket (Carter: custom agents for tickets, as on the web; `ticketMintPrefill`) the job
/// starts from the ticket and, once the agent starts, the ticket is assigned to it. From the room's New agent the job
/// starts empty, and the agent works in this chat or in a new one. A start whose outcome is not known is never sent as a
/// new one: it is checked again under its own key.
@MainActor
final class AgentStartModel: ObservableObject {
    /// Where a New agent works (the web's "Where the agent works"). A ticket's agent works in the ticket's room.
    enum Place: Equatable {
        case thisChat
        case newChat
    }

    enum Phase: Equatable {
        case loading
        case ready
        case starting(since: Date)
        case started(MintUpResponse)
        /// Sent, but not confirmed: the agent may exist. Offered to check again (the same start, the same key).
        case unconfirmed
        /// Not confirmed, and too old to check again: the mint may have forgotten its key, so it is never sent again.
        case unconfirmedTooOld
        case failed(String)
    }

    static let unconfirmedMessage = "Not confirmed: the agent may already be starting. Check again; it can only bring back this one agent."
    static let tooOldMessage = "Not confirmed, and too old to check again safely. Look for its agent in the Flight record before starting another; this start clears a day after it was made."
    static let notKeptMessage = "This phone could not keep a record of the start, so it was not sent. Nothing started."
    static let chatNotRecordedMessage = "The new chat is made, but this phone could not record it, so the agent was not sent. Nothing started; starting again uses that chat."

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var models: [MintModel] = []
    @Published private(set) var modelId = ""
    @Published var effort: String?
    @Published var agentName: String
    @Published var job: String
    @Published var place: Place = .thisChat
    /// The new chat kept from an earlier try: a start in a new chat goes there, never to a second one.
    @Published private(set) var keptChat: MintStartLedger.NewChat?
    /// The new chat the started agent works in; nil when it works in this room.
    @Published private(set) var startedChat: MintStartLedger.NewChat?
    /// Why the last check again did not go through; the start stays unconfirmed.
    @Published private(set) var checkProblem: String?

    private let mint: any MintStarting
    private let sessionId: String
    /// The ticket the agent is for; nil for the room's New agent.
    private let ticket: RoomTicketsCoordinator.AgentTicket?
    /// Makes a New agent's new chat; nil where none can be made.
    private let chats: (any AgentChatCreating)?
    private let ledger: MintStartLedger?
    private let account: String?
    private let onStarted: @MainActor (MintUpResponse) -> Void
    /// The start in flight or not confirmed, with its key.
    private var pending: MintUpRequest?

    init(ticket: RoomTicketsCoordinator.AgentTicket, sessionId: String, mint: any MintStarting,
         ledger: MintStartLedger? = nil, account: String? = nil, onStarted: @escaping @MainActor (String) -> Void) {
        self.ticket = ticket
        self.sessionId = sessionId
        self.mint = mint
        self.chats = nil
        self.ledger = ledger
        self.account = account
        self.onStarted = { onStarted($0.agentName) }
        agentName = TicketAgent.agentName(for: ticket.id)
        job = TicketAgent.jobDescription(ticketId: ticket.id, title: ticket.title, status: ticket.status,
                                         sessionId: sessionId, body: ticket.body)
    }

    /// The room's New agent: no ticket, an empty job, and a name the mint makes when none is given.
    init(newAgentIn sessionId: String, mint: any MintStarting, chats: (any AgentChatCreating)?,
         ledger: MintStartLedger? = nil, account: String? = nil,
         onStarted: @escaping @MainActor (MintUpResponse) -> Void = { _ in }) {
        self.ticket = nil
        self.sessionId = sessionId
        self.mint = mint
        self.chats = chats
        self.ledger = ledger
        self.account = account
        self.onStarted = onStarted
        agentName = ""
        job = ""
    }

    var selectedModel: MintModel? { models.first { $0.id == modelId } }

    /// Only the room's New agent offers a new chat, and only where chats can be made.
    var offersNewChat: Bool { ticket == nil && chats != nil }

    /// Longer than the mint takes: nothing is made or sent.
    var jobTooLong: Bool { !MintStartLimits.jobFits(job.trimmingCharacters(in: .whitespacesAndNewlines)) }

    /// What the mint will call the agent, when that is not the name as typed.
    var nameNote: String? {
        let typed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = MintStartLimits.name(typed)
        guard name != typed else { return nil }
        return name.isEmpty
            ? "The mint keeps only letters, digits, _ . and -, so it will make the name."
            : "It will be named \(name): the mint keeps letters, digits, _ . and -, up to 48."
    }

    var canStart: Bool {
        phase == .ready && !modelId.isEmpty && !job.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !jobTooLong
    }

    func load() async {
        guard phase == .loading else { return }
        do {
            models = try await mint.models()
            guard let first = models.first else {
                phase = .failed("The mint offered no models.")
                return
            }
            select(first.id)
            // A start left unconfirmed (the sheet closed, the app was killed, or the person signed out and in) comes
            // back as it was sent.
            if adoptKeptStart() { return }
            phase = .ready
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    /// A model and its default effort.
    func select(_ id: String) {
        modelId = id
        effort = selectedModel?.defaultEffort ?? selectedModel?.efforts.first
    }

    /// A new start: a new key, kept on the phone before it is sent. While another start for this ticket is unresolved
    /// (from another sheet, say), that one is taken up instead: one start per ticket.
    func start(now: Date = Date()) async {
        guard canStart else { return }
        if adoptKeptStart() { return }
        let name = MintStartLimits.name(agentName)
        let jobText = job.trimmingCharacters(in: .whitespacesAndNewlines)
        // In a new chat: the one kept from an earlier try, or one named now (the web's `newMintRoomId`) and kept with
        // the start before it is made.
        let chat = place == .newChat && offersNewChat
            ? keptChat ?? MintStartLedger.NewChat(
                sessionId: UUID().uuidString.lowercased(),
                title: NewAgentChat.title(agentName: name, job: jobText) ?? NewAgentChat.untitled,
                createKey: "create-" + UUID().uuidString.lowercased(),
                made: false
            )
            : nil
        let request = MintUpRequest(
            model: modelId,
            effort: effort,
            jobDescription: jobText,
            sessionId: chat?.sessionId ?? sessionId,
            agentName: name.isEmpty ? nil : name,
            ticketId: ticket?.id,
            ticketTitle: ticket.map { TicketSignal.publicTitle($0.title) },
            idempotencyKey: "pocket-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        )
        await send(request, chat: chat, now: now, again: false)
    }

    /// The unconfirmed start, sent again exactly as it was, under its own key: the mint returns that agent if it
    /// started, and starts it once if it never did.
    func checkAgain(now: Date = Date()) async {
        guard phase == .unconfirmed, let pending else { return }
        // Sent again only while the phone still holds this very start, inside the horizon. A record gone (pruned after a
        // day, deleted, unreadable) or replaced means the mint may have forgotten the key: never sent (#298 review).
        guard let ledger, let account,
              let kept = ledger.entry(account: account, sessionId: sessionId, ticketId: ticket?.id), kept.request == pending,
              ledger.isCheckable(kept) else {
            phase = .unconfirmedTooOld
            return
        }
        await send(pending, chat: nil, now: now, again: true)
    }

    /// Takes up this ticket's (or the room's New agent's) kept, unresolved start: its fields, and the phase it calls
    /// for. False when there is none. A kept new chat alone is noted for the next start.
    private func adoptKeptStart() -> Bool {
        guard let ledger, let account else { return false }
        if ticket == nil { keptChat = ledger.chat(account: account, sessionId: sessionId) }
        guard let kept = ledger.entry(account: account, sessionId: sessionId, ticketId: ticket?.id) else { return false }
        let request = kept.request
        pending = request
        if models.contains(where: { $0.id == request.model }) { modelId = request.model }
        effort = request.effort
        agentName = request.agentName ?? ""
        job = request.jobDescription
        place = request.sessionId == sessionId ? .thisChat : .newChat
        phase = ledger.isCheckable(kept) ? .unconfirmed : .unconfirmedTooOld
        return true
    }

    /// Sends a start that is kept on the phone first. One that cannot be kept (no record on this phone, no signed-in
    /// account, or the write failed) is not sent: after a kill its key would be lost, and a second start could follow.
    /// `again`: a check again, whose first send may have started the agent.
    private func send(_ request: MintUpRequest, chat: MintStartLedger.NewChat?, now: Date, again: Bool) async {
        guard let ledger, let account else {
            phase = .failed(Self.notKeptMessage)
            return
        }
        // Starting an agent writes to the room: never without the account's consent to share with AI.
        guard !AIConsentAsker.shared.refusesWrites else {
            phase = .failed(Self.consentMessage)
            return
        }
        do {
            try ledger.keep(request, chat: chat, account: account, sessionId: sessionId, ticketId: ticket?.id)
        } catch MintStartLedger.Refusal.anotherStartPending {
            // Another sheet made a start for this ticket meanwhile: that one is checked, never a second.
            _ = adoptKeptStart()
            return
        } catch {
            phase = .failed(Self.notKeptMessage)
            return
        }
        phase = .starting(since: now)
        pending = request
        checkProblem = nil
        // A start in a new chat goes there once the chat is made, under the id and key kept with it: made again, it is the
        // same chat. With that record gone, whether the chat was made is not known, so the start is never sent.
        var target: MintStartLedger.NewChat?
        if request.sessionId != sessionId {
            guard let kept = ledger.chat(account: account, sessionId: sessionId), kept.sessionId == request.sessionId else {
                if again {
                    phase = .unconfirmedTooOld
                } else {
                    notThrough(Self.notKeptMessage, again: false)
                }
                return
            }
            target = kept
        }
        if let target, !target.made {
            do {
                guard let chats else { throw RoomSendError.notConfigured }
                try await chats.createAgentChat(sessionId: target.sessionId, title: target.title,
                                                idempotencyKey: target.createKey)
            } catch {
                notThrough(again ? "The new chat could not be reached." : Self.chatMessage(error), again: again)
                return
            }
            do {
                try ledger.chatMade(account: account, sessionId: sessionId)
            } catch {
                notThrough(again ? "This phone could not record the new chat." : Self.chatNotRecordedMessage, again: again)
                return
            }
        }
        do {
            let started = try await mint.startAgent(request)
            forgetPending()
            if ticket == nil { ledger.forgetChat(account: account, sessionId: sessionId) }
            keptChat = nil
            startedChat = await named(target, for: started)
            phase = .started(started)
            onStarted(started)
        } catch MintError.notConfirmed {
            phase = .unconfirmed
        } catch {
            let message = Self.message(error)
            notThrough(target == nil || again ? message : message + " The new chat is made; starting again uses it.",
                       again: again)
        }
    }

    /// A new chat made before the mint named its agent (`NewAgentChat.untitled`) takes the agent's name now. Best effort:
    /// a rename that does not go through leaves the chat as it is, and the agent started either way.
    private func named(_ chat: MintStartLedger.NewChat?, for started: MintUpResponse) async -> MintStartLedger.NewChat? {
        guard let chat, chat.title == NewAgentChat.untitled, let chats,
              let name = NewAgentChat.title(agentName: started.agentName, job: "") else { return chat }
        guard (try? await chats.nameAgentChat(sessionId: chat.sessionId, title: name)) != nil else { return chat }
        return MintStartLedger.NewChat(sessionId: chat.sessionId, title: name, createKey: chat.createKey, made: chat.made)
    }

    /// A send that did not go through. The first send of a start refused (by the mint, or before it: its chat not made or
    /// not recorded): nothing started under its key, so it is forgotten, and the form can be changed and sent again; a new
    /// chat made for it stays kept. A check again refused: the first send may have started the agent, so the start stays
    /// as it was, to be checked again under its own key, never replaced by a new one.
    static let consentMessage = "Not started: say whether what you share may go to AI first, then try again."

    private func notThrough(_ message: String, again: Bool) {
        if again {
            checkProblem = message
            phase = .unconfirmed
        } else {
            forgetPending()
            phase = .failed(message)
        }
    }

    private func forgetPending() {
        pending = nil
        guard let ledger, let account else { return }
        ledger.forget(account: account, sessionId: sessionId, ticketId: ticket?.id)
        if ticket == nil { keptChat = ledger.chat(account: account, sessionId: sessionId) }
    }

    /// After a failure: change something and try again.
    func edit() {
        if case .failed = phase, !models.isEmpty { phase = .ready }
    }

    static func message(_ error: Error) -> String {
        switch error as? MintError {
        case .forbidden?: return "This account cannot start agents."
        case .capacity?: return "No machine is free right now. Try again in a minute."
        case .refused(let reason)?: return reason.map { "The mint refused it: \($0)" } ?? "The mint refused it as it stands."
        case .reauthenticationRequired?: return "Sign in again to start agents."
        case .notConfirmed?: return unconfirmedMessage
        default: return "The mint could not be reached. Try again."
        }
    }

    /// The new chat was not made, and the agent not sent.
    static func chatMessage(_ error: Error) -> String {
        switch error as? RoomSendError {
        case .reauthenticationRequired?: return "Sign in again to make the new chat. Nothing started."
        case .notAllowed?: return "This account can't make chats right now. Nothing started."
        default: return "The new chat could not be made, so nothing started. Try again: it makes that same chat, never a second one."
        }
    }

    /// Under an unconfirmed start whose check again did not go through.
    static func checkProblemMessage(_ problem: String) -> String {
        "Checking again did not go through: \(problem) The first try may have started it, so this start stays as it is; check again later."
    }

    /// The web's names for efforts.
    static func effortLabel(_ effort: String) -> String {
        switch effort {
        case "none": return "Fastest"
        case "low": return "Light"
        case "medium": return "Balanced"
        case "high": return "Strong"
        case "xhigh": return "Max"
        default: return effort
        }
    }
}

struct TicketAgentSheet: View {
    @StateObject private var model: AgentStartModel
    @Environment(\.dismiss) private var dismiss
    private let title: String

    init(ticket: RoomTicketsCoordinator.AgentTicket, sessionId: String, mint: any MintStarting,
         onStarted: @escaping @MainActor (String) -> Void) {
        title = TicketSignal.publicTitle(ticket.title)
        _model = StateObject(wrappedValue: AgentStartModel(
            ticket: ticket, sessionId: sessionId, mint: mint,
            ledger: .standard, account: RoomSendOutbox.account(token: SessionTokenStore.load()), onStarted: onStarted
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ticket") {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                switch model.phase {
                case .loading:
                    Section { ProgressView("Asking the mint for its models…") }
                case .started(let started):
                    startedSection(started)
                default:
                    AgentStartForm(
                        model: model,
                        namePrompt: "Name",
                        jobFooter: "It starts from the ticket. It posts a plan in the room, works on its own machine, and the ticket is assigned to it."
                    )
                }
            }
            .navigationTitle("Start an agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isStarted ? "Done" : "Cancel") { dismiss() }
                        .disabled(isStarting)
                }
            }
            .interactiveDismissDisabled(isStarting)
            .task { await model.load() }
        }
    }

    private var isStarting: Bool {
        if case .starting = model.phase { return true }
        return false
    }

    private var isStarted: Bool {
        if case .started = model.phase { return true }
        return false
    }

    private func startedSection(_ started: MintUpResponse) -> some View {
        Section {
            Label("\(started.agentName) is starting on its own machine.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.teal)
            Text("It will post a short plan in the room. The ticket is assigned to it; its box shows in the Flight record.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// The start form both sheets share (the web's `MintForm`): the model and its effort, the name, the job, and Start with
/// what became of it.
struct AgentStartForm: View {
    @ObservedObject var model: AgentStartModel
    /// The name field's prompt.
    let namePrompt: String
    /// Under the job.
    let jobFooter: String
    /// Shown while the job is empty.
    var jobPlaceholder: String?

    var body: some View {
        Section("Model") {
            Picker("Model", selection: Binding(get: { model.modelId }, set: { model.select($0) })) {
                ForEach(model.models) { item in
                    Text(item.label).tag(item.id)
                }
            }
            .accessibilityIdentifier("pocket.agent.model")
            if let note = model.selectedModel?.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let efforts = model.selectedModel?.efforts, !efforts.isEmpty {
                Picker("Effort", selection: $model.effort) {
                    ForEach(efforts, id: \.self) { effort in
                        Text(AgentStartModel.effortLabel(effort)).tag(Optional(effort))
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("pocket.agent.effort")
            }
        }
        Section {
            TextField(namePrompt, text: $model.agentName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("pocket.agent.name")
            if let note = model.nameNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("pocket.agent.nameNote")
            }
        } header: {
            Text("Its name in the room")
        }
        Section {
            TextEditor(text: $model.job)
                .font(.callout)
                .frame(minHeight: 200)
                .overlay(alignment: .topLeading) {
                    if let jobPlaceholder, model.job.isEmpty {
                        Text(jobPlaceholder)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("pocket.agent.job")
            if model.jobTooLong {
                Text("The mint takes a job of up to 20,000 characters; this one has \(model.job.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count).")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("pocket.agent.jobTooLong")
            }
        } header: {
            Text("Its job")
        } footer: {
            Text(jobFooter)
        }
        Section {
            if case .starting(let since) = model.phase {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Starting \(model.agentName.isEmpty ? "the agent" : model.agentName): booting its machine (\(Int(context.date.timeIntervalSince(since))) s)")
                            .font(.footnote)
                    }
                }
            } else if model.phase == .unconfirmed {
                Text(AgentStartModel.unconfirmedMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                if let problem = model.checkProblem {
                    Text(AgentStartModel.checkProblemMessage(problem))
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("pocket.agent.checkProblem")
                }
                Button {
                    Task { await model.checkAgain() }
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pocket.agent.checkAgain")
                Text("Its box shows in the Flight record once it is up.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if model.phase == .unconfirmedTooOld {
                Text(AgentStartModel.tooOldMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("pocket.agent.tooOld")
            } else {
                Button {
                    Task { await model.start() }
                } label: {
                    Label("Start the agent", systemImage: "cpu")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
                .accessibilityIdentifier("pocket.agent.start")
            }
            if case .failed(let message) = model.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .onTapGesture { model.edit() }
                if !model.models.isEmpty {
                    Button("Change something and try again") { model.edit() }
                        .font(.footnote)
                }
            }
        }
    }
}
