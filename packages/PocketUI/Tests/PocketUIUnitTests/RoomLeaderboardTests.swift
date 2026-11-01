import XCTest
@testable import PocketUI

/// A room that keeps a leaderboard pinned (a message starting with the trophy, edited as the scores change) shows a
/// Leaderboard button under its title that opens it, exactly when `leaderboard` is set. Other rooms show none.
final class RoomLeaderboardTests: XCTestCase {
    private func pin(_ seq: Int64, _ snippet: String) -> RoomChatPinned {
        RoomChatPinned(sequenceId: seq, snippet: snippet, pinnedBy: "ada-agent")
    }

    private func state(_ pinned: [RoomChatPinned]) -> RoomChatPresentationState {
        RoomChatPresentationState(sessionId: "room", title: "Help", messages: [], pinned: pinned)
    }

    func test_no_trophy_without_a_pin_that_starts_with_one() {
        XCTAssertNil(state([]).leaderboard, "no pins")
        XCTAssertNil(state([pin(7, "Ship the fix first."), pin(9, "Message #9")]).leaderboard,
                     "pins, none of them a leaderboard (one not read yet)")
        XCTAssertNil(state([pin(11, "Scores are in: 🏆 below")]).leaderboard, "the trophy has to lead")
    }

    func test_a_pin_that_starts_with_the_trophy_is_the_leaderboard() {
        let board = pin(57, "🏆 Who's helping most in this room")
        XCTAssertEqual(state([pin(7, "Ship the fix first."), board]).leaderboard, board)
        XCTAssertEqual(state([pin(80, "🏆 This week"), pin(57, "🏆 Last week")]).leaderboard?.sequenceId, 80,
                       "the newest pin first, as the strip shows them")

        let variationSelector = String(Unicode.Scalar(0xFE0F as UInt32)!)
        XCTAssertEqual(state([pin(12, "🏆" + variationSelector + " Who's helping most")]).leaderboard?.sequenceId, 12,
                       "the trophy written with its emoji variation selector")
    }

    // MARK: - The board as a list

    /// A board in the format the room's board process writes (its rows' shapes as on a live board; the ids are
    /// made up): medals for the first three, numbers after, person and team chips, every movement badge, an id at
    /// its longest, and the paragraph with the update time.
    static let fixture = """
        🏆 Who's helping most in this room

        🥇 **host-agent** · SentiLab team · 127.5 pts · 56 helpful
        🥈 **ada-agent** · SentiLab team · 72.1 pts · 25 helpful
        🥉 **lin-agent** · SentiLab team · 44.8 pts · 15 helpful
        4. **box-host** · SentiLab team · 34.9 pts · 14 helpful
        5. **oak-agent** · 33.2 pts · 11 helpful
        6. **review-agent** · SentiLab team · 30.6 pts · 11 helpful
        7. **pine-agent** · SentiLab team · 19.1 pts · 8 helpful
        8. **sam** (person) · 18.0 pts · 7 helpful
        9. **an-agent-with-the-longest-id-allowed-400** · SentiLab team · 14.7 pts · 7 helpful
        10. **elm-agent** · 13.5 pts · 5 helpful ▲2
        11. **mo-agent** · 12.9 pts · 5 helpful ▼1
        12. **fir-agent** · 12.8 pts · 5 helpful 🆕

        How it works: each message and reply is scored once for how much concrete help it gives someone else, from \
        0 to 4 points. An author's best 10 messages per hour count, so volume doesn't buy rank. Updated every 10 \
        minutes when scores change (last 00:46 UTC).
        """

    func test_the_board_reads_as_ranked_rows() throws {
        let board = try XCTUnwrap(RoomLeaderboard.parse(Self.fixture))
        XCTAssertEqual(board.rows.count, 12)
        XCTAssertEqual(board.rows.map(\.rank), Array(1...12))
        XCTAssertEqual(board.rows.map(\.rankText).prefix(4), ["🥇", "🥈", "🥉", "4."])
        XCTAssertEqual(board.rows[0].name, "host-agent")
        XCTAssertEqual(board.rows[0].points, "127.5")
        XCTAssertEqual(board.rows[0].helpful, 56)
        XCTAssertEqual(board.rows[0].chip, "SentiLab team")
        XCTAssertNil(board.rows[4].chip, "another agent: no chip")
        XCTAssertEqual(board.rows[7].chip, "person")
        XCTAssertEqual(board.rows[8].name.count, 40)
        XCTAssertEqual(board.rows.map(\.move).suffix(3), [.up(2), .down(1), .new])
        XCTAssertEqual(board.rows.map(\.moveText).suffix(3), ["▲2", "▼1", "🆕"])
        XCTAssertEqual(board.updatedAt, "00:46")
        XCTAssertEqual(board.header, "Who's helping most · Updated 00:46 UTC")
        XCTAssertTrue(board.howItWorks?.hasPrefix("How it works:") ?? false)
        XCTAssertFalse(board.howItWorks?.contains("**") ?? true, "no row in the paragraph")
    }

    /// VoiceOver reads each row as one line.
    func test_each_row_reads_as_one_line() throws {
        let rows = try XCTUnwrap(RoomLeaderboard.parse(Self.fixture)).rows
        XCTAssertEqual(rows[3].accessibilityLabel, "Rank 4, box-host, SentiLab team, 34.9 points, 14 helpful")
        XCTAssertEqual(rows[7].accessibilityLabel, "Rank 8, sam, person, 18.0 points, 7 helpful")
        XCTAssertEqual(rows[4].accessibilityLabel, "Rank 5, oak-agent, 33.2 points, 11 helpful")
        XCTAssertEqual(rows[9].accessibilityLabel, "Rank 10, elm-agent, 13.5 points, 5 helpful, up 2")
        XCTAssertEqual(rows[11].accessibilityLabel, "Rank 12, fir-agent, 12.8 points, 5 helpful, new on the board")
    }

    /// Only lines in the exact row shape are rows; any other line is never shown in the list.
    func test_lines_in_any_other_shape_are_not_rows() throws {
        let malformed = [
            "4. **Box-Host** · 34.9 pts · 14 helpful",
            "4. **box-host** · 34.95 pts · 14 helpful",
            "4) **box-host** · 34.9 pts · 14 helpful",
            "4. box-host · 34.9 pts · 14 helpful",
            "4. **box-host** · 34.9 pts · 14 helpful and more",
            "4. **box-host** · 34.9 pts · 14 helpful ▲",
            "1234. **box-host** · 34.9 pts · 14 helpful",
            "4. **box-host** · SentiLab team · 34.9 pts",
            "4. **" + String(repeating: "a", count: 41) + "** · 34.9 pts · 14 helpful",
            "<b>5. **evil** · 1.0 pts · 1 helpful</b>",
            "4. **box-host** · ٣٤.٩ pts · 14 helpful"
        ]
        for line in malformed { XCTAssertNil(RoomLeaderboard.row(line), line) }
        let board = try XCTUnwrap(RoomLeaderboard.parse((["🏆 Board", "", "1. **ok-agent** · 1.0 pts · 1 helpful"]
            + malformed + ["2. **ok-agent** · 0.5 pts · 1 helpful"]).joined(separator: "\n")))
        XCTAssertEqual(board.rows.map(\.name), ["ok-agent"], "and an author is on the board once")
        XCTAssertEqual(board.rows.first?.points, "1.0")
    }

    func test_a_board_with_crlf_line_ends_reads_the_same() {
        let board = RoomLeaderboard.parse(Self.fixture)
        XCTAssertNotNil(board)
        XCTAssertEqual(RoomLeaderboard.parse(Self.fixture.replacingOccurrences(of: "\n", with: "\r\n")), board)
    }

    /// No row to read: no board (the sheet says it is unavailable); and no update time: "just now".
    func test_a_board_without_rows_is_unavailable() throws {
        XCTAssertNil(RoomLeaderboard.parse(""))
        XCTAssertNil(RoomLeaderboard.parse("🏆 Who's helping most in this room\n\nScores are being counted."))
        let undated = try XCTUnwrap(RoomLeaderboard.parse("🏆 Board\n\n🥇 **ada-agent** · 2.0 pts · 1 helpful"))
        XCTAssertEqual(undated.header, "Who's helping most · Updated just now")
        XCTAssertNil(undated.howItWorks)
    }

    /// The update time is the paragraph's, as the format says: a time in the title (or anywhere above the rows) is
    /// not it, and with no paragraph there is none.
    func test_the_update_time_is_the_paragraphs() throws {
        let row = "🥇 **ada-agent** · 2.0 pts · 1 helpful"
        let board = try XCTUnwrap(RoomLeaderboard.parse(
            "🏆 Board last 00:01 UTC\n\n" + row + "\n\nHow it works: updated when scores change (last 09:40 UTC)."
        ))
        XCTAssertEqual(board.updatedAt, "09:40")
        let titleOnly = try XCTUnwrap(RoomLeaderboard.parse("🏆 Board last 00:01 UTC\n\n" + row))
        XCTAssertNil(titleOnly.updatedAt, "no paragraph, no time")
    }

    // MARK: - The sheet

    private func board(_ text: String, seq: Int64 = 57) -> RoomChatPinned {
        RoomChatPinned(sequenceId: seq, snippet: String(text.prefix { $0 != "\n" }), pinnedBy: "ada-agent", text: text)
    }

    private func state(_ pinned: [RoomChatPinned], open: Bool) -> RoomChatPresentationState {
        RoomChatPresentationState(sessionId: "room", title: "Help", messages: [], pinned: pinned, leaderboardOpen: open)
    }

    /// Open, the sheet shows the board read from the pinned message; closed, there is no sheet.
    func test_the_open_sheet_shows_the_board() throws {
        XCTAssertNil(state([board(Self.fixture)], open: false).leaderboardSheet, "closed")
        let sheet = try XCTUnwrap(state([board(Self.fixture)], open: true).leaderboardSheet)
        XCTAssertEqual(sheet.sequenceId, 57)
        guard case .board(let shown) = sheet.content else { return XCTFail("\(sheet.content)") }
        XCTAssertEqual(shown, RoomLeaderboard.parse(Self.fixture))
        XCTAssertNil(state([pin(7, "Ship the fix first.")], open: true).leaderboardSheet, "no board, no sheet")
    }

    /// The sheet follows the board's edits: the list is read again from the message's newest text.
    func test_an_edited_board_updates_the_open_sheet() throws {
        let edited = Self.fixture.replacingOccurrences(of: "🥇 **host-agent**", with: "🥇 **zed-agent**")
        let sheet = try XCTUnwrap(state([board(edited)], open: true).leaderboardSheet)
        guard case .board(let shown) = sheet.content else { return XCTFail("\(sheet.content)") }
        XCTAssertEqual(shown.rows.first?.name, "zed-agent")
    }

    /// A board message with no row to read: "Board unavailable" (and the message), never its raw text; one whose
    /// text isn't known yet: a loading line.
    func test_a_board_that_cant_be_read_falls_back() throws {
        let unreadable = try XCTUnwrap(state([board("🏆 Who's helping most\n\n<b>raw text</b>")], open: true)
            .leaderboardSheet)
        XCTAssertEqual(unreadable.content, .unavailable)
        let unknown = RoomChatPinned(sequenceId: 57, snippet: "🏆 Who's helping most", pinnedBy: "ada-agent")
        XCTAssertEqual(state([unknown], open: true).leaderboardSheet?.content, .loading)
    }
}
