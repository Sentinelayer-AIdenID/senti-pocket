import Foundation
import XCTest
@testable import PocketUI

final class RoomTicketsPresentationTests: XCTestCase {
    private func input(
        _ id: String,
        status: String = "open",
        priority: Int? = nil,
        updated: String = "2026-10-28T10:00:00Z",
        title: String? = nil,
        body: String = ""
    ) -> RoomTicketInput {
        RoomTicketInput(id: id, title: title ?? "Ticket \(id)", body: body, status: status, updatedAt: updated, priority: priority)
    }

    func test_active_and_archived_split_with_counts() {
        let tickets = [input("a"), input("b", status: "done"), input("c", status: "blocked"), input("d", status: "done")]
        let active = RoomTicketsPresentationState(tickets: tickets)
        XCTAssertEqual(active.activeCount, 2)
        XCTAssertEqual(active.archivedCount, 2)
        XCTAssertEqual(Set(active.rows.map(\.id)), ["a", "c"])
        let archived = RoomTicketsPresentationState(tickets: tickets, showsArchived: true)
        XCTAssertEqual(Set(archived.rows.map(\.id)), ["b", "d"])
    }

    func test_rows_rank_by_priority_then_most_recent_change() {
        let state = RoomTicketsPresentationState(tickets: [
            input("none", updated: "2026-10-28T12:00:00Z"),
            input("p2-old", priority: 2, updated: "2026-10-28T08:00:00Z"),
            input("p0", priority: 0, updated: "2026-10-27T08:00:00Z"),
            input("p2-new", priority: 2, updated: "2026-10-28T09:00:00Z")
        ])
        XCTAssertEqual(state.rows.map(\.id), ["p0", "p2-new", "p2-old", "none"])
    }

    func test_search_spans_archived_tickets_and_matches_title_body_id_or_assignee() {
        let state = RoomTicketsPresentationState(tickets: [
            input("c0ffee08-aaa", title: "Parity checklist"),
            input("decade00-bbb", status: "done", title: "Sample agent", body: "Get the sample agent working"),
            input("zzz", title: "Unrelated")
        ], query: "sample")
        XCTAssertEqual(state.rows.map(\.id), ["decade00-bbb"], "a done ticket is found by search")
        XCTAssertEqual(RoomTicketsPresentationState(tickets: [input("c0ffee08-aaa")], query: "c0ff").rows.count, 1)
    }

    func test_labels_and_protected_failures() {
        let done = RoomTicketsPresentationState(tickets: [input("a", status: "done")], showsArchived: true)
        XCTAssertEqual(done.rows.first?.statusLabel, "Done · unverified")
        XCTAssertEqual(RoomTicketsPresentationState(tickets: [input("b", status: "in_review")]).rows.first?.statusLabel, "In review")
        XCTAssertEqual(RoomTicketRow.displayName("human-mrrcarter"), "mrrcarter")

        let denied = RoomTicketsPresentationState(tickets: [input("a")], failure: .accessDenied)
        XCTAssertTrue(denied.rows.isEmpty)
        XCTAssertEqual(denied.activeCount, 0)
    }

    func test_an_open_ticket_with_a_decision_section_is_marked_until_done() {
        let ask = "## Decision\nQuestion: Ship it?\nOptions: Yes · No"
        let state = RoomTicketsPresentationState(tickets: [
            input("asks", body: ask),
            input("plain", body: "## Intent\nNothing to decide")
        ])
        XCTAssertEqual(state.rows.first { $0.id == "asks" }?.decision?.question, "Ship it?")
        XCTAssertNil(state.rows.first { $0.id == "plain" }?.decision)
        let done = RoomTicketsPresentationState(tickets: [input("asks", status: "done", body: ask)], showsArchived: true)
        XCTAssertNil(done.rows.first?.decision, "a done ticket no longer asks")
    }
}
