import Combine
import Foundation
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// From iOS 18 the room's list holds a window of its rows, every one of them built (`RoomRowWindow`, in PocketUI): not a
/// lazy list placing rows by estimated heights, where the room froze as it was dragged and opened blank after Jump to
/// latest. These tests hold it to that, read the way VoiceOver reads the screen:
/// - it holds a window of the room's rows, never the whole room, and an update makes again only the rows it changed;
/// - every row is measured: scrolling builds, draws and resizes nothing;
/// - a message counts as seen (read, and its receipt sent) only once enough of it shows, and a photo asks for its
///   preview only once it is in view, never because its row was built;
/// - the reader stays where they are as pages show above and below, as messages arrive, and as rows are taken away;
/// - Jump to latest after the room is made again and trimmed shows the newest rows, at the bottom.
@MainActor
final class RoomListWindowTests: XCTestCase {
    /// `RoomRowWindow`'s sizes (internal to PocketUI): the rows a room opens with, a page, the most the list holds.
    private static let opening = 80
    private static let step = 40
    private static let most = 160

    private static var holdsWindow: Bool {
        if #available(iOS 18.0, *) {
            return true
        } else {
            return false
        }
    }

    private var window: UIWindow?

    override func tearDown() {
        if let window { HostedSummary.close(window) }
        window = nil
        super.tearDown()
    }

    // MARK: - A window, built whole

    /// A room of 400 messages opens holding its newest 80 rows, each made once: not the room's 400, and not a lazy
    /// list's passes over every row to find its end (437 to 1,212 made for a room of 404).
    func test_opening_a_long_room_builds_its_window_not_the_room() throws {
        try XCTSkipUnless(Self.holdsWindow, "the window is iOS 18 and later")
        let room = LazyListTestCase.Room(LazyListTestCase.room(rows: 400))
        let built = RenderTrace.builtCount(.roomRow)
        try show(LazyListTestCase.RoomHost(room: room))
        XCTAssertTrue(quiet(), "the room settles")
        let made = RenderTrace.builtCount(.roomRow) - built
        let held = RenderTrace.roomRowsHeld().now
        print("ROOMLIST open: \(made) rows made, \(held) held of the room's \(room.state.rows.count)")
        XCTAssertLessThanOrEqual(held, Self.opening + 5, "the list holds the newest rows, not the room")
        XCTAssertGreaterThan(held, Self.opening / 2)
        XCTAssertLessThanOrEqual(made, 2 * Self.opening, "opening makes the window's rows once, not the room's")
    }

    /// Drawn again with nothing changed, no row is made again; an arrival makes its own row, and the one before it
    /// whose grouping may change. The list holds every row of its window, so this is what keeps an update small.
    func test_drawn_again_no_row_is_made_again_and_an_arrival_makes_only_its_own() throws {
        try XCTSkipUnless(Self.holdsWindow, "the window is iOS 18 and later")
        let room = LazyListTestCase.Room(LazyListTestCase.room(rows: 400))
        try show(LazyListTestCase.RoomHost(room: room))
        XCTAssertTrue(quiet(), "the room settles")
        var built = RenderTrace.builtCount(.roomRow)
        room.objectWillChange.send()
        XCTAssertTrue(quiet(), "the room settles")
        let again = RenderTrace.builtCount(.roomRow) - built
        built = RenderTrace.builtCount(.roomRow)
        room.state = LazyListTestCase.room(rows: 401)
        XCTAssertTrue(quiet(), "the room settles")
        let arrival = RenderTrace.builtCount(.roomRow) - built
        print("ROOMLIST made: \(again) drawn again, \(arrival) for an arrival")
        XCTAssertEqual(again, 0, "drawn again with nothing changed, no row is made again")
        XCTAssertLessThanOrEqual(arrival, 3, "an arrival makes its own row, not the window's")
    }

    /// Every row is measured as the list is made: its height is known at once, and scrolling it from the bottom to the
    /// top changes it never, and makes and draws no row. A lazy list measures rows only as they come into view (here
    /// thirty tall reports above thirty short messages), and grows as it scrolls.
    func test_the_list_is_measured_whole_so_scrolling_it_makes_draws_and_resizes_nothing() throws {
        try XCTSkipUnless(Self.holdsWindow, "the window is iOS 18 and later")
        let room = LazyListTestCase.Room(Self.room(60, tall: { $0 <= 30 }))
        let window = try show(LazyListTestCase.RoomHost(room: room))
        XCTAssertTrue(quiet(), "the room settles")
        let scroll = try XCTUnwrap(LazyListTestCase.list(in: window), "the room's list")
        let height = scroll.contentSize.height
        let built = RenderTrace.builtCount(.roomRow)
        let drawn = RenderTrace.snapshot().draws
        let top = -scroll.adjustedContentInset.top
        var offset = scroll.contentOffset.y
        var heights: [CGFloat] = []
        while offset > top {
            offset = max(top, offset - scroll.bounds.height / 2)
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            HostedSummary.pump(0.1)
            heights.append(scroll.contentSize.height)
        }
        XCTAssertTrue(quiet(), "the room settles")
        let made = RenderTrace.builtCount(.roomRow) - built
        let draws = RenderTrace.snapshot().draws - drawn
        print("ROOMLIST scrolled to the top in \(heights.count) steps: \(Int(height)) pt tall, from "
              + "\(Int(heights.min() ?? 0)) to \(Int(heights.max() ?? 0)) on the way; \(made) rows made, \(draws) drawn")
        XCTAssertGreaterThan(heights.count, 4, "the room is several screens tall")
        XCTAssertEqual(heights.min() ?? 0, height, accuracy: 1, "its height is known at once: every row is measured")
        XCTAssertEqual(heights.max() ?? 0, height, accuracy: 1, "its height is known at once: every row is measured")
        XCTAssertEqual(made, 0, "scrolling makes no row")
        XCTAssertEqual(draws, 0, "scrolling draws no row")
    }

    // MARK: - Seen: in view, not built

    /// The list holds sixty messages as the room opens at its newest: only those in view count as seen.
    func test_as_the_room_opens_only_the_messages_in_view_are_seen() throws {
        try XCTSkipUnless(Self.holdsWindow, "the window is iOS 18 and later")
        let room = LazyListTestCase.Room(Self.room(60))
        try show(LazyListTestCase.RoomHost(room: room))
        XCTAssertTrue(quiet(), "the room settles")
        let seen = Self.seen(room.intents)
        print("ROOMLIST seen as the room opens: \(seen.count) of 60 held")
        XCTAssertTrue(seen.contains(Self.messageId(60)), "the newest is in view")
        XCTAssertFalse(seen.contains(Self.messageId(1)), "the first, screens up, is held but not in view")
        XCTAssertLessThan(seen.count, 20, "a screen of messages, not every one held")
    }

    /// A message 2 points into view is not seen: it is not read and sends no receipt. A screen of it is.
    func test_a_message_peeking_into_view_is_not_seen_and_one_well_in_view_is() throws {
        try XCTSkipUnless(Self.holdsWindow, "the window is iOS 18 and later")
        // Message 30 is tall (29 lines), with thirty short messages below it: off screen as the room opens.
        let room = LazyListTestCase.Room(Self.room(60, tall: { $0 == 30 }, tallLines: 29))
        let window = try show(LazyListTestCase.RoomHost(room: room).environment(\.dynamicTypeSize, .xxxLarge))
        XCTAssertTrue(quiet(), "the room settles")
        let scroll = try XCTUnwrap(LazyListTestCase.list(in: window), "the room's list")
        let tall = Self.messageId(30)
        XCTAssertFalse(room.intents.contains(.messageOnScreen(id: tall, isOnScreen: true)), "off screen as it opens")
        let frame = try XCTUnwrap(messageFrames(in: window)[30], "the tall message is held")
        let visible = visibleRect(of: scroll)
        XCTAssertGreaterThan(frame.height, visible.height / 2, "taller than half the screen")

        // Its top 2 points into view, at the bottom of what can be read.
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + frame.minY - (visible.maxY - 2)), animated: false)
        HostedSummary.pump(1)
        let peeking = try XCTUnwrap(messageFrames(in: window)[30])
        print("ROOMLIST peek: \(Int(visible.maxY - peeking.minY)) pt of \(Int(peeking.height)) in view")
        XCTAssertEqual(visible.maxY - peeking.minY, 2, accuracy: 3, "2 points of it in view")
        XCTAssertFalse(room.intents.contains(.messageOnScreen(id: tall, isOnScreen: true)), "a sliver is not seen")

        // Its top just under the top of what can be read: a screen of it in view.
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentOffset.y + peeking.minY - (visible.minY + 20)),
                                animated: false)
        HostedSummary.pump(1)
        XCTAssertTrue(room.intents.contains(.messageOnScreen(id: tall, isOnScreen: true)), "well in view, it is seen")
    }

    /// 160 messages with photos (one each; every 7th three, a strip that fits; every 10th twelve, a strip that scrolls
    /// sideways). As the room opens, previews are asked for the photos in view only, never the window's eighty rows of
    /// them; scrolling up asks for those that come into view.
    func test_a_room_of_photos_asks_for_the_previews_in_view_only() throws {
        try XCTSkipUnless(Self.holdsWindow, "the window is iOS 18 and later")
        let room = LazyListTestCase.Room(Self.room(160, photos: { $0 % 10 == 0 ? 12 : $0 % 7 == 0 ? 3 : 1 }))
        let window = try show(LazyListTestCase.RoomHost(room: room))
        XCTAssertTrue(quiet(), "the room settles")
        let scroll = try XCTUnwrap(LazyListTestCase.list(in: window), "the room's list")
        let asked = Self.asked(room.intents)
        let frames = messageFrames(in: window)
        // The whole of the list's frame, what the bars and the box cover too: lenient on where "in view" ends.
        let list = scroll.convert(scroll.bounds, to: nil)
        let owners = Set(asked.compactMap(Self.owner))
        let outOfView = owners.filter { owner in !(frames[owner].map { $0.intersects(list) } ?? false) }
        print("ROOMLIST photos as the room opens: \(asked.count) previews asked for, of messages "
              + "\(owners.sorted()); \(RenderTrace.roomRowsHeld().now) rows held")
        XCTAssertGreaterThan(asked.count, 0, "the photos in view ask for their previews")
        XCTAssertLessThanOrEqual(asked.count, 30, "only those in view, never the window's")
        XCTAssertEqual(outOfView, [], "every preview asked for is of a message in view")

        let top = -scroll.adjustedContentInset.top
        var offset = scroll.contentOffset.y
        for _ in 0..<6 where offset > top {
            offset = max(top, offset - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            HostedSummary.pump(0.3)
        }
        let later = Self.asked(room.intents)
        print("ROOMLIST photos after six screens up: \(later.count) previews asked for")
        XCTAssertGreaterThan(later.count, asked.count, "photos coming into view ask for theirs")
    }

    // MARK: - The reader's place

    /// Scrolled up, the room says the reader left the bottom (the arrow shows), and a message arriving below moves
    /// nothing on screen.
    func test_scrolled_up_the_room_says_so_and_an_arrival_moves_nothing() throws {
        try XCTSkipUnless(Self.holdsWindow, "the window is iOS 18 and later")
        let room = LazyListTestCase.Room(Self.room(60))
        let window = try show(LazyListTestCase.RoomHost(room: room))
        XCTAssertTrue(quiet(), "the room settles")
        let scroll = try XCTUnwrap(LazyListTestCase.list(in: window), "the room's list")
        room.intents.removeAll()
        let up = LazyListTestCase.bottomOffset(of: scroll) - 3 * scroll.bounds.height
        scroll.setContentOffset(CGPoint(x: 0, y: up), animated: false)
        HostedSummary.pump(1.5)
        XCTAssertTrue(room.intents.contains(.readerAtBottom(false)), "three screens up, the reader is not at the bottom")
        XCTAssertNotNil(HostedSummary.element("pocket.room.jumpToLatest", in: window), "the arrow shows")
        let held = scroll.contentOffset.y
        room.state = Self.room(61)
        XCTAssertTrue(quiet(), "the room settles")
        print("ROOMLIST arrival while up: moved \(Int(abs(scroll.contentOffset.y - held))) pt")
        XCTAssertEqual(scroll.contentOffset.y, held, accuracy: 1, "an arrival below moves nothing on screen")
        XCTAssertFalse(room.intents.contains(.readerAtBottom(true)))
    }

    /// Up a room of 400, a page at a time: each page shows 40 rows above, the reader stays on the message that was
    /// first, the list never holds more than 160 rows, and the room's start is reached.
    func test_scrolling_up_shows_a_page_at_a_time_and_the_reader_stays_on_their_message() throws {
        try XCTSkipUnless(Self.holdsWindow, "the window is iOS 18 and later")
        let room = LazyListTestCase.Room(LazyListTestCase.room(rows: 400))
        let window = try show(LazyListTestCase.RoomHost(room: room))
        XCTAssertTrue(quiet(), "the room settles")
        let scroll = try XCTUnwrap(LazyListTestCase.list(in: window), "the room's list")
        RenderTrace.resetHeldRoomRows()
        var pages = 0
        while HostedSummary.element("pocket.room.start", in: window) == nil, pages < 15 {
            let first = try XCTUnwrap(messageFrames(in: window).min { $0.value.minY < $1.value.minY }?.key,
                                      "a message is held")
            let built = RenderTrace.builtCount(.roomRow)
            // To the top of what the list holds, where its edge comes into view.
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            XCTAssertTrue(quiet(), "the room settles")
            pages += 1
            let made = RenderTrace.builtCount(.roomRow) - built
            let kept = try XCTUnwrap(messageFrames(in: window)[first], "message \(first) is still held")
            let place = kept.minY - visibleRect(of: scroll).minY
            print("ROOMLIST page \(pages): \(made) rows made; message \(first) \(Int(place)) pt from the top")
            XCTAssertGreaterThan(made, 0, "a page shows rows above")
            XCTAssertLessThanOrEqual(made, Self.step + 5, "a page makes its own rows")
            XCTAssertLessThan(abs(place), 120, "the reader stays on the message that was first")
        }
        print("ROOMLIST up the room: \(pages) pages; most held \(RenderTrace.roomRowsHeld().most)")
        XCTAssertNotNil(HostedSummary.element("pocket.room.start", in: window), "the room's start is reached")
        XCTAssertGreaterThan(pages, 5, "a page at a time")
        XCTAssertLessThanOrEqual(RenderTrace.roomRowsHeld().most, Self.most + 5, "never more than 160 rows")
    }

    /// The reader up the room while 120 messages arrive: the window grows to 160 rows and the newest wait below it,
    /// with an edge that says so. The arrow counts all 120. Down at the end of what the list holds, the room is never
    /// told the reader is at its bottom: it keeps counting.
    func test_a_window_grown_to_the_most_never_says_the_reader_is_at_the_bottom_and_the_arrow_counts_them_all() throws {
        try XCTSkipUnless(Self.holdsWindow, "the window is iOS 18 and later")
        let room = LazyListTestCase.Room(Self.room(100))
        let window = try show(LazyListTestCase.RoomHost(room: room))
        XCTAssertTrue(quiet(), "the room settles")
        let scroll = try XCTUnwrap(LazyListTestCase.list(in: window), "the room's list")
        scroll.setContentOffset(CGPoint(x: 0, y: LazyListTestCase.bottomOffset(of: scroll) - 2 * scroll.bounds.height),
                                animated: false)
        HostedSummary.pump(1.5)
        XCTAssertTrue(room.intents.contains(.readerAtBottom(false)), "two screens up, the reader is not at the bottom")
        room.intents.removeAll()
        room.state = Self.room(220, unreadCount: 120)
        XCTAssertTrue(quiet(), "the room settles")
        let held = messageFrames(in: window)
        print("ROOMLIST 120 arrived while up: holds messages \(held.keys.min() ?? 0)-\(held.keys.max() ?? 0), "
              + "\(RenderTrace.roomRowsHeld().now) rows")
        XCTAssertNil(held[220], "the newest wait below the window")
        XCTAssertLessThanOrEqual(RenderTrace.roomRowsHeld().now, Self.most, "the window holds 160 rows at most")
        XCTAssertNotNil(HostedSummary.element("pocket.room.loadNewerRows", in: window), "an edge says more are below")
        let arrow = try XCTUnwrap(HostedSummary.element("pocket.room.jumpToLatest", in: window), "the arrow")
        XCTAssertEqual(arrow.accessibilityLabel, "Jump to latest, 120 new", "the arrow counts the messages waiting")

        // Down to the end of what the list holds.
        scroll.setContentOffset(CGPoint(x: 0, y: LazyListTestCase.bottomOffset(of: scroll)), animated: false)
        HostedSummary.pump(1.5)
        XCTAssertTrue(quiet(), "the room settles")
        XCTAssertFalse(room.intents.contains(.readerAtBottom(true)), "the end of the window is never the room's bottom")
        XCTAssertNotNil(messageFrames(in: window)[220], "the rows below come in, a page at a time")
    }

    /// The first message the window holds is deleted and the three after it fold away: the window holds from the next
    /// message on, to the newest, and the reader up the room stays up the room.
    func test_the_first_message_held_taken_away_holds_from_the_next_and_leaves_the_reader_where_they_are() throws {
        try XCTSkipUnless(Self.holdsWindow, "the window is iOS 18 and later")
        let room = LazyListTestCase.Room(Self.room(200))
        let window = try show(LazyListTestCase.RoomHost(room: room))
        XCTAssertTrue(quiet(), "the room settles")
        let scroll = try XCTUnwrap(LazyListTestCase.list(in: window), "the room's list")
        let first = try XCTUnwrap(messageFrames(in: window).keys.min(), "the first message held")
        scroll.setContentOffset(CGPoint(x: 0, y: LazyListTestCase.bottomOffset(of: scroll) - 2 * scroll.bounds.height),
                                animated: false)
        HostedSummary.pump(1.5)
        room.intents.removeAll()
        let gone = Int(first)...Int(first + 3)
        room.state = Self.room(200, skipping: Set(gone))
        XCTAssertTrue(quiet(), "the room settles")
        let held = messageFrames(in: window)
        print("ROOMLIST first held \(first) taken away: holds \(held.keys.min() ?? 0)-\(held.keys.max() ?? 0)")
        XCTAssertNil(held[first])
        XCTAssertEqual(held.keys.min(), first + 4, "held from the next message")
        XCTAssertNotNil(held[200], "to the newest")
        XCTAssertGreaterThan(LazyListTestCase.bottomOffset(of: scroll) - scroll.contentOffset.y, scroll.bounds.height,
                             "the reader is still up the room")
        XCTAssertFalse(room.intents.contains(.readerAtBottom(true)), "and not told they are at the bottom")
    }

    /// Carter's blank room after Jump to latest, as the Mac reproduced it: up a long room, back in it by a link (the
    /// room made again, at the message linked), then Jump to latest, which keeps only the newest rows and opens a new
    /// list in the same update. At the largest text size, with tall reports. The newest message is on screen within a
    /// second, at the bottom.
    func test_jump_to_latest_after_the_room_is_made_again_and_trimmed_shows_the_newest_rows() throws {
        try XCTSkipUnless(Self.holdsWindow, "the window is iOS 18 and later")
        let tall: (Int) -> Bool = { $0 % 3 == 0 }
        for run in 1...2 {
            let room = JumpRoom(Self.room(300, tall: tall, jumpDownKeepsLatest: true))
            let window = try show(JumpHost(room: room))
            XCTAssertTrue(quiet(), "the room settles")
            let first = try XCTUnwrap(LazyListTestCase.list(in: window), "the room's list")
            first.setContentOffset(CGPoint(x: 0, y: max(0, LazyListTestCase.bottomOffset(of: first)
                                                         - 5 * first.bounds.height)), animated: false)
            HostedSummary.pump(1)
            // Back by a link to a message up the room: the room is made again, opened at it.
            room.state = Self.room(300, tall: tall, focus: 250, jumpDownKeepsLatest: true)
            room.epoch += 1
            XCTAssertTrue(quiet(), "the room settles")
            let arrow = try XCTUnwrap(HostedSummary.wait(for: "pocket.room.jumpToLatest", in: window, timeout: 5),
                                      "the arrow shows, the reader up the room")
            room.intents.removeAll()
            XCTAssertTrue(arrow.accessibilityActivate())
            HostedSummary.pump(1)
            let list = try XCTUnwrap(LazyListTestCase.list(in: window), "the room's new list")
            let visible = visibleRect(of: list)
            let newest = messageFrames(in: window)[300]
            let fromBottom = LazyListTestCase.bottomOffset(of: list) - list.contentOffset.y
            print("ROOMLIST jump after a rebuild and a trim, run \(run): \(room.state.rows.count) rows; newest at "
                  + "\(newest.map { Int($0.minY) } ?? -1), screen \(Int(visible.minY))-\(Int(visible.maxY)); "
                  + "\(Int(fromBottom)) pt from the bottom")
            XCTAssertTrue(room.intents.contains(.keepLatestForJumpDown), "the room kept its newest rows")
            XCTAssertTrue(newest.map { $0.intersects(visible) } ?? false, "the newest message is on screen within a second")
            XCTAssertEqual(fromBottom, 0, accuracy: 2, "at the bottom")
            XCTAssertTrue(room.intents.contains(.messageOnScreen(id: Self.messageId(300), isOnScreen: true)),
                          "and seen")
            HostedSummary.close(window)
            self.window = nil
        }
    }

    // MARK: - What it costs

    /// What opening a room and a page cost, at the default and the largest text size, in a room of 400 with tall
    /// reports and 32,000-character ones (shown by their start). Printed for the record; bounded only against a list
    /// that holds far more than its window.
    func test_what_opening_and_a_page_cost_is_printed() throws {
        try XCTSkipUnless(Self.holdsWindow, "the window is iOS 18 and later")
        for (name, size) in [("default", DynamicTypeSize.large), ("AX5", DynamicTypeSize.accessibility5)] {
            let room = LazyListTestCase.Room(Self.room(400, tall: { $0 % 5 == 0 }, huge: { $0 % 25 == 0 }))
            let built = RenderTrace.builtCount(.roomRow)
            let started = Date()
            let window = try show(LazyListTestCase.RoomHost(room: room).environment(\.dynamicTypeSize, size))
            window.layoutIfNeeded()
            let open = Date().timeIntervalSince(started)
            XCTAssertTrue(quiet(), "the room settles")
            let made = RenderTrace.builtCount(.roomRow) - built
            let scroll = try XCTUnwrap(LazyListTestCase.list(in: window), "the room's list")
            let beforePage = RenderTrace.builtCount(.roomRow)
            let pageStarted = Date()
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
            var last = beforePage
            var lastChange = pageStarted
            let end = Date().addingTimeInterval(5)
            while Date() < end {
                HostedSummary.pump(0.01)
                let now = RenderTrace.builtCount(.roomRow)
                if now != last {
                    last = now
                    lastChange = Date()
                } else if Date().timeIntervalSince(lastChange) > 0.5 {
                    break
                }
            }
            let page = lastChange.timeIntervalSince(pageStarted)
            print("ROOMLIST cost \(name): open \(Int(open * 1_000)) ms for \(made) rows made; a page "
                  + "\(Int(page * 1_000)) ms for \(last - beforePage) rows")
            XCTAssertLessThan(open, 1.5, "\(name): opening the room's window")
            XCTAssertLessThanOrEqual(made, 2 * Self.opening, "\(name): opening makes the window's rows")
            HostedSummary.close(window)
            self.window = nil
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func show<Content: View>(_ content: Content) throws -> UIWindow {
        let window = try HostedSummary.host(content)
        self.window = window
        return window
    }

    /// Runs the main run loop until no row has been made or drawn for a second (at most 15 s).
    private func quiet() -> Bool {
        let end = Date().addingTimeInterval(15)
        var last = [RenderTrace.builtCount(.roomRow), RenderTrace.snapshot().draws]
        var quietSince = Date()
        while Date() < end {
            HostedSummary.pump(0.1)
            let now = [RenderTrace.builtCount(.roomRow), RenderTrace.snapshot().draws]
            if now != last {
                last = now
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= 1 {
                return true
            }
        }
        return false
    }

    /// The part of the list that can be read, in the window: its frame less what the bars and the box cover.
    private func visibleRect(of scroll: UIScrollView) -> CGRect {
        let frame = scroll.convert(scroll.bounds, to: nil)
        let insets = scroll.adjustedContentInset
        return CGRect(x: frame.minX, y: frame.minY + insets.top, width: frame.width,
                      height: frame.height - insets.top - insets.bottom)
    }

    /// The frames of the messages the list holds, in the window, by sequence (each message's row says its own).
    private func messageFrames(in window: UIWindow) -> [Int64: CGRect] {
        let prefix = "pocket.room.message."
        var frames: [Int64: CGRect] = [:]
        for element in HostedSummary.elements(in: window) {
            guard let id = HostedSummary.identifier(of: element), id.hasPrefix(prefix),
                  let sequence = Int64(id.dropFirst(prefix.count)) else { continue }
            frames[sequence] = element.accessibilityFrame
        }
        return frames
    }

    private static func messageId(_ index: Int) -> String { "evt-window-room-\(index)" }

    /// The messages said to be on screen.
    private static func seen(_ intents: [RoomChatIntent]) -> Set<String> {
        Set(intents.compactMap { intent -> String? in
            guard case .messageOnScreen(let id, true) = intent else { return nil }
            return id
        })
    }

    /// The previews asked for.
    private static func asked(_ intents: [RoomChatIntent]) -> Set<String> {
        Set(intents.compactMap { intent -> String? in
            guard case .attachmentAppeared(let id) = intent else { return nil }
            return id
        })
    }

    /// The message a photo is of ("att-<message>-<photo>").
    private static func owner(_ attachmentId: String) -> Int64? {
        let parts = attachmentId.split(separator: "-")
        return parts.count == 3 ? Int64(parts[1]) : nil
    }

    /// A room of `count` messages from `first`: agents and a person taking turns, a minute apart. `tall` ones run to
    /// `tallLines` lines; `huge` ones are 32,000 characters; `photos` gives each its photos. Made-up words only.
    static func room(_ count: Int, first: Int = 1, tall: (Int) -> Bool = { _ in false }, tallLines: Int = 20,
                     huge: (Int) -> Bool = { _ in false }, photos: (Int) -> Int = { _ in 0 },
                     skipping: Set<Int> = [], unreadCount: Int = 0, focus: Int64? = nil,
                     jumpDownKeepsLatest: Bool = false) -> RoomChatPresentationState {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let stamp = ISO8601DateFormatter()
        let agents = ["review-agent", "build-agent", "plan-agent"]
        var messages: [RoomChatMessageInput] = []
        for index in first..<(first + count) where !skipping.contains(index) {
            let author = index % 7 == 0 ? "human-alex" : agents[index % 3]
            let date = start.addingTimeInterval(Double(index) * 60)
            var text = "Message \(index)."
            if huge(index) {
                text = String(repeating: "A line of the long report, with its numbers 12345.\n", count: 640)
            } else if tall(index) {
                text = (1...tallLines).map { "Line \($0) of the report." }.joined(separator: "\n")
            }
            let chips = (0..<photos(index)).map {
                RoomAttachmentChip(attachmentId: "att-\(index)-\($0)", filename: "photo-\(index)-\($0).jpg",
                                   kind: .image)
            }
            messages.append(RoomChatMessageInput(id: messageId(index), sequenceId: Int64(index), kind: .message,
                                                 authorId: author, authorName: author,
                                                 isHuman: author.hasPrefix("human-"), text: text,
                                                 timestamp: stamp.string(from: date), date: date, attachments: chips))
        }
        return RoomChatPresentationState(sessionId: "window-room", title: "Room", messages: messages,
                                         ownAuthorIds: ["human-alex"], unreadCount: unreadCount,
                                         jumpDownKeepsLatest: jumpDownKeepsLatest, connection: .live,
                                         composer: RoomComposerState(canPost: true, disabledReason: nil),
                                         canReact: true, focusSequenceId: focus)
    }

    /// A room that keeps only its newest 60 rows when asked before a jump down, in the same update, as the room does;
    /// `epoch` makes its screen again, as a link back into the room does.
    @MainActor
    private final class JumpRoom: ObservableObject {
        @Published var state: RoomChatPresentationState
        @Published var epoch = 0
        var intents: [RoomChatIntent] = []

        init(_ state: RoomChatPresentationState) { self.state = state }

        func handle(_ intent: RoomChatIntent) {
            intents.append(intent)
            if intent == .keepLatestForJumpDown {
                state = RoomListWindowTests.room(60, first: 241, tall: { $0 % 3 == 0 })
            }
        }
    }

    private struct JumpHost: View {
        @ObservedObject var room: JumpRoom

        var body: some View {
            NavigationStack { RoomChatView(state: room.state) { room.handle($0) } }
                .id(room.epoch)
                .environment(\.dynamicTypeSize, .accessibility5)
        }
    }
}
