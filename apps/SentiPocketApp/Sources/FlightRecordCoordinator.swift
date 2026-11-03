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
    /// The names of the room's boxes that ended, lowercased.
    private var endedBoxNames: Set<String> = []
    private var flights: [String: MintFlightRecord] = [:]
    private var finished = 0
    private var summary: MintRoomSummary?
    private var failure: String?
    private var expandedId: String?
    private var agents: [FlightRecordState.Agent] = []
    private var people: [RoomRoster.Member] = []
    private var loop: Task<Void, Never>?
    private var expandedLoop: Task<Void, Never>?

    static let listInterval: TimeInterval = 30
    static let openBoxInterval: TimeInterval = 10

    private let now: () -> Date

    init(
        sessionId: String,
        mint: any MintReading,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.sessionId = sessionId
        self.mint = mint
        self.sleep = sleep
        self.now = now
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

    /// The room's people for their own list, from the room's roster.
    func setPeople(_ people: [RoomRoster.Member]) {
        guard people != self.people else { return }
        self.people = people
        publish()
    }

    /// The room's boxes only (one read), for who is here; the full flight record reads each box as well.
    func refreshBoxes() async {
        guard let room = try? await mint.roomSnapshot(sessionId: sessionId) else { return }
        lives = room.lives.filter(\.isActive)
        let running = Set(lives.map { $0.agentName.lowercased() })
        endedBoxNames = Set(room.lives.filter { !$0.isActive }.map { $0.agentName.lowercased() }).subtracting(running)
        publish()
    }

    func refresh() async {
        do {
            let room = try await mint.roomSnapshot(sessionId: sessionId)
            lives = room.lives.filter(\.isActive)
            let running = Set(lives.map { $0.agentName.lowercased() })
            endedBoxNames = Set(room.lives.filter { !$0.isActive }.map { $0.agentName.lowercased() }).subtracting(running)
            let figures = MintRoomSummary(room: room, now: now())
            summary = figures
            finished = figures.finished
            failure = nil
        } catch MintError.notConfigured {
            // A build without the Flight record's service shows the room's agents only.
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
            people: people,
            finishedBoxes: finished,
            isLoading: false,
            failure: failure,
            totals: summary.flatMap(Self.totals),
            endedBoxNames: endedBoxNames
        )
    }

    /// The figures the panel shows: none for a room that never ran a box.
    static func totals(_ summary: MintRoomSummary) -> FlightRecordState.Totals? {
        guard summary.minted > 0 else { return nil }
        return FlightRecordState.Totals(
            minted: summary.minted,
            active: summary.active,
            finished: summary.finished,
            isMinimum: summary.listCut,
            workedHours: summary.workKnown ? summary.workingHours : nil,
            workIsMinimum: summary.workIsPartial,
            savedDays: summary.workKnown ? summary.savedDays : nil,
            costUsd: summary.costUsd,
            costPercent: summary.costPercent
        )
    }
}
