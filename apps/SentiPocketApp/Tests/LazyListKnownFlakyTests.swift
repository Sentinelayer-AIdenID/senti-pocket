import Foundation
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// Three room-list checks that fail often on PRs that do not touch the room list. Until their fix, they run here, in
/// their own CI job that reports and prints its counts without gating (ticket 9d7d62f1, warden 2026-11-05):
/// - b508c37d: at rest, another arrival builds only the rows on screen, and an arrival three screens up follows back
///   to the room's bottom;
/// - 96166f35: a held message stays in view as messages arrive below it.
///
/// Their bounds are LazyListBuildTests' own, unchanged; every other check stays there, in the gating job. The split ends
/// when the blank-room fix (b) merges or on 2026-11-13, whichever comes first; after that date CI fails while this class
/// is still here. The gating job's guard (scripts/ios/known_flaky_guard.py) fails if a check marked here shows up in a
/// gating test, or if this class holds any test beyond these two.
@MainActor
final class LazyListKnownFlakyTests: LazyListTestCase {
    /// b508c37d. In a room of 400 messages resting at its bottom, the second arrival builds at most 80 rows, and an
    /// arrival while the list has drifted three screens up brings it back to its bottom (within a quarter of a screen).
    /// The steps before them are LazyListBuildTests' own, without their bounds, which gate there.
    func test_b508c37d_another_arrival_builds_only_what_it_shows_and_the_room_follows_back() throws {
        let room = Room(Self.room(rows: 400))
        try host(RoomHost(room: room))
        let rows = room.state.rows.count
        step("open", rows: rows, list: .roomRow, most: nil) {}
        step("the first update after the open", rows: rows, list: .roomRow, most: nil) { room.objectWillChange.send() }
        settleAtBottom()
        step("drawn again, nothing changed", rows: rows, list: .roomRow, most: nil) { room.objectWillChange.send() }
        settleAtBottom()
        step("an arrival", rows: rows, list: .roomRow, most: nil) { room.state = Self.room(rows: 401) }
        settleAtBottom()
        let built = step("another arrival", rows: rows, list: .roomRow, most: nil) { room.state = Self.room(rows: 402) }
        XCTAssertLessThanOrEqual(
            built, Self.mostBuiltPerStep,
            "another arrival: built \(built) of \(rows) items, not only those it shows [known-flaky b508c37d]"
        )

        settleAtBottom()
        let scroll = try XCTUnwrap(window.flatMap { Self.list(in: $0) }, "the room's list")
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, Self.bottomOffset(of: scroll) - 3 * scroll.bounds.height)),
                                animated: false)
        step("an arrival three screens up (followed)", rows: rows, list: .roomRow, most: nil) {
            room.state = Self.room(rows: 403)
        }
        let away = abs(scroll.contentOffset.y - Self.bottomOffset(of: scroll))
        print("LAZYLIST follow-back: \(Int(away)) pt from the bottom (bound \(Int(scroll.bounds.height / 4)) pt)")
        XCTAssertLessThan(away, scroll.bounds.height / 4,
                          "the room followed the arrival back to its bottom [known-flaky b508c37d]")
    }

    /// 96166f35. Opened at a message far up a room of 400, the room holds that message in view (it moves less than half
    /// a screen) while two messages arrive below it. LazyListBuildTests checks, gating, that the room opens there.
    func test_96166f35_a_held_message_stays_in_view_as_messages_arrive_below() throws {
        let room = Room(Self.room(rows: 400, focus: 60))
        try host(RoomHost(room: room))
        XCTAssertTrue(quiet { [RenderTrace.builtCount(.roomRow), RenderTrace.snapshot().draws] })
        let scroll = try XCTUnwrap(window.flatMap { Self.list(in: $0) }, "the room's list")
        let held = scroll.contentOffset.y
        room.state = Self.room(rows: 402, focus: 60)
        XCTAssertTrue(quiet { [RenderTrace.builtCount(.roomRow), RenderTrace.snapshot().draws] })
        let moved = abs(scroll.contentOffset.y - held)
        print("LAZYLIST held message: moved \(Int(moved)) pt as two messages arrived "
            + "(bound \(Int(scroll.bounds.height / 2)) pt)")
        XCTAssertLessThan(moved, scroll.bounds.height / 2,
                          "the held message stays in view as messages arrive below [known-flaky 96166f35]")
    }
}
