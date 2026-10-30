import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// A quiet room whose tail and actions are fixed.
private final class RepliesTransport: RoomTransport, @unchecked Sendable {
    let tail: RoomEventPage
    let actions: RoomActionsPage

    init(tail: RoomEventPage, actions: RoomActionsPage) {
        self.tail = tail
        self.actions = actions
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage { tail }
    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }
    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }
    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage { actions }
}

/// A room of a few messages: the first read gets the newest `newest`; any other page is cut from the whole room.
private final class FurtherBackTransport: RoomTransport, @unchecked Sendable {
    let room: [RoomMessage]
    let newest: Int
    let actions: RoomActionsPage

    init(room: [RoomMessage], newest: Int, actions: RoomActionsPage) {
        self.room = room.sorted { $0.sequenceId > $1.sequenceId }
        self.newest = newest
        self.actions = actions
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        let below = room.filter { $0.sequenceId < (beforeSequence ?? .max) }
        let page = Array(below.prefix(beforeSequence == nil ? newest : limit))
        return RoomEventPage(messages: page, hasMore: below.count > page.count)
    }
    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: Array(room.filter { $0.sequenceId > fromSequence }.reversed().prefix(limit)))
    }
    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }
    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage { actions }
}

@MainActor
final class InlineRepliesTests: XCTestCase {
    private func message(_ seq: Int64, _ time: String, author: String = "respawn-orchestrator", text: String = "cost") -> RoomMessage {
        RoomMessage(
            id: "evt-\(seq)",
            sequenceId: seq,
            kind: .message,
            authorId: author,
            authorName: author,
            isHuman: RoomMessage.isHumanAuthor(author),
            text: text,
            timestamp: "2026-10-29T\(time):00.000000+00:00"
        )
    }

    private func reply(_ id: String, to seq: Int64, _ time: String, author: String) -> RoomReply {
        RoomReply(id: id, targetSequenceId: seq, authorId: author, text: "reply \(id)", createdAt: "2026-10-29T\(time):00.000000+00:00")
    }

    private func rowIds(_ coordinator: RoomChatCoordinator) -> [String] {
        coordinator.state.rows.compactMap { row in
            if case .message(let message) = row { return message.id }
            return nil
        }
    }

    /// Carter (#54773, #54777): agents and boxes answer in threads, so the room looked nearly empty on the phone.
    func test_threaded_replies_show_in_the_room_at_their_own_time() async {
        let transport = RepliesTransport(
            tail: RoomEventPage(
                messages: [message(120, "18:20"), message(110, "18:10"), message(100, "18:00", text: "Cost line one")],
                hasMore: true
            ),
            actions: RoomActionsPage(replies: [
                reply("old", to: 50, "17:00", author: "review-agent"),
                reply("a", to: 100, "18:05", author: "review-agent"),
                reply("b", to: 110, "18:25", author: "ds-aid-tenant-registry")
            ])
        )
        let coordinator = RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            onReauthenticationRequired: {}
        )
        coordinator.resume()
        for _ in 0..<500 where !rowIds(coordinator).contains("reply-a") {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(rowIds(coordinator), ["evt-100", "reply-a", "evt-110", "evt-120", "reply-b"],
                       "replies at their own time; one from before the loaded rows stays in its thread")
        let replyRow = coordinator.state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row, message.id == "reply-a" { return message }
            return nil
        }.first
        XCTAssertEqual(replyRow?.authorName, "review-agent")
        XCTAssertEqual(replyRow?.sequenceId, 100, "it acts on its thread")
        XCTAssertEqual(replyRow?.replyContext, "respawn-orchestrator: Cost line one")
        coordinator.pause()
    }

    /// Review on #205: a reply shown in the room carries its message's sequence. When that message is further back
    /// than the loaded rows, opening the thread took the reply for the thread's message. It must load the room around
    /// the message and open the thread on it.
    func test_a_replys_thread_opens_on_its_message_even_one_further_back_than_the_loaded_rows() async {
        let transport = FurtherBackTransport(
            room: [message(50, "17:00", text: "The old plan"), message(100, "18:00"), message(110, "18:10"), message(120, "18:20")],
            newest: 3,
            actions: RoomActionsPage(replies: [reply("late", to: 50, "18:15", author: "review-agent")])
        )
        let coordinator = RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            onReauthenticationRequired: {}
        )
        coordinator.resume()
        for _ in 0..<500 where !rowIds(coordinator).contains("reply-late") {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(rowIds(coordinator), ["evt-100", "evt-110", "reply-late", "evt-120"], "its message is not loaded")

        coordinator.send(.openThread(sequenceId: 50))
        XCTAssertNotEqual(coordinator.state.thread?.parent.id, "reply-late", "a reply is never its own thread's message")
        for _ in 0..<500 where coordinator.state.thread?.parent.id != "evt-50" {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(coordinator.state.thread?.parent.id, "evt-50", "the room loads around the message and the thread opens on it")
        XCTAssertEqual(coordinator.state.thread?.parent.text, "The old plan")
        XCTAssertTrue(rowIds(coordinator).contains("reply-late"), "the reply stays in the room at its own time")
        coordinator.pause()
    }
}
