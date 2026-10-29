import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class PinsTransport: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [RoomActionsPage]
    let history: [RoomMessage]

    init(history: [RoomMessage], pages: [RoomActionsPage]) {
        self.history = history
        self.pages = pages
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: beforeSequence == nil ? history : [])
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }

    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        lock.lock()
        defer { lock.unlock() }
        return pages.count > 1 ? pages.removeFirst() : (pages.first ?? RoomActionsPage())
    }
}

private final class PinRecorder: RoomActionSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [RoomActionRequest] = []

    func sendAction(_ action: RoomActionRequest) async throws {
        lock.lock()
        sent.append(action)
        lock.unlock()
    }

    func requests() -> [RoomActionRequest] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }
}

@MainActor
final class PinnedMessagesTests: XCTestCase {
    private func message(_ seq: Int64, _ text: String) -> RoomMessage {
        RoomMessage(id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: "cobalt-warden",
                    authorName: "cobalt-warden", isHuman: false, text: text, timestamp: "2026-10-28T18:00:00Z")
    }

    private func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    private func coordinator(_ transport: PinsTransport, _ actions: PinRecorder, role: String = "owner") -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            actionSender: actions,
            membershipRole: role,
            ownAuthorIds: ["human-mrrcarter"],
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            onReauthenticationRequired: {}
        )
    }

    func test_pin_requests_name_their_type_and_get_a_fresh_key_each_tap() {
        let first = RoomActionRequest.pin(true, sessionId: "room_1", sequenceId: 9, actor: "mrrCarter")
        let again = RoomActionRequest.pin(true, sessionId: "room_1", sequenceId: 9, actor: "mrrCarter")
        XCTAssertEqual(first.actionType, "pin")
        XCTAssertEqual(RoomActionRequest.pin(false, sessionId: "room_1", sequenceId: 9, actor: "mrrCarter").actionType, "unpin")
        XCTAssertTrue(first.idempotencyKey.hasPrefix("pin:room_1:9:mrrCarter:"), first.idempotencyKey)
        XCTAssertNotEqual(first.idempotencyKey, again.idempotencyKey, "pin, unpin, pin again must not collapse")
        XCTAssertNil(first.note)
    }

    func test_the_strip_shows_the_rooms_pins_and_a_pin_shows_at_once_then_takes_the_room_list() async {
        let transport = PinsTransport(
            history: [message(3, "First line of the plan\nsecond line"), message(7, "Ship it")],
            pages: [
                RoomActionsPage(pinned: [RoomPinnedMessage(id: "p1", targetSequenceId: 3, pinnedBy: "human-griff")]),
                RoomActionsPage(pinned: [
                    RoomPinnedMessage(id: "p2", targetSequenceId: 7, pinnedBy: "human-mrrcarter"),
                    RoomPinnedMessage(id: "p1", targetSequenceId: 3, pinnedBy: "human-griff")
                ])
            ]
        )
        let actions = PinRecorder()
        let room = coordinator(transport, actions)
        room.resume()
        await waitUntil("pins loaded") { !room.state.pinned.isEmpty }
        XCTAssertEqual(room.state.pinned.map(\.snippet), ["First line of the plan"], "the first line only")
        XCTAssertEqual(room.state.pinned.first?.pinnedBy, "griff")
        XCTAssertTrue(room.state.canPin)

        room.send(.setPinned(sequenceId: 7, isPinned: true))
        XCTAssertEqual(room.state.pinned.map(\.sequenceId), [7, 3], "shown at once, newest first")
        await waitUntil("pin sent and the room's list loaded") {
            actions.requests().count == 1 && room.state.pinned.first?.pinnedBy == "mrrcarter"
        }
        XCTAssertEqual(actions.requests().first?.actionType, "pin")
        XCTAssertEqual(actions.requests().first?.targetSequenceId, 7)
        room.pause()
    }

    func test_a_viewer_cannot_pin_and_a_full_room_waits_for_an_unpin() async {
        let full = (1...10).map { RoomPinnedMessage(id: "p\($0)", targetSequenceId: Int64($0), pinnedBy: "human-griff") }
        let viewerRoom = coordinator(PinsTransport(history: [message(1, "a")], pages: [RoomActionsPage()]), PinRecorder(), role: "viewer")
        XCTAssertFalse(viewerRoom.state.canPin)

        let transport = PinsTransport(history: (1...11).map { message(Int64($0), "m\($0)") }, pages: [RoomActionsPage(pinned: full)])
        let actions = PinRecorder()
        let room = coordinator(transport, actions)
        room.resume()
        await waitUntil("pins loaded") { room.state.pinned.count == 10 }
        room.send(.setPinned(sequenceId: 11, isPinned: true))
        XCTAssertEqual(room.state.pinned.count, 10, "the API holds ten pins; an eleventh is not sent")
        XCTAssertTrue(actions.requests().isEmpty)

        room.send(.setPinned(sequenceId: 4, isPinned: false))
        XCTAssertFalse(room.state.pinned.contains { $0.sequenceId == 4 }, "unpinned at once")
        await waitUntil("unpin sent") { actions.requests().count == 1 }
        XCTAssertEqual(actions.requests().first?.actionType, "unpin")
        room.pause()
    }
}
