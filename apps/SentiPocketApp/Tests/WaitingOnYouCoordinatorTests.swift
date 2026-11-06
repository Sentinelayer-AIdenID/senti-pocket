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

/// Holds one call until the test lets it go.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?

    /// The next call waits for `release()`.
    func arm() { lock.withLock { armed = true } }
    var isHolding: Bool { lock.withLock { held != nil } }

    func release() {
        let held: CheckedContinuation<Void, Never>? = lock.withLock {
            let held = self.held
            self.held = nil
            return held
        }
        held?.resume()
    }

    func pass() async {
        let wait: Bool = lock.withLock {
            defer { armed = false }
            return armed
        }
        guard wait else { return }
        await withCheckedContinuation { continuation in lock.withLock { held = continuation } }
    }
}

private final class GatedWaiting: WaitingTransport, @unchecked Sendable {
    let gate = Gate()
    private let page: SentiWaitingPage

    init(_ page: SentiWaitingPage) { self.page = page }

    func waiting(limit: Int) async throws -> SentiWaitingPage {
        await gate.pass()
        return page
    }
}

private final class GatedSender: RoomMessageSending, @unchecked Sendable {
    let gate = Gate()
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }

    /// The first send fails, after the gate; later ones go.
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        let first: Bool = lock.withLock {
            calls += 1
            return calls == 1
        }
        await gate.pass()
        if first { throw RoomSendError.retryable(retryAfterSeconds: nil) }
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

    /// Once you take care of it, it leaves the list.
    /// The check under Waiting on you's answer: without the signed-in account's consent to share with AI nothing is
    /// posted; once it agrees, the same answer goes.
    func test_an_answer_is_never_posted_without_the_ai_consent() async {
        let consent = AIConsent(account: nil)
        AIConsentAsker.shared.consent = consent
        defer { AIConsentAsker.shared.consent = nil }
        let sender = RecordingSender()
        let waiting = WaitingOnYouCoordinator(
            transport: ScriptedWaiting([
                .success(SentiWaitingPage(total: 1, items: [ask("t1")])),
                .success(SentiWaitingPage(total: 1, items: [ask("t1")]))
            ]),
            sender: sender
        )
        await waiting.refresh()
        _ = waiting.send(.answer(id: "t1", choice: "Yes", detail: ""))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(sender.sent.isEmpty, "not agreed: nothing is posted")
        XCTAssertEqual(waiting.state.rows.map(\.id), ["t1"], "and the question stays")

        consent.grant()
        _ = waiting.send(.answer(id: "t1", choice: "Yes", detail: ""))
        await waitUntil("sent") { sender.sent.count == 1 }
    }

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

    /// An answer goes out, a read starts while it is on its way, the answer fails, then the read lands: the read must
    /// not bring the answer's "sending" back or take its failure away, and the answer can be tried again (warden, #325).
    func test_a_read_landing_after_a_failed_answer_keeps_the_failure_and_allows_a_retry() async {
        let transport = GatedWaiting(SentiWaitingPage(total: 1, items: [ask("t1")]))
        let sender = GatedSender()
        let waiting = WaitingOnYouCoordinator(transport: transport, sender: sender)
        await waiting.refresh()

        sender.gate.arm()
        _ = waiting.send(.answer(id: "t1", choice: "Yes", detail: ""))
        await waitUntil("the answer is on its way") { sender.gate.isHolding }
        XCTAssertEqual(waiting.state.sending, ["t1"])

        transport.gate.arm()
        let read = Task { await waiting.refresh() }
        await waitUntil("the read is waiting on the server") { transport.gate.isHolding }

        sender.gate.release()
        await waitUntil("the answer failed") { waiting.state.sending.isEmpty && waiting.state.notice != nil }
        let failure = waiting.state.notice

        transport.gate.release()
        await read.value
        XCTAssertTrue(waiting.state.sending.isEmpty, "the read brought the failed answer's sending back")
        XCTAssertEqual(waiting.state.notice, failure, "the read took the answer's failure away")

        _ = waiting.send(.answer(id: "t1", choice: "Yes", detail: ""))
        await waitUntil("the retry was sent") { sender.count == 2 && waiting.state.sending.isEmpty }
        XCTAssertTrue(waiting.state.rows.isEmpty, "the retry went through")
    }

    /// A failed read is not a read: the side panel's next open asks again instead of waiting out 15 s from the failure
    /// (warden, #325). The good read is 20 s old when the read fails; the open comes a second later.
    func test_a_failed_read_does_not_hold_off_the_next_one() async {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var date = Date(timeIntervalSince1970: 1_793_300_000)
            var now: Date { lock.withLock { date } }
            func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
        }
        let clock = Clock()
        let transport = ScriptedWaiting([
            .success(SentiWaitingPage(total: 1, items: [ask("t1")])),
            .failure(SessionTransportError.network),
            .success(SentiWaitingPage(total: 2, items: [ask("t1"), ask("t2")]))
        ])
        let waiting = WaitingOnYouCoordinator(transport: transport, sender: RecordingSender(), now: { clock.now })
        await waiting.refresh()
        clock.advance(20)
        await waiting.refresh()
        XCTAssertEqual(waiting.state.notice, WaitingOnYouCoordinator.readFailedNotice)
        clock.advance(1)
        await waiting.refresh(ifOlderThan: 15)
        XCTAssertEqual(waiting.state.rows.map(\.id), ["t1", "t2"], "read again at once after the failure")
        XCTAssertNil(waiting.state.notice, "the good read took the failed read's line away")
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
        let firstKey = waiting.state.rows.first?.askKey
        _ = waiting.send(.answer(id: "t1", choice: "Yes", detail: ""))
        await waitUntil("answered") { sender.sent.count == 1 && waiting.state.rows.isEmpty }
        await waiting.refresh()
        XCTAssertEqual(waiting.state.rows.map(\.question), ["Ship to everyone?"])
        XCTAssertNotEqual(waiting.state.rows.first?.askKey, firstKey, "its own words, not the last ask's (warden, #271)")
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
