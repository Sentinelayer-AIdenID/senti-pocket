import Foundation
import PocketContracts
import XCTest
@testable import PocketSyncClient

/// Carter, 10-31: the room list shows who is online and your unread messages, and opening a room with unread messages
/// takes you to the first of them, like Discord. These pin where a room opens and how reading is told to the server.
final class RoomOpeningTests: XCTestCase {
    private func mark(_ count: Int, first: Int64?, lastRead: Int64? = nil) -> RoomReadMark {
        RoomReadMark(unreadCount: count, firstUnreadSequenceId: first, lastReadSequenceId: lastRead)
    }

    func test_a_room_opens_at_its_first_unread_only_when_something_is_unread() {
        XCTAssertEqual(mark(3, first: 40).opensAt, 40)
        XCTAssertNil(mark(0, first: 40).opensAt, "nothing unread")
        XCTAssertNil(mark(3, first: nil).opensAt, "unread, but the server did not say where")
        XCTAssertNil(mark(3, first: 0).opensAt, "not a message")
        XCTAssertNil(mark(3, first: 40, lastRead: 40).opensAt, "a first unread at what you have read is a stale count")
        XCTAssertEqual(mark(3, first: 41, lastRead: 40).opensAt, 41)
    }

    func test_the_first_unread_among_the_loaded_rows_opens_at_its_line() {
        XCTAssertEqual(RoomOpening.choose(mark: mark(3, first: 120), focus: nil, oldestLoaded: 100, newestLoaded: 150,
                                          hasMoreOlder: true), .unreadLine(120))
        XCTAssertEqual(RoomOpening.choose(mark: mark(3, first: 100), focus: nil, oldestLoaded: 100, newestLoaded: 150,
                                          hasMoreOlder: true), .unreadLine(100), "the oldest loaded row itself")
    }

    func test_a_first_unread_further_back_than_the_newest_page_is_sought_further_back() {
        XCTAssertEqual(RoomOpening.choose(mark: mark(100, first: 40), focus: nil, oldestLoaded: 100, newestLoaded: 150,
                                          hasMoreOlder: true), .unreadFurtherBack(40))
        XCTAssertEqual(RoomOpening.choose(mark: mark(100, first: 40), focus: nil, oldestLoaded: 100, newestLoaded: 150,
                                          hasMoreOlder: false), .unreadLine(40),
                       "the page reaches the start of the room: the line goes before its first row")
    }

    func test_otherwise_the_room_opens_at_its_latest_as_before() {
        XCTAssertEqual(RoomOpening.choose(mark: nil, focus: nil, oldestLoaded: 100, newestLoaded: 150, hasMoreOlder: true),
                       .latest)
        XCTAssertEqual(RoomOpening.choose(mark: mark(0, first: nil), focus: nil, oldestLoaded: 100, newestLoaded: 150,
                                          hasMoreOlder: true), .latest)
        XCTAssertEqual(RoomOpening.choose(mark: mark(2, first: 160), focus: nil, oldestLoaded: 100, newestLoaded: 150,
                                          hasMoreOlder: true), .latest, "newer than any message shown: a notice")
        XCTAssertEqual(RoomOpening.choose(mark: mark(2, first: 40), focus: nil, oldestLoaded: nil, newestLoaded: nil,
                                          hasMoreOlder: false), .latest, "an empty room")
    }

    func test_a_link_decides_where_the_room_opens_and_loads_nothing_for_the_line() {
        XCTAssertEqual(RoomOpening.choose(mark: mark(100, first: 40), focus: 140, oldestLoaded: 100, newestLoaded: 150,
                                          hasMoreOlder: true), .latest)
        XCTAssertEqual(RoomOpening.choose(mark: mark(3, first: 120), focus: 140, oldestLoaded: 100, newestLoaded: 150,
                                          hasMoreOlder: true), .unreadLine(120), "the line still shows where it is loaded")
    }
}

final class RoomReadCursorTests: XCTestCase {
    func test_reading_only_moves_forward() {
        var cursor = RoomReadCursor(confirmed: 10)
        XCTAssertFalse(cursor.read(through: 9), "behind what the server holds")
        XCTAssertFalse(cursor.read(through: 10))
        XCTAssertTrue(cursor.read(through: 12))
        XCTAssertFalse(cursor.read(through: 11), "behind what is waiting")
        XCTAssertEqual(cursor.next(at: 0), .send(12))
        XCTAssertFalse(cursor.read(through: 12), "behind what is on its way")
        cursor.sent(12)
        XCTAssertEqual(cursor.confirmed, 12)
        XCTAssertFalse(cursor.read(through: 12))
        XCTAssertEqual(cursor.next(at: 10), .idle)
    }

    func test_one_request_every_interval_and_the_furthest_read_goes() {
        XCTAssertEqual(RoomReadCursor.interval, 1.5, "as the web sends them")
        let interval = RoomReadCursor.interval
        var cursor = RoomReadCursor()
        cursor.read(through: 5)
        XCTAssertEqual(cursor.next(at: 100), .send(5), "the first read goes at once")
        cursor.sent(5)
        cursor.read(through: 7)
        cursor.read(through: 9)
        XCTAssertEqual(cursor.next(at: 100.5), .wait(interval - 0.5))
        guard case .wait(let seconds) = cursor.next(at: 100 + interval - 0.1) else { return XCTFail("inside the interval") }
        XCTAssertEqual(seconds, 0.1, accuracy: 1e-9)
        XCTAssertEqual(cursor.next(at: 100 + interval), .send(9), "the two reads in between are one request, the furthest")
        cursor.sent(9)
        XCTAssertEqual(cursor.next(at: 200), .idle)
    }

    func test_a_request_on_its_way_holds_the_next_until_it_answers() {
        var cursor = RoomReadCursor()
        cursor.read(through: 5)
        XCTAssertEqual(cursor.next(at: 0), .send(5))
        cursor.read(through: 8)
        XCTAssertEqual(cursor.next(at: 10), .idle, "one at a time")
        cursor.sent(5)
        XCTAssertEqual(cursor.next(at: 10), .send(8))
    }

    func test_a_failure_worth_retrying_waits_longer_each_time_and_any_other_is_dropped() {
        let interval = RoomReadCursor.interval
        var cursor = RoomReadCursor()
        cursor.read(through: 5)
        XCTAssertEqual(cursor.next(at: 0), .send(5))
        cursor.failed(5, retryable: true)
        XCTAssertEqual(cursor.pending, 5)
        XCTAssertEqual(cursor.next(at: interval), .wait(interval), "twice the interval after one failure")
        XCTAssertEqual(cursor.next(at: 2 * interval), .send(5))
        cursor.failed(5, retryable: true)
        XCTAssertEqual(cursor.next(at: 5 * interval), .wait(interval), "four times after two")
        XCTAssertEqual(cursor.next(at: 6 * interval), .send(5))
        cursor.sent(5)
        cursor.read(through: 6)
        XCTAssertEqual(cursor.next(at: 7 * interval), .send(6), "a success starts the waits afresh")

        cursor.failed(6, retryable: false)
        XCTAssertNil(cursor.pending, "refused: never sent again")
        XCTAssertEqual(cursor.next(at: 100), .idle)
        XCTAssertTrue(cursor.read(through: 7), "a further read still goes")
    }

    func test_the_longest_wait_after_failures_is_a_minute() {
        var cursor = RoomReadCursor()
        var now: TimeInterval = 0
        cursor.read(through: 5)
        for _ in 0..<10 {
            guard case .send = cursor.next(at: now) else { return XCTFail("expected a send at \(now)") }
            cursor.failed(5, retryable: true)
            if case .wait(let seconds) = cursor.next(at: now) { now += seconds }
        }
        XCTAssertEqual(cursor.next(at: now), .send(5))
        cursor.failed(5, retryable: true)
        XCTAssertEqual(cursor.next(at: now), .wait(RoomReadCursor.longestWait))
    }

    func test_a_failure_behind_what_is_already_further_is_not_sent_again() {
        var cursor = RoomReadCursor()
        cursor.read(through: 5)
        XCTAssertEqual(cursor.next(at: 0), .send(5))
        cursor.read(through: 9)
        XCTAssertEqual(cursor.flush(at: 1), 9)
        cursor.failed(5, retryable: true)
        XCTAssertNil(cursor.pending, "9 is on its way")
        cursor.sent(9)
        XCTAssertEqual(cursor.furthest, 9)
    }

    func test_closing_the_room_sends_what_was_read_whatever_the_interval() {
        var cursor = RoomReadCursor()
        XCTAssertNil(cursor.flush(at: 0), "nothing read")
        cursor.read(through: 5)
        XCTAssertEqual(cursor.next(at: 0), .send(5))
        cursor.read(through: 8)
        XCTAssertEqual(cursor.flush(at: 0.1), 8, "inside the interval, with 5 on its way")
        XCTAssertNil(cursor.flush(at: 0.2), "and only once")
    }

    func test_a_clock_set_back_never_parks_the_send() {
        var cursor = RoomReadCursor()
        cursor.read(through: 5)
        XCTAssertEqual(cursor.next(at: 1_000), .send(5))
        cursor.sent(5)
        cursor.read(through: 6)
        XCTAssertEqual(cursor.next(at: 400), .send(6))
    }
}

final class RoomUnreadLineTests: XCTestCase {
    private func message(_ seq: Int64, author: String = "cobalt-warden") -> RoomMessage {
        RoomMessage(id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: author, authorName: author,
                    isHuman: RoomMessage.isHumanAuthor(author), text: "hi", timestamp: "2026-10-31T14:00:00Z")
    }

    /// Discord keeps the line where you opened the room while you are in it: reaching the bottom keeps it, and is
    /// news only when arrivals were unread.
    func test_the_line_the_room_opened_at_stays_at_the_bottom() {
        var unread = RoomUnreadState()
        unread.opened(at: 40)
        XCTAssertEqual(unread.dividerSequence, 40)
        XCTAssertFalse(unread.readerReachedBottom(), "nothing changed")
        XCTAssertEqual(unread.dividerSequence, 40)

        unread.noteArrivals([message(60)], readerIsAtBottom: false, selfAuthorIds: [])
        XCTAssertEqual(unread.unreadCount, 1)
        XCTAssertEqual(unread.dividerSequence, 40, "arrivals never move the line up past where you opened")
        XCTAssertTrue(unread.readerReachedBottom())
        XCTAssertEqual(unread.unreadCount, 0)
        XCTAssertEqual(unread.dividerSequence, 40)
    }

    func test_a_send_takes_every_line_away() {
        var unread = RoomUnreadState()
        unread.opened(at: 40)
        unread.noteArrivals([message(60)], readerIsAtBottom: false, selfAuthorIds: [])
        unread.caughtUp()
        XCTAssertNil(unread.dividerSequence)
        XCTAssertEqual(unread.unreadCount, 0)
    }
}

/// The room list's new fields (sentinelayer-api forge/roomlist-presence-unread): counts to show, decoded so that a
/// missing or malformed one shows nothing and never fails the list.
final class SessionListBadgesWireTests: XCTestCase {
    private func row(_ extra: String) -> String {
        """
        {"sessionId":"room-a","status":"active","archiveStatus":"active","visibility":"private",
        "membershipRole":"owner","title":"Room A","summaryText":null,"summaryGeneratedAt":null,"summaryModel":null,
        "agentCount":2,"eventCount":41,"totalCostUsd":0,"createdAt":null,"lastActivityAt":null,"expiresAt":null,
        "killedAt":null,"templateName":null,"codebasePath":null,"s3ArchivePath":null\(extra)}
        """
    }

    private func page(_ rows: [String]) throws -> SessionListPage {
        let json = #"{"sessions":["# + rows.joined(separator: ",")
            + #"],"count":\#(rows.count),"include_archived":false,"next_cursor":null,"has_more":false}"#
        return try JSONDecoder().decode(SessionListPage.self, from: Data(json.utf8))
    }

    func test_who_is_online_and_what_is_unread_decode() throws {
        let session = try page([row(#","online":{"humans":3,"agents":2},"lastReadSequenceId":4810,"#
            + #""unread":{"count":5,"firstUnreadSequenceId":4811}"#)]).sessions[0]
        XCTAssertEqual(session.online, SessionOnlineCounts(humans: 3, agents: 2))
        XCTAssertEqual(session.unread, SessionUnreadSummary(count: 5, firstUnreadSequenceId: 4811))
        XCTAssertEqual(session.lastReadSequenceId, 4810)
    }

    func test_an_older_server_without_them_shows_nothing() throws {
        let session = try page([row("")]).sessions[0]
        XCTAssertNil(session.online)
        XCTAssertNil(session.unread)
        XCTAssertNil(session.lastReadSequenceId)
        let nulls = try page([row(#","online":null,"unread":null,"lastReadSequenceId":null"#)]).sessions[0]
        XCTAssertNil(nulls.online)
        XCTAssertNil(nulls.unread)
        XCTAssertNil(nulls.lastReadSequenceId)
    }

    func test_malformed_counts_show_nothing_and_never_fail_the_list() throws {
        let sessions = try page([
            row(#","online":"three","unread":5,"lastReadSequenceId":"4810""#),
            row(#","online":{"humans":-2,"agents":"x"},"unread":{"count":"many","firstUnreadSequenceId":-7}"#)
                .replacingOccurrences(of: "room-a", with: "room-b")
        ]).sessions
        XCTAssertEqual(sessions.count, 2, "the list still shows")
        XCTAssertEqual(sessions[0].online, SessionOnlineCounts(humans: 0, agents: 0))
        XCTAssertEqual(sessions[0].unread, SessionUnreadSummary(count: 0, firstUnreadSequenceId: nil))
        XCTAssertNil(sessions[0].lastReadSequenceId)
        XCTAssertEqual(sessions[1].online, SessionOnlineCounts(humans: 0, agents: 0))
        XCTAssertEqual(sessions[1].unread, SessionUnreadSummary(count: 0, firstUnreadSequenceId: nil))
    }

    func test_the_rooms_own_fields_still_fail_the_list_when_missing() {
        let missingCount = row("").replacingOccurrences(of: #""agentCount":2,"#, with: "")
        XCTAssertThrowsError(try page([missingCount]), "a key the route guarantees")
    }
}
