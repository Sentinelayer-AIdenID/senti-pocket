import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// A room with scripted history, breakout pages (served in order, the last one repeating) and stream frames.
private final class BreakoutRoomTransport: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let history: [RoomMessage]
    private let pages: [RoomBreakoutsPage]
    private let frames: [RoomStreamFrame]
    private var reads = 0

    init(history: [RoomMessage], pages: [RoomBreakoutsPage], frames: [RoomStreamFrame] = []) {
        self.history = history
        self.pages = pages
        self.frames = frames
    }

    func breakoutReads() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: beforeSequence == nil ? history : [])
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> {
        let frames = self.frames
        return AsyncStream { continuation in
            let task = Task {
                try? await Task.sleep(nanoseconds: 20_000_000)
                for frame in frames { continuation.yield(.frame(frame)) }
                // Stay open like a quiet live room.
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func roomBreakouts(parentSessionId: String, cursor: String?, limit: Int) async throws -> RoomBreakoutsPage {
        lock.lock()
        defer { lock.unlock() }
        let page = pages[min(reads, pages.count - 1)]
        reads += 1
        return page
    }
}

@MainActor
final class RoomBreakoutsCoordinatorTests: XCTestCase {
    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    private func makeCoordinator(_ transport: BreakoutRoomTransport) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            onReauthenticationRequired: {}
        )
    }

    private func kinds(_ coordinator: RoomChatCoordinator) -> [RoomChatMessageInput.Kind] {
        coordinator.state.rows.compactMap { row in
            if case .message(let message) = row { return message.kind }
            return nil
        }
    }

    private static func message(_ seq: Int64, _ text: String) -> RoomMessage {
        RoomMessage(id: "m\(seq)", sequenceId: seq, kind: .message, authorId: "cobalt-warden", authorName: "cobalt-warden",
                    isHuman: false, text: text, timestamp: "2026-10-28T20:00:00Z")
    }

    private static func opened(_ seq: Int64, child: String) -> RoomMessage {
        RoomMessage(id: "b\(seq)", sequenceId: seq, kind: .breakoutOpened, authorId: "cobalt-warden",
                    authorName: "cobalt-warden", isHuman: false, text: "", timestamp: "2026-10-28T20:01:00Z",
                    breakout: RoomBreakoutEvent(childSessionId: child))
    }

    func test_opening_a_room_reads_its_breakouts_into_cards() async {
        let transport = BreakoutRoomTransport(
            history: [Self.message(1, "hi"), Self.opened(2, child: "child_1")],
            pages: [RoomBreakoutsPage(items: [RoomBreakout(
                childSessionId: "child_1",
                parentSessionId: "room_1",
                title: "Pick the storage",
                isLocked: true,
                participants: [.init(id: "cobalt-warden", isHuman: false), .init(id: "human-mrrcarter", isHuman: true)],
                messageCount: 4,
                unreadCount: 2,
                canRead: true,
                canPost: true
            )])]
        )
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("card") { coordinator.state.breakouts["child_1"] != nil }
        let card = coordinator.state.breakouts["child_1"]
        XCTAssertEqual(card?.title, "Pick the storage")
        XCTAssertEqual(card?.participantsLine, "cobalt-warden, mrrcarter", "people are named without the human- prefix")
        XCTAssertEqual(card?.messagesLine, "4 messages")
        XCTAssertEqual(card?.unreadCount, 2)
        XCTAssertEqual(card?.isLocked, true)
        XCTAssertTrue(kinds(coordinator).contains(.breakoutOpened(childSessionId: "child_1")))
        coordinator.pause()
    }

    func test_a_new_breakout_on_the_stream_is_described_at_once() async {
        let transport = BreakoutRoomTransport(
            history: [Self.message(1, "hi")],
            pages: [
                RoomBreakoutsPage(),
                RoomBreakoutsPage(items: [RoomBreakout(childSessionId: "child_2", parentSessionId: "room_1", title: "Fix the scroll")])
            ],
            frames: [.message(Self.opened(5, child: "child_2"))]
        )
        let coordinator = makeCoordinator(transport)
        coordinator.resume()
        await waitUntil("described") { coordinator.state.breakouts["child_2"]?.title == "Fix the scroll" }
        XCTAssertGreaterThanOrEqual(transport.breakoutReads(), 2, "the unknown card triggered its own read, not the next poll")
        coordinator.pause()
    }

    func test_an_outcome_names_who_acknowledged_and_who_disagreed() async {
        let outcome = RoomMessage(
            id: "o1", sequenceId: 9, kind: .breakoutOutcome, authorId: "coral-helper", authorName: "coral-helper",
            isHuman: false, text: "Use R2 for media.", timestamp: "2026-10-28T21:00:00Z",
            breakout: RoomBreakoutEvent(childSessionId: "child_1", outcome: RoomBreakoutOutcome(
                outcomeId: "out_1", revision: 1, text: "Use R2 for media.", authorId: "coral-helper",
                acknowledgements: [
                    RoomBreakoutAcknowledgement(principalId: "human-mrrcarter", isHuman: true, state: .ack),
                    RoomBreakoutAcknowledgement(principalId: "cobalt-warden", isHuman: false, state: .disagree)
                ]
            ))
        )
        let coordinator = makeCoordinator(BreakoutRoomTransport(history: [outcome], pages: [RoomBreakoutsPage()]))
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }
        guard case .breakoutOutcome(let card)? = kinds(coordinator).first else {
            return XCTFail("expected an outcome row, got \(kinds(coordinator))")
        }
        XCTAssertEqual(card.acknowledgements.map(\.name), ["mrrcarter", "cobalt-warden"])
        XCTAssertEqual(card.acknowledgementSummary, "1 of 2 acknowledged · disagreed: cobalt-warden")
        XCTAssertEqual(card.authorName, "coral-helper")
        coordinator.pause()
    }
}
