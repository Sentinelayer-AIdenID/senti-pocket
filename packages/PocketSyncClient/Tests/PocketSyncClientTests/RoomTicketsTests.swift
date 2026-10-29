import Foundation
import PocketContracts
import XCTest
@testable import PocketSyncClient

final class RoomTicketsTests: XCTestCase {
    private func ticket(_ id: String, version: Int64 = 1, status: String = "open", title: String? = nil) -> RoomTicket {
        RoomTicket(id: id, title: title ?? "Ticket \(id)", status: status, version: version)
    }

    func test_priority_comes_from_the_keepers_priority_section_and_ignores_code() {
        XCTAssertEqual(RoomTicket.priority(inBody: "## Intent\nx\n\n## Priority\nP1\n\n## Source\ny"), 1)
        XCTAssertEqual(RoomTicket.priority(inBody: "## Priority\n\nP0 (waits on Carter's decision)"), 0)
        XCTAssertNil(RoomTicket.priority(inBody: "## Priority\n## Next\nP1"), "a new heading ends the section")
        XCTAssertNil(RoomTicket.priority(inBody: "```\n## Priority\nP0\n```"), "fenced code is not the body's priority")
        XCTAssertNil(RoomTicket.priority(inBody: "## Priority\nhigh"))
        XCTAssertNil(RoomTicket.priority(inBody: "no sections"))
    }

    func test_snapshot_and_event_pages_decode_from_the_api_shapes() throws {
        let snapshot = try JSONDecoder().decode(RoomTicketSnapshotPage.self, from: Data("""
        {"items":[{"id":"a1","title":"One","body":"## Priority\\nP2","status":"assigned","createdBy":"human-mrrcarter",
          "assignee":"sol-max","createdAt":"2026-10-28T10:00:00+00:00","updatedAt":"2026-10-28T11:00:00+00:00",
          "version":3,"sourceMessage":{"sequenceId":2345},"completion":{"verified":false},"unaccepted":true}],
         "hasMore":false,"nextAfterId":null,"cursor":10293}
        """.utf8))
        XCTAssertEqual(snapshot.cursor, 10293)
        let first = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(first.priority, 2)
        XCTAssertEqual(first.assignee, "sol-max")
        XCTAssertEqual(first.sourceSequenceId, 2345)
        XCTAssertEqual(first.version, 3)
        XCTAssertTrue(first.unaccepted)

        let events = try JSONDecoder().decode(RoomTicketEventsPage.self, from: Data("""
        {"events":[{"id":"e1","cursor":10294,"ticketId":"a1","ticketVersion":4,"kind":"status_changed",
          "ticket":{"id":"a1","title":"One","status":"done","version":4}},
          {"id":"e2","cursor":10295,"ticketId":"b2","ticketVersion":1,"kind":"created","ticket":null}],
         "cursor":10295}
        """.utf8))
        XCTAssertEqual(events.tickets.map(\.status), ["done"])
        XCTAssertEqual(events.eventCount, 2)
        XCTAssertEqual(events.cursor, 10295)
    }

    func test_a_lease_decodes_holder_only_and_reads_live_by_its_expiry() throws {
        let page = try JSONDecoder().decode(RoomTicketSnapshotPage.self, from: Data("""
        {"items":[{"id":"a1","title":"Leased","status":"working","version":5,
          "lease":{"holderKind":"human","holder":"6f1c2b9e-0000-4000-8000-00000000000a","fence":3,
                   "expiresAt":"2026-10-29T09:15:00.123456+00:00","live":true}},
          {"id":"b2","title":"Free","status":"open","version":1,"lease":null}],
         "hasMore":false,"cursor":7}
        """.utf8))
        let leased = try XCTUnwrap(page.items.first { $0.id == "a1" }?.lease)
        XCTAssertEqual(leased.holder, "6f1c2b9e-0000-4000-8000-00000000000a")
        XCTAssertEqual(leased.holderKind, "human")
        XCTAssertEqual(leased.fence, 3)
        XCTAssertNil(page.items.first { $0.id == "b2" }?.lease)

        let expiry = try XCTUnwrap(ParsedSessionTimestamp("2026-10-29T09:15:00.123456+00:00").date)
        XCTAssertTrue(leased.isLive(at: expiry.addingTimeInterval(-1)))
        XCTAssertFalse(leased.isLive(at: expiry.addingTimeInterval(1)), "the expiry decides, not the stale read-time flag")
        // A ticket carried by a stored event has no read-time flag; without a parsable expiry it is not live.
        XCTAssertFalse(RoomTicketLease(holder: "x", expiresAt: nil).isLive(at: Date()))
        XCTAssertTrue(RoomTicketLease(holder: "x", expiresAt: "not a time", liveWhenRead: true).isLive(at: Date()))
    }

    func test_killed_is_archived_like_done() {
        XCTAssertTrue(ticket("a", status: "done").isArchived)
        XCTAssertTrue(ticket("b", status: "killed").isArchived, "the API's other final status")
        for status in ["open", "assigned", "accepted", "working", "in_review", "blocked"] {
            XCTAssertFalse(ticket("c", status: status).isArchived, status)
        }
    }

    func test_baseline_pages_to_the_end_and_keeps_the_first_cursor() async throws {
        var calls: [String?] = []
        let board = try await RoomTicketBoard.loadBaseline { afterId in
            calls.append(afterId)
            if afterId == nil {
                return RoomTicketSnapshotPage(items: [self.ticket("a"), self.ticket("b")], hasMore: true, nextAfterId: "b", cursor: 50)
            }
            return RoomTicketSnapshotPage(items: [self.ticket("c")], hasMore: false)
        }
        XCTAssertEqual(calls, [nil, "b"])
        XCTAssertEqual(board.cursor, 50)
        XCTAssertEqual(Set(board.tickets.keys), ["a", "b", "c"])
    }

    func test_baseline_refuses_a_feed_that_could_skip_or_repeat_tickets() async {
        let malformed: [[RoomTicketSnapshotPage]] = [
            [RoomTicketSnapshotPage(items: [ticket("a")], hasMore: false, cursor: nil)],            // no first cursor
            [RoomTicketSnapshotPage(items: [ticket("b"), ticket("a")], hasMore: false, cursor: 1)], // not ascending
            [RoomTicketSnapshotPage(items: [ticket("a"), ticket("b")], hasMore: true, nextAfterId: "z", cursor: 1)], // jumps
            [RoomTicketSnapshotPage(items: [], hasMore: true, nextAfterId: "a", cursor: 1)]         // empty yet more
        ]
        for pages in malformed {
            var remaining = pages
            do {
                _ = try await RoomTicketBoard.loadBaseline { _ in remaining.removeFirst() }
                XCTFail("expected a malformed-feed refusal")
            } catch {
                XCTAssertEqual(error as? SessionTransportError, .invalidData)
            }
        }
    }

    func test_catch_up_upserts_by_version_and_is_atomic() async throws {
        let base = try await RoomTicketBoard.loadBaseline { _ in
            RoomTicketSnapshotPage(items: [self.ticket("a", version: 2)], hasMore: false, cursor: 100)
        }

        let (next, changed) = try await base.caughtUp { after in
            switch after {
            case 100: return RoomTicketEventsPage(tickets: [self.ticket("a", version: 1, status: "stale"), self.ticket("b")], cursor: 102)
            default: return RoomTicketEventsPage(tickets: [], eventCount: 0, cursor: after)
            }
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(next.cursor, 102)
        XCTAssertEqual(next.tickets["a"]?.status, "open", "an older version never regresses a newer row")
        XCTAssertEqual(next.tickets["b"]?.title, "Ticket b")

        do {
            _ = try await base.caughtUp { after in
                if after == 100 { return RoomTicketEventsPage(tickets: [self.ticket("c")], cursor: 101) }
                throw SessionTransportError.network
            }
            XCTFail("expected the second page to fail")
        } catch {
            XCTAssertEqual(base.cursor, 100, "a failed catch-up leaves the committed board untouched")
            XCTAssertNil(base.tickets["c"])
        }
    }
}
