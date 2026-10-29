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
                reply("old", to: 50, "17:00", author: "claude-warden"),
                reply("a", to: 100, "18:05", author: "claude-warden"),
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
        XCTAssertEqual(replyRow?.authorName, "claude-warden")
        XCTAssertEqual(replyRow?.sequenceId, 100, "it acts on its thread")
        XCTAssertEqual(replyRow?.replyContext, "respawn-orchestrator: Cost line one")
        coordinator.pause()
    }
}
