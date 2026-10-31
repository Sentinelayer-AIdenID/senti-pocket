import XCTest
@testable import PocketUI

/// Carter's freezes on build 17 (#56316, #56340): the bottom marker wrote the reader's place during layout, the redraw
/// moved the marker, and the room never stopped redrawing. The place now settles outside layout.
final class RoomBottomSettleTests: XCTestCase {
    func test_a_report_during_layout_changes_nothing_until_it_lands() throws {
        var settle = RoomBottomSettle()
        let check = try XCTUnwrap(settle.marker(shown: false))
        XCTAssertTrue(settle.atBottom, "the report alone moves nothing")
        XCTAssertEqual(check.after, RoomBottomSettle.leaveDelay, "leaving must hold before it counts")
        XCTAssertEqual(settle.land(check, at: 0.1), .changed(false))
        XCTAssertFalse(settle.atBottom)

        let back = try XCTUnwrap(settle.marker(shown: true))
        XCTAssertEqual(back.after, 0, "coming back lands on the next turn")
        XCTAssertEqual(settle.land(back, at: 0.2), .changed(true))
        XCTAssertTrue(settle.atBottom)
    }

    func test_a_change_undone_before_it_lands_is_dropped() throws {
        var settle = RoomBottomSettle()
        let gone = try XCTUnwrap(settle.marker(shown: false))
        XCTAssertNil(settle.marker(shown: true), "back where it was: nothing to land")
        XCTAssertEqual(settle.land(gone, at: 0.1), .none)
        XCTAssertTrue(settle.atBottom)
    }

    func test_only_the_latest_report_lands() throws {
        var settle = RoomBottomSettle()
        let first = try XCTUnwrap(settle.marker(shown: false))
        XCTAssertNil(settle.marker(shown: true))
        let last = try XCTUnwrap(settle.marker(shown: false))
        XCTAssertEqual(settle.land(first, at: 0.1), .none, "a later report replaced it")
        XCTAssertTrue(settle.atBottom)
        XCTAssertEqual(settle.land(last, at: 0.15), .changed(false))
        XCTAssertEqual(settle.land(last, at: 0.2), .none, "a check lands once")
    }

    /// The flap breaker: the 11th change within a second is held, with the last settled place kept, for a second; the
    /// hold is said once, and then the marker's latest report lands.
    func test_more_than_ten_changes_in_a_second_hold_the_last_place_for_a_second() throws {
        var settle = RoomBottomSettle()
        var now: TimeInterval = 0
        for flip in 0..<RoomBottomSettle.flapLimit {
            let check = try XCTUnwrap(settle.marker(shown: !settle.atBottom))
            XCTAssertEqual(settle.land(check, at: now), .changed(flip % 2 == 1), "change \(flip + 1) lands")
            now += 0.05
        }
        let kept = settle.atBottom
        let eleventh = try XCTUnwrap(settle.marker(shown: !kept))
        XCTAssertEqual(settle.land(eleventh, at: now), .held(until: now + RoomBottomSettle.holdTime))
        XCTAssertEqual(settle.atBottom, kept, "the last settled place is kept")
        XCTAssertEqual(settle.heldUntil, now + RoomBottomSettle.holdTime)

        // While held, reports keep coming and none lands, and the hold is not said again.
        XCTAssertNil(settle.marker(shown: kept))
        let during = try XCTUnwrap(settle.marker(shown: !kept))
        XCTAssertEqual(settle.land(during, at: now + 0.5), .none)
        XCTAssertEqual(settle.landLatest(at: now + 0.9), .none)
        XCTAssertEqual(settle.atBottom, kept)

        // When it ends, the marker's latest report lands.
        XCTAssertEqual(settle.landLatest(at: now + RoomBottomSettle.holdTime), .changed(!kept))
        XCTAssertNil(settle.heldUntil)
        XCTAssertEqual(settle.landLatest(at: now + RoomBottomSettle.holdTime + 0.1), .none)
    }

    func test_a_reader_scrolling_up_and_down_is_never_held() throws {
        var settle = RoomBottomSettle()
        var now: TimeInterval = 0
        for _ in 0..<40 {
            let check = try XCTUnwrap(settle.marker(shown: !settle.atBottom))
            guard case .changed = settle.land(check, at: now) else { return XCTFail("held at \(now)") }
            now += 0.15
        }
        XCTAssertNil(settle.heldUntil)
    }

    func test_after_a_hold_ends_changes_count_afresh() throws {
        var settle = RoomBottomSettle()
        var now: TimeInterval = 0
        for _ in 0...RoomBottomSettle.flapLimit {
            if let check = settle.marker(shown: !settle.atBottom) { _ = settle.land(check, at: now) }
            now += 0.01
        }
        XCTAssertNotNil(settle.heldUntil)
        now = settle.heldUntil ?? now
        _ = settle.landLatest(at: now)
        let next = try XCTUnwrap(settle.marker(shown: !settle.atBottom))
        guard case .changed = settle.land(next, at: now + 0.05) else { return XCTFail("a new run of changes starts empty") }
    }

    func test_the_rooms_own_decision_lands_at_once_and_drops_the_markers_earlier_reports() throws {
        var settle = RoomBottomSettle()
        let gone = try XCTUnwrap(settle.marker(shown: false))
        XCTAssertFalse(settle.set(true), "already at the bottom")
        XCTAssertEqual(settle.land(gone, at: 0.1), .none, "the decision came after the report")
        XCTAssertTrue(settle.set(false), "taken to a message further up")
        XCTAssertFalse(settle.atBottom)
        XCTAssertEqual(settle.landLatest(at: 5), .none, "an earlier report never undoes the decision")
        let back = try XCTUnwrap(settle.marker(shown: true))
        XCTAssertEqual(settle.land(back, at: 5.1), .changed(true))
    }
}
