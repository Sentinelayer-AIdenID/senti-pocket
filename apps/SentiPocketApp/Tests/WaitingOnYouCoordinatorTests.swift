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
    private let failure: RoomSendError

    init(failures: Int = 0, failure: RoomSendError = .retryable(retryAfterSeconds: nil)) {
        self.failures = failures
        self.failure = failure
    }

    var sent: [(sessionId: String, text: String, clientId: String)] { lock.withLock { _sent } }

    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        let fail: Bool = lock.withLock {
            _sent.append((sessionId, text, clientId))
            if failures > 0 { failures -= 1; return true }
            return false
        }
        if fail { throw failure }
    }
}

@MainActor
final class WaitingOnYouCoordinatorTests: XCTestCase {
    private func ask(_ id: String, room: String = "room-1", options: [String] = ["Yes", "No"], title: String? = nil,
                     question: String = "Ship it?", at: String = "2026-10-30T18:00:00Z") -> SentiWaitingItem {
        SentiWaitingItem(roomId: room, roomTitle: "Senti-expansion-proj", ticketId: id, title: title ?? "Ticket \(id)",
                         question: question, options: options, custom: true, askedAt: at,
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

    /// Warden (#270): the shared fetch reads an older server's 404 as access denied, so that is what hides the row.
    func test_an_older_server_without_the_list_leaves_it_out_of_the_side_panel() async {
        let waiting = WaitingOnYouCoordinator(
            transport: ScriptedWaiting([
                .success(SentiWaitingPage(total: 1, items: [ask("t1")])),
                .failure(SessionTransportError.accessDenied)
            ]),
            sender: RecordingSender()
        )
        await waiting.refresh()
        XCTAssertTrue(waiting.state.isAvailable, "shown once the list loads")
        await waiting.refresh()
        XCTAssertFalse(waiting.state.isAvailable, "a list the server no longer gives hides the row")

        let shown = WaitingOnYouCoordinator(
            transport: ScriptedWaiting([.success(SentiWaitingPage(total: 0, items: []))]),
            sender: RecordingSender()
        )
        await shown.refresh()
        XCTAssertTrue(shown.state.isAvailable, "an empty list is still a list")
    }

    /// Warden (#270): the signal model's name is hidden in what is shown and in what is posted.
    func test_the_model_name_is_hidden_on_screen_and_in_the_answer() async {
        let sender = RecordingSender()
        let waiting = WaitingOnYouCoordinator(
            transport: ScriptedWaiting([.success(SentiWaitingPage(total: 1, items: [
                ask("t1", title: "Route it through Jev first", question: "Use Jev 2 here?")
            ]))]),
            sender: sender
        )
        await waiting.refresh()
        XCTAssertEqual(waiting.state.rows.first?.title, "Route it through the signal layer first")
        XCTAssertEqual(waiting.state.rows.first?.question, "Use the signal layer here?")
        _ = waiting.send(.answer(id: "t1", choice: "Yes", detail: ""))
        await waitUntil("sent") { sender.sent.count == 1 }
        XCTAssertFalse(sender.sent[0].text.contains("Jev"), sender.sent[0].text)
        XCTAssertTrue(sender.sent[0].text.hasPrefix("Decision on [Ticket: Route it through the signal layer first]("))
    }

    /// Warden (#270): a ticket that asks again is a new ask, not the one already answered.
    func test_a_ticket_that_asks_again_is_shown_again() async {
        let sender = RecordingSender()
        let first = ask("t1", question: "Ship it?", at: "2026-10-30T18:00:00Z")
        let second = ask("t1", question: "Ship to everyone?", at: "2026-10-30T19:00:00Z")
        let waiting = WaitingOnYouCoordinator(
            transport: ScriptedWaiting([
                .success(SentiWaitingPage(total: 1, items: [first])),
                .success(SentiWaitingPage(total: 1, items: [second]))
            ]),
            sender: sender
        )
        await waiting.refresh()
        _ = waiting.send(.answer(id: "t1", choice: "Yes", detail: ""))
        await waitUntil("answered") { sender.sent.count == 1 && waiting.state.rows.isEmpty }
        await waiting.refresh()
        XCTAssertEqual(waiting.state.rows.map(\.question), ["Ship to everyone?"])
        _ = waiting.send(.answer(id: "t1", choice: "No", detail: ""))
        await waitUntil("the new ask is answered too") { sender.sent.count == 2 }
        XCTAssertNotEqual(sender.sent[0].clientId, sender.sent[1].clientId, "a new ask is a new message")
    }

    /// Warden (#270): a send the room refuses says so and offers no retry.
    func test_a_refused_answer_says_so_without_offering_a_retry() async {
        let waiting = WaitingOnYouCoordinator(
            transport: ScriptedWaiting([.success(SentiWaitingPage(total: 1, items: [ask("t1")]))]),
            sender: RecordingSender(failures: 1, failure: .notAllowed)
        )
        await waiting.refresh()
        _ = waiting.send(.answer(id: "t1", choice: "Yes", detail: ""))
        await waitUntil("refused") { waiting.state.notice != nil && waiting.state.sending.isEmpty }
        XCTAssertFalse(waiting.state.notice?.contains("retry") == true, waiting.state.notice ?? "")
        XCTAssertEqual(waiting.state.rows.map(\.id), ["t1"], "still waiting")
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
