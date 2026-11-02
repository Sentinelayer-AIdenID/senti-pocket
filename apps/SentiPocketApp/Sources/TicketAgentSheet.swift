import Foundation
import PocketSyncClient
import PocketUI
import SwiftUI

/// Starts of an agent whose outcome is not known yet, kept on the phone per account, room and ticket with the key the
/// mint knows them by. Checking again sends the same start under the same key, so it can only return that agent, even
/// after the sheet closed or the app was killed. Kept for a day, as the mint keeps its keys.
struct MintStartLedger: Sendable {
    struct Entry: Codable, Equatable {
        let request: MintUpRequest
        let createdAt: Date
    }

    static let maxAge: TimeInterval = 24 * 60 * 60

    let url: URL
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

    /// Signing out forgets every unconfirmed start on the phone.
    static func clearStandard() {
        guard let url = standard?.url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func pending(account: String, sessionId: String, ticketId: String) -> MintUpRequest? {
        load()[Self.key(account, sessionId, ticketId)]?.request
    }

    /// Writes the start to the phone, and throws if it could not: a start that is not kept is not sent, since after a
    /// kill its key would be lost.
    func keep(_ request: MintUpRequest, account: String, sessionId: String, ticketId: String) throws {
        var all = load()
        all[Self.key(account, sessionId, ticketId)] = Entry(request: request, createdAt: now())
        try save(all)
        guard pending(account: account, sessionId: sessionId, ticketId: ticketId) == request else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func forget(account: String, sessionId: String, ticketId: String) {
        var all = load()
        guard all.removeValue(forKey: Self.key(account, sessionId, ticketId)) != nil else { return }
        // A start left behind by a failed write comes back as unconfirmed, and checking it again is safe.
        try? save(all)
    }

    private static func key(_ account: String, _ sessionId: String, _ ticketId: String) -> String {
        [account, sessionId, ticketId].joined(separator: "|")
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
}

/// Starting an agent for a ticket (Carter: custom agents for tickets, as on the web; sentinelayer-web
/// `NewAgentDialog` with `ticketMintPrefill`): a model and effort from the mint's list, a name, and a job that starts
/// from the ticket. Once it starts, the ticket is assigned to it. A start whose outcome is not known is never sent as a
/// new one: it is checked again under its own key.
@MainActor
final class TicketAgentModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case starting(since: Date)
        case started(MintUpResponse)
        /// Sent, but not confirmed: the agent may exist. Offered to check again (the same start, the same key).
        case unconfirmed
        case failed(String)
    }

    static let unconfirmedMessage = "Not confirmed: the agent may already be starting. Check again; it can only bring back this one agent."
    static let notKeptMessage = "This phone could not keep a record of the start, so it was not sent. Nothing started."

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var models: [MintModel] = []
    @Published private(set) var modelId = ""
    @Published var effort: String?
    @Published var agentName: String
    @Published var job: String

    private let mint: any MintStarting
    private let sessionId: String
    private let ticket: RoomTicketsCoordinator.AgentTicket
    private let ledger: MintStartLedger?
    private let account: String?
    private let onStarted: @MainActor (String) -> Void
    /// The start in flight or not confirmed, with its key.
    private var pending: MintUpRequest?

    init(ticket: RoomTicketsCoordinator.AgentTicket, sessionId: String, mint: any MintStarting,
         ledger: MintStartLedger? = nil, account: String? = nil, onStarted: @escaping @MainActor (String) -> Void) {
        self.ticket = ticket
        self.sessionId = sessionId
        self.mint = mint
        self.ledger = ledger
        self.account = account
        self.onStarted = onStarted
        agentName = TicketAgent.agentName(for: ticket.id)
        job = TicketAgent.jobDescription(ticketId: ticket.id, title: ticket.title, status: ticket.status,
                                         sessionId: sessionId, body: ticket.body)
    }

    var selectedModel: MintModel? { models.first { $0.id == modelId } }

    var canStart: Bool {
        phase == .ready && !modelId.isEmpty && !job.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            // A start left unconfirmed (the sheet closed, or the app was killed) comes back as it was sent.
            if let ledger, let account, let kept = ledger.pending(account: account, sessionId: sessionId, ticketId: ticket.id) {
                pending = kept
                if models.contains(where: { $0.id == kept.model }) { modelId = kept.model }
                effort = kept.effort
                agentName = kept.agentName ?? ""
                job = kept.jobDescription
                phase = .unconfirmed
                return
            }
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

    /// A new start: a new key, kept on the phone before it is sent.
    func start(now: Date = Date()) async {
        guard canStart else { return }
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = MintUpRequest(
            model: modelId,
            effort: effort,
            jobDescription: job.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionId: sessionId,
            agentName: name.isEmpty ? nil : name,
            ticketId: ticket.id,
            ticketTitle: TicketSignal.publicTitle(ticket.title),
            idempotencyKey: "pocket-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        )
        await send(request, now: now)
    }

    /// The unconfirmed start, sent again exactly as it was, under its own key: the mint returns that agent if it
    /// started, and starts it once if it never did.
    func checkAgain(now: Date = Date()) async {
        guard phase == .unconfirmed, let pending else { return }
        await send(pending, now: now)
    }

    /// Sends a start that is kept on the phone first. One that cannot be kept (no record on this phone, no signed-in
    /// account, or the write failed) is not sent: after a kill its key would be lost, and a second start could follow.
    private func send(_ request: MintUpRequest, now: Date) async {
        do {
            guard let ledger, let account else { throw CocoaError(.fileWriteUnknown) }
            try ledger.keep(request, account: account, sessionId: sessionId, ticketId: ticket.id)
        } catch {
            phase = .failed(Self.notKeptMessage)
            return
        }
        phase = .starting(since: now)
        pending = request
        do {
            let started = try await mint.startAgent(request)
            forgetPending()
            phase = .started(started)
            onStarted(started.agentName)
        } catch MintError.notConfirmed {
            phase = .unconfirmed
        } catch {
            // Refused outright (capacity, refusal, sign-in, not admitted): nothing started under this key.
            forgetPending()
            phase = .failed(Self.message(error))
        }
    }

    private func forgetPending() {
        pending = nil
        if let ledger, let account { ledger.forget(account: account, sessionId: sessionId, ticketId: ticket.id) }
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
    @StateObject private var model: TicketAgentModel
    @Environment(\.dismiss) private var dismiss
    private let title: String

    init(ticket: RoomTicketsCoordinator.AgentTicket, sessionId: String, mint: any MintStarting,
         onStarted: @escaping @MainActor (String) -> Void) {
        title = TicketSignal.publicTitle(ticket.title)
        _model = StateObject(wrappedValue: TicketAgentModel(
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
                    formSections
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

    @ViewBuilder
    private var formSections: some View {
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
                        Text(TicketAgentModel.effortLabel(effort)).tag(Optional(effort))
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("pocket.agent.effort")
            }
        }
        Section {
            TextField("Name", text: $model.agentName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("pocket.agent.name")
        } header: {
            Text("Its name in the room")
        }
        Section {
            TextEditor(text: $model.job)
                .font(.callout)
                .frame(minHeight: 200)
                .accessibilityIdentifier("pocket.agent.job")
        } header: {
            Text("Its job")
        } footer: {
            Text("It starts from the ticket. It posts a plan in the room, works on its own machine, and the ticket is assigned to it.")
        }
        Section {
            if case .starting(let since) = model.phase {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Starting \(model.agentName): booting its machine (\(Int(context.date.timeIntervalSince(since))) s)")
                            .font(.footnote)
                    }
                }
            } else if model.phase == .unconfirmed {
                Text(TicketAgentModel.unconfirmedMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
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
