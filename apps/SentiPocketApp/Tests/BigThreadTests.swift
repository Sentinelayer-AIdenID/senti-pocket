import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

// Big threads (#62423): typing in a thread of long replies lagged, a thread may hold hundreds of thousands of replies,
// and a reply's notification opened its thread without going to the reply. A thread opens on its newest page and reads
// older ones as asked; one opened at a reply opens with one read around it (sentinelayer-api #1199), however far back,
// and shows it; typing in it draws the reply box, never the room or the replies.

/// A thread of `count` replies on message 42, read as the API reads it: newest first, at most `pageSize` replies a read
/// (fewer than asked, as a server may answer), each page giving the cursor of the one before. Reply `n` is made when it
/// is read, so a thread of 100,000 costs only the replies read. Its reads are kept. It can grow to `capacity` replies,
/// as new ones arrive.
///
/// With `anchored` (the API since #1199), a read around a reply answers a window of up to `limit` around it, newest
/// first: the reply near the middle, the window filled from the other side at an edge of the thread, with
/// `anchoredActionId`, a cursor to the older side (`nextCursor`) and one to the newer side (`afterCursor`, nil when the
/// window reaches the newest). Its cursors (`w1.<n>`) read on either way, a page at a time. A reply not in the thread
/// is a 404 (`RoomActionNotFound`). Without it (an API before #1199), a read around a reply answers the newest page.
private final class PagedThread: RoomTransport, @unchecked Sendable {
    struct Read: Equatable {
        let limit: Int
        /// `beforeCursor`.
        let cursor: String?
        /// `aroundActionId`.
        let around: String?
        /// `afterCursor`.
        let after: String?

        init(limit: Int, cursor: String? = nil, around: String? = nil, after: String? = nil) {
            self.limit = limit
            self.cursor = cursor
            self.around = around
            self.after = after
        }
    }

    let pageSize: Int
    let anchored: Bool
    /// How long each read of the thread takes, as a slow network answers.
    var readDelay: UInt64 = 0
    /// How long a page back (a read with a cursor) and a page on take, each on top of `readDelay`.
    var olderDelay: UInt64 = 0
    var laterDelay: UInt64 = 0
    /// A read around a reply fails (a 503), as any read may.
    var failsAround = false
    /// A read around a reply answers a window without that reply in it.
    var windowLeavesOutItsReply = false
    /// Collapsed replies (never shown) and the reply each resolves to, as the API resolves them.
    var collapsed: [String: Int] = [:]
    private let capacity: Int
    private let lock = NSLock()
    private var visible: Int
    private var kept: [Read] = []
    private var failing: Set<String> = []

    init(count: Int, pageSize: Int = .max, capacity: Int? = nil, anchored: Bool = true) {
        self.capacity = max(count, capacity ?? count)
        visible = count
        self.pageSize = pageSize
        self.anchored = anchored
    }

    /// Reply `index`, made from its number.
    func reply(_ index: Int) -> RoomReply {
        RoomReply(id: BigThreadTests.id(index), targetSequenceId: 42,
                  authorId: index.isMultiple(of: 2) ? "build-agent" : "review-agent",
                  text: BigThreadTests.text(index, of: capacity),
                  createdAt: String(format: "2026-11-%02ldT%02ld:%02ld:%02ld.000000+00:00", 5 + index / 86_400,
                                    index / 3_600 % 24, index / 60 % 60, index % 60))
    }

    /// Replies `first...last`, oldest first.
    private func replies(_ first: Int, _ last: Int) -> [RoomReply] {
        first <= last ? (first...last).map { reply($0) } : []
    }

    var count: Int { lock.withLock { visible } }
    var reads: [Read] { lock.withLock { kept } }

    /// Replies up to `count` have arrived.
    func grow(to count: Int) { lock.withLock { visible = min(count, capacity) } }

    /// The read with this cursor fails, once.
    func failOnce(before cursor: String) { lock.withLock { _ = failing.insert(cursor) } }

    /// The reply a cursor is at: `w1.<n>` (a window's) or `<n>` (a page's).
    private static func position(_ cursor: String) -> Int? {
        Int(cursor.hasPrefix("w1.") ? String(cursor.dropFirst(3)) : cursor)
    }

    /// The reply an id names, as the API finds it: a reply of this thread that has arrived, or a collapsed one's.
    private func index(of id: String, count: Int) -> Int? {
        if let resolved = collapsed[id] { return resolved }
        guard let number = id.split(separator: "-").last.flatMap({ Int($0) }), (1...count).contains(number),
              BigThreadTests.id(number) == id else { return nil }
        return number
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [RoomMessage(id: "evt-42", sequenceId: 42, kind: .message, authorId: "human-me",
                                             authorName: "me", isHuman: true, text: "Two findings so far.",
                                             timestamp: "2026-11-05T00:00:00+00:00")])
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }

    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        try await roomActions(sessionId: sessionId, targetSequenceId: targetSequenceId, limit: limit, beforeCursor: nil)
    }

    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int, beforeCursor: String?) async throws
        -> RoomActionsPage {
        guard targetSequenceId == 42 else {
            return RoomActionsPage(byTarget: [42: RoomReactionSummary(targetSequenceId: 42, counts: ["reply": count],
                                                                      replyTotal: count)])
        }
        let (fails, count) = lock.withLock { () -> (Bool, Int) in
            kept.append(Read(limit: limit, cursor: beforeCursor))
            guard let beforeCursor else { return (false, visible) }
            return (failing.remove(beforeCursor) != nil, visible)
        }
        if readDelay > 0 { try? await Task.sleep(nanoseconds: readDelay) }
        if beforeCursor != nil, olderDelay > 0 { try? await Task.sleep(nanoseconds: olderDelay) }
        if fails { throw URLError(.timedOut) }
        return page(before: beforeCursor, limit: limit, count: count)
    }

    /// Up to `limit` replies older than `cursor` (nil: the newest). A window's cursor reads on as a window does: its
    /// pages give window cursors, both ways.
    private func page(before cursor: String?, limit: Int, count: Int) -> RoomActionsPage {
        let window = cursor?.hasPrefix("w1.") == true
        let end = cursor.flatMap(Self.position) ?? count + 1
        let start = max(1, end - min(limit, pageSize))
        return RoomActionsPage(replies: replies(start, end - 1),
                               nextCursor: start > 1 ? (window ? "w1.\(start)" : String(start)) : nil,
                               afterCursor: window && end - 1 < count ? "w1.\(end - 1)" : nil)
    }

    func roomActions(sessionId: String, targetSequenceId: Int64, limit: Int, aroundActionId: String) async throws
        -> RoomActionsPage {
        let count = lock.withLock { () -> Int in
            kept.append(Read(limit: limit, around: aroundActionId))
            return visible
        }
        if readDelay > 0 { try? await Task.sleep(nanoseconds: readDelay) }
        guard anchored else { return page(before: nil, limit: limit, count: count) }
        if failsAround { throw SessionTransportError.service(statusCode: 503) }
        guard let anchor = index(of: aroundActionId, count: count) else { throw RoomActionNotFound() }
        // As the API places it: at most (limit - 1) / 2 newer, the rest older, each side filling the other's shortfall.
        let size = min(limit, pageSize)
        var newer = min(count - anchor, (size - 1) / 2)
        let older = min(anchor - 1, size - 1 - newer)
        newer = min(count - anchor, size - 1 - older)
        var window = replies(anchor - older, anchor + newer)
        if windowLeavesOutItsReply { window.removeAll { $0.id == BigThreadTests.id(anchor) } }
        return RoomActionsPage(replies: window,
                               nextCursor: anchor - older > 1 ? "w1.\(anchor - older)" : nil,
                               afterCursor: anchor + newer < count ? "w1.\(anchor + newer)" : nil,
                               anchoredActionId: BigThreadTests.id(anchor))
    }

    func roomActions(sessionId: String, targetSequenceId: Int64, limit: Int, afterCursor: String) async throws
        -> RoomActionsPage {
        let count = lock.withLock { () -> Int in
            kept.append(Read(limit: limit, after: afterCursor))
            return visible
        }
        if laterDelay > 0 { try? await Task.sleep(nanoseconds: laterDelay) }
        guard anchored, let after = Self.position(afterCursor) else { return RoomActionsPage() }
        let last = min(count, after + min(limit, pageSize))
        return RoomActionsPage(replies: replies(after + 1, last),
                               nextCursor: after + 1 <= last ? "w1.\(after + 1)" : nil,
                               afterCursor: last < count ? "w1.\(last)" : nil)
    }
}

@MainActor
final class BigThreadTests: XCTestCase {
    private static let keystrokes = 20

    /// Reply `index`'s id, a UUID as a reply's is (a notification names only a UUID).
    nonisolated static func id(_ index: Int) -> String { String(format: "9b2f7a40-0000-4000-8000-%012ld", index) }

    /// The number of the reply an id names.
    nonisolated static func number(_ id: String) -> Int { id.split(separator: "-").last.flatMap { Int($0) } ?? -1 }

    /// A long reply, as agents write them: three paragraphs, a list and code.
    nonisolated static func text(_ index: Int, of count: Int) -> String {
        "Reply \(index) of \(count). Checked the **email step** again on this pass.\n\n"
            + "- `retryCount` keeps its value after a failed submit\n"
            + "- paste runs the same validation as typing\n\n"
            + "Next: the onboarding copy, step \(index % 12 + 1). Notes in `OnboardingForm.swift`."
    }

    private func coordinator(_ transport: PagedThread, focus: Int64? = nil) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1", title: "Room", transport: transport, focusSequenceId: focus,
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            onReauthenticationRequired: {}
        )
    }

    private func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(description)", file: file, line: line)
    }

    // MARK: - Pages

    /// A thread of 2,500 replies opens on its newest page, never whole; scrolling up to its top reads the page before,
    /// with the cursor the newest gave. A later read (a reply sent) keeps the older pages.
    func test_a_long_thread_opens_on_its_newest_page_and_reads_older_ones_as_asked() async throws {
        let transport = PagedThread(count: 2_500)
        let room = coordinator(transport)
        room.resume()
        room.send(.openThread(sequenceId: 42))
        await waitUntil("the newest page is read") {
            room.state.thread?.isLoading == false && room.state.thread?.replies.count == 100
        }
        XCTAssertEqual(transport.reads, [.init(limit: RoomChatCoordinator.threadPageSize, cursor: nil)])
        XCTAssertEqual(RoomChatCoordinator.threadPageSize, 100)
        XCTAssertEqual(room.state.thread?.replies.first?.id, Self.id(2_401))
        XCTAssertEqual(room.state.thread?.replies.last?.id, Self.id(2_500), "the newest reply last, as the thread shows it")
        XCTAssertEqual(room.state.thread?.hasOlder, true, "the page before is there to read")
        await waitUntil("the title counts the whole thread") { room.state.thread?.title == "2500 replies" }

        room.send(.loadOlderReplies(sequenceId: 42))
        await waitUntil("the page before is read") { room.state.thread?.replies.count == 200 }
        XCTAssertEqual(transport.reads.last, PagedThread.Read(limit: 100, cursor: "2401"))
        let ids = try XCTUnwrap(room.state.thread?.replies.map(\.id))
        XCTAssertEqual(ids, (2_301...2_500).map(Self.id), "oldest first, each once")
        XCTAssertEqual(room.state.thread?.isLoadingOlder, false)

        await room.replyPosted(to: 42)
        XCTAssertEqual(room.state.thread?.replies.count, 200, "a read of the newest page after a send keeps the older ones")
        room.pause()
    }

    /// More replies arrived while the thread was open than its newest page holds: the next read reads back until it
    /// meets the replies loaded, so none between is left out.
    func test_a_read_after_more_than_a_page_arrived_leaves_no_reply_out() async throws {
        let transport = PagedThread(count: 1_000, capacity: 1_150)
        let room = coordinator(transport)
        room.resume()
        room.send(.openThread(sequenceId: 42))
        await waitUntil("the newest page is read") { room.state.thread?.replies.count == 100 }
        transport.grow(to: 1_150)
        await room.replyPosted(to: 42)
        XCTAssertEqual(Array(transport.reads.suffix(2)), [PagedThread.Read(limit: 100, cursor: nil),
                                                          PagedThread.Read(limit: 500, cursor: "1051")],
                       "the newest page, then back to meet the replies loaded")
        let ids = try XCTUnwrap(room.state.thread?.replies.map(\.id))
        XCTAssertEqual(ids, (551...1_150).map(Self.id), "every reply from the oldest loaded to the newest, once each")
        room.send(.loadOlderReplies(sequenceId: 42))
        await waitUntil("scrolling up reads on from the oldest reply loaded") {
            room.state.thread?.replies.first?.id == Self.id(451)
        }
        XCTAssertEqual(transport.reads.last, PagedThread.Read(limit: 100, cursor: "551"))
        room.pause()
    }

    /// Too many arrived to meet within a few pages: the newest pages stand alone, and scrolling up reads on from them.
    func test_a_read_too_far_from_the_replies_loaded_starts_from_the_newest() async throws {
        let transport = PagedThread(count: 1_000, capacity: 4_000)
        let room = coordinator(transport)
        room.resume()
        room.send(.openThread(sequenceId: 42))
        await waitUntil("the newest page is read") { room.state.thread?.replies.count == 100 }
        transport.grow(to: 4_000)
        await room.replyPosted(to: 42)
        XCTAssertEqual(transport.reads.count, 2 + RoomChatCoordinator.threadGapPages)
        let ids = try XCTUnwrap(room.state.thread?.replies.map(\.id))
        XCTAssertEqual(ids, (3_901...4_000).map(Self.id), "the newest page alone, with nothing between it and older pages")
        XCTAssertEqual(room.state.thread?.hasOlder, true)
        room.send(.loadOlderReplies(sequenceId: 42))
        await waitUntil("scrolling up reads on from it") { room.state.thread?.replies.first?.id == Self.id(3_801) }
        room.pause()
    }

    /// One search reads up to 20,000 replies back (an API without reads around a reply: the thread reads back from the
    /// newest page it answered). The thread holds 1,000 of them at most (every room update goes over all it holds):
    /// older pages let the newest go, and "Newest replies" reads the newest again.
    func test_a_long_search_holds_at_most_a_thousand_replies_and_offers_the_newest_again() async throws {
        let transport = PagedThread(count: 25_000, anchored: false)
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(5))
        await waitUntil("the search stops at its last page") { room.state.thread?.focusMissing == true }
        XCTAssertEqual(transport.reads.count, 1 + RoomChatCoordinator.threadSearchPages, "20,500 replies read")
        XCTAssertEqual(RoomChatCoordinator.threadHeld, 1_000)
        XCTAssertEqual(room.state.thread?.replies.map(\.id), (4_501...5_500).map(Self.id),
                       "the oldest 1,000 read, in order: the newest were let go")
        XCTAssertEqual(room.state.thread?.hasNewer, true, "the thread offers its newest again")
        XCTAssertEqual(room.state.thread?.hasOlder, true)

        room.send(.jumpToNewestReplies(sequenceId: 42))
        await waitUntil("the newest are read again") {
            room.state.thread?.hasNewer == false && room.state.thread?.isLoading == false
                && room.state.thread?.replies.last?.id == Self.id(25_000)
        }
        XCTAssertEqual(room.state.thread?.replies.count, 100, "the newest page")
        XCTAssertNil(room.state.thread?.focusReplyId, "no longer at the reply it was opened at")
        XCTAssertEqual(room.state.thread?.focusMissing, false)
        room.pause()
    }

    /// Leaving the room (or the app going to the background) pauses it: a search for the reply stops there, with at most
    /// the read on its way, and "Jump to the reply" goes on from where it stopped.
    func test_leaving_the_room_stops_a_search_for_the_reply() async throws {
        let transport = PagedThread(count: 25_000, anchored: false)
        transport.readDelay = 30_000_000
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(5))
        await waitUntil("the search is under way") { transport.reads.count >= 3 }
        room.pause()
        let left = transport.reads.count
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertLessThanOrEqual(transport.reads.count, left + 1, "at most the read on its way when the room was left")
        XCTAssertLessThan(transport.reads.count, 1 + RoomChatCoordinator.threadSearchPages)
        await waitUntil("Jump to the reply is offered") { room.state.thread?.focusMissing == true }
    }

    // MARK: - Opened at a reply: one read around it (sentinelayer-api #1199)

    /// The witness. A reply's notification, as a push carries it, opens its thread at a reply 60,000 back in a thread
    /// of 100,000 with exactly ONE read of the thread: a window around the reply, with no cursor. (Reading back 500 a
    /// page, it was 1 + 40 reads, then "Jump to the reply".) The window is the thread's pages: scrolling up reads on
    /// from its older side, and down from its newer side.
    func test_a_reply_60000_back_in_a_thread_of_100000_opens_with_exactly_one_read() async throws {
        let payload: [AnyHashable: Any] = ["sessionId": "room_1", "sequenceId": NSNumber(value: 42),
                                           "replyId": Self.id(40_000).uppercased()]
        let link = try XCTUnwrap(PushRoute.link(from: payload))
        let transport = PagedThread(count: 100_000)
        let room = coordinator(transport, focus: link.messageSequence)
        room.resume()
        // What the room screen does with the route the push opens (`applyRouteLinksOnce`).
        room.openThread(try XCTUnwrap(link.messageSequence), at: link.replyId)
        await waitUntil("the thread is open at the reply") {
            room.state.thread?.isLoading == false
                && room.state.thread?.replies.contains { $0.id == Self.id(40_000) } == true
        }
        XCTAssertEqual(transport.reads, [PagedThread.Read(limit: 500, around: Self.id(40_000))],
                       "exactly one read of the thread: around the reply, with no beforeCursor")
        let thread = try XCTUnwrap(room.state.thread)
        XCTAssertEqual(thread.focusReplyId, Self.id(40_000), "opened at the reply, and marked")
        XCTAssertFalse(thread.focusMissing)
        XCTAssertNil(thread.failureText)
        XCTAssertEqual(thread.replies.map(\.id), (39_750...40_249).map(Self.id), "the window around it, oldest first")
        XCTAssertTrue(thread.hasOlder)
        XCTAssertTrue(thread.hasLater, "short of the newest: the thread reads on down")
        XCTAssertFalse(thread.hasNewer)

        room.send(.loadOlderReplies(sequenceId: 42))
        await waitUntil("scrolling up reads on from the window's older side") {
            room.state.thread?.replies.first?.id == Self.id(39_650)
        }
        room.send(.loadLaterReplies(sequenceId: 42))
        await waitUntil("scrolling down reads on from its newer side") {
            room.state.thread?.replies.last?.id == Self.id(40_349)
        }
        XCTAssertEqual(Array(transport.reads.dropFirst()), [PagedThread.Read(limit: 100, cursor: "w1.39750"),
                                                            PagedThread.Read(limit: 100, after: "w1.40249")])
        XCTAssertEqual(room.state.thread?.replies.map(\.id), (39_650...40_349).map(Self.id), "each once, in order")
        room.pause()
    }

    /// The same 2,200 back in a thread of 2,500 (reading back 500 a page took 6 reads): one read.
    func test_a_reply_notification_opens_its_thread_with_the_reply_loaded_however_far_back() async throws {
        let payload: [AnyHashable: Any] = ["sessionId": "room_1", "sequenceId": NSNumber(value: 42),
                                           "replyId": Self.id(300).uppercased()]
        let link = try XCTUnwrap(PushRoute.link(from: payload))
        let transport = PagedThread(count: 2_500)
        let room = coordinator(transport, focus: link.messageSequence)
        room.resume()
        room.openThread(try XCTUnwrap(link.messageSequence), at: link.replyId)
        await waitUntil("the reply is loaded") {
            room.state.thread?.replies.contains { $0.id == Self.id(300) } == true
                && room.state.thread?.isLoading == false
        }
        let thread = try XCTUnwrap(room.state.thread)
        XCTAssertEqual(thread.focusReplyId, Self.id(300), "opened at the reply")
        XCTAssertFalse(thread.focusMissing)
        XCTAssertNil(thread.failureText)
        XCTAssertEqual(transport.reads, [.init(limit: 500, around: Self.id(300))], "1 read, around the reply")
        room.pause()
    }

    /// A reply on the thread's newest page: the one read around it reaches the newest reply. A later read (a reply
    /// sent) merges into it, and scrolling up reads on from the window.
    func test_a_reply_near_the_newest_opens_with_one_read_and_later_reads_merge_into_it() async throws {
        let transport = PagedThread(count: 2_500, capacity: 2_520)
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(2_400))
        await waitUntil("the thread is open at the reply") {
            room.state.thread?.isLoading == false && room.state.thread?.replies.last?.id == Self.id(2_500)
        }
        XCTAssertEqual(transport.reads, [.init(limit: 500, around: Self.id(2_400))])
        XCTAssertEqual(room.state.thread?.replies.map(\.id), (2_001...2_500).map(Self.id))
        XCTAssertEqual(room.state.thread?.focusReplyId, Self.id(2_400))
        XCTAssertEqual(room.state.thread?.hasLater, false, "the window reaches the newest reply")

        transport.grow(to: 2_520)
        await room.replyPosted(to: 42)
        XCTAssertEqual(transport.reads.last, PagedThread.Read(limit: 100), "the newest page")
        XCTAssertEqual(room.state.thread?.replies.map(\.id), (2_001...2_520).map(Self.id), "merged, each once")
        XCTAssertEqual(room.state.thread?.focusReplyId, Self.id(2_400), "still at the reply")

        room.send(.loadOlderReplies(sequenceId: 42))
        await waitUntil("scrolling up reads on from the window") {
            room.state.thread?.replies.first?.id == Self.id(1_901)
        }
        XCTAssertEqual(transport.reads.last, PagedThread.Read(limit: 100, cursor: "w1.2001"))
        room.pause()
    }

    /// A reply the API says is not in the thread (its 404: missing, deleted, or in another thread) is said to be gone
    /// after that one read: nothing reads on looking for it.
    func test_a_reply_the_api_says_is_not_in_the_thread_is_said_to_be_gone_after_one_read() async throws {
        let transport = PagedThread(count: 300)
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(5_000))
        await waitUntil("the thread says so") {
            room.state.thread?.failureText == "That reply is no longer in this thread."
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.reads, [.init(limit: 500, around: Self.id(5_000))], "one read, and no paging on")
        XCTAssertEqual(room.state.thread?.focusMissing, false, "nothing to jump to")
        XCTAssertEqual(room.state.thread?.isLoading, false)
        XCTAssertEqual(room.state.thread?.isLoadingOlder, false)
        room.pause()
    }

    /// After that 404 the thread is no dead end: it offers its replies, and scrolling up reads its newest page, then
    /// pages back from that page's cursor. Nothing is read until the reader scrolls up.
    func test_after_a_reply_not_in_the_thread_scrolling_up_reads_the_newest_page_and_pages_back() async throws {
        let transport = PagedThread(count: 300)
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(5_000))
        await waitUntil("the thread says so") {
            room.state.thread?.failureText == "That reply is no longer in this thread."
        }
        XCTAssertEqual(room.state.thread?.hasOlder, true, "the thread's replies are there to read")
        XCTAssertEqual(transport.reads, [.init(limit: 500, around: Self.id(5_000))])

        room.send(.loadOlderReplies(sequenceId: 42))
        await waitUntil("its newest page is read") {
            room.state.thread?.isLoading == false && room.state.thread?.replies.last?.id == Self.id(300)
        }
        XCTAssertEqual(room.state.thread?.replies.map(\.id), (201...300).map(Self.id))
        XCTAssertEqual(room.state.thread?.hasOlder, true)

        room.send(.loadOlderReplies(sequenceId: 42))
        await waitUntil("the page before it") { room.state.thread?.replies.first?.id == Self.id(101) }
        XCTAssertEqual(transport.reads, [.init(limit: 500, around: Self.id(5_000)), .init(limit: 100, cursor: nil),
                                         .init(limit: 100, cursor: "201")],
                       "the newest page, then back from its cursor")
        room.pause()
    }

    /// A link to a reply that was collapsed into another: the API resolves it, and the thread opens at the reply it
    /// resolved to (`anchoredActionId`), with that one read.
    func test_a_collapsed_reply_opens_at_the_reply_the_api_resolved_it_to() async throws {
        let collapsedReply = "9b2f7a40-0000-4000-8000-00000000c0de"
        let transport = PagedThread(count: 2_500)
        transport.collapsed = [collapsedReply: 1_200]
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: collapsedReply)
        await waitUntil("the thread is open") {
            room.state.thread?.isLoading == false
                && room.state.thread?.replies.contains { $0.id == Self.id(1_200) } == true
        }
        XCTAssertEqual(transport.reads, [.init(limit: 500, around: collapsedReply)])
        XCTAssertEqual(room.state.thread?.focusReplyId, Self.id(1_200), "at the reply it resolved to")
        XCTAssertNil(room.state.thread?.failureText)
        room.pause()
    }

    /// The window keeps a collapsed reply's own row as well as the final one it resolved to: the thread opens at the
    /// one the API placed the window around (`anchoredActionId`), never at the old row, with that one read.
    func test_a_window_holding_a_collapsed_reply_and_its_final_one_opens_at_the_final_one() async throws {
        let transport = PagedThread(count: 2_500)
        transport.collapsed = [Self.id(1_190): 1_200]
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(1_190))
        await waitUntil("the thread is open") {
            room.state.thread?.isLoading == false && room.state.thread?.replies.isEmpty == false
        }
        let ids = try XCTUnwrap(room.state.thread?.replies.map(\.id))
        XCTAssertTrue(ids.contains(Self.id(1_190)) && ids.contains(Self.id(1_200)), "both rows are in the window")
        XCTAssertEqual(transport.reads, [.init(limit: 500, around: Self.id(1_190))])
        XCTAssertEqual(room.state.thread?.focusReplyId, Self.id(1_200), "at the final one, not the collapsed row")
        XCTAssertNil(room.state.thread?.failureText)
        room.pause()
    }

    /// An API without reads around a reply (before #1199) answers that read with the thread's newest page: the thread
    /// reads back from it, so the read around costs no read more. 2,200 back: 5 reads.
    func test_an_api_without_reads_around_a_reply_reads_back_from_the_newest_page_it_answered() async throws {
        let transport = PagedThread(count: 2_500, anchored: false)
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(300))
        await waitUntil("the reply is loaded") {
            room.state.thread?.replies.contains { $0.id == Self.id(300) } == true
                && room.state.thread?.isLoadingOlder == false
        }
        XCTAssertEqual(transport.reads, [
            .init(limit: 500, around: Self.id(300)),
            .init(limit: 500, cursor: "2001"),
            .init(limit: 500, cursor: "1501"),
            .init(limit: 500, cursor: "1001"),
            .init(limit: 500, cursor: "501")
        ], "the newest page it answered is the first page read back from, never read again")
        XCTAssertEqual(room.state.thread?.focusReplyId, Self.id(300))
        XCTAssertNil(room.state.thread?.failureText)
        room.pause()
    }

    /// A read around the reply that fails (anything but the API's 404) reads back from the newest page as before, and
    /// still reaches the reply.
    func test_a_read_around_the_reply_that_fails_reads_back_and_still_reaches_it() async throws {
        let transport = PagedThread(count: 2_500)
        transport.failsAround = true
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(300))
        await waitUntil("the reply is loaded") {
            room.state.thread?.replies.contains { $0.id == Self.id(300) } == true
                && room.state.thread?.isLoadingOlder == false
        }
        XCTAssertEqual(transport.reads, [
            .init(limit: 500, around: Self.id(300)),
            .init(limit: 100, cursor: nil),
            .init(limit: 500, cursor: "2401"),
            .init(limit: 500, cursor: "1901"),
            .init(limit: 500, cursor: "1401"),
            .init(limit: 500, cursor: "901"),
            .init(limit: 500, cursor: "401")
        ], "the newest page, then pages of 500 back, and no more once it is there")
        XCTAssertEqual(room.state.thread?.focusReplyId, Self.id(300))
        XCTAssertFalse(room.state.thread?.focusMissing ?? true)
        XCTAssertNil(room.state.thread?.failureText)
        room.pause()
    }

    /// A window that does not hold the reply it is around is no answer to open at: the thread reads back instead.
    func test_a_window_without_its_reply_reads_back_instead() async throws {
        let transport = PagedThread(count: 1_000)
        transport.windowLeavesOutItsReply = true
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(600))
        await waitUntil("the reply is loaded") {
            room.state.thread?.replies.contains { $0.id == Self.id(600) } == true
                && room.state.thread?.isLoadingOlder == false
        }
        XCTAssertEqual(transport.reads, [.init(limit: 500, around: Self.id(600)), .init(limit: 100, cursor: nil),
                                         .init(limit: 500, cursor: "901")])
        XCTAssertEqual(room.state.thread?.focusReplyId, Self.id(600))
        room.pause()
    }

    /// Reading on down from a window holds 1,000 replies at most, as reading back does: the oldest go up to the start
    /// of a page read on, and scrolling up reads them again from there, leaving none out.
    func test_reading_on_from_a_window_holds_at_most_a_thousand_and_reads_back_what_it_let_go() async throws {
        let transport = PagedThread(count: 100_000)
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(40_000))
        await waitUntil("the thread is open at the reply") {
            room.state.thread?.isLoading == false && room.state.thread?.replies.count == 500
        }
        for page in 1...6 {
            room.send(.loadLaterReplies(sequenceId: 42))
            await waitUntil("page \(page) on is read") {
                room.state.thread?.replies.last?.id == Self.id(40_249 + page * 100)
                    && room.state.thread?.isLoadingLater == false
            }
        }
        XCTAssertEqual(room.state.thread?.replies.map(\.id), (40_250...40_849).map(Self.id),
                       "1,100 read: the window's 500 went, up to the first page read on")
        XCTAssertEqual(room.state.thread?.hasLater, true)
        XCTAssertEqual(room.state.thread?.hasOlder, true)

        room.send(.loadOlderReplies(sequenceId: 42))
        await waitUntil("scrolling up reads again what went") {
            room.state.thread?.replies.first?.id == Self.id(40_150)
        }
        XCTAssertEqual(transport.reads.last, PagedThread.Read(limit: 100, cursor: "w1.40250"))
        XCTAssertEqual(room.state.thread?.replies.map(\.id), (40_150...40_849).map(Self.id), "none left out")
        room.pause()
    }

    /// One page read is on its way at a time, either way. A page back and a page on asked for together never both land,
    /// whichever would come back first: the thread holds no gap, and its cursors are its loaded edges. (Both landing, a
    /// page back could let the newest go, or a page on the oldest, and the other would land beyond a gap.)
    func test_a_page_back_and_a_page_on_asked_together_leave_no_gap_whichever_would_land_first() async throws {
        for olderLandsFirst in [true, false] {
            let transport = PagedThread(count: 100_000)
            let room = coordinator(transport, focus: 42)
            room.resume()
            room.openThread(42, at: Self.id(40_000))
            await waitUntil("the thread is open at the reply") {
                room.state.thread?.isLoading == false && room.state.thread?.replies.count == 500
            }
            for page in 1...5 {
                room.send(.loadOlderReplies(sequenceId: 42))
                await waitUntil("page \(page) back is read") {
                    room.state.thread?.replies.first?.id == Self.id(39_750 - page * 100)
                        && room.state.thread?.isLoadingOlder == false
                }
            }
            let held = try XCTUnwrap(room.state.thread?.replies.map(\.id))
            XCTAssertEqual(held, (39_250...40_249).map(Self.id), "1,000 held: one page more either way goes past it")

            // The one asked for second would land first.
            transport.olderDelay = olderLandsFirst ? 50_000_000 : 400_000_000
            transport.laterDelay = olderLandsFirst ? 400_000_000 : 50_000_000
            let before = transport.reads.count
            if olderLandsFirst {
                room.send(.loadLaterReplies(sequenceId: 42))
                room.send(.loadOlderReplies(sequenceId: 42))
            } else {
                room.send(.loadOlderReplies(sequenceId: 42))
                room.send(.loadLaterReplies(sequenceId: 42))
            }
            await waitUntil("a page lands") {
                room.state.thread?.replies.map(\.id) != held && room.state.thread?.isLoadingOlder == false
                    && room.state.thread?.isLoadingLater == false
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            XCTAssertEqual(transport.reads.count, before + 1,
                           "one page on its way at a time (older first: \(olderLandsFirst))")
            let numbers = try XCTUnwrap(room.state.thread?.replies.map { Self.number($0.id) })
            let first = try XCTUnwrap(numbers.first)
            let last = try XCTUnwrap(numbers.last)
            XCTAssertEqual(numbers, Array(first...last), "no gap (older first: \(olderLandsFirst))")

            // The cursors are the loaded edges.
            transport.olderDelay = 0
            transport.laterDelay = 0
            room.send(.loadOlderReplies(sequenceId: 42))
            await waitUntil("a page back") { room.state.thread?.replies.first?.id == Self.id(first - 100) }
            XCTAssertEqual(transport.reads.last, PagedThread.Read(limit: 100, cursor: "w1.\(first)"))
            if room.state.thread?.hasLater == true {
                let newest = Self.number(try XCTUnwrap(room.state.thread?.replies.last?.id))
                room.send(.loadLaterReplies(sequenceId: 42))
                await waitUntil("a page on") { room.state.thread?.replies.last?.id == Self.id(newest + 100) }
                XCTAssertEqual(transport.reads.last, PagedThread.Read(limit: 100, after: "w1.\(newest)"))
            }
            room.pause()
        }
    }

    /// Reading back from a window past 1,000 lets the newest go, as before: the page on would then leave them out, so
    /// the thread offers its newest instead.
    func test_reading_back_from_a_window_past_a_thousand_offers_the_newest_instead() async throws {
        let transport = PagedThread(count: 100_000)
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(40_000))
        await waitUntil("the thread is open at the reply") {
            room.state.thread?.isLoading == false && room.state.thread?.replies.count == 500
        }
        for page in 1...6 {
            room.send(.loadOlderReplies(sequenceId: 42))
            await waitUntil("page \(page) back is read") {
                room.state.thread?.replies.first?.id == Self.id(39_750 - page * 100)
                    && room.state.thread?.isLoadingOlder == false
            }
        }
        XCTAssertEqual(room.state.thread?.replies.map(\.id), (39_150...40_149).map(Self.id), "the newest 100 went")
        XCTAssertEqual(room.state.thread?.hasNewer, true)
        XCTAssertEqual(room.state.thread?.hasLater, false, "the page on would leave out the replies that went")
        room.pause()
    }

    // MARK: - Opened at a reply, read back a page at a time (an API without reads around a reply, or that read failed)

    /// Further back than one search reads (40 pages): the thread stays at its newest page and offers "Jump to the
    /// reply"; each tap reads on (40 pages more), until the reply is there.
    func test_a_reply_further_back_than_a_search_reads_is_offered_and_reached_on_tap() async throws {
        // At most 10 replies a read, so 40 pages are 400 replies. The read around the reply fails.
        let transport = PagedThread(count: 1_000, pageSize: 10)
        transport.failsAround = true
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(5))
        await waitUntil("the search stops at its last page") { room.state.thread?.focusMissing == true }
        XCTAssertEqual(transport.reads.count, 2 + RoomChatCoordinator.threadSearchPages,
                       "the read around it, the newest page, then 40 pages")
        XCTAssertEqual(RoomChatCoordinator.threadSearchPages, 40)
        XCTAssertEqual(room.state.thread?.replies.count, 410)
        XCTAssertEqual(room.state.thread?.isLoadingOlder, false)
        XCTAssertEqual(room.state.thread?.focusReplyId, Self.id(5), "still opened at the reply, offered")

        room.send(.continueToReply(sequenceId: 42))
        await waitUntil("a tap reads 40 pages more") {
            transport.reads.count == 82 && room.state.thread?.isLoadingOlder == false
        }
        XCTAssertEqual(room.state.thread?.focusMissing, true, "still further back: offered again")
        XCTAssertEqual(room.state.thread?.replies.count, 810)

        room.send(.continueToReply(sequenceId: 42))
        await waitUntil("the reply is reached") { room.state.thread?.replies.contains { $0.id == Self.id(5) } == true }
        await waitUntil("and the offer goes") { room.state.thread?.focusMissing == false }
        XCTAssertEqual(transport.reads.count, 101, "read back to it and no further")
        room.pause()
    }

    /// A page that could not be read stops the search where it is, says so, and offers "Jump to the reply" to try
    /// again: never silent.
    func test_a_search_page_that_fails_says_so_and_offers_to_go_on() async throws {
        let transport = PagedThread(count: 1_000, anchored: false)
        transport.failOnce(before: "501")
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(50))
        await waitUntil("the search stops") { room.state.thread?.focusMissing == true }
        XCTAssertEqual(room.state.thread?.failureText, "Earlier replies could not be loaded. Try again in a moment.")
        XCTAssertEqual(room.state.thread?.replies.count, 500)

        room.send(.continueToReply(sequenceId: 42))
        await waitUntil("the reply is reached") { room.state.thread?.replies.contains { $0.id == Self.id(50) } == true }
        await waitUntil("the offer and the failure go") {
            room.state.thread?.focusMissing == false && room.state.thread?.failureText == nil
        }
        room.pause()
    }

    /// Read to its start without the reply (an API without reads around a reply): the thread says it is not there.
    func test_a_reply_that_is_not_in_the_thread_is_said_to_be_gone() async throws {
        let transport = PagedThread(count: 300, anchored: false)
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(5_000))
        await waitUntil("the thread says so") { room.state.thread?.failureText == "That reply is no longer in this thread." }
        XCTAssertEqual(room.state.thread?.focusMissing, false, "nothing further to jump to")
        XCTAssertEqual(room.state.thread?.replies.count, 300)
        room.pause()
    }

    // MARK: - The thread on screen

    /// Message 42 with a thread of `count` long replies open (the newest `count`, numbered up to `newest`).
    private static func openThread(count: Int = 1_000, newest: Int = 1_000, focus: Int? = nil, hasOlder: Bool = false,
                                   focusMissing: Bool = false, hasLater: Bool = false,
                                   draftKey: String? = nil) -> RoomChatPresentationState {
        let parent = RoomChatMessageInput(id: "evt-42", sequenceId: 42, kind: .message, authorId: "review-agent",
                                          authorName: "review-agent", isHuman: false, text: "Two findings so far.",
                                          timestamp: "2026-11-05T00:00:00.000000+00:00")
        let replies = ((newest - count + 1)...newest).map { index in
            RoomChatReplyRow(id: id(index), authorName: index.isMultiple(of: 2) ? "build-agent" : "review-agent",
                             isHuman: false, isOwn: false, text: text(index, of: newest),
                             date: Date(timeIntervalSince1970: 1_793_000_000 + Double(index) * 60), isEdited: false)
        }
        return RoomChatPresentationState(
            sessionId: "room-big", title: "Review", messages: [parent], connection: .live,
            thread: RoomChatThreadInput(sequenceId: 42, replies: replies, canReply: true, focusReplyId: focus.map(id),
                                        hasOlder: hasOlder, totalReplies: newest, focusMissing: focusMissing,
                                        hasLater: hasLater),
            draftKey: draftKey
        )
    }

    private func host(_ state: RoomChatPresentationState,
                      send: @escaping (RoomChatIntent) -> Void = { _ in }) throws -> UIWindow {
        let window = try HostedSummary.host(NavigationStack { RoomChatView(state: state, send: send) })
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.thread.composer", in: window), "the thread opens over the room")
        return window
    }

    private static func views(in window: UIWindow) -> [UIView] {
        var roots: [UIView] = [window]
        if let presented = window.rootViewController?.presentedViewController?.view { roots.append(presented) }
        var found: [UIView] = []
        var queue = roots
        while !queue.isEmpty {
            let view = queue.removeFirst()
            found.append(view)
            queue.append(contentsOf: view.subviews)
        }
        return found
    }

    private static func layout(_ window: UIWindow) {
        window.rootViewController?.view.layoutIfNeeded()
        window.rootViewController?.presentedViewController?.view.layoutIfNeeded()
    }

    /// Reply `index` on screen, read as VoiceOver reads it, or nil once the time is up.
    private func replyOnScreen(_ index: Int, in window: UIWindow, timeout: TimeInterval = 10) -> NSObject? {
        let words = "Reply \(index) of "
        let end = Date().addingTimeInterval(timeout)
        while true {
            HostedSummary.pump(0.1)
            let shown = HostedSummary.elements(in: window).first { element in
                let frame = element.accessibilityFrame
                return (element.accessibilityLabel ?? "").contains(words) && frame.height > 0
                    && window.bounds.intersects(frame)
            }
            if let shown { return shown }
            if Date() >= end { return nil }
        }
    }

    /// UI automation: an assistive client (VoiceOver, a UI test) reading the screen. `HostedSummary` turns it on.
    private static let setAutomation: (@convention(c) (Bool) -> Void)? = {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (Bool) -> Void).self)
    }()

    /// The room with `state`'s thread open, in a window on the simulator, with an assistive client reading the screen
    /// or not. Nothing here reads the screen: what is built is what the room built to show itself.
    private func roomWindow(showing state: RoomChatPresentationState, automation: Bool,
                        send: @escaping (RoomChatIntent) -> Void = { _ in }) throws -> UIWindow {
        let setAutomation = try XCTUnwrap(Self.setAutomation, "UI automation could not be set")
        setAutomation(automation)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        window.windowLevel = .normal + 5
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            RoomChatView(state: state, send: send)
        })
        window.makeKeyAndVisible()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        HostedSummary.pump(0.2)
        Self.setAutomation?(false)
    }

    /// The thread's reply box, found among the window's views (never by reading the screen, which builds what it
    /// reads), or nil once the time is up.
    private func composer(in window: UIWindow, timeout: TimeInterval = 15) -> UITextView? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let box = Self.views(in: window).compactMap({ $0 as? UITextView })
                .first(where: { $0.accessibilityIdentifier == "pocket.thread.composer" }) {
                return box
            }
            HostedSummary.pump(0.1)
        }
        return nil
    }

    /// The replies built to open `state`'s thread and come to rest, with an assistive client reading the screen or
    /// not; then, with one, what reading the screen once more built.
    private func builtToOpen(_ state: RoomChatPresentationState, automation: Bool) throws
        -> (open: Set<String>, read: Set<String>) {
        RenderTrace.resetThreadReplies()
        let window = try roomWindow(showing: state, automation: automation)
        defer { close(window) }
        XCTAssertNotNil(composer(in: window), "the thread opens over the room")
        HostedSummary.pump(1.5)
        let open = RenderTrace.threadRepliesBuiltSinceReset()
        guard automation else { return (open, open) }
        _ = HostedSummary.elements(in: window)
        HostedSummary.pump(0.3)
        return (open, RenderTrace.threadRepliesBuiltSinceReset())
    }

    /// Reply numbers as runs: "1-6, 590-612".
    private static func runs(_ ids: Set<String>) -> String {
        let numbers = ids.compactMap { id in id.split(separator: "-").last.flatMap { Int($0) } }.sorted()
        var parts: [String] = []
        var start: Int?
        var last: Int?
        for number in numbers {
            if let current = last, number == current + 1 {
                last = number
                continue
            }
            if let first = start, let end = last { parts.append(first == end ? "\(first)" : "\(first)-\(end)") }
            start = number
            last = number
        }
        if let first = start, let end = last { parts.append(first == end ? "\(first)" : "\(first)-\(end)") }
        return parts.joined(separator: ", ")
    }

    /// A thread of 1,000 long replies opens building the replies in sight, never the thousand. Counted with no
    /// assistive client reading the screen, before anything reads it; what an assistive client (VoiceOver) costs is
    /// counted apart, and printed.
    func test_a_thread_of_a_thousand_replies_opens_building_only_the_replies_in_sight() throws {
        let plain = try builtToOpen(Self.openThread(), automation: false)
        let read = try builtToOpen(Self.openThread(), automation: true)
        print("THREADOPEN built to open 1,000 replies: \(plain.open.count) with no assistive client "
              + "(\(Self.runs(plain.open))); \(read.open.count) with one (\(Self.runs(read.open))), "
              + "\(read.read.count) once it read the screen")
        XCTAssertGreaterThan(plain.open.count, 0, "the replies in sight are built")
        XCTAssertLessThan(plain.open.count, 60, "a lazy list builds the replies in sight, never all 1,000")
    }

    /// Opened at reply 600 of 1,000 (its notification): the thread goes to it, building the replies near it and never
    /// the ones between the top and it. Counted with no assistive client, then with one (printed). Then, read as
    /// VoiceOver reads the screen, the reply is on screen.
    func test_a_thread_opened_at_a_reply_far_down_goes_to_it_without_building_the_replies_between() throws {
        let plain = try builtToOpen(Self.openThread(focus: 600), automation: false)
        let read = try builtToOpen(Self.openThread(focus: 600), automation: true)
        let between = plain.open.filter { id in
            guard let number = id.split(separator: "-").last.flatMap({ Int($0) }) else { return false }
            return (60...540).contains(number)
        }
        print("THREADFOCUS built to open at reply 600 of 1,000: \(plain.open.count) with no assistive client "
              + "(\(Self.runs(plain.open))), \(between.count) of them between the top and it; "
              + "\(read.open.count) with one (\(Self.runs(read.open))), \(read.read.count) once it read the screen")
        XCTAssertTrue(plain.open.contains(Self.id(600)), "the reply it was opened at is built")
        XCTAssertEqual(between.count, 0, "none of the replies between the top and it is built on the way")
        XCTAssertLessThan(plain.open.count, 60, "the replies in sight at the top, then near it: never the thousand")

        let window = try HostedSummary.host(NavigationStack { RoomChatView(state: Self.openThread(focus: 600),
                                                                           send: { _ in }) })
        defer { HostedSummary.close(window) }
        XCTAssertNotNil(replyOnScreen(600, in: window), "reply 600 of 1,000 is on screen")
    }

    /// A long thread opens with its newest replies shown. Scrolled up to the top, it shows the replies loaded above
    /// them, 30 at a time, and asks for the page before only once all loaded are shown.
    func test_scrolling_up_shows_the_replies_loaded_above_before_reading_the_page_before() throws {
        var sent: [RoomChatIntent] = []
        let window = try roomWindow(showing: Self.openThread(count: 100, newest: 1_000, hasOlder: true),
                                    automation: false) { sent.append($0) }
        defer { close(window) }
        XCTAssertNotNil(composer(in: window), "the thread opens over the room")
        HostedSummary.pump(1.2)
        let list = try XCTUnwrap(Self.views(in: window).compactMap { $0 as? UIScrollView }
            .filter { !($0 is UITextView) }.max { $0.contentSize.height < $1.contentSize.height }, "the replies' list")
        func asksForThePageBefore() -> Bool {
            sent.contains { intent in
                guard case .loadOlderReplies(let sequenceId) = intent else { return false }
                return sequenceId == 42
            }
        }
        var scrolls = 0
        RenderTrace.resetThreadReplies()
        while !asksForThePageBefore(), scrolls < 8 {
            list.setContentOffset(CGPoint(x: 0, y: -list.adjustedContentInset.top), animated: false)
            HostedSummary.pump(0.8)
            scrolls += 1
        }
        print("THREADSCROLLUP asked for the page before at scroll \(scrolls); built on the way: "
              + "\(Self.runs(RenderTrace.threadRepliesBuiltSinceReset()))")
        XCTAssertTrue(asksForThePageBefore(), "with every loaded reply shown, scrolling up asks for the page before")
        XCTAssertEqual(scrolls, 4, "first the 70 replies loaded above the newest 30: 30, 30, then 10")
        XCTAssertTrue(RenderTrace.threadRepliesBuiltSinceReset().contains(Self.id(901)),
                      "the oldest reply loaded is shown when the page before is asked for")
    }

    /// What `keystrokes` keystrokes into `box` drew: the room, the replies' list, and replies built.
    private func typing(_ keystrokes: Int, into box: UITextView, in window: UIWindow, explaining: Bool)
        -> (room: Int, list: Int, replies: Int, ms: Int) {
        let room = RenderTrace.builtCount(.roomBody)
        let list = RenderTrace.builtCount(.threadList)
        let replies = RenderTrace.builtCount(.threadReply)
        let started = Date()
        for index in 0..<keystrokes {
            RenderTrace.explainsThreadList = explaining && index < 3
            box.insertText("a")
            RunLoop.main.run(until: Date())
            Self.layout(window)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1_000)
        HostedSummary.pump(0.3)
        RenderTrace.explainsThreadList = false
        return (RenderTrace.builtCount(.roomBody) - room, RenderTrace.builtCount(.threadList) - list,
                RenderTrace.builtCount(.threadReply) - replies, ms)
    }

    /// Typing in a thread of 1,000 long replies draws the reply box alone: the room under it is never drawn again, the
    /// replies' list is not, and so no reply is built again. Typed with no assistive client (asserted), then with one
    /// (printed).
    func test_typing_in_a_thread_of_a_thousand_long_replies_draws_neither_the_room_nor_the_replies() throws {
        let window = try roomWindow(showing: Self.openThread(), automation: false)
        defer { close(window) }
        let box = try XCTUnwrap(composer(in: window), "the thread opens with its reply box")
        box.becomeFirstResponder()
        HostedSummary.pump(0.8)
        let plain = typing(Self.keystrokes, into: box, in: window, explaining: true)
        Self.setAutomation?(true)
        HostedSummary.pump(0.5)
        let read = typing(Self.keystrokes, into: box, in: window, explaining: true)
        let send = try XCTUnwrap(HostedSummary.wait(for: "pocket.thread.send", in: window))
        print("THREADTYPING \(Self.keystrokes) keystrokes with no assistive client in \(plain.ms) ms: room drawn "
              + "\(plain.room), replies' list drawn \(plain.list), replies built \(plain.replies); with one: "
              + "\(read.ms) ms, room \(read.room), list \(read.list), replies \(read.replies)")

        XCTAssertEqual(box.text, String(repeating: "a", count: Self.keystrokes * 2), "every keystroke reached the box")
        XCTAssertFalse(send.accessibilityTraits.contains(.notEnabled), "what was typed reached the thread: it can be sent")
        XCTAssertEqual(plain.room, 0, "typing in a thread never draws the room under it")
        XCTAssertLessThanOrEqual(plain.list, 1, "nor the thread's replies")
        XCTAssertLessThanOrEqual(plain.replies, Self.keystrokes / 4, "nor builds its replies again, keystroke after keystroke")
        box.resignFirstResponder()
    }
    /// A reply kept on the phone answers a reply on an older page: the thread opens on its newest page, and the reply
    /// sent still answers that one, not the message (its row has not loaded, but it may be on a page not yet read).
    func test_a_kept_reply_to_a_reply_further_back_still_answers_it() throws {
        let key = RoomComposerDraft.savedKey(sessionId: "room-big-\(UUID().uuidString)", account: "big-thread-test")
        let drafts = RoomReplyDrafts(base: key)
        drafts.save("Agreed, the paste check first.", thread: 42, reply: Self.id(5))
        defer { drafts.save("", thread: 42, reply: Self.id(5)) }
        var sent: [RoomChatIntent] = []
        let window = try host(Self.openThread(count: 100, newest: 1_000, hasOlder: true, draftKey: key)) {
            sent.append($0)
        }
        defer { HostedSummary.close(window) }
        HostedSummary.pump(0.5)
        let box = Self.views(in: window).compactMap { $0 as? UITextView }
            .first { $0.accessibilityIdentifier == "pocket.thread.composer" }
        XCTAssertEqual(box?.text, "Agreed, the paste check first.", "the kept reply is back in the box")
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.thread.composer.restoredAnswer", in: window, timeout: 5),
                        "the box says it answers an earlier reply, and can stop")
        let send = try XCTUnwrap(HostedSummary.element("pocket.thread.send", in: window))
        XCTAssertTrue(send.accessibilityActivate())
        HostedSummary.pump(0.3)
        let replied = sent.compactMap { intent -> String? in
            guard case .sendReplyToReply(let sequenceId, let replyId, _) = intent, sequenceId == 42 else { return nil }
            return replyId
        }
        XCTAssertEqual(replied, [Self.id(5)], "it answers the reply it was written to")
        XCTAssertFalse(sent.contains { if case .sendReply = $0 { return true } else { return false } },
                       "never the message instead")
    }

    /// The reply it was opened at is further back than a search reads: the thread shows its newest reply, and "Jump to
    /// the reply" goes on looking.
    func test_a_reply_not_yet_found_opens_at_the_newest_with_a_jump_to_it() throws {
        var sent: [RoomChatIntent] = []
        let window = try host(Self.openThread(count: 100, newest: 1_000, focus: 5, hasOlder: true, focusMissing: true)) {
            sent.append($0)
        }
        defer { HostedSummary.close(window) }
        XCTAssertNotNil(replyOnScreen(1_000, in: window), "the newest reply is on screen")
        let jump = try XCTUnwrap(HostedSummary.wait(for: "pocket.thread.jumpToReply", in: window), "Jump to the reply")
        XCTAssertTrue(jump.accessibilityActivate())
        HostedSummary.pump(0.2)
        XCTAssertTrue(sent.contains { intent in
            guard case .continueToReply(let sequenceId) = intent else { return false }
            return sequenceId == 42
        }, "a tap goes on looking")
    }

    /// Opened at a reply short of the newest (one read around it): "Load later replies" is below the replies loaded,
    /// and a tap reads on.
    func test_a_thread_opened_short_of_its_newest_offers_its_later_replies() throws {
        var sent: [RoomChatIntent] = []
        let window = try host(Self.openThread(count: 1, newest: 600, focus: 600, hasOlder: true, hasLater: true)) {
            sent.append($0)
        }
        defer { HostedSummary.close(window) }
        let later = try XCTUnwrap(HostedSummary.wait(for: "pocket.thread.later", in: window), "Load later replies")
        XCTAssertTrue(later.accessibilityActivate())
        HostedSummary.pump(0.2)
        XCTAssertTrue(sent.contains { intent in
            guard case .loadLaterReplies(let sequenceId) = intent else { return false }
            return sequenceId == 42
        }, "a tap reads on")
    }
}
