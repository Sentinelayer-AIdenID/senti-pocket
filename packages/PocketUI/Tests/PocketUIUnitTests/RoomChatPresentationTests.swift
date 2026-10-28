import Foundation
import XCTest
@testable import PocketUI

final class RoomChatPresentationTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func input(
        _ seq: Int64,
        author: String = "cobalt-warden",
        at timestamp: String = "2026-10-20T10:00:00.000000+00:00",
        kind: RoomChatMessageInput.Kind = .message,
        text: String = "hello"
    ) -> RoomChatMessageInput {
        RoomChatMessageInput(
            id: "evt-\(seq)",
            sequenceId: seq,
            kind: kind,
            authorId: author,
            authorName: author,
            isHuman: author.hasPrefix("human-"),
            text: text,
            timestamp: timestamp
        )
    }

    private func messageRows(_ state: RoomChatPresentationState) -> [RoomChatMessageRow] {
        state.rows.compactMap { if case .message(let row) = $0 { return row } else { return nil } }
    }

    func test_the_api_timestamp_format_parses_so_rows_get_times_and_days() {
        let state = RoomChatPresentationState(
            sessionId: "room",
            title: "Room",
            messages: [input(1, at: "2026-10-28T18:33:15.681000+00:00")],
            calendar: utc
        )
        XCTAssertNotNil(messageRows(state).first?.date, "microsecond ISO timestamps from the API must parse")
        XCTAssertEqual(state.rows.count, 2, "one day header and one message")
    }

    func test_rows_are_ordered_and_same_author_runs_share_one_header() {
        let state = RoomChatPresentationState(
            sessionId: "room",
            title: "Room",
            messages: [
                input(3, at: "2026-10-20T10:02:00Z"),
                input(1, at: "2026-10-20T10:00:00Z"),
                input(2, at: "2026-10-20T10:01:00Z"),
                input(4, author: "human-mrrcarter", at: "2026-10-20T10:03:00Z"),
                input(5, author: "human-mrrcarter", at: "2026-10-20T10:20:00Z")
            ],
            calendar: utc
        )
        let rows = messageRows(state)
        XCTAssertEqual(rows.map(\.sequenceId), [1, 2, 3, 4, 5])
        XCTAssertEqual(rows.map(\.showsHeader), [true, false, false, true, true],
                       "a new author, or a gap of five minutes or more, repeats the header")
    }

    func test_a_new_day_inserts_one_header_and_repeats_the_author() {
        let state = RoomChatPresentationState(
            sessionId: "room",
            title: "Room",
            messages: [
                input(1, at: "2026-10-20T23:58:00Z"),
                input(2, at: "2026-10-21T00:01:00Z"),
                input(3, at: "2026-10-21T00:02:00Z")
            ],
            calendar: utc
        )
        let headers = state.rows.filter { if case .dayHeader = $0 { return true } else { return false } }
        XCTAssertEqual(headers.count, 2)
        XCTAssertEqual(messageRows(state).map(\.showsHeader), [true, true, false])
    }

    func test_the_unread_divider_sits_before_the_first_unseen_row_once() {
        let state = RoomChatPresentationState(
            sessionId: "room",
            title: "Room",
            messages: [input(1), input(5), input(9)],
            unreadDividerSequence: 4,
            unreadCount: 2,
            calendar: utc
        )
        let ids = state.rows.map(\.id)
        let dividerIndex = try? XCTUnwrap(ids.firstIndex(of: RoomChatRow.unreadDivider.id))
        XCTAssertEqual(ids.filter { $0 == RoomChatRow.unreadDivider.id }.count, 1)
        XCTAssertEqual(dividerIndex.map { ids[$0 + 1] }, "msg:evt-5")
        XCTAssertEqual(messageRows(state).last?.showsHeader, false, "the run after the divider still groups")
        XCTAssertEqual(messageRows(state)[1].showsHeader, true, "the first unseen row repeats the author")
    }

    func test_own_rows_are_marked_and_protected_failures_render_nothing() {
        let own = RoomChatPresentationState(
            sessionId: "room",
            title: "Room",
            messages: [input(1, author: "human-mrrcarter")],
            ownAuthorIds: ["human-mrrcarter"],
            calendar: utc
        )
        XCTAssertEqual(messageRows(own).first?.isOwn, true)

        let denied = RoomChatPresentationState(
            sessionId: "room",
            title: "Room",
            messages: [input(1)],
            failure: .accessDenied,
            calendar: utc
        )
        XCTAssertTrue(denied.rows.isEmpty)
        XCTAssertTrue(denied.isEmpty)

        let offline = RoomChatPresentationState(
            sessionId: "room",
            title: "Room",
            messages: [input(1)],
            failure: .network,
            calendar: utc
        )
        XCTAssertFalse(offline.isEmpty, "a network failure keeps the rows already loaded")
    }

    func test_link_policy_only_allows_web_links_to_a_real_host() {
        XCTAssertTrue(RoomLinkPolicy.isAllowed(URL(string: "https://github.com/a/b/pull/1")!))
        XCTAssertTrue(RoomLinkPolicy.isAllowed(URL(string: "http://example.com")!))
        XCTAssertFalse(RoomLinkPolicy.isAllowed(URL(string: "tel:5551234")!))
        XCTAssertFalse(RoomLinkPolicy.isAllowed(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(RoomLinkPolicy.isAllowed(URL(string: "/dashboard/sessions/x")!))
        XCTAssertFalse(RoomLinkPolicy.isAllowed(URL(string: "https://user:pw@example.com")!))
    }

    #if canImport(SwiftUI)
    func test_chat_text_keeps_safe_links_and_disarms_the_rest() {
        let text = RoomChatText.attributed("see [pr](https://github.com/a/b/pull/1) or [call](tel:5551234) **now**")
        let links = text.runs.compactMap { $0.link }
        XCTAssertEqual(links, [URL(string: "https://github.com/a/b/pull/1")!])
        XCTAssertTrue(String(text.characters).contains("call"), "a disarmed link keeps its visible text")
        XCTAssertTrue(String(text.characters).contains("now"))
    }
    #endif
}
