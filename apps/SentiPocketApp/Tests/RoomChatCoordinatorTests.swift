import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// Scripted room transport: queued pages and stream scripts, with every call recorded. A script that does not end
/// with `.ended` stays open, and when the scripts run out the stream stays open forever (a quiet room) until the
/// coordinator cancels it.
private final class ScriptedRoomTransport: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var beforePages: [Result<RoomEventPage, Error>]
    private var afterPages: [Result<RoomEventPage, Error>]
    private var streamScripts: [[RoomStreamEvent]]
    private(set) var beforeCalls: [Int64?] = []
    private(set) var afterCalls: [Int64] = []
    private(set) var streamCalls: [Int64?] = []
    /// A before call (by its index) that waits for `releaseHeldPage()` before it answers.
    private var heldBeforeCall: Int?
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var heldReleased = false

    init(
        before: [Result<RoomEventPage, Error>] = [],
        after: [Result<RoomEventPage, Error>] = [],
        streams: [[RoomStreamEvent]] = []
    ) {
        self.beforePages = before
        self.afterPages = after
        self.streamScripts = streams
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        let (index, held) = locked { () -> (Int, Int?) in
            beforeCalls.append(beforeSequence)
            return (beforeCalls.count - 1, heldBeforeCall)
        }
        if index == held {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                let now = locked { () -> Bool in
                    if heldReleased { return true }
                    heldWaiter = waiter
                    return false
                }
                if now { waiter.resume() }
            }
        }
        return try locked {
            beforePages.isEmpty ? RoomEventPage(messages: []) : try beforePages.removeFirst().get()
        }
    }

    func hold(beforeCall index: Int) {
        locked { heldBeforeCall = index }
    }

    var isHoldingPage: Bool {
        locked { heldWaiter != nil }
    }

    func releaseHeldPage() {
        let waiter = locked { () -> CheckedContinuation<Void, Never>? in
            heldReleased = true
            defer { heldWaiter = nil }
            return heldWaiter
        }
        waiter?.resume()
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        try locked {
            afterCalls.append(fromSequence)
            return afterPages.isEmpty ? RoomEventPage(messages: []) : try afterPages.removeFirst().get()
        }
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> {
        let script: [RoomStreamEvent]? = locked {
            streamCalls.append(fromSequence)
            return streamScripts.isEmpty ? nil : streamScripts.removeFirst()
        }
        guard let script else { return AsyncStream { _ in } }
        // A script that ends with `.ended` closes the connection; any other script leaves it open (a live room).
        return AsyncStream { continuation in
            for event in script { continuation.yield(event) }
            if case .ended? = script.last { continuation.finish() }
        }
    }

    func snapshot() -> (before: [Int64?], after: [Int64], streams: [Int64?]) {
        locked { (beforeCalls, afterCalls, streamCalls) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Takes every message at once.
private struct AcceptingSender: RoomMessageSending {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {}
}

@MainActor
final class RoomChatCoordinatorTests: XCTestCase {
    private func message(_ seq: Int64, author: String = "cobalt-warden", text: String = "hi") -> RoomMessage {
        RoomMessage(
            id: "evt-\(seq)",
            sequenceId: seq,
            kind: .message,
            authorId: author,
            authorName: author,
            isHuman: RoomMessage.isHumanAuthor(author),
            text: text,
            timestamp: "2026-10-28T18:00:00.000000+00:00"
        )
    }

    private func page(_ seqs: [Int64], hasMore: Bool = false, maxSequence: Int64? = nil) -> RoomEventPage {
        RoomEventPage(
            messages: seqs.map { message($0) },
            maxSequence: maxSequence,
            nextBeforeSequence: seqs.min(),
            hasMore: hasMore
        )
    }

    private func makeCoordinator(
        _ transport: ScriptedRoomTransport,
        sender: (any RoomMessageSending)? = nil,
        onReauth: @escaping @MainActor () -> Void = {}
    ) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            sender: sender,
            ownAuthorIds: ["human-mrrcarter"],
            // Short delays (reconnect backoff) return at once; the long safety-poll waits park until cancelled.
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            onReauthenticationRequired: onReauth
        )
    }

    private func messageSequences(_ coordinator: RoomChatCoordinator) -> [Int64] {
        coordinator.state.rows.compactMap { row in
            if case .message(let message) = row { return message.sequenceId }
            return nil
        }
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

    func test_open_seeds_from_the_tail_and_streams_from_the_highest_sequence_seen() async {
        let transport = ScriptedRoomTransport(before: [.success(page([3, 1, 2], hasMore: true, maxSequence: 9))])
        let coordinator = makeCoordinator(transport)
        coordinator.resume()

        await waitUntil("stream opened") { transport.snapshot().streams.count == 1 }
        XCTAssertEqual(messageSequences(coordinator), [1, 2, 3])
        XCTAssertEqual(transport.snapshot().streams, [9], "a non-chat row at 9 still moves the resume point")
        XCTAssertTrue(coordinator.state.canLoadOlder)
        XCTAssertFalse(coordinator.state.isLoadingInitial)
        coordinator.pause()
    }

    func test_stream_rows_arrive_live_and_composing_clears_when_that_agent_posts() async {
        let transport = ScriptedRoomTransport(
            before: [.success(page([1]))],
            streams: [[
                .frame(.control),
                .frame(.composing(agentId: "cobalt-warden", targetSequenceId: 1))
            ]]
        )
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("composing shown") { coordinator.state.composingAgents == ["cobalt-warden"] }
        XCTAssertEqual(coordinator.state.connection, .live)

        coordinator.handle(.message(message(5)))
        XCTAssertEqual(messageSequences(coordinator), [1, 5])
        XCTAssertTrue(coordinator.state.composingAgents.isEmpty, "the agent's own post ends its composing line")
        coordinator.pause()
        XCTAssertEqual(coordinator.state.connection, .paused)
    }

    func test_arrivals_while_reading_history_count_as_unread_until_the_reader_returns() async {
        let transport = ScriptedRoomTransport(before: [.success(page([1]))])
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }

        coordinator.send(.readerAtBottom(false))
        coordinator.handle(.message(message(7)))
        coordinator.handle(.message(message(8, author: "human-mrrcarter")))
        XCTAssertEqual(coordinator.state.unreadCount, 1, "your own message is never unread")
        XCTAssertTrue(coordinator.state.rows.contains(.unreadDivider))

        coordinator.send(.readerAtBottom(true))
        XCTAssertEqual(coordinator.state.unreadCount, 0)
        XCTAssertFalse(coordinator.state.rows.contains(.unreadDivider))
        coordinator.pause()
    }

    func test_a_dropped_stream_catches_up_then_reconnects_from_the_new_high_water_mark() async {
        let transport = ScriptedRoomTransport(
            before: [.success(page([1, 2]))],
            after: [.success(page([3, 4], maxSequence: 6))],
            streams: [[.ended(.retryable(retryAfterSeconds: nil))]]
        )
        let coordinator = makeCoordinator(transport)
        coordinator.resume()

        await waitUntil("reconnected") { transport.snapshot().streams.count == 2 }
        XCTAssertEqual(transport.snapshot().after.first, 2, "catch-up reads after the last applied row")
        XCTAssertEqual(transport.snapshot().streams, [2, 6])
        XCTAssertEqual(messageSequences(coordinator), [1, 2, 3, 4])
        coordinator.pause()
    }

    /// Carter, #55371: a message edited elsewhere showed neither its new text nor "edited" until the room reopened.
    private func edit(of seq: Int64, text: String) -> RoomMessage {
        RoomMessage(id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: "human-mrrcarter", authorName: "mrrCarter",
                    isHuman: true, text: text, timestamp: "2026-10-28T18:00:00.000000+00:00", revision: 2, isEdited: true)
    }

    private func editedRow(_ coordinator: RoomChatCoordinator, _ seq: Int64) -> (text: String, isEdited: Bool)? {
        for row in coordinator.state.rows {
            if case .message(let message) = row, message.sequenceId == seq { return (message.text, message.isEdited) }
        }
        return nil
    }

    func test_an_edit_made_elsewhere_shows_live_with_edited_and_adds_no_row() async {
        let transport = ScriptedRoomTransport(before: [.success(page([1, 2]))])
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("stream opened") { transport.snapshot().streams.count == 1 }

        coordinator.handle(.edited(edit(of: 2, text: "Better words"), sequenceId: 7))
        XCTAssertEqual(editedRow(coordinator, 2)?.text, "Better words")
        XCTAssertEqual(editedRow(coordinator, 2)?.isEdited, true)
        XCTAssertEqual(messageSequences(coordinator), [1, 2])

        coordinator.handle(.edited(edit(of: 40, text: "Not loaded"), sequenceId: 41))
        XCTAssertEqual(messageSequences(coordinator), [1, 2], "an edit of a message not loaded brings nothing in")
        coordinator.pause()
    }

    func test_a_catch_up_page_applies_the_edits_in_it_after_its_rows() async {
        let transport = ScriptedRoomTransport(
            before: [.success(page([1, 2]))],
            after: [.success(RoomEventPage(messages: [message(3)], edits: [edit(of: 3, text: "Edited at once"), edit(of: 1, text: "First, edited")],
                                           maxSequence: 6))],
            streams: [[.ended(.retryable(retryAfterSeconds: nil))]]
        )
        let coordinator = makeCoordinator(transport)
        coordinator.resume()

        await waitUntil("reconnected") { transport.snapshot().streams.count == 2 }
        XCTAssertEqual(transport.snapshot().streams, [2, 6], "the next read starts after the edit")
        XCTAssertEqual(messageSequences(coordinator), [1, 2, 3])
        XCTAssertEqual(editedRow(coordinator, 1)?.text, "First, edited")
        XCTAssertEqual(editedRow(coordinator, 3)?.text, "Edited at once")
        XCTAssertEqual(editedRow(coordinator, 2)?.isEdited, false)
        coordinator.pause()
    }

    /// Carter's freezes on 10-30: going to the bottom of a long loaded history measured every row in between. The
    /// room keeps only its newest rows before the jump; older ones load again on demand.
    func test_a_long_history_keeps_only_its_newest_rows_before_the_jump_down() async {
        let transport = ScriptedRoomTransport(before: [.success(page(Array(1...130), hasMore: true))])
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("loaded") { messageSequences(coordinator).count == 130 }
        XCTAssertTrue(coordinator.state.jumpDownKeepsLatest, "Jump to latest keeps the newest rows first")

        coordinator.send(.keepLatestForJumpDown)
        XCTAssertEqual(messageSequences(coordinator), Array(71...130), "the newest 60 stay")
        XCTAssertTrue(coordinator.state.canLoadOlder, "and the rest can load again")
        XCTAssertFalse(coordinator.state.jumpDownKeepsLatest, "the jump is now short enough to animate")

        coordinator.send(.keepLatestForJumpDown)
        XCTAssertEqual(messageSequences(coordinator).count, 60, "a short history is left alone")
        coordinator.pause()
    }

    /// Carter's freezes came from sending far up a long history (10-30, "sendMessage (497 rows)").
    func test_sending_from_up_a_long_history_keeps_only_the_newest_rows_first() async {
        let transport = ScriptedRoomTransport(before: [.success(page(Array(1...497), hasMore: true))])
        let coordinator = makeCoordinator(transport, sender: AcceptingSender())
        coordinator.resume()
        await waitUntil("loaded") { messageSequences(coordinator).count == 497 }

        coordinator.send(.readerAtBottom(false))
        coordinator.send(.sendMessage(text: "on my way down"))
        XCTAssertEqual(messageSequences(coordinator), Array(438...497), "only the newest 60 are crossed on the way down")
        XCTAssertTrue(coordinator.state.canLoadOlder)
        XCTAssertEqual(coordinator.state.pending.map(\.text), ["on my way down"])
        coordinator.pause()
    }

    func test_sending_at_the_bottom_leaves_the_history_loaded() async {
        let transport = ScriptedRoomTransport(before: [.success(page(Array(1...130), hasMore: true))])
        let coordinator = makeCoordinator(transport, sender: AcceptingSender())
        coordinator.resume()
        await waitUntil("loaded") { messageSequences(coordinator).count == 130 }

        coordinator.send(.readerAtBottom(true))
        coordinator.send(.sendMessage(text: "here"))
        XCTAssertEqual(messageSequences(coordinator).count, 130, "already at the bottom: nothing to cross")
        coordinator.pause()
    }

    /// Warden, #253: an older page in flight when the rows are trimmed must not land above the rows kept.
    func test_an_older_page_requested_before_a_trim_is_dropped_and_asked_again_from_the_rows_kept() async {
        let transport = ScriptedRoomTransport(before: [
            .success(page(Array(101...230), hasMore: true)),
            .success(page(Array(21...100), hasMore: true)),
            .success(page(Array(111...170), hasMore: true))
        ])
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("loaded") { messageSequences(coordinator).count == 130 }

        transport.hold(beforeCall: 1)
        coordinator.send(.loadOlder)
        await waitUntil("older page in flight") { transport.isHoldingPage }
        coordinator.send(.keepLatestForJumpDown)
        XCTAssertEqual(messageSequences(coordinator), Array(171...230))

        transport.releaseHeldPage()
        await waitUntil("late page answered") { !coordinator.state.isLoadingOlder }
        XCTAssertEqual(messageSequences(coordinator), Array(171...230), "the late page is dropped: no gap above the rows kept")
        XCTAssertTrue(coordinator.state.canLoadOlder)

        coordinator.send(.loadOlder)
        await waitUntil("asked again") { transport.snapshot().before.count == 3 && !coordinator.state.isLoadingOlder }
        XCTAssertEqual(transport.snapshot().before.last, 171, "from the oldest row kept")
        XCTAssertEqual(messageSequences(coordinator), Array(111...230), "and history is whole again")
        coordinator.pause()
    }

    func test_access_denied_stops_the_room_and_shows_no_rows() async {
        let transport = ScriptedRoomTransport(
            before: [.success(page([1, 2]))],
            streams: [[.ended(.accessDenied)]]
        )
        let coordinator = makeCoordinator(transport)
        coordinator.resume()

        await waitUntil("denied") { coordinator.state.failure == .accessDenied }
        XCTAssertTrue(coordinator.state.rows.isEmpty)
        XCTAssertEqual(transport.snapshot().streams.count, 1, "no reconnect after access is denied")

        coordinator.resume()
        await Task.yield()
        XCTAssertEqual(transport.snapshot().streams.count, 1, "resume does not reopen a denied room")
    }

    func test_an_expired_sign_in_asks_for_reauthentication() async {
        var asked = 0
        let transport = ScriptedRoomTransport(before: [.failure(SessionTransportError.reauthenticationRequired)])
        let coordinator = makeCoordinator(transport) { asked += 1 }
        coordinator.resume()

        await waitUntil("reauth") { coordinator.state.failure == .reauthenticationRequired }
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(transport.snapshot().streams.isEmpty)
    }

    func test_older_history_pages_back_from_the_server_anchor_until_the_start() async {
        let transport = ScriptedRoomTransport(before: [
            .success(page([40, 50], hasMore: true)),
            .success(page([20, 30], hasMore: true)),
            .success(page([10], hasMore: false))
        ])
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }

        coordinator.send(.loadOlder)
        await waitUntil("first older page") { messageSequences(coordinator).count == 4 && !coordinator.state.isLoadingOlder }
        coordinator.send(.loadOlder)
        await waitUntil("start reached") { messageSequences(coordinator).count == 5 && !coordinator.state.isLoadingOlder }

        XCTAssertEqual(transport.snapshot().before, [nil, 40, 20])
        XCTAssertFalse(coordinator.state.canLoadOlder, "the start of the room ends paging")
        coordinator.pause()
    }

    func test_a_room_opened_at_a_message_loads_the_window_around_it_and_clears_the_focus_once_shown() async {
        let transport = ScriptedRoomTransport(
            before: [
                .success(page([90, 100], hasMore: true)),
                .success(page([50, 60, 70], hasMore: true))
            ],
            after: [.success(page([80]))]
        )
        let coordinator = RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            focusSequenceId: 70,
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            onReauthenticationRequired: {}
        )
        coordinator.resume()
        await waitUntil("focus target loaded") { messageSequences(coordinator).contains(70) && !coordinator.state.isLoadingOlder }
        XCTAssertEqual(coordinator.state.focusSequenceId, 70)
        XCTAssertEqual(transport.snapshot().before, [nil, 71], "the tail, then one page ending at the message")
        XCTAssertEqual(transport.snapshot().after, [70], "then one page after it")
        XCTAssertEqual(messageSequences(coordinator), [50, 60, 70, 80, 90, 100], "a window that reaches the rows joins them")
        XCTAssertFalse(coordinator.state.canLoadNewer)

        coordinator.send(.focusHandled)
        XCTAssertNil(coordinator.state.focusSequenceId, "the focus is applied once")
        coordinator.pause()
    }

    func test_jumping_to_an_unloaded_reply_target_loads_its_window() async {
        let transport = ScriptedRoomTransport(
            before: [
                .success(page([90, 100], hasMore: true)),
                .success(page([40, 50, 60], hasMore: true))
            ],
            after: [.success(page([70, 80]))]
        )
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }

        coordinator.send(.jumpToMessage(sequenceId: 60))
        await waitUntil("target loaded") { messageSequences(coordinator).contains(60) && !coordinator.state.isLoadingOlder }
        XCTAssertEqual(transport.snapshot().before, [nil, 61], "one page ending at the target, not a page walk")
        XCTAssertEqual(coordinator.state.focusSequenceId, 60, "the view brings it into view")
        coordinator.pause()
    }

    func test_a_link_to_an_unloaded_message_loads_its_window_and_focuses_it() async {
        let transport = ScriptedRoomTransport(
            before: [
                .success(page([90, 100], hasMore: true)),
                .success(page([50, 60], hasMore: true))
            ],
            after: [.success(page([70, 80]))]
        )
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }

        coordinator.focus(on: 500)
        XCTAssertEqual(coordinator.state.focusSequenceId, 500)
        XCTAssertEqual(transport.snapshot().before, [nil], "a message newer than the loaded rows arrives live; no paging")

        coordinator.focus(on: 60)
        XCTAssertEqual(coordinator.state.focusSequenceId, 60)
        await waitUntil("target loaded") { messageSequences(coordinator).contains(60) && !coordinator.state.isLoadingOlder }
        XCTAssertEqual(transport.snapshot().before, [nil, 61])
        XCTAssertEqual(coordinator.state.focusSequenceId, 60, "the focus stays until the view has shown it")
        coordinator.send(.focusHandled)
        XCTAssertNil(coordinator.state.focusSequenceId)
        XCTAssertEqual(coordinator.state.focusFallbackCount, 0, "a message that was shown is no fallback")
        coordinator.pause()
    }

    /// The scale case: a link thousands of messages back is two requests, and the live room waits below the window.
    func test_a_link_far_back_loads_one_window_and_the_live_room_waits_below_it() async {
        let transport = ScriptedRoomTransport(
            before: [
                .success(page([990, 1_000], hasMore: true)),
                .success(page([740, 750, 760, 770], hasMore: true))
            ],
            after: [
                // A full page after the target that stops far short of the loaded rows: the window stands alone.
                .success(RoomEventPage(messages: [message(780), message(790)], rawCount: 50, maxSequence: 800)),
                // Paging down below the window reaches the live room.
                .success(RoomEventPage(messages: [message(810), message(990), message(1_000), message(1_010)], rawCount: 30))
            ]
        )
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }

        coordinator.focus(on: 770)
        await waitUntil("window loaded") { messageSequences(coordinator).contains(770) && !coordinator.state.isLoadingOlder }
        XCTAssertEqual(transport.snapshot().before, [nil, 771], "one page ending at the message, whatever the distance")
        XCTAssertEqual(transport.snapshot().after, [770])
        XCTAssertEqual(messageSequences(coordinator), [740, 750, 760, 770, 780, 790], "the window replaces the rows")
        XCTAssertTrue(coordinator.state.canLoadNewer, "newer messages load below the window")
        XCTAssertEqual(coordinator.state.focusSequenceId, 770)
        XCTAssertEqual(coordinator.state.focusFallbackCount, 0)

        coordinator.handle(.message(message(1_010)))
        XCTAssertEqual(messageSequences(coordinator), [740, 750, 760, 770, 780, 790], "a live message never lands in the window")
        XCTAssertEqual(coordinator.state.unreadCount, 1, "it is counted as new below")

        coordinator.send(.loadNewer)
        await waitUntil("joined the live room") { !coordinator.state.canLoadNewer && !coordinator.state.isLoadingNewer }
        XCTAssertEqual(transport.snapshot().after, [770, 800], "the next page starts where the last one read to")
        XCTAssertEqual(Array(messageSequences(coordinator).suffix(3)), [990, 1_000, 1_010])
        coordinator.pause()
    }

    func test_jump_to_latest_from_a_window_reloads_the_live_room() async {
        let transport = ScriptedRoomTransport(
            before: [
                .success(page([990, 1_000], hasMore: true)),
                .success(page([760, 770], hasMore: true)),
                .success(page([1_000, 1_010], hasMore: true))
            ],
            after: [.success(RoomEventPage(messages: [message(780)], rawCount: 50, maxSequence: 820))]
        )
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }
        coordinator.focus(on: 770)
        await waitUntil("window") { coordinator.state.canLoadNewer && !coordinator.state.isLoadingOlder }

        coordinator.send(.jumpToLatest)
        await waitUntil("live again") { !coordinator.state.canLoadNewer && !coordinator.state.isLoadingOlder }
        XCTAssertEqual(transport.snapshot().before, [nil, 771, nil], "the newest page of the room, as it opens")
        XCTAssertEqual(messageSequences(coordinator), [1_000, 1_010])
        coordinator.pause()
    }

    /// Review of b3f8252: a second link far from both the first window and the live room loads a window of its own,
    /// never stitched to the first one over a hole.
    func test_a_second_link_far_from_the_window_and_the_live_room_stands_alone() async {
        let transport = ScriptedRoomTransport(
            before: [
                .success(page([8_990, 9_000], hasMore: true)),
                .success(page([740, 750, 760, 770], hasMore: true)),
                .success(RoomEventPage(
                    messages: [message(4_960), message(4_980), message(5_000)],
                    minSequence: 4_951,
                    nextBeforeSequence: 4_951,
                    hasMore: true
                ))
            ],
            after: [
                .success(RoomEventPage(messages: [message(780), message(790)], rawCount: 50, maxSequence: 800)),
                .success(RoomEventPage(messages: [message(5_010), message(5_020)], rawCount: 50, maxSequence: 5_050)),
                .success(RoomEventPage(messages: [message(5_060)], rawCount: 100, maxSequence: 5_150))
            ]
        )
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }
        coordinator.focus(on: 770)
        await waitUntil("first window") { messageSequences(coordinator).contains(770) && !coordinator.state.isLoadingOlder }

        coordinator.focus(on: 5_000)
        await waitUntil("second window") { messageSequences(coordinator).contains(5_000) && !coordinator.state.isLoadingOlder }
        XCTAssertEqual(messageSequences(coordinator), [4_960, 4_980, 5_000, 5_010, 5_020], "only the new window, no rows from the first")
        XCTAssertTrue(coordinator.state.canLoadNewer)

        coordinator.send(.loadNewer)
        await waitUntil("next page") { transport.snapshot().after.count == 3 && !coordinator.state.isLoadingNewer }
        XCTAssertEqual(transport.snapshot().after, [770, 5_000, 5_050], "newer pages continue from the new window's end")
        coordinator.pause()
    }

    /// Review of b3f8252: a page answered before a message the stream has since shown does not take the window live
    /// without it.
    func test_rejoining_reads_on_to_messages_the_stream_showed_while_the_page_was_on_its_way() async {
        let transport = ScriptedRoomTransport(
            before: [
                .success(page([990, 1_000], hasMore: true)),
                .success(page([740, 750, 760, 770], hasMore: true))
            ],
            after: [
                .success(RoomEventPage(messages: [message(780), message(790)], rawCount: 50, maxSequence: 800)),
                // Answered before 1,010 existed: short, and it stops at 1,000.
                .success(RoomEventPage(messages: [message(810), message(990), message(1_000)], rawCount: 30, maxSequence: 1_000)),
                .success(RoomEventPage(messages: [message(1_010)], rawCount: 1, maxSequence: 1_010))
            ]
        )
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }
        coordinator.focus(on: 770)
        await waitUntil("window") { coordinator.state.canLoadNewer && !coordinator.state.isLoadingOlder }

        coordinator.handle(.message(message(1_010)))
        coordinator.send(.loadNewer)
        await waitUntil("live again") { !coordinator.state.canLoadNewer && !coordinator.state.isLoadingNewer }
        XCTAssertEqual(transport.snapshot().after, [770, 800, 1_000], "a short page that stops before the stream's newest is read on")
        XCTAssertEqual(Array(messageSequences(coordinator).suffix(3)), [990, 1_000, 1_010])
        coordinator.pause()
    }

    /// Review of b3f8252: Jump to latest reads on from its page to messages the stream showed while it loaded.
    func test_jump_to_latest_reads_on_to_messages_the_stream_showed_meanwhile() async {
        let transport = ScriptedRoomTransport(
            before: [
                .success(page([990, 1_000], hasMore: true)),
                .success(page([760, 770], hasMore: true)),
                .success(page([990, 1_000], hasMore: true))
            ],
            after: [
                .success(RoomEventPage(messages: [message(780)], rawCount: 50, maxSequence: 820)),
                .success(RoomEventPage(messages: [message(1_010)], rawCount: 1, maxSequence: 1_010))
            ]
        )
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }
        coordinator.focus(on: 770)
        await waitUntil("window") { coordinator.state.canLoadNewer && !coordinator.state.isLoadingOlder }

        coordinator.handle(.message(message(1_010)))
        coordinator.send(.jumpToLatest)
        await waitUntil("live again") {
            !coordinator.state.canLoadNewer && !coordinator.state.isLoadingOlder && messageSequences(coordinator).contains(1_010)
        }
        XCTAssertEqual(messageSequences(coordinator), [990, 1_000, 1_010])
        XCTAssertEqual(transport.snapshot().after, [770, 1_000], "read on from where the newest page stopped")
        coordinator.pause()
    }

    func test_older_pages_over_the_capacity_keep_the_page_just_loaded() {
        var timeline = RoomTimeline(capacity: 50)
        timeline.merge((101...150).map { message($0) })
        timeline.merge((41...50).map { message($0) }, trimming: .newest)
        XCTAssertEqual(timeline.messages.first?.sequenceId, 41, "the older page stays")
        XCTAssertEqual(timeline.messages.count, 50)
        XCTAssertEqual(timeline.messages.last?.sequenceId, 140, "the newest rows go instead")
        XCTAssertTrue(timeline.hasMoreNewer, "and load again below")

        var live = RoomTimeline(capacity: 50)
        live.merge((101...150).map { message($0) })
        live.merge([message(151)])
        XCTAssertEqual(live.messages.first?.sequenceId, 102, "a live arrival lets the oldest row go")
        XCTAssertFalse(live.hasMoreNewer)
    }

    func test_a_link_that_can_never_load_falls_back_at_once() async {
        let transport = ScriptedRoomTransport(before: [.success(page([90, 100], hasMore: false))])
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }

        coordinator.focus(on: 95)
        XCTAssertNil(coordinator.state.focusSequenceId, "inside the loaded rows but not a chat row")
        coordinator.focus(on: 50)
        XCTAssertNil(coordinator.state.focusSequenceId, "before the start of the room")
        XCTAssertEqual(coordinator.state.focusFallbackCount, 2)
        XCTAssertEqual(transport.snapshot().before, [nil], "nothing more is loaded for either")

        coordinator.focus(on: 500)
        XCTAssertEqual(coordinator.state.focusSequenceId, 500, "a newer message is still on its way")
        XCTAssertEqual(coordinator.state.focusFallbackCount, 2)
        coordinator.pause()
    }

    func test_a_link_to_a_newer_event_that_is_not_a_chat_row_is_let_go_once_the_room_passes_it() async {
        let transport = ScriptedRoomTransport(before: [.success(page([90, 100], hasMore: false))])
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }

        coordinator.focus(on: 105)
        XCTAssertEqual(coordinator.state.focusSequenceId, 105, "newer than the loaded rows: it may still arrive")
        coordinator.handle(.nonDisplayable(sequenceId: 104))
        XCTAssertEqual(coordinator.state.focusSequenceId, 105, "the room has not reached it yet")
        coordinator.handle(.nonDisplayable(sequenceId: 105))
        XCTAssertNil(coordinator.state.focusSequenceId, "the room passed it without a chat row")
        XCTAssertEqual(coordinator.state.focusFallbackCount, 1)

        coordinator.focus(on: 110)
        coordinator.handle(.message(message(110)))
        XCTAssertEqual(coordinator.state.focusSequenceId, 110, "a linked message that arrives is focused by the view")
        XCTAssertEqual(coordinator.state.focusFallbackCount, 1)
        coordinator.pause()
    }
}
