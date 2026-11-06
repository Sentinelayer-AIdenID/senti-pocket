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
        /// As the coordinator does from up a long history: with more than `RoomChatCoordinator.rowsKeptForTheJumpDown`
        /// messages the arrow keeps only the newest (`keepLatestForJumpDown`), and the room opens again at them.
        var trimsForJumpDown = false {
            didSet { publish() }
        }
        static let own: Set<String> = ["human-reader"]

        init(_ inputs: [RoomChatMessageInput]) {
            self.inputs = inputs
            state = RoomChatPresentationState(sessionId: "stays", title: "Room", messages: [])
            publish()
        }

        func send(_ intent: RoomChatIntent) {
            if case .keepLatestForJumpDown = intent, trimsForJumpDown {
                inputs = Array(inputs.suffix(RoomChatCoordinator.rowsKeptForTheJumpDown))
                atBottom = false
                publish()
                return
            }
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
                messages: inputs,
                ownAuthorIds: Self.own,
                unreadCount: unread,
                jumpDownKeepsLatest: trimsForJumpDown && inputs.count > RoomChatCoordinator.rowsKeptForTheJumpDown,
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

    /// At the bottom, a follow scrolls to the end by the heights the list estimates for rows it has not drawn yet, and
    /// stops short when they are taller (in a burst at 60 a second, 102 to 436 points short; more at the largest text
    /// sizes): the reader is left a little up from the end, at a place they never chose. Where each follow lands is
    /// taken as a new reading, even when it shows what the reading before the follow showed (the end below), so one
    /// that stopped short is followed again until the end is in view. A second follow needs no such retaking (the
    /// arrival's own reading, taken on the next frame, makes it); a follow made from a reading makes the next reading
    /// look the same, and that landing is seen only because it is retaken (`RoomScrollTrace.shortLandingsRetaken`).
    /// Here, at the largest text size, forty long reports arrive at once under a room of short rows, up to four times,
    /// until such a landing was retaken and followed.
    func test_a_follow_that_stops_short_of_the_end_is_followed_again() throws {
        try XCTSkipUnless(Self.readsGeometry, "the exact place reads the scroll view's geometry (iOS 18 and later)")
        let textSize = DynamicTypeSize.accessibility5
        let room = Room(Self.messages())
        let list = try host(room, textSize: textSize)
        // Up to four batches: whether a follow stops short depends on the heights the list has measured so far. One at
        // least must have had a landing short of the end retaken; in every batch the room never strands the reader
        // (warden's rule). Reaching the end every time is (b)'s: here the follows can stop short at this size (CI: 6,911
        // pt short after 5 follows), and the arrow then takes the reader down (the next test).
        var retaken = false
        var seq: Int64 = 61
        for batch in 1...4 where !retaken {
            let height = list.contentSize.height
            RoomScrollTrace.start()
            room.arrive((seq..<seq + 40).map { Self.longArrival($0) })
            seq += 40
            // Every 50 ms until the end is reached (at most 8 s): where the list is, how far the end is below, the
            // content's height, the follows made and the short landings retaken so far, the room's place.
            var timeline: [String] = []
            let end = Date().addingTimeInterval(8)
            // Since when the end has been out of view without a break (more than the bottom's 24 points below; only
            // its coming back within them resets it, not a follow), and the longest the room said the reader is at
            // the bottom past `strandedLimit` of that.
            var outOfViewSince: Date?
            var longestStranded: TimeInterval = 0
            pump(0.1)
            // Sampled until the end is reached (at most 8 s), then one second more: a strand that starts late is caught.
            var settledUntil: Date?
            while Date() < end {
                let below = Self.bottomOffset(of: list) - list.contentOffset.y
                if below > RoomReaderPlace.atBottomDistance {
                    let since = outOfViewSince ?? Date()
                    outOfViewSince = since
                    if room.atBottom { longestStranded = max(longestStranded, Date().timeIntervalSince(since)) }
                } else {
                    outOfViewSince = nil
                }
                let snap = RoomScrollTrace.snapshot()
                timeline.append("\(Int(list.contentOffset.y))/\(Int(below))/\(Int(list.contentSize.height))/"
                    + "f\(RoomScrollTrace.followsMade)r\(RoomScrollTrace.shortLandingsRetaken)t\(snap.taken)"
                    + "\(room.atBottom ? "B" : "")")
                if settledUntil == nil, list.contentSize.height > height, Self.atBottom(list) {
                    settledUntil = Date().addingTimeInterval(1)
                }
                if let settledUntil, Date() >= settledUntil { break }
                pump(0.05)
            }
            print("READER-STAYS-PUT tall-arrivals timeline batch=\(batch) longest-stranded="
                + "\(String(format: "%.2f", longestStranded)) s " + timeline.joined(separator: " "))
            XCTAssertLessThanOrEqual(longestStranded, Self.strandedLimit, "batch \(batch): the room said the reader "
                + "is at the bottom with the end out of view for \(String(format: "%.2f", longestStranded)) s")
            XCTAssertGreaterThan(list.contentSize.height, height, "batch \(batch): the reports did not grow the room")
            let follows = RoomScrollTrace.followsMade
            let shortLandings = RoomScrollTrace.shortLandingsRetaken
            print("READER-STAYS-PUT tall-arrivals \(textSize) batch=\(batch) follows=\(follows) "
                + "short-landings-retaken=\(shortLandings) "
                + "end-below=\(Self.bottomOffset(of: list) - list.contentOffset.y) content=\(list.contentSize.height) "
                + "(was \(height))")
            XCTAssertTrue(Self.atBottom(list) || !room.atBottom,
                          "batch \(batch): short of the end, and the room says the reader is at the bottom")
            if room.atBottom { XCTAssertEqual(room.unreadCount, 0, "batch \(batch): at the bottom with messages unread") }
            retaken = shortLandings > 0
        }
        XCTAssertTrue(retaken, "no follow's landing short of the end was retaken: this case did not test it")
    }

    /// At the largest text size, forty tall reports arriving at once under a room of short rows, twice: the room never
    /// says the reader is at the bottom while the end has been out of view for longer than `strandedLimit` (a reader
    /// stranded mid-room with the arrow hidden; at 32cca3f the follows stopped 5,597 pt short and the room said so for
    /// 7.6 s). Where the follows stop short, the arrow shows within that second, and its tap takes the reader down at
    /// least a screen (to the end at the largest text size is (b)'s: here the list the arrow opens at the newest rows
    /// can settle short of it by the rows' estimated heights, as on the Mac at 8962b6b).
    /// So that this always happens (in CI both batches reached the end), the room's placed follows and its one retry
    /// move nothing here (`RoomScrollTrace`'s DEBUG seam): every batch ends short, and the room must give up and show
    /// the arrow.
    func test_tall_arrivals_never_strand_the_reader_and_the_arrow_takes_them_down() throws {
        try XCTSkipUnless(Self.readsGeometry, "the exact place reads the scroll view's geometry (iOS 18 and later)")
        RoomScrollTrace.followMovesNothing = true
        RoomScrollTrace.injectedRetry = .movesNothing
        addTeardownBlock {
            RoomScrollTrace.followMovesNothing = false
            RoomScrollTrace.injectedRetry = nil
        }
        var endedShort = 0
        let room = Room(Self.messages())
        room.trimsForJumpDown = true
        let window = try HostedSummary.host(Host(room: room, textSize: .accessibility5))
        addTeardownBlock { HostedSummary.close(window) }
        wait("the room opened at its newest rows", seconds: 20) {
            guard let list = Self.list(in: window), list.contentSize.height > list.bounds.height * 2 else { return false }
            return Self.atBottom(list)
        }
        pump(0.5)
        var seq: Int64 = 61
        for batch in 1...2 {
            let list = try XCTUnwrap(Self.list(in: window), "the room's list")
            let height = list.contentSize.height
            room.arrive((seq..<seq + 40).map { Self.longArrival($0) })
            seq += 40
            var outOfViewSince: Date?
            var longestStranded: TimeInterval = 0
            var leftAt: Date?
            let end = Date().addingTimeInterval(8)
            pump(0.1)
            while Date() < end, !(list.contentSize.height > height && Self.atBottom(list)) {
                let below = Self.bottomOffset(of: list) - list.contentOffset.y
                if below > RoomReaderPlace.atBottomDistance {
                    let since = outOfViewSince ?? Date()
                    outOfViewSince = since
                    if room.atBottom {
                        longestStranded = max(longestStranded, Date().timeIntervalSince(since))
                    } else if leftAt == nil {
                        leftAt = Date()
                    }
                } else {
                    outOfViewSince = nil
                }
                if leftAt != nil { break }
                pump(0.05)
            }
            let below = Self.bottomOffset(of: list) - list.contentOffset.y
            XCTAssertGreaterThan(list.contentSize.height, height, "batch \(batch): the reports did not grow the room")
            print("READER-STAYS-PUT tall-arrivals arrow batch=\(batch) end-below=\(Int(below)) "
                + "longest-stranded=\(String(format: "%.2f", longestStranded)) s at-bottom=\(room.atBottom)")
            XCTAssertLessThanOrEqual(longestStranded, Self.strandedLimit, "batch \(batch): the room said the reader "
                + "is at the bottom with the end out of view for \(String(format: "%.2f", longestStranded)) s")
            guard below > RoomReaderPlace.atBottomDistance else { continue }
            endedShort += 1
            // Short of the end and not at the bottom: the arrow shows, and takes the reader down. The seam is off for
            // the arrow's way down: the list it opens at its newest rows settles there by the room's own follows.
            let arrow = try XCTUnwrap(HostedSummary.wait(for: "pocket.room.jumpToLatest", in: window,
                                                         timeout: Self.strandedLimit),
                                      "batch \(batch): the arrow shows within \(Self.strandedLimit) s")
            RoomScrollTrace.followMovesNothing = false
            RoomScrollTrace.injectedRetry = nil
            let screen = list.bounds.height - list.adjustedContentInset.top - list.adjustedContentInset.bottom
            XCTAssertTrue(arrow.accessibilityActivate(), "batch \(batch): the arrow could be pressed")
            // Down at least a screen (the arrow can open a new list at the newest rows: measured from the end).
            func belowNow() -> CGFloat {
                Self.list(in: window).map { Self.bottomOffset(of: $0) - $0.contentOffset.y } ?? below
            }
            // Down a screen, and not a screen past the end (a list scrolled past its end shows nothing).
            wait("batch \(batch): the arrow took the reader down a screen", seconds: 8) {
                below - belowNow() >= screen && belowNow() > -screen
            }
            print("READER-STAYS-PUT tall-arrivals arrow batch=\(batch) after the tap: end-below=\(Int(belowNow()))")
            XCTAssertGreaterThanOrEqual(below - belowNow(), screen, "batch \(batch): the arrow did not take the reader "
                + "down a screen")
            XCTAssertGreaterThan(belowNow(), -screen, "batch \(batch): the list is not a screen past its end")
            pump(1)
            RoomScrollTrace.followMovesNothing = true
            RoomScrollTrace.injectedRetry = .movesNothing
        }
        XCTAssertGreaterThan(endedShort, 0, "no batch ended short of the end: the arrow was not tested")
    }

    /// The room's one retry of a follow that moved nothing is the room's own scroll: where it lands is judged from
    /// there. In CI (`9f968e3`) the retry landed 754 pt up, the bottom's 120-point rule took that for the reader
    /// leaving, and the room showed the arrow 6,911 pt short. Here the placed follows move nothing and the retry lands at
    /// the room's first row, far above (`RoomScrollTrace`'s DEBUG seam): every "left" the room tells comes from its
    /// giving up, none from the retry.
    func test_the_rooms_own_retry_never_takes_the_reader_for_leaving() throws {
        try XCTSkipUnless(Self.readsGeometry, "the exact place reads the scroll view's geometry (iOS 18 and later)")
        RoomScrollTrace.followMovesNothing = true
        RoomScrollTrace.injectedRetry = .landsAbove
        addTeardownBlock {
            RoomScrollTrace.followMovesNothing = false
            RoomScrollTrace.injectedRetry = nil
        }
        let room = Room(Self.messages())
        let list = try host(room, textSize: .accessibility5)
        let told = room.placesTold.count
        RoomScrollTrace.start()
        room.arrive((61..<101).map { Self.longArrival(Int64($0)) })
        pump(3)
        let stalls = RoomScrollTrace.stalls
        let left = room.placesTold.dropFirst(told).filter { !$0 }.count
        print("READER-STAYS-PUT own-retry retries=\(stalls.retries) gave-up=\(stalls.gaveUp) told=\(room.placesTold.dropFirst(told)) "
            + "end-below=\(Int(Self.bottomOffset(of: list) - list.contentOffset.y))")
        XCTAssertGreaterThanOrEqual(stalls.retries, 1, "the room never retried: this case did not test it")
        XCTAssertLessThanOrEqual(left, stalls.gaveUp, "the room's own retry was taken for the reader leaving")
    }

    /// The longest the room may say the reader is at the bottom while the end has been more than
    /// `RoomReaderPlace.atBottomDistance` (the arrow's own threshold) out of view without a break: a follow on its way
    /// (about 0.25 s) is, a reader stranded mid-room with the arrow hidden is not (warden).
    private static let strandedLimit: TimeInterval = 1

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
    /// rests there, a few points above the very end (the list's own padding). Not a whole screen past it: a list
    /// scrolled that far shows none of the room.
    private static func atBottom(_ scroll: UIScrollView) -> Bool {
        let below = bottomOffset(of: scroll) - scroll.contentOffset.y
        let visible = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
        return below < 24 && below > -visible
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
