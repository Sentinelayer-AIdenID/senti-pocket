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

    /// Carter, 11-05: real steps, not a percentage. The row gets the server's step as it came, with since when it has
    /// not moved; a ticket with only the old estimate shows its status alone.
    func test_a_row_gets_the_servers_step_and_never_the_old_estimate() async {
        var stepped = ticket("s", status: "in_review")
        stepped.step = RoomTicketStep(index: 2, count: 5, name: .inReview, stalledSince: "2026-11-05T19:10:00Z",
                                      stalledReason: .waitingOnReview, lastHolder: "forge-box-7",
                                      waitingOn: "human-alex")
        stepped.progress = RoomTicketProgress(value: 0.62, basis: "b", at: "a")
        var estimated = ticket("e", status: "working")
        estimated.progress = RoomTicketProgress(value: 0.45, basis: "b", at: "a")
        var notStarted = ticket("n", status: "assigned")
        notStarted.step = RoomTicketStep(index: 0, count: 5, name: .notStarted)
        // Ids strictly ascending, as the API pages them: the board refuses a snapshot out of order.
        let transport = ScriptedTicketsTransport(
            snapshots: [.success(RoomTicketSnapshotPage(items: [estimated, notStarted, stepped], hasMore: false, cursor: 1))]
        )
        let coordinator = makeCoordinator(transport)
        await coordinator.refresh()
        let rows = Dictionary(uniqueKeysWithValues: coordinator.state.rows.map { ($0.id, $0) })
        XCTAssertEqual(Set(rows.keys), ["e", "n", "s"], "the board loaded: every ticket has a row")
        XCTAssertEqual(rows["s"]?.step, RoomTicketInput.Step(
            index: 2, count: 5, name: "in_review", stalledSince: Date(timeIntervalSince1970: 1_793_905_800),
            stalledReason: "waiting_on_review", lastHolder: "forge-box-7", waitingOn: "human-alex"
        ), "the server's words, as they came")
        XCTAssertEqual(rows["s"]?.stepStrip?.segments, [.done, .current, .ahead, .ahead, .ahead])
        XCTAssertEqual(rows["s"]?.stepStrip?.label, "In review")
        XCTAssertNil(rows["e"]?.step, "only the old estimate: no step")
        XCTAssertNil(rows["e"]?.stepStrip, "and no bar: its status alone")
        XCTAssertEqual(rows["n"]?.step, RoomTicketInput.Step(index: 0, count: 5, name: "not_started"),
                       "index 0 as it came")
        XCTAssertEqual(rows["n"]?.stepStrip?.segments, [.ahead, .ahead, .ahead, .ahead, .ahead])
        XCTAssertEqual(rows["n"]?.stepStrip?.label, "Not started")
    }

    /// Tickets name people as the room does (warden, 11-05): by user id, their display name, else their login; by
    /// `human-<login>`, their display name. Someone with neither has no name, so a ticket never shows their id.
    func test_ticket_names_come_from_the_directory_by_account_and_by_login() {
        let names = RoomTicketsCoordinator.ticketNames([
            RoomDirectoryMember(userId: "00000000-0000-4000-8000-00000000AAAA", displayName: "Priya", githubLogin: "priya-dev"),
            RoomDirectoryMember(userId: "00000000-0000-4000-8000-00000000bbbb", displayName: nil, githubLogin: "dana"),
            RoomDirectoryMember(userId: "00000000-0000-4000-8000-00000000cccc", displayName: "", githubLogin: nil)
        ])
        XCTAssertEqual(names, [
            "00000000-0000-4000-8000-00000000aaaa": "Priya",
            "human-priya-dev": "Priya",
            "00000000-0000-4000-8000-00000000bbbb": "dana"
        ])
        XCTAssertEqual(RoomTicketRow.actorLabel("human-g.0000000000004000800000000000aaaa", viewerId: nil, names: names),
                       "Priya")
        XCTAssertEqual(RoomTicketRow.actorLabel("human-g.000000000000400080000000000000cc", viewerId: nil, names: names),
                       "a person", "a member with no name is not shown by id")
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
