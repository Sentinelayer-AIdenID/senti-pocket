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
        static let own: Set<String> = ["human-reader"]

        init(_ inputs: [RoomChatMessageInput]) {
            self.inputs = inputs
            state = RoomChatPresentationState(sessionId: "stays", title: "Room", messages: [])
            publish()
        }

        func send(_ intent: RoomChatIntent) {
            guard case .readerAtBottom(let value) = intent, value != atBottom else { return }
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
                messages: inputs,
                ownAuthorIds: Self.own,
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

        var body: some View {
            NavigationStack {
                RoomChatView(state: room.state) { room.send($0) }
            }
            .dynamicTypeSize(textSize)
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
    private static func messages() -> [RoomChatMessageInput] {
        (1...60).map { index -> RoomChatMessageInput in
            let seq = Int64(index)
            switch index % 4 {
            case 0: return input(seq, "human-reader", "A note from the phone, \(index).")
            case 1: return input(seq, "review-agent", "Findings \(index):\n1. The **first** step.\n2. The `second` step.")
            case 2: return input(seq, "build-agent", String(repeating: "A longer status line about build \(index). ", count: 6))
            default: return input(seq, "design-agent", "Done, \(index).")
            }
        }
    }

    private static func arrival(_ seq: Int64) -> RoomChatMessageInput {
        input(seq, "review-agent", "An arrival, \(seq): " + String(repeating: "more words ", count: Int(seq % 5) * 6))
    }

    /// A long report, drawn whole (under `LongMessage`'s 1,000 characters and 30 lines): many times taller than the
    /// room's rows, whose heights are what the list estimates the rows it has not drawn yet by.
    private static func longArrival(_ seq: Int64) -> RoomChatMessageInput {
        input(seq, "review-agent", (1...12).map { "Part \($0) of report \(seq): the second screen still crowds its "
            + "buttons." }.joined(separator: "\n\n"))
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

    /// At the bottom, a follow scrolls to the end by the heights the list estimates for rows it has not drawn yet, and
    /// stops short when they are taller (in a burst at 60 a second, 102 to 436 points short; more at the largest text
    /// sizes): the reader is left a little up from the end, at a place they never chose. Where each follow lands is
    /// taken as a new reading, so one that stopped short is followed again until the end is in view. Here eight long
    /// reports arrive at once under a room of short rows.
    func test_a_follow_that_stops_short_of_the_end_is_followed_again() throws {
        try followsTallArrivalsToTheEnd(textSize: .large)
    }

    func test_a_follow_that_stops_short_of_the_end_is_followed_again_at_the_largest_text_size() throws {
        try followsTallArrivalsToTheEnd(textSize: .accessibility5)
    }

    private func followsTallArrivalsToTheEnd(textSize: DynamicTypeSize) throws {
        try XCTSkipUnless(Self.readsGeometry, "the exact place reads the scroll view's geometry (iOS 18 and later)")
        let room = Room(Self.messages())
        let list = try host(room, textSize: textSize)
        let height = list.contentSize.height
        RoomScrollTrace.start()
        room.arrive((61...80).map { Self.longArrival($0) })
        pump(0.1)
        wait("followed to the end of the long reports", seconds: 6) {
            list.contentSize.height > height && Self.atBottom(list)
        }
        pump(1)
        let follows = RoomScrollTrace.followsMade
        print("READER-STAYS-PUT tall-arrivals \(textSize) follows=\(follows) "
            + "end-below=\(Self.bottomOffset(of: list) - list.contentOffset.y) content=\(list.contentSize.height) "
            + "(was \(height))")
        XCTAssertGreaterThan(follows, 1, "the first follow reached the end: this case did not stop short")
        XCTAssertTrue(Self.atBottom(list), "the follow stopped short of the end and stayed there")
        XCTAssertTrue(room.atBottom)
        XCTAssertEqual(room.unreadCount, 0)
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

    // MARK: - Scrolling up without touching the list, while messages arrive

    /// VoiceOver's three-finger scroll moves the list a page with an animation, not by touch. While messages arrive
    /// faster than the room follows them, the end is pushed below, and a list moving up then was taken for the room
    /// settling its rows: the reader was pulled back down. The scroll is the reader's: they leave the bottom, and what
    /// arrives after it moves nothing.
    func test_voiceover_scrolling_up_while_messages_arrive_leaves_the_bottom() throws {
        try scrollsUpWhileMessagesArrive("voiceover") { list in
            // A three-finger swipe down: the page above.
            _ = list.accessibilityScroll(.down)
        }
    }

    /// A tap on the status bar, and a keyboard's arrows or Page Up, scroll the list with an animation too, not by touch.
    func test_an_animated_scroll_up_not_by_touch_while_messages_arrive_leaves_the_bottom() throws {
        try scrollsUpWhileMessagesArrive("animated") { list in
            list.setContentOffset(CGPoint(x: 0, y: list.contentOffset.y - list.bounds.height * 0.8), animated: true)
        }
    }

    private func scrollsUpWhileMessagesArrive(_ name: String, scroll: (UIScrollView) -> Void) throws {
        try XCTSkipUnless(Self.readsGeometry, "the exact place reads the scroll view's geometry (iOS 18 and later)")
        let room = Room(Self.messages())
        let list = try host(room)
        var seq: Int64 = 61
        func arrive(_ count: Int) {
            for _ in 0..<count {
                room.arrive([Self.arrival(seq)])
                seq += 1
                pump(1.0 / 60.0)
            }
        }
        // More than the room follows in a second (`RoomBottomWatch.followLimit`): the end stays below until the second
        // is up.
        arrive(26)
        XCTAssertFalse(Self.atBottom(list), "the end is below when the reader scrolls (the arrivals pushed it)")
        let before = list.contentOffset.y
        scroll(list)
        // The scroll's animation lands before the room's next follow is due (the follow limit's second is up).
        var highest = before
        let scrolling = Date().addingTimeInterval(0.4)
        while Date() < scrolling {
            pump(0.02)
            highest = min(highest, list.contentOffset.y)
        }
        let scrolledTo = list.contentOffset.y
        print("READER-STAYS-PUT \(name) scroll: \(before) -> highest \(highest) -> \(scrolledTo) "
            + "(end at \(Self.bottomOffset(of: list)))")
        XCTAssertLessThan(highest, before - 300, "\(name): the list was scrolled up a page")
        XCTAssertEqual(scrolledTo, highest, accuracy: 1, "\(name): the reader was pulled back down at once")
        arrive(14)
        pump(1.5)
        print("READER-STAYS-PUT \(name) after: \(list.contentOffset.y) unread=\(room.unreadCount)")
        XCTAssertEqual(list.contentOffset.y, scrolledTo, accuracy: 1, "\(name): the reader was pulled back down")
        XCTAssertFalse(room.atBottom, "\(name): the reader left the bottom")
        XCTAssertGreaterThan(room.unreadCount, 0, "\(name): what arrived after is counted for the arrow")
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
