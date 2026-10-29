import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI

/// The Flight record for one room: its running boxes with what each is thinking and doing, read from the mint
/// service while the panel is open (every 30 seconds, and every 10 for the box opened), plus the room's other agents
/// with their latest "working on" line. Nothing is read while the panel is closed.
@MainActor
final class FlightRecordCoordinator: ObservableObject {
    @Published private(set) var state = FlightRecordState(isLoading: true)

    private let sessionId: String
    private let mint: any MintReading
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var lives: [MintLife] = []
    private var flights: [String: MintFlightRecord] = [:]
    private var finished = 0
    private var failure: String?
    private var expandedId: String?
    private var agents: [FlightRecordState.Agent] = []
    private var loop: Task<Void, Never>?
    private var expandedLoop: Task<Void, Never>?

    static let listInterval: TimeInterval = 30
    static let openBoxInterval: TimeInterval = 10

    init(
        sessionId: String,
        mint: any MintReading,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.sessionId = sessionId
        self.mint = mint
        self.sleep = sleep
    }

    /// The panel opened: read now, then keep reading until `stop()`.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                await self.sleep(Self.listInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        expandedLoop?.cancel()
        expandedLoop = nil
    }

    /// The box whose steps are open reads more often, so its steps stream in.
    func expand(_ lifeId: String?) {
        expandedId = lifeId
        expandedLoop?.cancel()
        guard let lifeId else { return }
        expandedLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sleep(Self.openBoxInterval)
                guard !Task.isCancelled, self.expandedId == lifeId else { return }
                await self.readFlight(lifeId)
                self.publish()
            }
        }
    }

    /// The room's agents and what each said it is working on, from the room screen.
    func setAgents(_ agents: [FlightRecordState.Agent]) {
        guard agents != self.agents else { return }
        self.agents = agents
        publish()
    }

    func refresh() async {
        do {
            let all = try await mint.roomLives(sessionId: sessionId)
            lives = all.filter(\.isActive)
            finished = all.count - lives.count
            failure = nil
        } catch MintError.forbidden {
            failure = "This account cannot see the room's boxes."
        } catch {
            if lives.isEmpty { failure = "The flight record could not load. It retries every 30 seconds." }
        }
        publish()
        await withTaskGroup(of: (String, MintFlightRecord?).self) { group in
            for life in lives {
                let mint = self.mint
                group.addTask { (life.id, try? await mint.flight(lifeId: life.id)) }
            }
            for await (id, record) in group {
                if let record { flights[id] = record }
            }
        }
        flights = flights.filter { id, _ in lives.contains { $0.id == id } }
        publish()
    }

    private func readFlight(_ lifeId: String) async {
        if let record = try? await mint.flight(lifeId: lifeId) { flights[lifeId] = record }
    }

    private func publish() {
        let boxes = lives.map { life -> FlightRecordState.Box in
            let record = flights[life.id]
            let lines = FlightRecordState.lines(
                narration: (record?.narration ?? []).map { ($0.at, $0.text) },
                commands: (record?.commands ?? []).map { ($0.at, $0.text, $0.exitCode) }
            )
            let newestThought = record?.narration.last?.text
            let newestCommand = record?.commands.last.map { "$ " + FlightRecordState.command($0.text) }
            return FlightRecordState.Box(
                id: life.id,
                name: life.agentName,
                model: life.model,
                phase: record?.phase ?? life.phase,
                job: life.ticketTitle ?? life.jobDescription.map { $0.split(whereSeparator: \.isNewline).first.map(String.init) ?? $0 },
                current: newestThought ?? newestCommand,
                lastActivity: (record?.lastActivity).flatMap { ParsedSessionTimestamp($0).date },
                expiresAt: ParsedSessionTimestamp(record?.expiresAt ?? life.expiresAt).date,
                consoleURL: life.consoleURL,
                lines: lines,
                posts: record?.posts ?? 0,
                doneSummary: record?.doneSummary
            )
        }
        .sorted { ($0.isWorking ? 0 : 1, -( $0.lastActivity?.timeIntervalSince1970 ?? 0)) < ($1.isWorking ? 0 : 1, -($1.lastActivity?.timeIntervalSince1970 ?? 0)) }
        let boxNames = Set(boxes.map { $0.name.lowercased() })
        state = FlightRecordState(
            boxes: boxes,
            agents: agents.filter { !boxNames.contains($0.id.lowercased()) },
            finishedBoxes: finished,
            isLoading: false,
            failure: failure
        )
    }
}
