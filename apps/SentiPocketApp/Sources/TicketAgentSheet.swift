import Foundation
import PocketSyncClient
import PocketUI
import SwiftUI

/// Starting an agent for a ticket (Carter: custom agents for tickets, as on the web; sentinelayer-web
/// `NewAgentDialog` with `ticketMintPrefill`): a model and effort from the mint's list, a name, and a job that starts
/// from the ticket. Once it starts, the ticket is assigned to it.
@MainActor
final class TicketAgentModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case starting(since: Date)
        case started(MintUpResponse)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var models: [MintModel] = []
    @Published private(set) var modelId = ""
    @Published var effort: String?
    @Published var agentName: String
    @Published var job: String

    private let mint: any MintStarting
    private let sessionId: String
    private let ticket: RoomTicketsCoordinator.AgentTicket
    private let onStarted: @MainActor (String) -> Void

    init(ticket: RoomTicketsCoordinator.AgentTicket, sessionId: String, mint: any MintStarting,
         onStarted: @escaping @MainActor (String) -> Void) {
        self.ticket = ticket
        self.sessionId = sessionId
        self.mint = mint
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

    func start(now: Date = Date()) async {
        guard canStart else { return }
        phase = .starting(since: now)
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = MintUpRequest(
            model: modelId,
            effort: effort,
            jobDescription: job.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionId: sessionId,
            agentName: name.isEmpty ? nil : name,
            ticketId: ticket.id,
            ticketTitle: TicketSignal.publicTitle(ticket.title)
        )
        do {
            let started = try await mint.startAgent(request)
            phase = .started(started)
            onStarted(started.agentName)
        } catch {
            phase = .failed(Self.message(error))
        }
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
        _model = StateObject(wrappedValue: TicketAgentModel(ticket: ticket, sessionId: sessionId, mint: mint, onStarted: onStarted))
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
