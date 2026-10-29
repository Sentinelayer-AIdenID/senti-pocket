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
        try locked {
            beforeCalls.append(beforeSequence)
            return beforePages.isEmpty ? RoomEventPage(messages: []) : try beforePages.removeFirst().get()
        }
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
        onReauth: @escaping @MainActor () -> Void = {}
    ) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
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
