import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class ScriptedWaiting: WaitingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [Result<SentiWaitingPage, Error>]

    init(_ pages: [Result<SentiWaitingPage, Error>]) { self.pages = pages }

    func waiting(limit: Int) async throws -> SentiWaitingPage {
        let next: Result<SentiWaitingPage, Error> = lock.withLock {
            pages.count > 1 ? pages.removeFirst() : (pages.first ?? .success(SentiWaitingPage(total: 0, items: [])))
        }
        return try next.get()
    }
}

private final class RecordingSender: RoomMessageSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [(sessionId: String, text: String, clientId: String)] = []
    private var failures: Int

    init(failures: Int = 0) { self.failures = failures }

    var sent: [(sessionId: String, text: String, clientId: String)] { lock.withLock { _sent } }

    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        let fail: Bool = lock.withLock {
            _sent.append((sessionId, text, clientId))
            if failures > 0 { failures -= 1; return true }
            return false
        }
        if fail { throw RoomSendError.retryable(retryAfterSeconds: nil) }
    }
}

@MainActor
final class WaitingOnYouCoordinatorTests: XCTestCase {
    private func ask(_ id: String, room: String = "room-1", options: [String] = ["Yes", "No"]) -> SentiWaitingItem {
        SentiWaitingItem(roomId: room, roomTitle: "Senti-expansion-proj", ticketId: id, title: "Ticket \(id)",
                         question: "Ship it?", options: options, custom: true, askedAt: "2026-10-30T18:00:00Z",
                         askedBy: "claude-warden", assignee: "pocket-forge")
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    /// Carter (10-30): "if ... I take care of it, it disappears from that list".
    func test_an_answer_posts_the_webs_line_to_the_tickets_room_and_leaves_the_list_at_once() async {
        let sender = RecordingSender()
        let waiting = WaitingOnYouCoordinator(
            transport: ScriptedWaiting([
                .success(SentiWaitingPage(total: 3, items: [ask("t1"), ask("t2", room: "room-2")])),
                .success(SentiWaitingPage(total: 3, items: [ask("t1"), ask("t2", room: "room-2")])),
                .success(SentiWaitingPage(total: 2, items: [ask("t2", room: "room-2")]))
            ]),
            sender: sender
        )
        await waiting.refresh()
        XCTAssertTrue(waiting.state.isAvailable)
        XCTAssertEqual(waiting.state.total, 3)
        XCTAssertEqual(waiting.state.rows.map(\.id), ["t1", "t2"], "oldest first, as the server sends them")

        _ = waiting.send(.answer(id: "t1", choice: "Yes", detail: ""))
        await waitUntil("sent") { sender.sent.count == 1 && waiting.state.sending.isEmpty }
        XCTAssertEqual(sender.sent.first?.sessionId, "room-1")
        XCTAssertEqual(sender.sent.first?.text,
                       "Decision on [Ticket: Ticket t1](/dashboard/sessions/room-1?ticket=t1): Yes @pocket-forge")
        XCTAssertTrue(sender.sent.first?.clientId.hasPrefix("hm_") == true)
        XCTAssertEqual(waiting.state.rows.map(\.id), ["t2"], "gone at once")
        XCTAssertEqual(waiting.state.total, 2)

        await waiting.refresh()
        XCTAssertEqual(waiting.state.rows.map(\.id), ["t2"], "stays gone while the server catches up")
        await waiting.refresh()
        XCTAssertEqual(waiting.state.rows.map(\.id), ["t2"])
        XCTAssertEqual(waiting.state.total, 2)
    }

    func test_a_retry_after_a_failed_send_reuses_its_id_so_it_never_posts_twice() async {
        let sender = RecordingSender(failures: 1)
        let waiting = WaitingOnYouCoordinator(
            transport: ScriptedWaiting([.success(SentiWaitingPage(total: 1, items: [ask("t1")]))]),
            sender: sender
        )
        await waiting.refresh()
        _ = waiting.send(.answer(id: "t1", choice: "Custom", detail: "ship Monday"))
        await waitUntil("first try") { sender.sent.count == 1 && waiting.state.sending.isEmpty }
        XCTAssertNotNil(waiting.state.notice)
        XCTAssertEqual(waiting.state.rows.map(\.id), ["t1"], "still waiting after a failed send")

        _ = waiting.send(.answer(id: "t1", choice: "Custom", detail: "ship Monday"))
        await waitUntil("retried") { sender.sent.count == 2 && waiting.state.sending.isEmpty }
        XCTAssertEqual(sender.sent[0].clientId, sender.sent[1].clientId)
        XCTAssertTrue(sender.sent[1].text.hasSuffix(": Custom — ship Monday @pocket-forge"))
        XCTAssertTrue(waiting.state.rows.isEmpty)
    }

    func test_an_older_server_without_the_list_leaves_it_out_of_the_side_panel() async {
        let waiting = WaitingOnYouCoordinator(
            transport: ScriptedWaiting([.failure(SessionTransportError.service(statusCode: 404))]),
            sender: RecordingSender()
        )
        await waiting.refresh()
        XCTAssertFalse(waiting.state.isAvailable)
    }

    func test_opening_an_ask_goes_to_its_ticket_in_its_room() async {
        let waiting = WaitingOnYouCoordinator(
            transport: ScriptedWaiting([.success(SentiWaitingPage(total: 1, items: [ask("t9", room: "room-9")]))]),
            sender: RecordingSender()
        )
        await waiting.refresh()
        let link = waiting.send(.open(id: "t9"))
        XCTAssertEqual(link?.sessionId, "room-9")
        XCTAssertEqual(link?.ticketId, "t9")
    }
}
