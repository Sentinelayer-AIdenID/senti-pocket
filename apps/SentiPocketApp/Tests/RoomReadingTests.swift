import Combine
import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// A clock the test moves. Sleeps of up to five seconds (the dwell, the read interval and its retries) wait until the
/// clock passes them; longer ones (the room's polls) park until the room stops them, as the room's own tests do.
private final class TestClock: @unchecked Sendable {
    private typealias Waiter = (deadline: Date, id: UUID, continuation: CheckedContinuation<Void, Never>)
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var waiters: [Waiter] = []

    var now: Date { locked { current } }
    var waiting: Int { locked { waiters.count } }

    func sleep(_ seconds: TimeInterval) async {
        if seconds > 5 {
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            return
        }
        guard seconds > 0 else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                locked { waiters.append((current.addingTimeInterval(seconds), id, continuation)) }
            }
        } onCancel: {
            self.resume { $0.id == id }
        }
    }

    func advance(by seconds: TimeInterval) {
        let now = locked { () -> Date in
            current = current.addingTimeInterval(seconds)
            return current
        }
        resume { $0.deadline <= now }
    }

    func releaseAll() {
        resume { _ in true }
    }

    private func resume(where due: (Waiter) -> Bool) {
        let ready = locked { () -> [Waiter] in
            let ready = waiters.filter(due)
            waiters.removeAll(where: due)
            return ready
        }
        ready.forEach { $0.continuation.resume() }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Pages for the room's opening reads, and its reads of replies; the live stream stays open and quiet.
private final class PagedRoom: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var before: [RoomEventPage]
    private var after: [RoomEventPage]
    private var actions: [RoomActionsPage]
    private var beforeCalls: [Int64?] = []
    private var afterCalls: [Int64] = []
    private var actionReads = 0

    init(before: [RoomEventPage], after: [RoomEventPage] = [], actions: [RoomActionsPage] = []) {
        self.before = before
        self.after = after
        self.actions = actions
    }

    var calls: (before: [Int64?], after: [Int64]) { locked { (beforeCalls, afterCalls) } }
    var repliesRead: Int { locked { actionReads } }

    /// Each read of the replies answers the next page given; the last one stays.
    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        locked {
            actionReads += 1
            return actions.count > 1 ? actions.removeFirst() : (actions.first ?? RoomActionsPage())
        }
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        locked {
            beforeCalls.append(beforeSequence)
            return before.isEmpty ? RoomEventPage(messages: []) : before.removeFirst()
        }
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        locked {
            afterCalls.append(fromSequence)
            return after.isEmpty ? RoomEventPage(messages: []) : after.removeFirst()
        }
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> {
        AsyncStream { _ in }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Records each read told to the server, which takes it (recorded, holding that position) unless told to refuse the
/// next ones or to answer them otherwise.
private final class ReadMarks: RoomReadMarking, @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [Int64] = []
    private var refusals: [RoomSendError] = []
    private var answers: [RoomReadReceipt] = []

    var sent: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return marks
    }

    func refuseNext(_ error: RoomSendError) {
        lock.lock()
        refusals.append(error)
        lock.unlock()
    }

    func answerNext(_ receipt: RoomReadReceipt) {
        lock.lock()
        answers.append(receipt)
        lock.unlock()
    }

    func markRead(sessionId: String, through sequenceId: Int64) async throws -> RoomReadReceipt {
        lock.lock()
        marks.append(sequenceId)
        let refusal = refusals.isEmpty ? nil : refusals.removeFirst()
        let answer = refusal != nil || answers.isEmpty ? nil : answers.removeFirst()
        lock.unlock()
        if let refusal { throw refusal }
        return answer ?? RoomReadReceipt(outcome: .recorded, lastReadSequenceId: sequenceId)
    }
}

private struct TakesEverything: RoomMessageSending {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {}
}

/// Opening a room with unread messages takes you back to where you stopped reading, and the room list's badge
/// follows your reading.
@MainActor
final class RoomReadingTests: XCTestCase {
    private let clock = TestClock()

    override func tearDown() async throws {
        clock.releaseAll()
        try await super.tearDown()
    }

    private func message(_ seq: Int64, author: String = "ada-agent") -> RoomMessage {
        RoomMessage(id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: author, authorName: author,
                    isHuman: RoomMessage.isHumanAuthor(author), text: "Note \(seq).",
                    timestamp: "2026-10-31T14:00:00.000000+00:00")
    }

    private func page(_ seqs: ClosedRange<Int64>, hasMore: Bool = false) -> RoomEventPage {
        RoomEventPage(messages: seqs.map { message($0) }, nextBeforeSequence: seqs.lowerBound, hasMore: hasMore)
    }

    private func mark(_ count: Int, first: Int64?, lastRead: Int64?) -> RoomReadMark {
        RoomReadMark(unreadCount: count, firstUnreadSequenceId: first, lastReadSequenceId: lastRead)
    }

    private func makeRoom(
        _ transport: PagedRoom,
        mark: RoomReadMark?,
        marks: ReadMarks? = nil,
        sender: (any RoomMessageSending)? = nil,
        membershipRole: String? = "contributor",
        onRead: @escaping @MainActor (Int64, Bool) -> Void = { _, _ in }
    ) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            sender: sender,
            membershipRole: membershipRole,
            ownAuthorIds: ["human-sam"],
            sleep: { [clock] seconds in await clock.sleep(seconds) },
            now: { [clock] in clock.now },
            readMark: mark,
            readMarker: marks,
            onRead: onRead,
            onReauthenticationRequired: {}
        )
    }

    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)", file: file, line: line)
    }

    /// Lets every task the room started run as far as it can.
    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func underTheLine(_ state: RoomChatPresentationState) -> Int64? {
        guard let index = state.rows.firstIndex(of: .unreadDivider), index + 1 < state.rows.count,
              case .message(let row) = state.rows[index + 1] else { return nil }
        return row.sequenceId
    }

    private func sequences(_ state: RoomChatPresentationState) -> [Int64] {
        state.rows.compactMap { row in
            if case .message(let message) = row { return message.sequenceId }
            return nil
        }
    }

    private func open(_ room: RoomChatCoordinator) async {
        room.resume()
        await waitUntil("loaded") { !room.state.isLoadingInitial && !room.state.rows.isEmpty }
    }

    // MARK: - Where the room opens

    func test_a_room_with_unread_messages_opens_behind_the_line_at_the_first_of_them() async {
        let transport = PagedRoom(before: [page(1...10, hasMore: true)])
        let room = makeRoom(transport, mark: mark(3, first: 8, lastRead: 7))
        await open(room)
        XCTAssertEqual(underTheLine(room.state), 8)
        XCTAssertEqual(room.state.openPosition(reopening: false), .unreadLine)
        XCTAssertEqual(transport.calls.before, [nil], "the newest page holds it: nothing more to load")
        room.pause()
    }

    func test_with_nothing_unread_it_opens_at_its_latest_as_before() async {
        for readMark in [nil, mark(0, first: nil, lastRead: 10)] {
            let room = makeRoom(PagedRoom(before: [page(1...10, hasMore: true)]), mark: readMark)
            await open(room)
            XCTAssertNil(underTheLine(room.state))
            XCTAssertEqual(room.state.openPosition(reopening: false), .latest)
            room.pause()
        }
    }

    /// As the web does: the room pages back to the first unread, then opens at its line, one stretch to the latest.
    func test_a_first_unread_further_back_than_the_newest_page_is_paged_back_to() async {
        let transport = PagedRoom(before: [page(201...300, hasMore: true), page(101...200, hasMore: true)])
        let room = makeRoom(transport, mark: mark(100, first: 120, lastRead: 119))
        await open(room)
        XCTAssertEqual(transport.calls.before, [nil, 201], "one page further back")
        XCTAssertEqual(transport.calls.after, [], "no window")
        XCTAssertEqual(sequences(room.state), Array(101...300), "from before the line to the latest")
        XCTAssertEqual(underTheLine(room.state), 120)
        XCTAssertFalse(room.state.canLoadNewer)
        XCTAssertEqual(room.state.openPosition(reopening: false), .unreadLine)
        room.pause()
    }

    /// Five pages in all, then the window around the first unread, as a link opens.
    func test_a_first_unread_further_back_than_five_pages_opens_on_the_window_around_it() async {
        let transport = PagedRoom(
            before: [page(901...1000, hasMore: true), page(801...900, hasMore: true), page(701...800, hasMore: true),
                     page(601...700, hasMore: true), page(501...600, hasMore: true), page(71...120, hasMore: true)],
            after: [page(121...170)]
        )
        let room = makeRoom(transport, mark: mark(100, first: 120, lastRead: 119))
        await open(room)
        XCTAssertEqual(transport.calls.before, [nil, 901, 801, 701, 601, 121], "five pages, then up to the first unread")
        XCTAssertEqual(transport.calls.after, [120], "and the page after it")
        XCTAssertEqual(sequences(room.state), Array(71...170), "the window, not the newest pages")
        XCTAssertEqual(underTheLine(room.state), 120)
        XCTAssertTrue(room.state.canLoadNewer, "newer messages load as you scroll down")
        room.pause()
    }

    func test_a_window_that_reaches_the_pages_read_joins_them() async {
        let transport = PagedRoom(
            before: [page(901...1000, hasMore: true), page(801...900, hasMore: true), page(701...800, hasMore: true),
                     page(601...700, hasMore: true), page(501...600, hasMore: true), page(431...480, hasMore: true)],
            after: [page(481...530)]
        )
        let room = makeRoom(transport, mark: mark(100, first: 480, lastRead: 479))
        await open(room)
        XCTAssertEqual(sequences(room.state), Array(431...1000), "one stretch from before the line to the latest")
        XCTAssertFalse(room.state.canLoadNewer)
        XCTAssertEqual(underTheLine(room.state), 480)
        room.pause()
    }

    /// Discord keeps the line while you are in the room: coming back to the bottom keeps it, and is not news.
    func test_coming_back_to_the_bottom_keeps_the_line_and_never_publishes_for_it() async {
        let room = makeRoom(PagedRoom(before: [page(1...10, hasMore: true)]), mark: mark(3, first: 8, lastRead: 7))
        await open(room)
        var publishes = 0
        let watching = room.$state.dropFirst().sink { _ in publishes += 1 }
        room.send(.readerAtBottom(true))
        room.send(.readerAtBottom(false))
        room.send(.readerAtBottom(true))
        XCTAssertEqual(publishes, 0, "the same rows: nothing to draw")
        XCTAssertEqual(underTheLine(room.state), 8)
        watching.cancel()
        room.pause()
    }

    func test_a_send_takes_the_line_away() async {
        let room = makeRoom(PagedRoom(before: [page(1...10, hasMore: true)]), mark: mark(3, first: 8, lastRead: 7),
                            sender: TakesEverything())
        await open(room)
        room.send(.sendMessage(text: "On it."))
        XCTAssertNil(underTheLine(room.state), "your message is at the bottom, and so are you")
        XCTAssertEqual(room.state.openPosition(reopening: true), .latest)
        room.pause()
    }

    // MARK: - Reading

    /// Opens the room at the line after 7 (so nothing is read for being at the bottom).
    private func openAtTheLine(_ marks: ReadMarks, onRead: @escaping @MainActor (Int64, Bool) -> Void = { _, _ in })
        async -> RoomChatCoordinator {
        let room = makeRoom(PagedRoom(before: [page(1...10, hasMore: true)]), mark: mark(3, first: 8, lastRead: 7),
                            marks: marks, onRead: onRead)
        await open(room)
        return room
    }

    private func onScreen(_ room: RoomChatCoordinator, _ seq: Int64, _ shown: Bool = true) async {
        let before = clock.waiting
        room.send(.messageOnScreen(id: "evt-\(seq)", isOnScreen: shown))
        if shown, seq > 7 { await waitUntil("its dwell started") { clock.waiting > before } }
    }

    func test_a_row_that_stays_on_screen_is_read_and_one_that_flashes_past_is_not() async {
        let marks = ReadMarks()
        let room = await openAtTheLine(marks)
        await onScreen(room, 9)
        clock.advance(by: RoomChatCoordinator.readDwell / 2)
        await onScreen(room, 9, false)
        clock.advance(by: RoomChatCoordinator.readDwell)
        await settle()
        XCTAssertEqual(marks.sent, [], "gone before the dwell")

        await onScreen(room, 9)
        clock.advance(by: RoomChatCoordinator.readDwell)
        await waitUntil("read through it") { marks.sent == [9] }
        room.pause()
    }

    func test_reading_only_moves_forward() async {
        let marks = ReadMarks()
        let room = await openAtTheLine(marks)
        await onScreen(room, 6)
        clock.advance(by: 1)
        await settle()
        XCTAssertEqual(marks.sent, [], "behind what you had read")

        await onScreen(room, 9)
        clock.advance(by: RoomChatCoordinator.readDwell)
        await waitUntil("read through 9") { marks.sent == [9] }
        room.send(.messageOnScreen(id: "evt-8", isOnScreen: true))
        clock.advance(by: 5)
        await settle()
        XCTAssertEqual(marks.sent, [9], "never back")
        room.pause()
    }

    func test_reads_are_one_request_every_two_seconds_with_the_furthest_last() async {
        let marks = ReadMarks()
        let room = await openAtTheLine(marks)
        await onScreen(room, 8)
        clock.advance(by: RoomChatCoordinator.readDwell)
        await waitUntil("the first read goes at once") { marks.sent == [8] }

        await onScreen(room, 9)
        await onScreen(room, 10)
        let waiting = clock.waiting
        clock.advance(by: RoomChatCoordinator.readDwell)
        await waitUntil("both read, then waiting out the interval") { clock.waiting == waiting - 1 }
        XCTAssertEqual(marks.sent, [8], "inside the interval")
        clock.advance(by: RoomReadCursor.interval - RoomChatCoordinator.readDwell)
        await waitUntil("the furthest goes once the interval is over") { marks.sent == [8, 10] }
        room.pause()
    }

    func test_reaching_the_bottom_reads_through_the_newest_message() async {
        let marks = ReadMarks()
        let room = await openAtTheLine(marks)
        let waiting = clock.waiting
        room.send(.readerAtBottom(true))
        await waitUntil("the dwell at the bottom started") { clock.waiting > waiting }
        clock.advance(by: RoomChatCoordinator.readDwell)
        await waitUntil("read through the newest") { marks.sent == [10] }
        room.pause()
    }

    func test_leaving_the_bottom_before_the_dwell_reads_nothing() async {
        let marks = ReadMarks()
        let room = await openAtTheLine(marks)
        let waiting = clock.waiting
        room.send(.readerAtBottom(true))
        await waitUntil("the dwell at the bottom started") { clock.waiting > waiting }
        room.send(.readerAtBottom(false))
        clock.advance(by: RoomChatCoordinator.readDwell)
        await settle()
        XCTAssertEqual(marks.sent, [])
        room.pause()
    }

    func test_a_room_opened_at_its_latest_is_read_once_it_has_stayed_there() async {
        let marks = ReadMarks()
        let room = makeRoom(PagedRoom(before: [page(1...10, hasMore: true)]), mark: mark(0, first: nil, lastRead: 4),
                            marks: marks)
        room.resume()
        await waitUntil("the dwell at the bottom started") { clock.waiting > 0 }
        clock.advance(by: RoomChatCoordinator.readDwell)
        await waitUntil("read through the newest") { marks.sent == [10] }
        room.pause()
    }

    func test_closing_the_room_sends_what_was_read_at_once() async {
        let marks = ReadMarks()
        let room = await openAtTheLine(marks)
        await onScreen(room, 8)
        clock.advance(by: RoomChatCoordinator.readDwell)
        await waitUntil("the first read") { marks.sent == [8] }
        await onScreen(room, 10)
        clock.advance(by: RoomChatCoordinator.readDwell)
        await settle()
        XCTAssertEqual(marks.sent, [8], "waiting out the interval")
        room.pause()
        await waitUntil("sent as the room closes") { marks.sent == [8, 10] }
    }

    func test_the_room_list_hears_of_a_read_only_once_the_server_took_it() async {
        let marks = ReadMarks()
        marks.refuseNext(.retryable(retryAfterSeconds: nil))
        var heard: [Int64] = []
        let room = await openAtTheLine(marks) { through, _ in heard.append(through) }
        await onScreen(room, 9)
        clock.advance(by: RoomChatCoordinator.readDwell)
        await waitUntil("tried once") { marks.sent == [9] }
        await settle()
        XCTAssertEqual(heard, [], "not taken")
        clock.advance(by: 2 * RoomReadCursor.interval)
        await waitUntil("tried again, after a longer wait") { marks.sent == [9, 9] }
        await waitUntil("taken") { heard == [9] }
        room.pause()
    }

    func test_a_room_you_are_not_a_member_of_is_never_marked_read() async {
        let marks = ReadMarks()
        let room = makeRoom(PagedRoom(before: [page(1...10, hasMore: true)]), mark: nil, marks: marks, membershipRole: nil)
        await open(room)
        room.send(.messageOnScreen(id: "evt-9", isOnScreen: true))
        // Whatever the room meant to wait out (the bottom it opened at, the row on screen) is waiting now.
        await settle()
        clock.advance(by: 5)
        await settle()
        room.pause()
        await settle()
        XCTAssertEqual(marks.sent, [], "a link into a public room never makes you a member of it")
    }

    func test_a_refused_read_is_never_sent_again() async {
        let marks = ReadMarks()
        marks.refuseNext(.rejected)
        let room = await openAtTheLine(marks)
        await onScreen(room, 9)
        clock.advance(by: RoomChatCoordinator.readDwell)
        await waitUntil("tried") { marks.sent == [9] }
        clock.advance(by: 60)
        await settle()
        XCTAssertEqual(marks.sent, [9])
        room.pause()
        await settle()
        XCTAssertEqual(marks.sent, [9], "closing does not send it either")
    }

    // MARK: - What the server answers (sentinelayer-api #1078)

    private func reply(_ id: String, to seq: Int64 = 9, author: String = "lin-agent") -> RoomReply {
        RoomReply(id: id, targetSequenceId: seq, authorId: author, text: "On it.",
                  createdAt: "2026-10-31T14:05:00.000000+00:00")
    }

    /// The count includes thread replies. With only replies unread (no first unread message) the room opens at its
    /// latest, and once the reader has stayed there the same position goes again, which reads the replies; caught
    /// up, nothing more goes for them.
    func test_a_room_with_only_replies_unread_opens_at_the_bottom_and_reads_them_with_the_same_position() async {
        let marks = ReadMarks()
        marks.answerNext(RoomReadReceipt(outcome: .recorded, lastReadSequenceId: 10, caughtUp: true))
        var heard: [String] = []
        let room = makeRoom(PagedRoom(before: [page(1...10, hasMore: true)]), mark: mark(4, first: nil, lastRead: 10),
                            marks: marks) { through, caughtUp in
            heard.append("\(through)\(caughtUp ? " caught up" : "")")
        }
        room.resume()
        await waitUntil("the dwell at the bottom started") { clock.waiting > 0 }
        XCTAssertNil(underTheLine(room.state), "no unread message: no line")
        XCTAssertEqual(room.state.openPosition(reopening: false), .latest)
        clock.advance(by: RoomChatCoordinator.readDwell)
        await waitUntil("the same position again") { marks.sent == [10] }
        await waitUntil("the room list hears it caught up") { heard == ["10 caught up"] }

        room.send(.readerAtBottom(false))
        room.send(.readerAtBottom(true))
        clock.advance(by: 5)
        await settle()
        XCTAssertEqual(marks.sent, [10], "caught up: nothing more for the replies")
        room.pause()
    }

    /// A reply from someone else, while the reader is at the bottom, goes as the same position again; not the first
    /// read of the replies (that is history), not your own reply, and not while the reader is up the room.
    func test_a_new_reply_at_the_bottom_sends_the_same_position_again() async {
        let marks = ReadMarks()
        let transport = PagedRoom(before: [page(1...10, hasMore: true)], actions: [
            RoomActionsPage(replies: [reply("r1")]),
            RoomActionsPage(replies: [reply("r1"), reply("r2", author: "human-sam")]),
            RoomActionsPage(replies: [reply("r1"), reply("r2", author: "human-sam"), reply("r3")]),
            RoomActionsPage(replies: [reply("r1"), reply("r2", author: "human-sam"), reply("r3"), reply("r4")])
        ])
        let room = makeRoom(transport, mark: mark(0, first: nil, lastRead: 10), marks: marks)
        await open(room)
        await waitUntil("the replies read once") { transport.repliesRead == 1 }
        clock.advance(by: 5)
        await settle()
        XCTAssertEqual(marks.sent, [], "nothing unread and nothing new")

        await room.refreshActions(force: true)
        clock.advance(by: 5)
        await settle()
        XCTAssertEqual(marks.sent, [], "your own reply is never unread")

        await room.refreshActions(force: true)
        await waitUntil("the dwell at the bottom started") { clock.waiting > 0 }
        clock.advance(by: RoomChatCoordinator.readDwell)
        await waitUntil("the same position again") { marks.sent == [10] }

        room.send(.readerAtBottom(false))
        await room.refreshActions(force: true)
        clock.advance(by: 5)
        await settle()
        XCTAssertEqual(marks.sent, [10], "up the room, a reply waits")
        room.send(.readerAtBottom(true))
        await waitUntil("the dwell at the bottom started") { clock.waiting > 0 }
        clock.advance(by: RoomChatCoordinator.readDwell)
        await waitUntil("back at the bottom, it goes") { marks.sent == [10, 10] }
        room.pause()
    }

    /// A no-op answer (`updated: false` from your own cursor): nothing moved, and the server holds a position past
    /// the one told. That is what counts as read from then on.
    func test_a_no_op_answer_moves_nothing_but_counts_what_the_server_holds() async {
        let marks = ReadMarks()
        marks.answerNext(RoomReadReceipt(outcome: .unchanged, lastReadSequenceId: 12))
        var heard: [String] = []
        let room = await openAtTheLine(marks) { through, caughtUp in
            heard.append("\(through)\(caughtUp ? " caught up" : "")")
        }
        await onScreen(room, 9)
        clock.advance(by: RoomChatCoordinator.readDwell)
        await waitUntil("told") { marks.sent == [9] }
        await waitUntil("the room list hears what the server holds") { heard == ["12"] }

        room.send(.messageOnScreen(id: "evt-10", isOnScreen: true))
        clock.advance(by: 5)
        await settle()
        XCTAssertEqual(marks.sent, [9], "10 is behind what the server holds")
        room.pause()
    }

    /// Only your own signed-in session moves your badge. Any other credential is answered `updated: false` with
    /// `read_cursor_requires_signed_in_session`: not recorded, so the room list keeps its count, and the room tells the
    /// server nothing more while it is open, nor as it closes.
    func test_a_read_the_server_does_not_record_is_not_news_and_nothing_more_is_sent() async {
        let marks = ReadMarks()
        marks.answerNext(RoomReadReceipt(body: Data(
            (#"{"ok":true,"updated":false,"lastReadSequenceId":null,"actorKind":null,"actorId":null,"#
             + #""reason":"read_cursor_requires_signed_in_session"}"#).utf8)))
        var heard: [Int64] = []
        let room = await openAtTheLine(marks) { through, _ in heard.append(through) }
        await onScreen(room, 9)
        clock.advance(by: RoomChatCoordinator.readDwell)
        await waitUntil("told once") { marks.sent == [9] }
        await settle()

        room.send(.messageOnScreen(id: "evt-10", isOnScreen: true))
        room.send(.readerAtBottom(true))
        clock.advance(by: 5)
        await settle()
        room.pause()
        await settle()
        XCTAssertEqual(marks.sent, [9])
        XCTAssertEqual(heard, [], "the room list keeps its count")
    }

    // MARK: - Opening the room that is already open

    func test_picking_the_open_room_again_keeps_it_where_you_are() {
        let open = RoomRoute(sessionId: "a", title: "A", membershipRole: "owner", readMark: mark(4, first: 8, lastRead: 7))
        let again = RoomRoute(sessionId: "a", title: "A", membershipRole: "owner", readMark: mark(9, first: 8, lastRead: 7))
        XCTAssertEqual(RoomRoute.keepingOpenRoom(open, for: again), open, "a newer count never reopens it")
        let linked = RoomRoute(sessionId: "a", title: "A", membershipRole: "owner", focusSequenceId: 5)
        XCTAssertEqual(RoomRoute.keepingOpenRoom(open, for: linked), linked, "a link opens it at its message")
        let other = RoomRoute(sessionId: "b", title: "B", readMark: mark(2, first: 3, lastRead: 2))
        XCTAssertEqual(RoomRoute.keepingOpenRoom(open, for: other), other)
        XCTAssertEqual(RoomRoute.keepingOpenRoom(nil, for: other), other)
    }
}

private actor BadgedRooms: SessionTransport {
    private let unread: String

    init(unread: String = #"{"count":5,"firstUnreadSequenceId":4811}"#) {
        self.unread = unread
    }

    func listSessions(includeArchived: Bool, limit: Int, cursor: String?) async throws -> SessionListPage {
        let json = """
        {"sessions":[{"sessionId":"room-a","status":"active","archiveStatus":"active","visibility":"private",
        "membershipRole":"owner","title":"Room A","summaryText":null,"summaryGeneratedAt":null,"summaryModel":null,
        "agentCount":2,"eventCount":41,"totalCostUsd":0,"createdAt":null,"lastActivityAt":null,"expiresAt":null,
        "killedAt":null,"templateName":null,"codebasePath":null,"s3ArchivePath":null,
        "online":{"humans":1,"agents":2},"lastReadSequenceId":4810,"unread":\(unread)}],
        "count":1,"include_archived":false,"next_cursor":null,"has_more":false}
        """
        return try JSONDecoder().decode(SessionListPage.self, from: Data(json.utf8))
    }

    func listEvents(sessionId: String, after: String?, fromSequence: Int64?, limit: Int) async throws
        -> SessionEventForwardPage { throw SessionTransportError.invalidRequest }

    func listEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws
        -> SessionEventBeforePage { throw SessionTransportError.invalidRequest }

    func listActions(sessionId: String, targetSequenceId: Int64?, targetActionId: String?, limit: Int) async throws
        -> SessionActionPage { throw SessionTransportError.invalidRequest }

    func listCheckpoints(sessionId: String, limit: Int) async throws -> SessionCheckpointListPage {
        throw SessionTransportError.invalidRequest
    }
}

/// A read the server took clears that room's badge in the list at once, before the list is read again.
@MainActor
final class SessionListReadTests: XCTestCase {
    func test_a_read_past_the_first_unread_clears_the_badge_once() async throws {
        let sessions = SessionListCoordinator(repository: SessionRepository(transport: BadgedRooms()))
        await sessions.refreshSessions().value
        let row = try XCTUnwrap(sessions.state.rows.first)
        XCTAssertEqual(row.activity, RoomListActivity(humansOnline: 1, agentsOnline: 2, unread: 5))
        XCTAssertEqual(RoomReadMark(row: row),
                       RoomReadMark(unreadCount: 5, firstUnreadSequenceId: 4811, lastReadSequenceId: 4810),
                       "the room opens at 4811")

        var publishes = 0
        let watching = sessions.$state.dropFirst().sink { _ in publishes += 1 }
        sessions.noteRead(sessionId: "room-a", through: 4800)
        XCTAssertEqual(publishes, 0, "behind the first unread: the badge stays")
        sessions.noteRead(sessionId: "room-a", through: 4811)
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(sessions.state.rows.first?.activity.unread, 0)
        XCTAssertEqual(sessions.state.rows.first?.activity.agentsOnline, 2, "who is online stays")
        XCTAssertEqual(sessions.state.rows.first?.lastReadSequenceId, 4811, "the room opens from where you read")
        sessions.noteRead(sessionId: "room-a", through: 4815)
        XCTAssertEqual(publishes, 1, "a further read is not news to the list")

        await sessions.refreshSessions().value
        XCTAssertEqual(sessions.state.rows.first?.activity.unread, 0,
                       "a count the server made before your read stays cleared when the list is read again")
        watching.cancel()
    }

    /// Thread replies alone (a count with no first unread message) clear when a read caught up on the room, not for a
    /// read further on. The list's next read counts again: replies posted since show.
    func test_a_badge_of_replies_alone_clears_when_the_read_caught_up() async throws {
        let sessions = SessionListCoordinator(repository: SessionRepository(
            transport: BadgedRooms(unread: #"{"count":3,"firstUnreadSequenceId":null}"#)))
        await sessions.refreshSessions().value
        XCTAssertEqual(sessions.state.rows.first?.activity.unread, 3)

        sessions.noteRead(sessionId: "room-a", through: 4815)
        XCTAssertEqual(sessions.state.rows.first?.activity.unread, 3, "further on is not a read of the replies")
        sessions.noteRead(sessionId: "room-a", through: 4815, caughtUp: true)
        XCTAssertEqual(sessions.state.rows.first?.activity.unread, 0, "caught up")

        await sessions.refreshSessions().value
        XCTAssertEqual(sessions.state.rows.first?.activity.unread, 3, "counted after the read: replies since then show")
    }
}
