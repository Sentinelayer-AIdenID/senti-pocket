import CoreGraphics
import Foundation
import XCTest
@testable import PocketUI

/// Reading up a busy room, people were moved by arriving messages and taken down by their own sends (Carter, #61581).
/// The reader's place now comes from the scroll view's geometry: at the bottom is exact, only the list moving up from
/// where it was at the bottom leaves it, and the end moving away from a reader at the bottom is followed.
final class RoomReaderPlaceTests: XCTestCase {
    private func reading(_ distanceToEnd: CGFloat, offset: CGFloat) -> RoomReaderPlace.Reading {
        RoomReaderPlace.Reading(distanceToEnd: distanceToEnd, offset: offset)
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

    /// A gentle coast up from the bottom moves a third of a point a frame or less near its end, at 120 Hz. Measured from
    /// the last frame, each step looked like rounding and the reader never left the bottom, so the next message pulled
    /// them down; measured from where the list was at the bottom, every coast that ends 24 points or more up leaves it.
    /// The curve is UIKit's normal deceleration (v = v0 × 0.998 per ms), offsets rounded to a third of a point.
    func test_a_slow_coast_up_from_the_bottom_leaves_it_wherever_it_ends_past_24_points() {
        for hz in [60.0, 120.0] {
            for rest in [10.0, 20.0, 26.0, 30.0, 40.0, 45.0, 60.0, 100.0] {
                var tracker = RoomReaderPlace.Tracker(atBottom: true)
                let (end, changes) = Self.coast(restingAbove: rest, hz: hz, tracker: &tracker)
                let away = end.distanceToEnd >= RoomReaderPlace.atBottomDistance
                XCTAssertEqual(tracker.atBottom, !away,
                               "\(Int(hz)) Hz, resting \(String(format: "%.1f", end.distanceToEnd)) pt up: \(changes)")
                if away {
                    // A message arriving below now moves nothing.
                    let arrival = reading(end.distanceToEnd + 180, offset: end.offset)
                    XCTAssertEqual(tracker.read(arrival), .none, "\(Int(hz)) Hz, \(rest): an arrival is not followed")
                }
            }
        }
    }

    func test_the_list_moving_up_past_the_bottom_leaves_it() {
        var tracker = RoomReaderPlace.Tracker(atBottom: true)
        XCTAssertEqual(tracker.read(reading(9, offset: 1_000)), .none, "at the bottom already")
        XCTAssertEqual(tracker.bottomOffset, 1_000)
        XCTAssertEqual(tracker.read(reading(20, offset: 989)), .none, "still within the bottom")
        XCTAssertEqual(tracker.read(reading(129, offset: 880)), .mayHaveLeft, "not by the reader's hand: held a frame")
        XCTAssertTrue(tracker.atBottom)
        XCTAssertEqual(tracker.read(reading(129, offset: 880)), .leftBottom, "still up on the next frame")
        XCTAssertFalse(tracker.atBottom)
        XCTAssertEqual(tracker.read(reading(400, offset: 609)), .none, "further up, already away")
    }

    /// A message arriving under a reader at the bottom, a row above growing, the keyboard rising: the end moves away
    /// while the list did not move up from where it was at the bottom. That is followed, never taken for leaving.
    func test_the_end_moving_away_from_a_reader_at_the_bottom_is_followed() {
        var tracker = RoomReaderPlace.Tracker(atBottom: true)
        _ = tracker.read(reading(9, offset: 1_000))
        XCTAssertEqual(tracker.read(reading(209, offset: 1_000)), .endMovedAway, "a message arrived")
        XCTAssertTrue(tracker.atBottom)
        XCTAssertEqual(tracker.read(reading(109, offset: 1_050)), .endMovedAway, "the follow is on its way down")
        XCTAssertEqual(tracker.read(reading(9, offset: 1_150)), .none, "followed there")
        XCTAssertEqual(tracker.bottomOffset, 1_150)
        XCTAssertEqual(tracker.read(reading(40, offset: 1_150)), .endMovedAway, "the keyboard rose: same list, end lower")
        XCTAssertEqual(tracker.read(reading(9.2, offset: 1_181)), .none)
    }

    /// While a burst arrives faster than the room follows, SwiftUI settles the lazy list's rows and moves the list up
    /// by itself, with the end already pushed below by what arrived (measured in the room on the simulator: 15 points,
    /// then 35, at 60 messages a second). That is not the reader leaving: the room follows once it may. The reader
    /// moving the list themselves still leaves, the end pushed below or not.
    func test_the_list_settling_up_while_the_end_is_pushed_below_is_not_the_reader_leaving() {
        var tracker = RoomReaderPlace.Tracker(atBottom: true)
        XCTAssertEqual(tracker.read(reading(0, offset: 7_919)), .none)
        XCTAssertEqual(tracker.read(reading(441, offset: 7_919)), .endMovedAway, "arrivals pushed the end below")
        XCTAssertEqual(tracker.read(reading(456, offset: 7_904)), .endMovedAway, "SwiftUI moved the list up 15 points")
        XCTAssertTrue(tracker.atBottom)
        XCTAssertEqual(tracker.read(reading(9, offset: 8_539.333)), .none, "followed")
        XCTAssertEqual(tracker.read(reading(196, offset: 8_539.333)), .endMovedAway)
        XCTAssertEqual(tracker.read(reading(520, offset: 8_504.333)), .endMovedAway, "and up 35 points")
        XCTAssertEqual(tracker.read(reading(560, offset: 8_480), readerMoving: true), .leftBottom,
                       "the reader dragging the list up leaves, the end pushed below or not")
        XCTAssertFalse(tracker.atBottom)

        var resting = RoomReaderPlace.Tracker(atBottom: true)
        _ = resting.read(reading(9, offset: 1_000))
        XCTAssertEqual(resting.read(reading(130, offset: 879)), .mayHaveLeft)
        XCTAssertEqual(resting.read(reading(130, offset: 879)), .leftBottom,
                       "from the end in view, the list moving up and staying up is the reader, whatever moved it")
    }

    /// SwiftUI lays the list out several times within one frame, and one pass can show it a little up for a moment:
    /// measured in a burst at 60 a second, the end in view at 8998.7, then 31 points up, then the end in view at 8999.7,
    /// within 3 ms, and the reading taken between them took the reader at the bottom for gone. Not by the reader's
    /// hand, the list must still be up on the next frame; by their hand (a drag, its coast) it leaves at once.
    func test_a_leave_not_by_the_readers_hand_holds_for_a_frame() {
        var tracker = RoomReaderPlace.Tracker(atBottom: true)
        XCTAssertEqual(tracker.read(reading(9.33, offset: 8_998.667)), .none)
        XCTAssertEqual(tracker.read(reading(40.67, offset: 8_967.333)), .mayHaveLeft, "one layout pass shows it up")
        XCTAssertEqual(tracker.read(reading(8.33, offset: 8_999.667)), .none, "the next frame: at the end")
        XCTAssertTrue(tracker.atBottom)
        XCTAssertEqual(tracker.read(reading(60, offset: 8_949), readerMoving: true), .leftBottom,
                       "the reader's drag leaves at once")
        XCTAssertFalse(tracker.atBottom)
    }

    /// Put at the bottom by the room (it opened there, the jump button went there), the list may still be on its way:
    /// until the end has been in view there is no place to measure leaving from, and the end below is followed. The
    /// reader moving the list then is not followed back against their hand.
    func test_the_readers_hand_before_the_end_was_in_view_is_not_followed() {
        var tracker = RoomReaderPlace.Tracker(atBottom: false)
        tracker.set(atBottom: true)
        XCTAssertNil(tracker.bottomOffset)
        XCTAssertEqual(tracker.read(reading(300, offset: 500)), .endMovedAway, "on its way down: followed")
        XCTAssertEqual(tracker.read(reading(420, offset: 380), readerMoving: true), .leftBottom,
                       "the reader moved the list up before the end was in view")
        XCTAssertFalse(tracker.atBottom)
        XCTAssertEqual(tracker.read(reading(520, offset: 380)), .none, "an arrival below is not followed")
    }

    func test_the_end_coming_into_view_is_the_bottom_unless_the_room_says_otherwise() {
        var tracker = RoomReaderPlace.Tracker(atBottom: false)
        XCTAssertEqual(tracker.read(reading(300, offset: 500)), .none)
        XCTAssertEqual(tracker.read(reading(10, offset: 790), mayBeAtBottom: false), .none,
                       "a window further back, or a message the reader was taken to")
        XCTAssertFalse(tracker.atBottom)
        XCTAssertEqual(tracker.read(reading(10, offset: 790)), .endInView)
        XCTAssertTrue(tracker.atBottom)
        tracker.set(atBottom: false)
        XCTAssertEqual(tracker.read(reading(130, offset: 680)), .none, "the room's own decision holds")
    }

    /// UIKit's normal deceleration from the bottom (distance 0) up, until it would move less than a point a second.
    private static func coast(restingAbove rest: Double, hz: Double,
                              tracker: inout RoomReaderPlace.Tracker) -> (RoomReaderPlace.Reading, [String]) {
        let k = -log(0.998) * 1_000
        let v0 = rest * k
        let base = 10_000.0
        var last = RoomReaderPlace.Reading(distanceToEnd: 0, offset: CGFloat(base))
        var changes: [String] = []
        if tracker.read(last) != .none { changes.append("start") }
        var t = 0.0
        while true {
            t += 1 / hz
            if v0 * exp(-k * t) < 1 { break }
            let travelled = v0 / k * (1 - exp(-k * t))
            let offset = ((base - travelled) * 3).rounded() / 3
            last = RoomReaderPlace.Reading(distanceToEnd: CGFloat(base - offset), offset: CGFloat(offset))
            let change = tracker.read(last)
            if change != .none { changes.append("\(change) at \(String(format: "%.2f", base - offset))") }
        }
        // The room takes the last reading again on the next frame (`Change.mayHaveLeft`).
        if tracker.read(last) != .none { changes.append("again: \(tracker.atBottom)") }
        return (last, changes)
    }
}

/// The jump button tells the reader what arrived, takes them to the first of it, and lets them decide (Carter, #61581;
/// the web room's words).
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
        XCTAssertEqual(RoomJumpToLatest.accessibilityLabel(newCount: 1), "1 new message, jump to the first one")
        XCTAssertEqual(RoomJumpToLatest.accessibilityLabel(newCount: 20), "20 new messages, jump to the first one")
        XCTAssertEqual(RoomJumpToLatest.accessibilityLabel(newCount: 99), "99 new messages, jump to the first one")
        XCTAssertEqual(RoomJumpToLatest.accessibilityLabel(newCount: 250),
                       "More than 99 new messages, jump to the first one")
    }

    func test_voiceover_hears_what_arrives_below() {
        XCTAssertNil(RoomJumpToLatest.arrivalAnnouncement(newCount: 0))
        XCTAssertEqual(RoomJumpToLatest.arrivalAnnouncement(newCount: 1), "1 new message")
        XCTAssertEqual(RoomJumpToLatest.arrivalAnnouncement(newCount: 3), "3 new messages")
        XCTAssertEqual(RoomJumpToLatest.arrivalAnnouncement(newCount: 120), "More than 99 new messages")
    }
}
