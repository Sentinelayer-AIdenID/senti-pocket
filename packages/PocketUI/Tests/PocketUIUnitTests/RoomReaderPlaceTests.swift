import CoreGraphics
import XCTest
@testable import PocketUI

/// Reading up a busy room, people were moved by arriving messages and taken down by their own sends (Carter, #61581).
/// The reader's place now comes from the scroll view's geometry: at the bottom is exact, only the list moving up leaves
/// it, and the end moving away from a reader at the bottom is followed.
final class RoomReaderPlaceTests: XCTestCase {
    private func reading(_ distanceToEnd: CGFloat, offset: CGFloat) -> RoomReaderPlace.Reading {
        RoomReaderPlace.Reading(distanceToEnd: distanceToEnd, offset: offset)
    }

    private func change(_ old: RoomReaderPlace.Reading, _ new: RoomReaderPlace.Reading) -> RoomReaderPlace.Change {
        RoomReaderPlace.change(from: old, to: new)
    }

    func test_the_bottom_is_the_end_of_the_room_within_24_points() {
        XCTAssertEqual(RoomReaderPlace.atBottomDistance, 24)
        XCTAssertTrue(reading(0, offset: 900).endInView)
        XCTAssertTrue(reading(9, offset: 900).endInView, "where the room rests at its end, over its own padding")
        XCTAssertTrue(reading(23.5, offset: 900).endInView)
        XCTAssertFalse(reading(24, offset: 900).endInView)
        XCTAssertFalse(reading(120, offset: 900).endInView, "a few lines up, the end still under the composer")
        XCTAssertTrue(reading(-60, offset: 900).endInView, "pulled past the end")
    }

    func test_the_list_moving_up_past_the_bottom_leaves_it() {
        XCTAssertEqual(change(reading(9, offset: 1_000), reading(129, offset: 880)), .leftBottom)
        XCTAssertEqual(change(reading(129, offset: 880), reading(400, offset: 609)), .leftBottom, "and further up")
        XCTAssertEqual(change(reading(9, offset: 1_000), reading(20, offset: 989)), .none, "still within the bottom")
    }

    /// A message arriving under a reader at the bottom, a row above growing while the top row is held, the keyboard
    /// rising: the end moves away while the list did not move up. That is followed, never taken for the reader leaving.
    func test_the_end_moving_away_from_a_list_that_did_not_move_up_is_followed() {
        XCTAssertEqual(change(reading(9, offset: 1_000), reading(209, offset: 1_000)), .endMovedAway, "a message arrived")
        XCTAssertEqual(change(reading(9, offset: 1_000), reading(109, offset: 1_050)), .endMovedAway,
                       "a row above grew and the list kept its top row")
        XCTAssertEqual(change(reading(9, offset: 1_000), reading(9.2, offset: 1_000)), .none, "layout rounding")
    }

    func test_the_end_coming_into_view_is_the_bottom() {
        XCTAssertEqual(change(reading(300, offset: 500), reading(10, offset: 790)), .endInView)
        XCTAssertEqual(change(reading(130, offset: 500), reading(120, offset: 500)), .none, "not yet")
        XCTAssertEqual(change(reading(10, offset: 790), reading(5, offset: 795)), .none, "already there")
    }

    func test_scrolling_down_short_of_the_end_changes_nothing() {
        XCTAssertEqual(change(reading(600, offset: 400), reading(500, offset: 500)), .none)
    }
}

/// The jump button tells the reader what arrived and lets them decide (Carter, #61581).
final class RoomJumpToLatestTests: XCTestCase {
    func test_the_arrow_says_how_many_arrived_since_the_reader_left_the_bottom() {
        XCTAssertNil(RoomJumpToLatest.badge(newCount: 0), "nothing new: the plain arrow")
        XCTAssertEqual(RoomJumpToLatest.badge(newCount: 1), "1 new")
        XCTAssertEqual(RoomJumpToLatest.badge(newCount: 20), "20 new")
        XCTAssertEqual(RoomJumpToLatest.badge(newCount: 99), "99 new")
        XCTAssertEqual(RoomJumpToLatest.badge(newCount: 100), "99+ new")
        XCTAssertEqual(RoomJumpToLatest.badge(newCount: 4_000), "99+ new")
    }

    func test_voiceover_reads_how_many_and_where_it_goes() {
        XCTAssertEqual(RoomJumpToLatest.accessibilityLabel(newCount: 0), "Jump to latest")
        XCTAssertEqual(RoomJumpToLatest.accessibilityLabel(newCount: 1), "1 new message, jump to latest")
        XCTAssertEqual(RoomJumpToLatest.accessibilityLabel(newCount: 20), "20 new messages, jump to latest")
        XCTAssertEqual(RoomJumpToLatest.accessibilityLabel(newCount: 99), "99 new messages, jump to latest")
        XCTAssertEqual(RoomJumpToLatest.accessibilityLabel(newCount: 250), "More than 99 new messages, jump to latest")
    }
}
