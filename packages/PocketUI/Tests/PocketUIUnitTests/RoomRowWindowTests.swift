import XCTest
@testable import PocketUI

/// The rows the room's list holds from iOS 18 (`RoomRowWindow`): the newest 80 as the room opens, 40 more as the reader
/// reaches either end, never more than 160, and kept by its messages, so rows loading, arriving or taken away leave the
/// reader on the same messages.
final class RoomRowWindowTests: XCTestCase {
    private struct Row: RoomWindowRow {
        let windowId: String
        let windowSequence: Int64?

        static func message(_ sequence: Int64) -> Row { Row(windowId: "m\(sequence)", windowSequence: sequence) }
        static func day(_ name: String) -> Row { Row(windowId: "day:\(name)", windowSequence: nil) }
        static func reply(_ name: String) -> Row { Row(windowId: "reply:\(name)", windowSequence: nil) }
        static let line = Row(windowId: "unread-divider", windowSequence: nil)
    }

    /// Messages with sequences `range`, one row each.
    private func messages(_ range: ClosedRange<Int64>) -> [Row] { range.map(Row.message) }

    private func ids(_ rows: [Row], _ range: Range<Int>) -> [String] { rows[range].map(\.windowId) }

    // MARK: - Opening

    func test_a_room_opens_holding_its_newest_eighty_rows_and_holds_them_by_their_messages() {
        let rows = messages(1...300)
        let opening = RoomRowWindow()
        XCTAssertFalse(opening.isHeld)
        XCTAssertEqual(opening.range(in: rows), 220..<300)
        let held = opening.held(in: rows)
        XCTAssertTrue(held.isHeld)
        XCTAssertEqual(held.range(in: rows), 220..<300, "held, it holds the same rows")
        XCTAssertTrue(held.reachesNewest(in: rows))
        XCTAssertEqual(RoomRowWindow().range(in: [Row]()), 0..<0, "a room with no rows holds none")
    }

    func test_a_room_shorter_than_the_window_holds_all_of_it() {
        let rows = [Row.day("mon")] + messages(1...30)
        XCTAssertEqual(RoomRowWindow().held(in: rows).range(in: rows), 0..<31, "with its first day")
    }

    // MARK: - Arrivals

    func test_arrivals_join_a_held_window_and_its_first_rows_stay() {
        let held = RoomRowWindow().held(in: messages(1...300))
        let after = messages(1...310)
        XCTAssertEqual(held.range(in: after), 220..<310, "nothing above the reader is let go")
        XCTAssertTrue(held.reachesNewest(in: after))
        XCTAssertFalse(held.isFull(in: after))
    }

    func test_a_window_grown_to_the_most_keeps_its_first_rows_and_the_newest_wait_below() {
        let held = RoomRowWindow().held(in: messages(1...300))
        let after = messages(1...400)
        XCTAssertEqual(held.range(in: after), 220..<380, "160 rows at most, from the same first message")
        XCTAssertTrue(held.isFull(in: after))
        XCTAssertFalse(held.reachesNewest(in: after))
    }

    // MARK: - Paging

    func test_older_shows_forty_more_above_and_keeps_the_reader_on_their_first_message() throws {
        let rows = messages(1...300)
        let held = RoomRowWindow().held(in: rows)
        let page = try XCTUnwrap(held.older(in: rows))
        XCTAssertEqual(page.window.range(in: rows), 180..<300)
        XCTAssertEqual(page.keep, "m221", "the message that was first stays where it was on screen")
        XCTAssertTrue(page.window.reachesNewest(in: rows), "nothing let go below yet")
    }

    func test_older_lets_go_of_the_bottom_past_the_most_and_the_newest_wait_below() throws {
        let rows = messages(1...300)
        var window = RoomRowWindow().held(in: rows)
        for _ in 0..<3 { window = try XCTUnwrap(window.older(in: rows)).window }
        XCTAssertEqual(window.range(in: rows), 100..<260, "160 rows, the bottom 40 let go")
        XCTAssertFalse(window.reachesNewest(in: rows))
        XCTAssertFalse(window.isFull(in: rows), "short of the newest by its own last message, not grown past the most")
        XCTAssertEqual(window.range(in: messages(1...320)), 100..<260, "arrivals do not join a window short of the newest")
    }

    func test_older_is_nil_at_the_rooms_first_row() {
        let rows = messages(1...50)
        XCTAssertNil(RoomRowWindow().held(in: rows).older(in: rows))
    }

    func test_newer_adds_below_moving_nothing_until_the_top_is_let_go() throws {
        let rows = messages(1...300)
        let top = RoomRowWindow.holding(0..<80, of: rows)
        XCTAssertEqual(top.range(in: rows), 0..<80)
        let page = try XCTUnwrap(top.newer(in: rows))
        XCTAssertEqual(page.window.range(in: rows), 0..<120)
        XCTAssertNil(page.keep, "rows added below move nothing on screen")

        let short = RoomRowWindow.holding(100..<260, of: rows)
        let down = try XCTUnwrap(short.newer(in: rows))
        XCTAssertEqual(down.window.range(in: rows), 140..<300, "the top let go past 160")
        XCTAssertEqual(down.keep, "m260", "the reader stays on the last message they had")
        XCTAssertTrue(down.window.reachesNewest(in: rows), "back at the newest: arrivals join it again")
        XCTAssertNil(RoomRowWindow().held(in: rows).newer(in: rows), "nothing below the newest")
    }

    func test_paging_never_holds_more_than_the_most() throws {
        let rows = messages(1...1_000)
        var window = RoomRowWindow().held(in: rows)
        var most = window.range(in: rows).count
        while let page = window.older(in: rows) {
            window = page.window
            most = max(most, window.range(in: rows).count)
        }
        XCTAssertEqual(window.range(in: rows).lowerBound, 0, "up to the room's first row")
        while let page = window.newer(in: rows) {
            window = page.window
            most = max(most, window.range(in: rows).count)
        }
        XCTAssertTrue(window.reachesNewest(in: rows), "and back down to its newest")
        XCTAssertEqual(most, RoomRowWindow.most)
    }

    // MARK: - Rows taken away

    func test_the_first_message_deleted_holds_from_the_next_and_the_last_from_the_one_before() {
        let rows = messages(1...300)
        let window = RoomRowWindow.holding(100..<200, of: rows)
        let fewer = rows.filter { $0.windowSequence != 101 && $0.windowSequence != 200 }
        let range = window.range(in: fewer)
        XCTAssertEqual(fewer[range].first?.windowId, "m102", "from the message after the one deleted")
        XCTAssertEqual(fewer[range].last?.windowId, "m199", "to the message before the one deleted")
    }

    func test_a_stack_folding_the_first_messages_holds_from_the_first_one_left() {
        let rows = messages(1...300)
        let window = RoomRowWindow().held(in: rows)
        let folded = rows.filter { !(221...226).contains($0.windowSequence ?? 0) }
        XCTAssertEqual(folded[window.range(in: folded)].first?.windowId, "m227")
        XCTAssertTrue(window.reachesNewest(in: folded))
    }

    func test_rows_replaced_by_older_ones_fall_back_to_the_newest_of_them() {
        let window = RoomRowWindow().held(in: messages(201...300))
        let older = messages(1...150)
        XCTAssertEqual(window.range(in: older), 70..<150)
    }

    // MARK: - What the window starts with

    func test_it_starts_with_the_day_the_line_and_the_replies_just_above_its_first_message() {
        var rows = messages(1...99)
        rows += [Row.day("tue"), Row.line, Row.reply("r1")]
        rows += messages(100...200)
        // Message 100 is in row 102; its day, the line and a reply are just above it.
        let window = RoomRowWindow.holding(102..<203, of: rows)
        XCTAssertEqual(window.range(in: rows).lowerBound, 99, "its day, the line and the reply come with it")
        XCTAssertEqual(rows[window.range(in: rows)].first?.windowId, "day:tue")
    }

    func test_a_long_run_of_replies_never_stops_the_window_paging_up() throws {
        var rows = messages(1...50)
        rows += (1...100).map { Row.reply("r\($0)") }
        rows += messages(51...150)
        var window = RoomRowWindow().held(in: rows)
        var pages = 0
        while let page = window.older(in: rows), pages < 20 {
            window = page.window
            pages += 1
        }
        XCTAssertEqual(window.range(in: rows).lowerBound, 0, "every row above was reached")
        XCTAssertLessThan(pages, 20)
    }

    // MARK: - Around a row

    func test_around_a_message_holds_ten_above_it_and_seventy_below() {
        let rows = messages(1...300)
        let around = RoomRowWindow.around("m150", above: RoomRowWindow.aboveMessage)
        XCTAssertFalse(around.isHeld)
        XCTAssertEqual(around.range(in: rows), 139..<219)
        let held = around.held(in: rows)
        XCTAssertEqual(held.range(in: rows), 139..<219, "held, the same rows")
        XCTAssertEqual(held.range(in: messages(1...320)), 139..<219, "arrivals far below do not join it")
    }

    func test_around_the_unread_line_starts_twenty_above_it() {
        var rows = messages(1...200)
        rows.insert(Row.line, at: 150)
        let around = RoomRowWindow.around(Row.line.windowId, above: RoomRowWindow.aboveLine)
        let range = around.range(in: rows)
        XCTAssertEqual(range.lowerBound, 130)
        XCTAssertTrue(range.contains(150), "the line is held")
        XCTAssertEqual(range.upperBound, rows.count, "with everything after it, here less than the window")
    }

    func test_around_a_row_the_room_does_not_have_is_its_newest() {
        let rows = messages(1...300)
        XCTAssertEqual(RoomRowWindow.around("m9999", above: 10).range(in: rows), 220..<300)
    }
}
