import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class ScriptedTicketsTransport: RoomTicketsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [Result<RoomTicketSnapshotPage, Error>]
    private var events: [Result<RoomTicketEventsPage, Error>]
    private(set) var eventCalls: [Int64] = []

    init(snapshots: [Result<RoomTicketSnapshotPage, Error>], events: [Result<RoomTicketEventsPage, Error>] = []) {
        self.snapshots = snapshots
        self.events = events
    }

    func roomTicketSnapshot(sessionId: String, afterId: String?, limit: Int) async throws -> RoomTicketSnapshotPage {
        let next: Result<RoomTicketSnapshotPage, Error> = {
            lock.lock()
            defer { lock.unlock() }
            return snapshots.isEmpty ? .failure(SessionTransportError.network) : snapshots.removeFirst()
        }()
        return try next.get()
    }

    func roomTicketEvents(sessionId: String, after: Int64, limit: Int) async throws -> RoomTicketEventsPage {
        let next: Result<RoomTicketEventsPage, Error> = {
            lock.lock()
            defer { lock.unlock() }
            eventCalls.append(after)
            return events.isEmpty ? .success(RoomTicketEventsPage(tickets: [], eventCount: 0, cursor: after)) : events.removeFirst()
        }()
        return try next.get()
    }
}

@MainActor
final class RoomTicketsCoordinatorTests: XCTestCase {
    private func makeCoordinator(_ transport: ScriptedTicketsTransport, onReauth: @escaping @MainActor () -> Void = {}) -> RoomTicketsCoordinator {
        RoomTicketsCoordinator(
            sessionId: "room_1",
            transport: transport,
            // Park the poll loop; tests drive refresh() directly.
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            onReauthenticationRequired: onReauth
        )
    }

    private func ticket(_ id: String, version: Int64 = 1, status: String = "open", body: String = "") -> RoomTicket {
        RoomTicket(id: id, title: "Ticket \(id)", body: body, status: status, version: version)
    }

    func test_the_board_loads_then_follows_the_feed() async {
        let transport = ScriptedTicketsTransport(
            snapshots: [.success(RoomTicketSnapshotPage(items: [ticket("a", body: "## Priority\nP1")], hasMore: false, cursor: 7))],
            events: [.success(RoomTicketEventsPage(tickets: [ticket("a", version: 2, status: "done"), ticket("b")], cursor: 9))]
        )
        let coordinator = makeCoordinator(transport)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.rows.map(\.id), ["a"])
        XCTAssertEqual(coordinator.state.rows.first?.priorityLabel, "P1")
        XCTAssertFalse(coordinator.state.isLoading)

        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.rows.map(\.id), ["b"], "a is done now, so it moved to Archived")
        XCTAssertEqual(coordinator.state.archivedCount, 1)
        XCTAssertEqual(transport.eventCalls.first, 7, "the feed resumes from the snapshot's first-page cursor")
    }

    func test_a_failed_poll_keeps_the_board_and_marks_it_stale() async {
        let transport = ScriptedTicketsTransport(
            snapshots: [.success(RoomTicketSnapshotPage(items: [ticket("a")], hasMore: false, cursor: 1))],
            events: [.failure(SessionTransportError.network), .success(RoomTicketEventsPage(tickets: [], eventCount: 0, cursor: 1))]
        )
        let coordinator = makeCoordinator(transport)
        await coordinator.refresh()
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.rows.map(\.id), ["a"])
        XCTAssertTrue(coordinator.state.isStale)
        XCTAssertNil(coordinator.state.failure)

        await coordinator.refresh()
        XCTAssertFalse(coordinator.state.isStale, "the next good poll clears the stale mark")
    }

    func test_denied_or_signed_out_stops_the_board() async {
        var asked = 0
        let denied = makeCoordinator(ScriptedTicketsTransport(snapshots: [.failure(SessionTransportError.accessDenied)]))
        await denied.refresh()
        XCTAssertEqual(denied.state.failure, .accessDenied)
        XCTAssertTrue(denied.state.rows.isEmpty)

        let signedOut = makeCoordinator(ScriptedTicketsTransport(snapshots: [.failure(SessionTransportError.reauthenticationRequired)])) {
            asked += 1
        }
        await signedOut.refresh()
        XCTAssertEqual(signedOut.state.failure, .reauthenticationRequired)
        XCTAssertEqual(asked, 1)
    }

    func test_search_and_archive_toggle_drive_the_list() async {
        let transport = ScriptedTicketsTransport(snapshots: [.success(RoomTicketSnapshotPage(
            items: [ticket("a"), ticket("b", status: "done")], hasMore: false, cursor: 1
        ))])
        let coordinator = makeCoordinator(transport)
        await coordinator.refresh()
        coordinator.send(.setShowsArchived(true))
        XCTAssertEqual(coordinator.state.rows.map(\.id), ["b"])
        coordinator.send(.search("Ticket a"))
        XCTAssertEqual(coordinator.state.rows.map(\.id), ["a"], "search covers both lists")
    }
}
