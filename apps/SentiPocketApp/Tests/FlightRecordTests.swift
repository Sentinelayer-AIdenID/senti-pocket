import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class FakeMint: MintReading, @unchecked Sendable {
    let lives: [MintLife]
    let records: [String: MintFlightRecord]
    let totals: MintRoomTotals?

    init(lives: [MintLife], records: [String: MintFlightRecord], totals: MintRoomTotals? = nil) {
        self.lives = lives
        self.records = records
        self.totals = totals
    }

    func roomLives(sessionId: String) async throws -> [MintLife] { lives }
    func roomSnapshot(sessionId: String) async throws -> MintRoomLives { MintRoomLives(lives: lives, totals: totals) }
    func flight(lifeId: String) async throws -> MintFlightRecord {
        guard let record = records[lifeId] else { throw MintError.unavailable }
        return record
    }
}

/// A quiet room whose actions hold "working on" updates.
private final class WorkTransport: RoomTransport, @unchecked Sendable {
    let actions: RoomActionsPage
    init(actions: RoomActionsPage) { self.actions = actions }
    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [RoomMessage(id: "evt-10", sequenceId: 10, kind: .message, authorId: "human-mrrcarter",
                                             authorName: "mrrcarter", isHuman: true, text: "please file this",
                                             timestamp: "2026-10-29T20:00:00.000000+00:00")])
    }
    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage { RoomEventPage(messages: []) }
    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }
    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage { actions }
}

@MainActor
final class FlightRecordTests: XCTestCase {
    /// Carter (#55014): the web's room figures on top of the panel.
    func test_the_room_figures_show_over_the_boxes() async {
        let mint = FakeMint(
            lives: [MintLife(id: "a", agentName: "astra", model: "m", phase: "working")],
            records: [:],
            totals: MintRoomTotals(lifeCount: 10, endedCount: 7, firstBornAt: "2026-10-27T10:00:00Z", lastEndAt: nil,
                                   workingSeconds: 144_000, exactLives: 8, exactWorkingSeconds: 108_000,
                                   exactCostUsd: 120, costUsd: 150)
        )
        let coordinator = FlightRecordCoordinator(sessionId: "room", mint: mint, sleep: { _ in },
                                                  now: { ParsedSessionTimestamp("2026-10-29T10:00:00Z").date! })
        await coordinator.refresh()
        let totals = coordinator.state.totals
        XCTAssertEqual(totals?.minted, 10)
        XCTAssertEqual(totals?.active, 3)
        XCTAssertEqual(totals?.finished, 7)
        XCTAssertEqual(totals?.workedHours, 40)
        XCTAssertEqual(totals?.savedDays ?? -1, 3, accuracy: 0.0001)
        XCTAssertEqual(totals?.costUsd, 150)
        XCTAssertEqual(coordinator.state.finishedBoxes, 7, "the summary line counts every finished box, listed or not")
        XCTAssertNil(FlightRecordCoordinator.totals(MintRoomSummary(room: MintRoomLives(lives: []), now: Date())),
                     "a room that never ran a box shows no figures")
    }

    func test_the_flight_record_lists_running_boxes_with_what_each_is_doing_and_counts_the_finished() async {
        let mint = FakeMint(
            lives: [
                MintLife(id: "a", agentName: "astra-billing-core", model: "model-a", phase: "ready",
                         ticketTitle: "Billing core"),
                MintLife(id: "b", agentName: "ds-aid-install-cli", model: "model-b", phase: "working"),
                MintLife(id: "c", agentName: "old-box", model: "m", phase: "destroyed")
            ],
            records: [
                "a": MintFlightRecord(narration: [.init(at: "2026-10-29T19:00:00Z", text: "Writing the ledger tests.")]),
                "b": MintFlightRecord(commands: [.init(at: "2026-10-29T19:00:00Z", text: "/bin/bash -lc \"npm test\"", exitCode: nil)])
            ]
        )
        let coordinator = FlightRecordCoordinator(sessionId: "room", mint: mint, sleep: { _ in
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
        })
        coordinator.setAgents([
            FlightRecordState.Agent(id: "review-agent", isHere: true, isIdle: false, status: "reviewing #207", statusAt: nil),
            FlightRecordState.Agent(id: "astra-billing-core", isHere: true, isIdle: false, status: nil, statusAt: nil)
        ])
        await coordinator.refresh()
        let state = coordinator.state
        XCTAssertEqual(state.boxes.map(\.name), ["ds-aid-install-cli", "astra-billing-core"], "working boxes first; finished ones are left out")
        XCTAssertEqual(state.finishedBoxes, 1)
        XCTAssertEqual(state.endedBoxNames, ["old-box"], "a call never rings a box that ended")
        XCTAssertEqual(state.boxes.first?.current, "$ npm test", "no thought yet: its newest command")
        XCTAssertEqual(state.boxes.last?.current, "Writing the ledger tests.")
        XCTAssertEqual(state.boxes.last?.job, "Billing core")
        XCTAssertEqual(state.agents.map(\.id), ["review-agent"], "an agent with a box is shown once, as its box")
    }

    func test_working_on_lines_sit_under_their_message_and_only_the_newest_unfinished_one_is_live() async {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let older = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120))
        let stale = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3_600))
        let transport = WorkTransport(actions: RoomActionsPage(workingOn: [
            RoomWorkingOn(id: "w0", targetSequenceId: 10, actorId: "review-agent", note: "looking", createdAt: stale),
            RoomWorkingOn(id: "w1", targetSequenceId: 10, actorId: "ticket-keeper", note: "filing", createdAt: older),
            RoomWorkingOn(id: "w2", targetSequenceId: 10, actorId: "ticket-keeper", note: "done: filed 1 ticket", createdAt: recent),
            RoomWorkingOn(id: "w3", targetSequenceId: 10, actorId: "astra-site", note: "drafting the copy", createdAt: recent)
        ]))
        let coordinator = RoomChatCoordinator(sessionId: "room", title: "Room", transport: transport,
                                              sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
                                              onReauthenticationRequired: {})
        coordinator.resume()
        var work: [RoomChatWorkLine] = []
        for _ in 0..<500 {
            work = coordinator.state.rows.compactMap { row -> [RoomChatWorkLine]? in
                if case .message(let message) = row, message.sequenceId == 10 { return message.work }
                return nil
            }.first ?? []
            if work.count == 4 { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(work.map(\.id), ["w0", "w1", "w2", "w3"], "oldest first (same time: by id)")
        XCTAssertEqual(work.filter(\.isLive).map(\.id), ["w3"], "done, superseded and stale lines are not live")
        XCTAssertEqual(coordinator.latestWork()["ticket-keeper"]?.text, "done: filed 1 ticket")
        coordinator.pause()
    }
}
