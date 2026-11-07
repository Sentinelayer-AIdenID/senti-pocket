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
// older ones as asked; one opened at a reply reads back until that reply is there, and shows it; typing in it draws the
// reply box, never the room or the replies.

/// A thread of `count` replies on message 42, read as the API reads it: newest first, at most `pageSize` replies a read
/// (fewer than asked, as a server may answer), each page giving the cursor of the one before. Its reads are kept.
private final class PagedThread: RoomTransport, @unchecked Sendable {
    struct Read: Equatable {
        let limit: Int
        let cursor: String?
    }

    let count: Int
    let pageSize: Int
    let replies: [RoomReply]
    private let lock = NSLock()
    private var kept: [Read] = []
    private var failing: Set<String> = []

    init(count: Int, pageSize: Int = .max) {
        self.count = count
        self.pageSize = pageSize
        replies = (1...count).map { index in
            RoomReply(id: BigThreadTests.id(index), targetSequenceId: 42,
                      authorId: index.isMultiple(of: 2) ? "build-agent" : "review-agent",
                      text: BigThreadTests.text(index, of: count),
                      createdAt: String(format: "2026-11-05T%02ld:%02ld:%02ld.000000+00:00",
                                        index / 3_600 % 24, index / 60 % 60, index % 60))
        }
    }

    var reads: [Read] { lock.withLock { kept } }

    /// The read with this cursor fails, once.
    func failOnce(before cursor: String) { lock.withLock { _ = failing.insert(cursor) } }

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
        let fails = lock.withLock { () -> Bool in
            kept.append(Read(limit: limit, cursor: beforeCursor))
            guard let beforeCursor else { return false }
            return failing.remove(beforeCursor) != nil
        }
        if fails { throw URLError(.timedOut) }
        let end = beforeCursor.flatMap { Int($0) } ?? count + 1
        let start = max(1, end - min(limit, pageSize))
        return RoomActionsPage(replies: Array(replies[(start - 1)..<(end - 1)]),
                               nextCursor: start > 1 ? String(start) : nil)
    }
}

@MainActor
final class BigThreadTests: XCTestCase {
    private static let keystrokes = 20

    /// Reply `index`'s id, a UUID as a reply's is (a notification names only a UUID).
    nonisolated static func id(_ index: Int) -> String { String(format: "9b2f7a40-0000-4000-8000-%012ld", index) }

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

    // MARK: - Opened at a reply

    /// A reply's notification, as a push carries it: the room opens its thread at that reply, 2,200 replies back. The
    /// thread reads back 500 a page until the reply is there (5 pages), and is opened at it.
    func test_a_reply_notification_opens_its_thread_with_the_reply_loaded_however_far_back() async throws {
        let payload: [AnyHashable: Any] = ["sessionId": "room_1", "sequenceId": NSNumber(value: 42),
                                           "replyId": Self.id(300).uppercased()]
        let link = try XCTUnwrap(PushRoute.link(from: payload))
        let transport = PagedThread(count: 2_500)
        let room = coordinator(transport, focus: link.messageSequence)
        room.resume()
        // What the room screen does with the route the push opens (`applyRouteLinksOnce`).
        room.openThread(try XCTUnwrap(link.messageSequence), at: link.replyId)
        await waitUntil("the reply is loaded") {
            room.state.thread?.replies.contains { $0.id == Self.id(300) } == true
                && room.state.thread?.isLoadingOlder == false
        }
        let thread = try XCTUnwrap(room.state.thread)
        XCTAssertEqual(thread.focusReplyId, Self.id(300), "opened at the reply")
        XCTAssertFalse(thread.focusMissing)
        XCTAssertNil(thread.failureText)
        XCTAssertEqual(transport.reads, [
            .init(limit: 100, cursor: nil),
            .init(limit: 500, cursor: "2401"),
            .init(limit: 500, cursor: "1901"),
            .init(limit: 500, cursor: "1401"),
            .init(limit: 500, cursor: "901"),
            .init(limit: 500, cursor: "401")
        ], "pages of 500 back from the newest, and no more once it is there")
        room.pause()
    }

    /// Further back than one search reads (40 pages): the thread stays at its newest page and offers "Jump to the
    /// reply"; each tap reads on (40 pages more), until the reply is there.
    func test_a_reply_further_back_than_a_search_reads_is_offered_and_reached_on_tap() async throws {
        // At most 10 replies a read, so 40 pages are 400 replies.
        let transport = PagedThread(count: 1_000, pageSize: 10)
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(5))
        await waitUntil("the search stops at its last page") { room.state.thread?.focusMissing == true }
        XCTAssertEqual(transport.reads.count, 1 + RoomChatCoordinator.threadSearchPages)
        XCTAssertEqual(RoomChatCoordinator.threadSearchPages, 40)
        XCTAssertEqual(room.state.thread?.replies.count, 410)
        XCTAssertEqual(room.state.thread?.isLoadingOlder, false)
        XCTAssertEqual(room.state.thread?.focusReplyId, Self.id(5), "still opened at the reply, offered")

        room.send(.continueToReply(sequenceId: 42))
        await waitUntil("a tap reads 40 pages more") {
            transport.reads.count == 81 && room.state.thread?.isLoadingOlder == false
        }
        XCTAssertEqual(room.state.thread?.focusMissing, true, "still further back: offered again")
        XCTAssertEqual(room.state.thread?.replies.count, 810)

        room.send(.continueToReply(sequenceId: 42))
        await waitUntil("the reply is reached") { room.state.thread?.replies.contains { $0.id == Self.id(5) } == true }
        await waitUntil("and the offer goes") { room.state.thread?.focusMissing == false }
        XCTAssertEqual(transport.reads.count, 100, "read back to it and no further")
        room.pause()
    }

    /// A page that could not be read stops the search where it is, says so, and offers "Jump to the reply" to try
    /// again: never silent.
    func test_a_search_page_that_fails_says_so_and_offers_to_go_on() async throws {
        let transport = PagedThread(count: 1_000)
        transport.failOnce(before: "901")
        let room = coordinator(transport, focus: 42)
        room.resume()
        room.openThread(42, at: Self.id(50))
        await waitUntil("the search stops") { room.state.thread?.focusMissing == true }
        XCTAssertEqual(room.state.thread?.failureText, "Earlier replies could not be loaded. Try again in a moment.")
        XCTAssertEqual(room.state.thread?.replies.count, 100)

        room.send(.continueToReply(sequenceId: 42))
        await waitUntil("the reply is reached") { room.state.thread?.replies.contains { $0.id == Self.id(50) } == true }
        await waitUntil("the offer and the failure go") {
            room.state.thread?.focusMissing == false && room.state.thread?.failureText == nil
        }
        room.pause()
    }

    /// Read to its start without the reply (it is not in this thread): the thread says so.
    func test_a_reply_that_is_not_in_the_thread_is_said_to_be_gone() async throws {
        let transport = PagedThread(count: 300)
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
                                   focusMissing: Bool = false) -> RoomChatPresentationState {
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
                                        hasOlder: hasOlder, totalReplies: newest, focusMissing: focusMissing)
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

    /// Typing in a thread of 1,000 long replies draws the reply box alone: the room under it is never drawn again, the
    /// replies' list is not, and so no reply is built again. The list is lazy: only the replies in sight are built.
    func test_typing_in_a_thread_of_a_thousand_long_replies_draws_neither_the_room_nor_the_replies() throws {
        RenderTrace.resetThreadReplies()
        let window = try host(Self.openThread())
        defer { HostedSummary.close(window) }
        HostedSummary.pump(0.8)
        let builtOnOpen = RenderTrace.threadRepliesBuiltSinceReset()
        XCTAssertFalse(builtOnOpen.isEmpty, "the replies in sight are built")
        XCTAssertLessThan(builtOnOpen.count, 60, "a lazy list builds the replies in sight, never all 1,000")

        let box = try XCTUnwrap(Self.views(in: window).compactMap { $0 as? UITextView }
            .first { $0.accessibilityIdentifier == "pocket.thread.composer" }, "the thread's reply box")
        box.becomeFirstResponder()
        HostedSummary.pump(0.8)
        let roomBefore = RenderTrace.builtCount(.roomBody)
        let listBefore = RenderTrace.builtCount(.threadList)
        let repliesBefore = RenderTrace.builtCount(.threadReply)
        let started = Date()
        for _ in 0..<Self.keystrokes {
            box.insertText("a")
            RunLoop.main.run(until: Date())
            Self.layout(window)
        }
        let elapsed = Date().timeIntervalSince(started)
        HostedSummary.pump(0.3)
        let roomDraws = RenderTrace.builtCount(.roomBody) - roomBefore
        let listDraws = RenderTrace.builtCount(.threadList) - listBefore
        let replyBuilds = RenderTrace.builtCount(.threadReply) - repliesBefore
        print("THREADTYPING \(Self.keystrokes) keystrokes in \(Int(elapsed * 1_000)) ms: room drawn \(roomDraws), "
              + "replies' list drawn \(listDraws), replies built \(replyBuilds); \(builtOnOpen.count) of 1,000 built to open")

        XCTAssertEqual(box.text, String(repeating: "a", count: Self.keystrokes), "every keystroke reached the box")
        let send = try XCTUnwrap(HostedSummary.element("pocket.thread.send", in: window))
        XCTAssertFalse(send.accessibilityTraits.contains(.notEnabled), "what was typed reached the thread: it can be sent")
        XCTAssertEqual(roomDraws, 0, "typing in a thread never draws the room under it")
        XCTAssertLessThanOrEqual(listDraws, 1, "nor the thread's replies")
        XCTAssertLessThanOrEqual(replyBuilds, Self.keystrokes / 4, "nor builds its replies again, keystroke after keystroke")
        box.resignFirstResponder()
    }

    /// Opened at reply 600 of 1,000 (its notification): the thread goes to it and marks it, without building the
    /// replies between.
    func test_a_thread_opened_at_a_reply_far_down_brings_it_into_view() throws {
        RenderTrace.resetThreadReplies()
        let window = try host(Self.openThread(focus: 600))
        defer { HostedSummary.close(window) }
        XCTAssertNotNil(replyOnScreen(600, in: window), "reply 600 of 1,000 is on screen")
        let built = RenderTrace.threadRepliesBuiltSinceReset()
        print("THREADFOCUS built \(built.count) of 1,000 replies to show reply 600")
        XCTAssertTrue(built.contains(Self.id(600)))
        XCTAssertLessThan(built.count, 200, "it went to the reply, not through the thousand")
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
}
