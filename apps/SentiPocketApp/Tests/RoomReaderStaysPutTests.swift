import Foundation
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// A reader who is not at the very bottom of a room is never moved, by an arrival or by their own send; a reader at the
/// very bottom follows what arrives (Carter, #61581). These host the room in a window on the simulator, as
/// `RoomBottomFlapTests` do, and move its list as a reader would, through its scroll view.
///
/// "At the bottom" is the end of the room within `RoomReaderPlace.atBottomDistance` of the bottom of what can be read,
/// from the scroll view's own geometry (iOS 18 and later). It used to be a 1-point marker at the end of the lazy list
/// coming into view, which it does while still hidden under the composer: a reader a few lines up was taken for one at
/// the bottom, and the next message scrolled them down.
@MainActor
final class RoomReaderStaysPutTests: XCTestCase {
    private var window: UIWindow?

    /// The coordinator's side of the reader's place, as `RoomChatCoordinator` keeps it: arrivals while away are counted,
    /// coming back clears them.
    private final class Room: ObservableObject {
        @Published private(set) var state: RoomChatPresentationState
        private var inputs: [RoomChatMessageInput]
        private var pending: [RoomChatPendingRow] = []
        private var unread = 0
        private(set) var atBottom = true
        /// Every place the room was told (`readerAtBottom`), in order, as told.
        private(set) var placesTold: [Bool] = []
        /// Shows no messages, as while it loads: its list is put away, and built anew when they show again.
        var emptied = false {
            didSet { publish() }
        }
        static let own: Set<String> = ["human-reader"]

        init(_ inputs: [RoomChatMessageInput]) {
            self.inputs = inputs
            state = RoomChatPresentationState(sessionId: "stays", title: "Room", messages: [])
            publish()
        }

        func send(_ intent: RoomChatIntent) {
            guard case .readerAtBottom(let value) = intent else { return }
            placesTold.append(value)
            guard value != atBottom else { return }
            atBottom = value
            if value, unread > 0 {
                unread = 0
                publish()
            }
        }

        func arrive(_ more: [RoomChatMessageInput]) {
            inputs += more
            if !atBottom { unread += more.count }
            publish()
        }

        /// The reader sends: the message waits at the bottom as a pending row, as the coordinator shows it.
        func sendMessage(_ text: String) {
            pending.append(RoomChatPendingRow(clientId: "sent-\(pending.count)", text: text, status: .sending))
            publish()
        }

        var unreadCount: Int { unread }

        private func publish() {
            state = RoomChatPresentationState(
                sessionId: "stays",
                title: "Room",
                messages: emptied ? [] : inputs,
                ownAuthorIds: Self.own,
                unreadDividerSequence: unread > 0 ? inputs[inputs.count - unread].sequenceId : nil,
                unreadCount: unread,
                connection: .live,
                pending: pending,
                composer: RoomComposerState(canPost: true, disabledReason: nil)
            )
        }
    }

    private struct Host: View {
        @ObservedObject var room: Room
        var textSize: DynamicTypeSize = .large
        var reduceMotion = false

        var body: some View {
            NavigationStack {
                RoomChatView(state: room.state) { room.send($0) }
            }
            .dynamicTypeSize(textSize)
            .environment(\._accessibilityReduceMotion, reduceMotion)
        }
    }

    // MARK: - The room

    private static let start = Date(timeIntervalSince1970: 1_793_000_000)

    private static func input(_ seq: Int64, _ author: String, _ text: String) -> RoomChatMessageInput {
        let date = start.addingTimeInterval(Double(seq) * 30)
        return RoomChatMessageInput(
            id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: author, authorName: author,
            isHuman: author.hasPrefix("human-"), text: text, timestamp: ISO8601DateFormatter().string(from: date), date: date
        )
    }

    /// Several screens of messages of every length.
    private static func messages(count: Int = 60) -> [RoomChatMessageInput] {
        (1...count).map { index -> RoomChatMessageInput in
            let seq = Int64(index)
            switch index % 4 {
            case 0: return input(seq, "human-reader", "A note from the phone, \(index).")
            case 1: return input(seq, "review-agent", "Findings \(index):\n1. The **first** step.\n2. The `second` step.")
            case 2: return input(seq, "build-agent", String(repeating: "A longer status line about build \(index). ", count: 6))
            default: return input(seq, "design-agent", "Done, \(index).")
            }
        }
    }

    /// A room where every other message holds a code block, which scrolls sideways inside its row.
    private static func codeMessages(count: Int) -> [RoomChatMessageInput] {
        (1...count).map { index -> RoomChatMessageInput in
            let seq = Int64(index)
            guard index % 2 == 0 else { return input(seq, "human-reader", "A note from the phone, \(index).") }
            return input(seq, "build-agent", "Build \(index):\n```\nxcodebuild test -scheme SentiPocket -destination "
                + "'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SentiPocketAppTests \(index)\n```")
        }
    }

    /// Rows of very different heights: long reports, code, one-line notes, paragraphs.
    private static func unevenMessages(from first: Int64, count: Int) -> [RoomChatMessageInput] {
        (first..<first + Int64(count)).map { seq -> RoomChatMessageInput in
            switch seq % 5 {
            case 0: return longArrival(seq)
            case 2: return input(seq, "build-agent", "Build \(seq):\n```\nswift build -c release \(seq)\nswift test\n```")
            case 4: return input(seq, "design-agent", String(repeating: "A paragraph about screen \(seq). ", count: 7))
            default: return input(seq, "human-reader", "OK, \(seq).")
            }
        }
    }

    private static func arrival(_ seq: Int64) -> RoomChatMessageInput {
        input(seq, "review-agent", "An arrival, \(seq): " + String(repeating: "more words ", count: Int(seq % 5) * 6))
    }

    /// A long report, drawn whole (under `LongMessage`'s 1,000 characters and 30 lines): many times taller than the
    /// room's rows, whose heights are what the list estimates the rows it has not drawn yet by. Each one's words differ
    /// from the next one's: reports alike but for their numbers fold into one row with a count (`RoomChatRepeats`).
    private static func longArrival(_ seq: Int64) -> RoomChatMessageInput {
        let screen = ["sign-in", "room list", "composer", "call", "settings", "search", "thread", "profile", "inbox",
                      "files"][Int(seq % 10)]
        return input(seq, "review-agent", (1...12).map { "Part \($0) of report \(seq): the \(screen) screen still "
            + "crowds its buttons." }.joined(separator: "\n\n"))
    }

    /// The rows a room draws small: the orchestrator's cost lines (background, and alike but for their numbers, so
    /// they fold into one row with a count), an agent speaking to another agent (a background line), an agent's notice
    /// repeating with only its numbers changing (one row with its count), a checkpoint and an agent joining.
    private static func compactArrivals(from seq: Int64) -> [(kind: String, row: RoomChatMessageInput)] {
        let date = start.addingTimeInterval(Double(seq) * 30)
        let stamp = ISO8601DateFormatter().string(from: date)
        func row(_ offset: Int64, _ kind: RoomChatMessageInput.Kind, _ author: String, _ text: String) -> RoomChatMessageInput {
            RoomChatMessageInput(id: "evt-\(seq + offset)", sequenceId: seq + offset, kind: kind, authorId: author,
                                 authorName: author, isHuman: false, text: text, timestamp: stamp, date: date)
        }
        return [
            ("cost line", row(0, .message, "respawn-orchestrator", "[cost] box-1: $12.64 est over 140 calls")),
            ("cost line folding", row(1, .message, "respawn-orchestrator", "[cost] box-2: $13.71 est over 143 calls")),
            ("background line", row(2, .message, "build-agent", "@review-agent the build is green on shard 3.")),
            ("repeated notice", row(3, .message, "build-agent", "Retrying the upload of build 319: attempt 1 of 40")),
            ("repeated notice folding", row(4, .message, "build-agent", "Retrying the upload of build 319: attempt 2 of 40")),
            ("checkpoint", row(5, .checkpoint, "senti", "Build 319 reviewed: 2 findings, both fixed")),
            ("join", row(6, .memberJoined, "senti", "agent-7"))
        ]
    }

    // MARK: - The cases

    /// 120 points up the end of the room is under the composer, where the marker still counted as in view: the reader
    /// is away from the bottom, the arrival is counted for the arrow, and it moves nothing.
    func test_a_few_lines_up_is_away_from_the_bottom_and_an_arrival_moves_nothing() throws {
        try XCTSkipUnless(Self.readsGeometry, "the exact place reads the scroll view's geometry (iOS 18 and later)")
        let room = Room(Self.messages())
        let list = try host(room)
        let up = Self.bottomOffset(of: list) - 120
        list.setContentOffset(CGPoint(x: 0, y: up), animated: false)
        wait("away from the bottom", seconds: 3) { !room.atBottom }
        XCTAssertFalse(room.atBottom, "120 points up is away from the bottom")

        room.arrive([Self.arrival(61)])
        pump(1)
        XCTAssertEqual(list.contentOffset.y, up, accuracy: 1, "the arrival moved the reader")
        XCTAssertEqual(room.unreadCount, 1, "and it is counted for the arrow")
    }

    /// A couple of lines up, the end of the room still under the composer: the rows a room draws small arriving one by
    /// one (each a few points tall, so the old marker was still "in view" under the composer) move nothing.
    func test_a_couple_of_lines_up_small_rows_arriving_move_nothing() throws {
        try XCTSkipUnless(Self.readsGeometry, "the exact place reads the scroll view's geometry (iOS 18 and later)")
        let room = Room(Self.messages())
        let list = try host(room)
        let up = Self.bottomOffset(of: list) - 60
        list.setContentOffset(CGPoint(x: 0, y: up), animated: false)
        wait("away from the bottom", seconds: 3) { !room.atBottom }
        XCTAssertFalse(room.atBottom, "60 points up is away from the bottom")

        for arrival in Self.compactArrivals(from: 61) {
            room.arrive([arrival.row])
            pump(0.4)
            XCTAssertEqual(list.contentOffset.y, up, accuracy: 1, "a \(arrival.kind) arriving moved the reader")
        }
        XCTAssertFalse(room.atBottom)
    }

    /// A gentle coast up from the bottom moves a third of a point a frame near its end: measured frame to frame it never
    /// looked like leaving, and the next message pulled the reader down. Here the list moves up 36 points in 0.33-point
    /// steps, one per frame: the reader is away from the bottom, and an arrival moves nothing.
    func test_a_slow_coast_a_little_way_up_leaves_the_bottom() throws {
        try XCTSkipUnless(Self.readsGeometry, "the exact place reads the scroll view's geometry (iOS 18 and later)")
        let room = Room(Self.messages())
        let list = try host(room)
        var offset = list.contentOffset.y
        let target = Self.bottomOffset(of: list) - 36
        while offset > target {
            offset = max(target, offset - 1.0 / 3.0)
            list.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            pump(1.0 / 60.0)
        }
        wait("away from the bottom", seconds: 3) { !room.atBottom }
        XCTAssertFalse(room.atBottom, "36 points up, reached a third of a point at a time, is away from the bottom")

        room.arrive([Self.arrival(61)])
        pump(1)
        XCTAssertEqual(list.contentOffset.y, offset, accuracy: 1, "the arrival moved the reader")
    }

    /// The scroll view's readings come while the list is laid out. Acting on one there (a follow, the reader's place)
    /// changes the list again in the same frame, and SwiftUI warns "tried to update multiple times per frame". Each is
    /// only kept, and taken when the screen next draws: through a follow at the bottom, the reader leaving, and arrivals
    /// while away, readings are taken, and never while the geometry is being read.
    func test_a_reading_is_never_taken_while_the_list_is_laid_out() throws {
        try XCTSkipUnless(Self.readsGeometry, "the scroll view's readings are iOS 18 and later")
        let room = Room(Self.messages())
        let list = try host(room)
        RoomScrollTrace.start()
        try followLeaveAndArrive(room, list)
        let trace = RoomScrollTrace.snapshot()
        print("ROOM-SCROLL-TRACE taken=\(trace.taken) taken-while-reading=\(trace.takenWhileReading)")
        XCTAssertGreaterThan(trace.taken, 2, "readings were taken: the follow, the leaving")
        XCTAssertEqual(trace.takenWhileReading, 0, "a reading was acted on while the list was laid out")
    }

    /// At the bottom, a burst faster than the room follows (more than `RoomBottomWatch`'s 20 a second): the follow
    /// over the limit is made once the second is up, not dropped, so the reader ends at the bottom with the last of it.
    func test_a_burst_faster_than_twenty_a_second_still_ends_at_the_bottom() throws {
        try XCTSkipUnless(Self.readsGeometry, "the exact place reads the scroll view's geometry (iOS 18 and later)")
        let room = Room(Self.messages())
        let list = try host(room)
        let height = list.contentSize.height
        for seq in Int64(61)...100 {
            room.arrive([Self.arrival(seq)])
            pump(1.0 / 60.0)
        }
        wait("followed to the end of the burst", seconds: 4) { list.contentSize.height > height && Self.atBottom(list) }
        XCTAssertTrue(Self.atBottom(list), "the last of the burst was not followed")
        XCTAssertTrue(room.atBottom)
        XCTAssertEqual(room.unreadCount, 0)
    }

    /// At the bottom, what arrives is followed by the room's own scroll to its end (the list's scroll view's, as the
    /// arrow's): on its way the rows that come into sight are measured, and where that moves the end it goes on to the
    /// new end, so it lands there the first time. SwiftUI's animated scroll to the bottom marker went by the heights the
    /// list estimated for rows it had not drawn, and stopped short when they were taller (in a burst at 60 a second,
    /// 102 to 436 points short; at the largest text size every batch of twenty long reports in CI took a second
    /// follow). At the largest text size, twenty long reports arrive at once under a room of short rows, three times;
    /// each is followed once, to the end, and never read as the reader leaving.
    func test_a_follow_lands_at_the_end_the_first_time_at_the_largest_text_size() throws {
        try followLandsFirstTime(textSize: .accessibility5, room: Self.messages()) { seq in
            (seq..<seq + 20).map { Self.longArrival($0) }
        }
    }

    /// The same at the default size in a room of rows of very different heights (long reports, code, one-line notes,
    /// paragraphs), twenty of them arriving at once.
    func test_a_follow_lands_at_the_end_the_first_time_in_a_room_of_uneven_rows() throws {
        try followLandsFirstTime(textSize: .large, room: Self.unevenMessages(from: 1, count: 120)) { seq in
            Self.unevenMessages(from: seq, count: 20)
        }
    }

    private func followLandsFirstTime(textSize: DynamicTypeSize, room messages: [RoomChatMessageInput],
                                      arrivals: (Int64) -> [RoomChatMessageInput]) throws {
        try XCTSkipUnless(Self.readsGeometry, "the exact place reads the scroll view's geometry (iOS 18 and later)")
        let room = Room(messages)
        let list = try host(room, textSize: textSize)
        var seq = Int64(messages.count + 1)
        for batch in 1...3 {
            let height = list.contentSize.height
            let told = room.placesTold.count
            RoomScrollTrace.start()
            let batchArrivals = arrivals(seq)
            seq += Int64(batchArrivals.count)
            room.arrive(batchArrivals)
            pump(0.1)
            wait("batch \(batch) followed to the end", seconds: 8) { list.contentSize.height > height && Self.atBottom(list) }
            pump(1)
            let follows = RoomScrollTrace.followsMade
            print("READER-STAYS-PUT follow-lands \(textSize) batch=\(batch) follows=\(follows) "
                + "end-below=\(Self.bottomOffset(of: list) - list.contentOffset.y) content=\(list.contentSize.height) "
                + "(was \(height)) told=\(room.placesTold.dropFirst(told))")
            XCTAssertTrue(Self.atBottom(list), "batch \(batch): the follow did not reach the end")
            XCTAssertEqual(follows, 1, "batch \(batch): the follow did not land at the end the first time")
            XCTAssertFalse(room.placesTold.dropFirst(told).contains(false),
                           "batch \(batch): the room's own follow was read as the reader leaving")
        }
        XCTAssertTrue(room.atBottom)
        XCTAssertEqual(room.unreadCount, 0)
    }

    /// A burst at the bottom is followed by the room's own scroll to its end, retaken as more arrives: the reader is
    /// never taken to have left, and the last of it lands with no step bigger than a few points.
    func test_a_burst_at_the_bottom_is_followed_by_the_rooms_own_scroll_never_as_the_reader_leaving() throws {
        try XCTSkipUnless(Self.readsGeometry, "the exact place reads the scroll view's geometry (iOS 18 and later)")
        let room = Room(Self.messages())
        let list = try host(room)
        let window = try XCTUnwrap(self.window)
        let height = list.contentSize.height
        let told = room.placesTold.count
        let watch = FrameWatch(window: window, list: list)
        watch.mark = { room.atBottom }
        RoomScrollTrace.start()
        watch.start()
        for seq in Int64(61)...120 {
            room.arrive([Self.arrival(seq)])
            pump(1.0 / 60.0)
        }
        wait("followed to the end of the burst", seconds: 4) { list.contentSize.height > height && Self.atBottom(list) }
        pump(0.6)
        watch.stop()
        let steps = zip(watch.frames, watch.frames.dropFirst()).map { $1.offset - $0.offset }
        let landing = steps.last { abs($0) > 0.01 } ?? 0
        let landings = RoomScrollTrace.listLandings
        let mostInAFrame = Self.mostBuiltInAFrame(watch.frames)
        print("READER-STAYS-PUT burst-follow frames=\(watch.frames.count) up-steps=\(steps.filter { $0 < -2 }.count) "
            + "landing=\(String(format: "%.1f", landing)) told=\(room.placesTold.dropFirst(told)) "
            + "landings=\(landings.all) moved-by-swiftui=\(landings.movedBySwiftUI) "
            + "largest-snap=\(String(format: "%.1f", landings.largestSnap)) most-built-in-a-frame=\(mostInAFrame)")
        print("READER-STAYS-PUT burst-follow each-frame " + Self.eachFrame(watch.frames))
        XCTAssertEqual(landings.movedBySwiftUI, 0, "SwiftUI's scroll to the marker moved the list after UIKit's")
        XCTAssertGreaterThanOrEqual(landings.all, 1, "the room's own follow did not land")
        XCTAssertLessThanOrEqual(mostInAFrame, LazyListBuildTests.mostBuiltPerStep, "rows built in one frame")
        XCTAssertLessThanOrEqual(landings.largestSnap, Self.landingStep, "it landed with a snap of \(landings.largestSnap) pt")
        XCTAssertTrue(Self.atBottom(list), "the last of the burst was not followed")
        XCTAssertFalse(room.placesTold.dropFirst(told).contains(false), "the room's own follow was read as the reader leaving")
        XCTAssertEqual(steps.filter { $0 < -2 }.count, 0, "the list went up on its way down")
    }

    /// A finger on the list while the room follows an arrival stops the follow, and the list is the reader's: here the
    /// room's scroll is stopped as a touch stops it, two frames into it, and the list moved up 180 points; it stays
    /// where it was put, and the reader has left the bottom.
    func test_a_drag_while_an_arrival_is_followed_stops_the_follow_where_the_reader_puts_the_list() throws {
        try XCTSkipUnless(Self.readsGeometry, "the exact place reads the scroll view's geometry (iOS 18 and later)")
        let room = Room(Self.messages())
        let list = try host(room)
        let window = try XCTUnwrap(self.window)
        let watch = FrameWatch(window: window, list: list)
        var put: CGFloat?
        watch.onFrame = { frame in
            Self.dragUp(list, at: frame, from: 2, put: &put)
        }
        watch.start()
        room.arrive([Self.longArrival(61)])
        pump(1.5)
        watch.stop()
        let leftAt = try XCTUnwrap(put, "the list was taken")
        print("READER-STAYS-PUT drag-during-follow put=\(Int(leftAt)) now=\(Int(list.contentOffset.y)) "
            + "end=\(Int(Self.bottomOffset(of: list))) atBottom=\(room.atBottom)")
        XCTAssertEqual(list.contentOffset.y, leftAt, accuracy: 1, "the follow went on after the reader took the list")
        XCTAssertFalse(room.atBottom, "the reader moved the list up and is away from the bottom")
    }

    /// Within the bottom's 24 points the reader is at the bottom, and follows what arrives.
    func test_at_the_very_bottom_the_reader_follows_what_arrives() throws {
        try XCTSkipUnless(Self.readsGeometry, "the exact place reads the scroll view's geometry (iOS 18 and later)")
        let room = Room(Self.messages())
        let list = try host(room)
        list.setContentOffset(CGPoint(x: 0, y: Self.bottomOffset(of: list) - 10), animated: false)
        pump(0.5)
        XCTAssertTrue(room.atBottom, "10 points up is still the bottom")

        let height = list.contentSize.height
        for seq in Int64(61)...66 {
            room.arrive([Self.arrival(seq)])
            pump(0.15)
        }
        wait("followed to the new bottom", seconds: 3) { list.contentSize.height > height && Self.atBottom(list) }
        XCTAssertTrue(Self.atBottom(list), "at the bottom after the arrivals")
        XCTAssertTrue(room.atBottom)
        XCTAssertEqual(room.unreadCount, 0, "nothing is unread at the bottom")
    }

    /// A send from up the room used to put the room back at its newest rows as a new list. The list is the same one,
    /// still where the reader had it, and the reader is still away from the bottom.
    func test_sending_from_up_the_room_keeps_the_list_and_the_readers_place() throws {
        let room = Room(Self.messages())
        let list = try host(room)
        let up = Self.bottomOffset(of: list) - 600
        list.setContentOffset(CGPoint(x: 0, y: up), animated: false)
        wait("away from the bottom", seconds: 3) { !room.atBottom }

        room.sendMessage("Sent from up the room.")
        pump(1)
        let now = try XCTUnwrap(window.flatMap { Self.list(in: $0) })
        XCTAssertTrue(now === list, "the room was put back at its newest rows as a new list")
        XCTAssertEqual(list.contentOffset.y, up, accuracy: 1, "the send moved the reader")
        XCTAssertFalse(room.atBottom, "still away from the bottom")
    }

    /// Sending at the bottom follows the message there.
    func test_sending_at_the_bottom_follows_the_message_down() throws {
        let room = Room(Self.messages())
        let list = try host(room)
        let height = list.contentSize.height
        room.sendMessage("Sent at the bottom.")
        wait("followed to the message", seconds: 3) { list.contentSize.height > height && Self.atBottom(list) }
        XCTAssertTrue(Self.atBottom(list), "at the bottom with the message")
        XCTAssertTrue(room.atBottom)
    }

    // MARK: - The arrow's way down a long room

    /// From far up a long room the arrow takes the reader down to the latest in the list as it is. It used to build the
    /// room again as a new list at its newest rows: the screen went dark, glitched, then showed the bottom (Carter).
    /// Every frame on the way is recorded: the list is the same one throughout, the last stretch is seen scrolling, and
    /// it ends at the bottom. The list is first put six rows above the end, at once, and SwiftUI draws the rows there one
    /// frame later: that one frame (8 to 16 ms) has none, and is allowed; no other may. The rows on the way are not
    /// drawn: an animated scroll the whole way down draws every one, which once froze the app from up a long history.
    func test_the_arrow_takes_a_reader_far_up_a_long_room_down_in_the_same_list_frame_by_frame() throws {
        let jump = try farJump(textSize: .large)
        XCTAssertGreaterThanOrEqual(jump.scrolling, 4, "the way down was not seen scrolling")
        assertLands(jump)
    }

    /// The same at the largest text size, where a row can be taller than the screen. Put six rows above the end by the
    /// rows' estimated heights, the list can already be at the end or past it (in CI it was 827 points past): it is then
    /// placed there at once, not animated back up. At most one step up, the placing, and never a scroll up.
    func test_the_arrow_takes_a_reader_far_up_a_long_room_down_at_the_largest_text_size() throws {
        let jump = try farJump(textSize: .accessibility5)
        XCTAssertFalse(jump.placesTold.contains(false), "the jump was read as the reader leaving")
    }

    /// The rows the list builds on the way are the ones around where it lands: no more than a list builds in any one
    /// step (`LazyListBuildTests.mostBuiltPerStep`), of a room of 400.
    private func farJump(textSize: DynamicTypeSize, reduceMotion: Bool = false) throws -> Jump {
        let jump = try arrowJump(rows: 400, textSize: textSize, reduceMotion: reduceMotion) { list in
            Self.bottomOffset(of: list) * 0.2
        }
        XCTAssertLessThanOrEqual(jump.blankFrames, 1, "frames on the way down with no messages drawn")
        XCTAssertLessThan(jump.draws, 100, "rows drawn on the way down: \(jump.draws) of 400")
        XCTAssertLessThanOrEqual(jump.built, LazyListBuildTests.mostBuiltPerStep,
                                 "rows built on the way down: \(jump.built) of the room's")
        // After the jump's own step: down, or a single placing step up, never an animation back up.
        let up = jump.steps.dropFirst().filter { $0 < -2 }
        XCTAssertLessThanOrEqual(up.count, 1, "the list went back up on its way down: \(up)")
        return jump
    }

    /// Two screens up the same room, the arrow scrolls the whole way, with messages drawn in every frame.
    func test_the_arrow_takes_a_reader_a_short_way_up_down_with_every_frame_drawn() throws {
        try shortJump(textSize: .large)
    }

    /// The same at the largest text size.
    func test_the_arrow_takes_a_reader_a_short_way_up_down_at_the_largest_text_size() throws {
        try shortJump(textSize: .accessibility5)
    }

    private func shortJump(textSize: DynamicTypeSize) throws {
        let jump = try arrowJump(rows: 400, textSize: textSize, from: Self.twoScreensUp)
        XCTAssertEqual(jump.blankFrames, 0, "frames on the way down with no messages drawn")
        XCTAssertGreaterThanOrEqual(jump.scrolling, 4, "the way down was not seen scrolling")
        XCTAssertLessThanOrEqual(jump.built, LazyListBuildTests.mostBuiltPerStep,
                                 "rows built on the way down: \(jump.built) of the room's")
        assertLands(jump)
    }

    /// With Reduce Motion on, the arrow places the room at its latest: one step, nothing blank but the frame the rows
    /// there are drawn in, and no second step where it lands.
    func test_with_reduce_motion_the_arrow_places_the_room_at_its_latest() throws {
        let jump = try farJump(textSize: .large, reduceMotion: true)
        let big = jump.steps.filter { abs($0) > Self.landingStep }
        XCTAssertLessThanOrEqual(big.count, 1, "more than one step: \(big)")
        XCTAssertLessThanOrEqual(jump.scrolling, 1, "it was animated")
        XCTAssertFalse(jump.placesTold.contains(false), "the jump was read as the reader leaving")
    }

    /// In a room whose rows scroll sideways (code blocks), the arrow scrolls the room's list, never a row's: the way
    /// down is seen scrolling and no row's own scroll view moved.
    func test_in_a_room_whose_rows_scroll_sideways_the_arrow_scrolls_the_room() throws {
        let jump = try arrowJump(rows: 400, inputs: Self.codeMessages(count: 400), from: Self.twoScreensUp)
        XCTAssertGreaterThan(jump.rowScrolls, 0, "rows with their own scroll views were on screen")
        XCTAssertEqual(jump.rowScrollsMoved, 0, "a row's own scroll view was scrolled")
        XCTAssertGreaterThanOrEqual(jump.scrolling, 4, "the way down was not seen scrolling")
        XCTAssertLessThanOrEqual(jump.built, LazyListBuildTests.mostBuiltPerStep,
                                 "rows built on the way down: \(jump.built) of the room's")
        assertLands(jump)
    }

    /// The room emptied (as while it loads) and filled again puts its list away and builds it anew: the arrow scrolls
    /// the new list, not the one put away.
    func test_after_the_list_is_built_anew_the_arrow_scrolls_the_new_list() throws {
        let jump = try arrowJump(rows: 400, rebuiltFirst: true, from: Self.twoScreensUp)
        XCTAssertGreaterThanOrEqual(jump.scrolling, 4, "the way down was not seen scrolling")
        assertLands(jump)
    }

    /// A message arriving while the arrow takes the reader down is not followed on its own (the reader is not at the
    /// bottom yet): the way down goes on, never back up, and ends at the latest, the arrival with it.
    func test_a_message_arriving_on_the_arrows_way_down_does_not_replace_it() throws {
        let jump = try arrowJump(rows: 400, from: Self.twoScreensUp) { frame, _, room in
            if frame == 3 { room.arrive([Self.arrival(401)]) }
        }
        let firstScroll = jump.steps.firstIndex { $0 > 0.5 } ?? 0
        let up = jump.steps.dropFirst(firstScroll).filter { $0 < -2 }
        XCTAssertEqual(up.count, 0, "the list went back up on its way down: \(up)")
        XCTAssertGreaterThanOrEqual(jump.scrolling, 4, "the way down was not seen scrolling")
        XCTAssertLessThanOrEqual(jump.built, LazyListBuildTests.mostBuiltPerStep,
                                 "rows built on the way down: \(jump.built) of the room's")
        XCTAssertFalse(jump.placesTold.contains(false), "the jump was read as the reader leaving")
    }

    /// A finger on the list on the arrow's way down stops it, and the list is the reader's: the room's scroll is
    /// stopped as a touch stops it, three frames into it, and the list moved up 180 points; it stays where it was put,
    /// away from the bottom.
    func test_a_drag_on_the_arrows_way_down_stops_it_where_the_reader_puts_the_list() throws {
        var put: CGFloat?
        let jump = try arrowJump(rows: 400, endsAtBottom: false, from: Self.twoScreensUp) { frame, list, _ in
            Self.dragUp(list, at: frame, from: 3, put: &put)
        }
        let leftAt = try XCTUnwrap(put, "the list was taken")
        print("READER-STAYS-PUT drag-during-jump put=\(Int(leftAt)) now=\(Int(jump.finalOffset)) told=\(jump.placesTold)")
        XCTAssertEqual(jump.finalOffset, leftAt, accuracy: 1, "the jump went on after the reader took the list")
        XCTAssertFalse(jump.placesTold.contains(true), "the reader was taken to be at the bottom")
    }

    /// Where the arrow's scroll lands: no frame without messages once it was seen scrolling, no step bigger than a few
    /// points, never read as the reader leaving, and told once it is at the bottom.
    private func assertLands(_ jump: Jump, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(jump.blankAfterScrolling, 0, "frames with no messages drawn once it was scrolling",
                       file: file, line: line)
        XCTAssertFalse(jump.placesTold.contains(false), "the jump was read as the reader leaving", file: file, line: line)
        XCTAssertTrue(jump.placesTold.contains(true), "the room was not told the reader is at the bottom",
                      file: file, line: line)
        XCTAssertGreaterThanOrEqual(jump.landings, 1, "the room's own scroll did not land", file: file, line: line)
        XCTAssertLessThanOrEqual(jump.largestSnap, Self.landingStep, "it landed with a snap of \(jump.largestSnap) pt",
                                 file: file, line: line)
        XCTAssertEqual(jump.voiceOverFocus.last, jump.newestRowId, "VoiceOver's focus was not put on the newest message",
                       file: file, line: line)
    }

    /// The far jump lands at the latest and says so, three times over: at `45d201a` its scroll stalled 343 points
    /// short of the end (SwiftUI laying the rows out stopped UIKit's scroll) and stayed there, never told at the
    /// bottom.
    func test_the_arrows_far_jump_lands_at_the_latest_every_time() throws {
        for round in 1...3 {
            let jump = try arrowJump(rows: 400) { list in Self.bottomOffset(of: list) * 0.2 }
            print("READER-STAYS-PUT far-jump round \(round): landings=\(jump.landings) told=\(jump.placesTold)")
            XCTAssertTrue(jump.placesTold.contains(true), "round \(round): not told the reader is at the bottom")
            XCTAssertGreaterThanOrEqual(jump.landings, 1, "round \(round): the room's own scroll did not land")
        }
    }

    /// The arrow during a burst at 60 a second: each chase reaches an end that has moved on, so after a second the
    /// room's follow takes it, the reader at the bottom. No frame builds more than a step may, SwiftUI's scroll never
    /// moves the list after UIKit's, it never goes up, and where it lands the step is a few points at most.
    func test_the_arrow_during_a_burst_lands_with_no_full_pass_and_no_snap() throws {
        let jump = try arrowJump(rows: 400, from: Self.twoScreensUp) { frame, _, room in
            if frame < 60 { room.arrive([Self.arrival(Int64(401 + frame))]) }
        }
        let firstScroll = jump.steps.firstIndex { $0 > 0.5 } ?? 0
        let up = jump.steps.dropFirst(firstScroll).filter { $0 < -2 }
        XCTAssertEqual(up.count, 0, "the list went back up on its way down: \(up)")
        XCTAssertLessThanOrEqual(jump.largestSnap, Self.landingStep, "it landed with a snap of \(jump.largestSnap) pt")
        XCTAssertFalse(jump.placesTold.contains(false), "the jump was read as the reader leaving")
    }

    /// With messages waiting, the arrow goes to the New messages line, and VoiceOver's focus goes there; the second
    /// tap goes to the latest, and the focus to the newest message (UIKit's scroll does not move it, and it could be
    /// left on a row now off screen).
    func test_after_the_arrow_voiceovers_focus_is_where_it_went() throws {
        try XCTSkipUnless(Self.readsGeometry, "the exact place reads the scroll view's geometry (iOS 18 and later)")
        let room = Room(Self.messages())
        let list = try host(room)
        let window = try XCTUnwrap(self.window)
        list.setContentOffset(CGPoint(x: 0, y: Self.bottomOffset(of: list) - 3 * list.bounds.height), animated: false)
        wait("away from the bottom", seconds: 3) { !room.atBottom }
        room.arrive((61...90).map { Self.arrival(Int64($0)) })
        wait("the arrivals counted", seconds: 3) { room.unreadCount == 30 }
        RoomScrollTrace.start()
        let arrow = try XCTUnwrap(HostedSummary.wait(for: "pocket.room.jumpToLatest", in: window), "the arrow shows")
        XCTAssertTrue(arrow.accessibilityActivate(), "the arrow could be pressed")
        pump(1.5)
        let first = RoomScrollTrace.listLandings.voiceOverFocus
        print("READER-STAYS-PUT voiceover first-tap focus=\(first)")
        XCTAssertEqual(first.last, RoomChatRow.unreadDivider.id, "VoiceOver's focus was not put on the New messages line")
        let again = try XCTUnwrap(HostedSummary.wait(for: "pocket.room.jumpToLatest", in: window), "the arrow shows")
        XCTAssertTrue(again.accessibilityActivate(), "the arrow could be pressed again")
        wait("down at the latest", seconds: 4) { Self.atBottom(list) }
        pump(1)
        let second = RoomScrollTrace.listLandings.voiceOverFocus
        print("READER-STAYS-PUT voiceover second-tap focus=\(second)")
        XCTAssertEqual(second.last, Self.newestRowId(room), "VoiceOver's focus was not put on the newest message")
    }

    /// "A few points": the most a frame may move the list where the room's own scroll lands.
    private static let landingStep: CGFloat = 4

    private static func twoScreensUp(_ list: UIScrollView) -> CGFloat {
        let visible = list.bounds.height - list.adjustedContentInset.top - list.adjustedContentInset.bottom
        return bottomOffset(of: list) - visible * 2
    }

    /// The reader's finger, as far as the room can tell: at frame `from` the room's scroll is stopped as a touch stops
    /// it (the list set where it is), then the list moves up 30 points a frame for six frames. `put` is where it was
    /// left.
    private static func dragUp(_ list: UIScrollView, at frame: Int, from: Int, put: inout CGFloat?) {
        guard frame >= from, frame <= from + 6 else { return }
        let y = frame == from ? list.contentOffset.y : (put ?? list.contentOffset.y) - 30
        list.setContentOffset(CGPoint(x: list.contentOffset.x, y: y), animated: false)
        put = y
    }

    /// What a jump down did, frame by frame from the tap.
    private struct Jump {
        let blankFrames: Int
        /// Frames with no messages drawn once the list was seen scrolling (its landing included).
        let blankAfterScrolling: Int
        let draws: Int
        let built: Int
        let scrolling: Int
        let steps: [CGFloat]
        /// The list's last step, where it landed.
        let landing: CGFloat
        let finalOffset: CGFloat
        /// Scroll views inside rows (a code block) on screen at the tap, and those of them that moved.
        let rowScrolls: Int
        let rowScrollsMoved: Int
        /// The places the room was told after the tap, in order.
        let placesTold: [Bool]
        /// The room's own scroll landed this many times, and SwiftUI's scroll to the marker after UIKit's moved the
        /// list this many times (`RoomScrollTrace.listLandings`); the most rows built in one frame; where VoiceOver's
        /// focus was put; the newest message's row.
        let landings: Int
        let landingsMovedBySwiftUI: Int
        /// The largest step put at once where the room's own scroll landed.
        let largestSnap: CGFloat
        let mostBuiltInAFrame: Int
        let voiceOverFocus: [String]
        let newestRowId: String?
    }

    /// The most rows built in any one frame of `frames` (each frame records the rows built so far).
    private static func mostBuiltInAFrame(_ frames: [FrameWatch.Frame]) -> Int {
        zip(frames, frames.dropFirst()).map { $1.built - $0.built }.max() ?? 0
    }

    /// Each frame: where the list was, what was drawn in the band, the rows built in it, "B" once the room says the
    /// reader is at the bottom.
    private static func eachFrame(_ frames: [FrameWatch.Frame]) -> String {
        zip(frames, [frames.first?.built ?? 0] + frames.map(\.built)).map { frame, before in
            "\(String(format: "%.0f", frame.offset))/\(frame.drawn)/+\(frame.built - before)"
                + "\(frame.mark ? "B" : "")\(frame.sameList ? "" : "*")"
        }.joined(separator: " ")
    }

    /// The newest message's row in the room as it is.
    private static func newestRowId(_ room: Room) -> String? {
        room.state.rows.last { if case .message = $0 { return true } else { return false } }?.id
    }

    /// Opens a room of `rows` messages (or `inputs`), puts the reader at `from` (an offset of the list), presses the
    /// arrow, and records every frame until a moment after the reader is down at the latest. `eachFrame` runs at each
    /// frame from the tap (its number, the list, the room). Checks what every jump down must do: the same list
    /// throughout, and (unless the reader takes the list on the way) the end reached.
    private func arrowJump(rows: Int, textSize: DynamicTypeSize = .large, reduceMotion: Bool = false,
                           inputs: [RoomChatMessageInput]? = nil, rebuiltFirst: Bool = false, endsAtBottom: Bool = true,
                           from: (UIScrollView) -> CGFloat,
                           eachFrame: ((Int, UIScrollView, Room) -> Void)? = nil) throws -> Jump {
        try XCTSkipUnless(Self.readsGeometry, "how far the end is comes from the scroll view's geometry (iOS 18 and later)")
        let room = Room(inputs ?? Self.messages(count: rows))
        let window = try HostedSummary.host(Host(room: room, textSize: textSize, reduceMotion: reduceMotion))
        addTeardownBlock { HostedSummary.close(window) }
        var opened: UIScrollView?
        let openedAtBottom = {
            opened = Self.list(in: window)
            guard let list = opened, list.contentSize.height > list.bounds.height * 2 else { return false }
            return Self.atBottom(list)
        }
        wait("the room opened at its newest rows", seconds: 20, openedAtBottom)
        if rebuiltFirst, let first = opened {
            room.emptied = true
            wait("the list put away", seconds: 5) { Self.list(in: window).map { $0.contentSize.height < 400 } ?? true }
            room.emptied = false
            wait("the room shown again at its newest rows", seconds: 20) { openedAtBottom() && opened !== first }
            XCTAssertFalse(opened === first, "the list was built anew")
        }
        let list = try XCTUnwrap(opened, "the room's list")
        pump(0.5)
        list.setContentOffset(CGPoint(x: 0, y: from(list)), animated: false)
        wait("away from the bottom", seconds: 3) { !room.atBottom }
        pump(1)
        let arrow = try XCTUnwrap(HostedSummary.wait(for: "pocket.room.jumpToLatest", in: window), "the arrow shows")

        let rowScrollViews = Self.scrollViews(in: list).map { ($0, $0.contentOffset) }
        let watch = FrameWatch(window: window, list: list)
        watch.mark = { room.atBottom }
        watch.start()
        pump(0.5)
        let tappedAt = watch.frames.count
        let told = room.placesTold.count
        RoomScrollTrace.start()
        watch.onFrame = { frame in
            if frame >= tappedAt { eachFrame?(frame - tappedAt, list, room) }
        }
        let drawsBefore = RenderTrace.snapshot().draws
        let builtBefore = RenderTrace.builtCount(.roomRow)
        XCTAssertTrue(arrow.accessibilityActivate(), "the arrow could be pressed")
        if endsAtBottom {
            wait("down at the latest", seconds: 4) { Self.list(in: window).map(Self.atBottom) ?? false }
            pump(0.6)
        } else {
            pump(1.5)
        }
        watch.stop()
        let rowScrollsMoved = rowScrollViews.filter { view, offset in
            view.window != nil && (abs(view.contentOffset.x - offset.x) > 0.5 || abs(view.contentOffset.y - offset.y) > 0.5)
        }.count
        let draws = RenderTrace.snapshot().draws - drawsBefore
        let built = RenderTrace.builtCount(.roomRow) - builtBefore

        let before = watch.frames[..<tappedAt].map(\.drawn).sorted()
        let during = Array(watch.frames[tappedAt...])
        let usual = before.isEmpty ? 0 : before[before.count / 2]
        let blankFrames = during.filter { $0.drawn < max(1, usual / 3) }.count
        let visible = list.bounds.height - list.adjustedContentInset.top - list.adjustedContentInset.bottom
        let steps = zip(during, during.dropFirst()).map { $1.offset - $0.offset }
        let scrolling = steps.filter { $0 > 0.5 && $0 < visible * 0.9 }.count
        let firstScroll = steps.firstIndex { $0 > 0.5 && $0 < visible * 0.9 }
        let blankAfterScrolling = firstScroll.map { first in
            during.dropFirst(first + 1).filter { $0.drawn < max(1, usual / 3) }.count
        } ?? 0
        let landing = steps.last { abs($0) > 0.01 } ?? 0
        let placesTold = Array(room.placesTold.dropFirst(told))
        let landings = RoomScrollTrace.listLandings
        let mostInAFrame = Self.mostBuiltInAFrame(Array(watch.frames[max(0, tappedAt - 1)...]))
        // The frame the room first says the reader is at the bottom: what it built (a body update there once walked
        // every row). And how far the list moved after it first stopped once it had been scrolling (a drift after
        // the landing).
        let fromTap = Array(watch.frames[max(0, tappedAt - 1)...])
        let flip = zip(fromTap, fromTap.dropFirst()).first { !$0.0.mark && $0.1.mark }.map { pair in pair.1.built - pair.0.built }
        let stopped = firstScroll.flatMap { first in steps[(first + 1)...].firstIndex { abs($0) < 0.5 } }
        let drift = stopped.map { steps[$0...].reduce(0, +) } ?? 0
        print("READER-STAYS-PUT arrow-jump at-bottom-frame-built=\(flip.map(String.init) ?? "none") "
            + "drift-after-stop=\(String(format: "%.1f", drift))")
        if let flip {
            XCTAssertLessThanOrEqual(flip, LazyListBuildTests.mostBuiltPerStep,
                                     "rows built in the frame the room said the reader is at the bottom")
        }
        print("READER-STAYS-PUT arrow-jump landings=\(landings.all) moved-by-swiftui=\(landings.movedBySwiftUI) "
            + "largest-snap=\(String(format: "%.1f", landings.largestSnap)) most-built-in-a-frame=\(mostInAFrame) "
            + "voiceover-focus=\(landings.voiceOverFocus)")
        print("READER-STAYS-PUT arrow-jump rows=\(rows) text=\(textSize) reduce-motion=\(reduceMotion) "
            + "frames=\(during.count) usual-drawn=\(usual) blank-frames=\(blankFrames) "
            + "blank-after-scrolling=\(blankAfterScrolling) scrolling-frames=\(scrolling) row-draws=\(draws) "
            + "rows-built=\(built) landing=\(String(format: "%.1f", landing)) row-scrolls=\(rowScrollViews.count) "
            + "row-scrolls-moved=\(rowScrollsMoved) told=\(placesTold) "
            + "steps=\(steps.filter { $0 != 0 }.map { String(format: "%.0f", $0) })")
        // Each frame from the last before the tap: where the list was, what was drawn in the band, the rows built in
        // that frame, and "B" once the room says the reader is at the bottom.
        print("READER-STAYS-PUT arrow-jump each-frame " + Self.eachFrame(Array(watch.frames[max(0, tappedAt - 1)...])))
        // The full pass a SwiftUI scroll made after UIKit's: never, and no frame builds more than a step may.
        XCTAssertEqual(landings.movedBySwiftUI, 0, "SwiftUI's scroll to the marker moved the list after UIKit's")
        XCTAssertLessThanOrEqual(mostInAFrame, LazyListBuildTests.mostBuiltPerStep, "rows built in one frame")
        XCTAssertGreaterThan(usual, 0, "what is drawn could be read before the tap")
        XCTAssertGreaterThan(during.count, 10, "frames were recorded on the way down")
        XCTAssertTrue(during.allSatisfy(\.sameList), "the room was built again as a new list")
        if endsAtBottom {
            XCTAssertTrue(Self.list(in: window).map(Self.atBottom) ?? false, "it ended at the bottom")
            XCTAssertTrue(room.atBottom)
        }
        return Jump(blankFrames: blankFrames, blankAfterScrolling: blankAfterScrolling, draws: draws, built: built,
                    scrolling: scrolling, steps: steps, landing: landing, finalOffset: list.contentOffset.y,
                    rowScrolls: rowScrollViews.count, rowScrollsMoved: rowScrollsMoved, placesTold: placesTold,
                    landings: landings.all, landingsMovedBySwiftUI: landings.movedBySwiftUI,
                    largestSnap: landings.largestSnap, mostBuiltInAFrame: mostInAFrame, voiceOverFocus: landings.voiceOverFocus,
                    newestRowId: Self.newestRowId(room))
    }

    /// The scroll views inside `view` (in a room's list: the rows' own, a code block's).
    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        view.subviews.flatMap { child -> [UIScrollView] in
            ((child as? UIScrollView).map { [$0] } ?? []) + scrollViews(in: child)
        }
    }

    /// Records each frame the screen draws (on the display link): where the list is, how many layers with something
    /// drawn in them lie where the reader reads (between the navigation bar and the composer), and whether it is still
    /// the same list. Reading the layers is cheap enough for every frame; drawing the screen to an image is not.
    @MainActor
    private final class FrameWatch: NSObject {
        struct Frame {
            let offset: CGFloat
            let drawn: Int
            let sameList: Bool
            /// The room's rows built so far (`RenderTrace`), and what `mark` said, at this frame.
            let built: Int
            let mark: Bool
        }

        private(set) var frames: [Frame] = []
        /// Read at each frame (the room says the reader is at the bottom).
        var mark: () -> Bool = { false }
        /// Runs at each frame recorded, with its number (from 0), after it is recorded.
        var onFrame: ((Int) -> Void)?
        private let window: UIWindow
        private let list: UIScrollView
        private var link: CADisplayLink?

        init(window: UIWindow, list: UIScrollView) {
            self.window = window
            self.list = list
        }

        func start() {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick() {
            let current = RoomReaderStaysPutTests.list(in: window) ?? list
            frames.append(Frame(offset: current.contentOffset.y, drawn: Self.drawn(in: current),
                                sameList: current === list, built: RenderTrace.builtCount(.roomRow), mark: mark()))
            onFrame?(frames.count - 1)
        }

        /// Layers with something drawn in them (text, an image, a fill) inside the list, overlapping what can be read.
        /// The list's bounds are where it is scrolled to in this frame.
        static func drawn(in list: UIScrollView) -> Int {
            let root = list.layer
            let insets = list.adjustedContentInset
            let band = CGRect(x: root.bounds.minX, y: root.bounds.minY + insets.top, width: root.bounds.width,
                              height: root.bounds.height - insets.top - insets.bottom)
            var count = 0
            var stack = root.sublayers ?? []
            while let layer = stack.popLast() {
                guard !layer.isHidden, layer.opacity > 0.01 else { continue }
                if layer.contents != nil || layer.backgroundColor != nil,
                   root.convert(layer.bounds, from: layer).intersects(band) {
                    count += 1
                }
                stack.append(contentsOf: layer.sublayers ?? [])
            }
            return count
        }
    }

    // MARK: - Running it

    /// Arrivals followed at the bottom, the reader leaving, arrivals while away.
    private func followLeaveAndArrive(_ room: Room, _ list: UIScrollView) throws {
        for seq in Int64(61)...64 {
            room.arrive([Self.arrival(seq)])
            pump(0.2)
        }
        wait("followed", seconds: 3) { Self.atBottom(list) }
        list.setContentOffset(CGPoint(x: 0, y: Self.bottomOffset(of: list) - 300), animated: false)
        wait("away from the bottom", seconds: 3) { !room.atBottom }
        for seq in Int64(65)...67 {
            room.arrive([Self.arrival(seq)])
            pump(0.2)
        }
    }

    private static var readsGeometry: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    /// The room in a window, opened at its newest rows.
    private func host(_ room: Room, textSize: DynamicTypeSize = .large) throws -> UIScrollView {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 5
        window.rootViewController = UIHostingController(rootView: Host(room: room, textSize: textSize))
        window.makeKeyAndVisible()
        self.window = window
        addTeardownBlock { [weak self] in
            self?.window?.isHidden = true
            self?.window = nil
        }
        var list: UIScrollView?
        // A hosted runner's first SwiftUI window can take a few seconds.
        wait("the room opened at its newest rows", seconds: 15) {
            list = Self.list(in: window)
            guard let list, list.contentSize.height > list.bounds.height * 2 else { return false }
            return Self.atBottom(list)
        }
        pump(0.5)
        return try XCTUnwrap(list, "the room's list")
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }

    private func wait(_ what: String, seconds: TimeInterval, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { pump(0.05) }
        if !condition() { XCTFail("timed out waiting: \(what)") }
    }

    /// The content offset at which the list shows its end.
    private static func bottomOffset(of scroll: UIScrollView) -> CGFloat {
        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
    }

    /// The end of the room within the bottom's 24 points of the composer (`RoomReaderPlace.atBottomDistance`): the room
    /// rests there, a few points above the very end (the list's own padding).
    private static func atBottom(_ scroll: UIScrollView) -> Bool {
        bottomOffset(of: scroll) - scroll.contentOffset.y < 24
    }

    /// The room's list: the tallest scroll view in the window.
    private static func list(in view: UIView) -> UIScrollView? {
        var found = view as? UIScrollView
        for child in view.subviews {
            if let inner = list(in: child), inner.contentSize.height > (found?.contentSize.height ?? 0) { found = inner }
        }
        return found
    }
}
