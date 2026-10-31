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
}
