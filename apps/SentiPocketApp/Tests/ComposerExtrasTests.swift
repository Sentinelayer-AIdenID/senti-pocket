import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class OneTicketTransport: RoomTicketsTransport, @unchecked Sendable {
    let ticket: RoomTicket
    init(_ ticket: RoomTicket) { self.ticket = ticket }

    func roomTicketSnapshot(sessionId: String, afterId: String?, limit: Int) async throws -> RoomTicketSnapshotPage {
        RoomTicketSnapshotPage(items: [ticket], hasMore: false, cursor: 1)
    }

    func roomTicketEvents(sessionId: String, after: Int64, limit: Int) async throws -> RoomTicketEventsPage {
        RoomTicketEventsPage(tickets: [], eventCount: 0, cursor: after)
    }
}

/// A ticket that moves to its next version on the first catch-up after the snapshot.
private final class SteppingTicketTransport: RoomTicketsTransport, @unchecked Sendable {
    let first: RoomTicket
    let next: RoomTicket
    init(_ first: RoomTicket, then next: RoomTicket) {
        self.first = first
        self.next = next
    }

    func roomTicketSnapshot(sessionId: String, afterId: String?, limit: Int) async throws -> RoomTicketSnapshotPage {
        RoomTicketSnapshotPage(items: [first], hasMore: false, cursor: 1)
    }

    func roomTicketEvents(sessionId: String, after: Int64, limit: Int) async throws -> RoomTicketEventsPage {
        after < 2
            ? RoomTicketEventsPage(tickets: [next], eventCount: 1, cursor: 2)
            : RoomTicketEventsPage(tickets: [], eventCount: 0, cursor: after)
    }
}

private final class CapturingSender: RoomMessageSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [(sessionId: String, text: String)] = []

    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        lock.lock()
        sent.append((sessionId, text))
        lock.unlock()
    }

    func messages() -> [(sessionId: String, text: String)] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }
}

/// Fails the first `failures` sends as retryable, then accepts; records every client id.
private final class FlakySender: RoomMessageSending, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: Int
    private var ids: [String] = []

    init(failures: Int) { self.failures = failures }

    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        lock.lock()
        ids.append(clientId)
        let fail = failures > 0
        if fail { failures -= 1 }
        lock.unlock()
        if fail { throw RoomSendError.retryable(retryAfterSeconds: nil) }
    }

    func clientIds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

private final class AuthorsTransport: RoomTransport, @unchecked Sendable {
    let history: [RoomMessage]
    init(_ history: [RoomMessage]) { self.history = history }
    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: beforeSequence == nil ? history : [])
    }
    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage { RoomEventPage(messages: []) }
    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }
}

@MainActor
final class ComposerExtrasTests: XCTestCase {
    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    func test_answering_a_decision_posts_the_web_line_mentioning_the_assignee() async {
        let ticket = RoomTicket(
            id: "t1",
            title: "Where should the gateway run?",
            body: "## Decision\nQuestion: Where should the gateway run?\nOptions: The Mac · The cloud · Custom",
            status: "assigned",
            assignee: "cobalt-warden",
            version: 1
        )
        let sender = CapturingSender()
        let coordinator = RoomTicketsCoordinator(
            sessionId: "room_1",
            transport: OneTicketTransport(ticket),
            sender: sender,
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            onReauthenticationRequired: {}
        )
        await coordinator.refresh()
        XCTAssertTrue(coordinator.state.canAnswerDecisions)

        coordinator.send(.answerDecision(ticketId: "t1", answer: "The cloud", detail: ""))
        await waitUntil("posted") { sender.messages().count == 1 && coordinator.state.decisionStatus["t1"] == "Answer sent to the room." }
        XCTAssertEqual(sender.messages().first?.sessionId, "room_1")
        XCTAssertEqual(
            sender.messages().first?.text,
            "Decision on [Ticket: Where should the gateway run?](/dashboard/sessions/room_1?ticket=t1): The cloud @cobalt-warden"
        )
    }

    func test_a_retried_answer_is_the_same_message_and_a_new_answer_is_not() async {
        let ticket = RoomTicket(id: "t1", title: "T", body: "## Decision\nQuestion: Go?\nOptions: Yes · No", version: 1)
        let sender = FlakySender(failures: 1)
        let coordinator = RoomTicketsCoordinator(
            sessionId: "room_1",
            transport: OneTicketTransport(ticket),
            sender: sender,
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            onReauthenticationRequired: {}
        )
        await coordinator.refresh()
        coordinator.send(.answerDecision(ticketId: "t1", answer: "Yes", detail: ""))
        await waitUntil("retry offered") { coordinator.state.retryableDecisions.contains("t1") }

        coordinator.send(.retryDecision(ticketId: "t1"))
        await waitUntil("sent") { coordinator.state.decisionStatus["t1"] == "Answer sent to the room." }
        XCTAssertEqual(sender.clientIds().count, 2)
        XCTAssertEqual(sender.clientIds()[0], sender.clientIds()[1], "a retry is the same message, so it never posts twice")
        XCTAssertFalse(coordinator.state.retryableDecisions.contains("t1"))

        coordinator.send(.answerDecision(ticketId: "t1", answer: "No", detail: ""))
        await waitUntil("new answer sent") { sender.clientIds().count == 3 }
        XCTAssertNotEqual(sender.clientIds()[2], sender.clientIds()[0], "a different answer is a new message")
    }

    func test_without_a_sender_decisions_are_read_only() async {
        let ticket = RoomTicket(id: "t1", title: "T", body: "## Decision\nQuestion: Go?\nOptions: Yes · No", version: 1)
        let coordinator = RoomTicketsCoordinator(
            sessionId: "room_1",
            transport: OneTicketTransport(ticket),
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            onReauthenticationRequired: {}
        )
        await coordinator.refresh()
        XCTAssertFalse(coordinator.state.canAnswerDecisions)
    }

    func test_the_composer_offers_everyone_who_posted_except_you() async {
        let history = [
            RoomMessage(id: "1", sequenceId: 1, kind: .message, authorId: "cobalt-warden", authorName: "cobalt-warden",
                        isHuman: false, text: "hi", timestamp: "2026-10-28T18:00:00Z"),
            // Your display name need not match your handle: you are excluded by author id.
            RoomMessage(id: "2", sequenceId: 2, kind: .message, authorId: "human-mrrcarter", authorName: "Carter Theogene",
                        isHuman: true, text: "yo", timestamp: "2026-10-28T18:01:00Z"),
            RoomMessage(id: "3", sequenceId: 3, kind: .message, authorId: "human-griff", authorName: "griff",
                        isHuman: true, text: "hey", timestamp: "2026-10-28T18:02:00Z")
        ]
        let coordinator = RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: AuthorsTransport(history),
            sender: CapturingSender(),
            ownAuthorIds: ["human-mrrcarter"],
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            onReauthenticationRequired: {}
        )
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }
        XCTAssertEqual(coordinator.state.mentionCandidates.map(\.handle), ["griff", "cobalt-warden"])
        coordinator.pause()
    }

    func test_an_answer_that_landed_is_forgotten_so_the_same_words_post_again() async {
        let ticket = RoomTicket(id: "t1", title: "T", body: "## Decision\nQuestion: Go?\nOptions: Yes · No", version: 1)
        let sender = FlakySender(failures: 0)
        let coordinator = RoomTicketsCoordinator(
            sessionId: "room_1",
            transport: OneTicketTransport(ticket),
            sender: sender,
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            onReauthenticationRequired: {}
        )
        await coordinator.refresh()
        coordinator.send(.answerDecision(ticketId: "t1", answer: "Yes", detail: ""))
        await waitUntil("first sent") { coordinator.state.decisionStatus["t1"] == "Answer sent to the room." }
        coordinator.send(.answerDecision(ticketId: "t1", answer: "Yes", detail: ""))
        await waitUntil("second sent") {
            sender.clientIds().count == 2 && coordinator.state.decisionStatus["t1"] == "Answer sent to the room."
        }
        XCTAssertNotEqual(sender.clientIds()[0], sender.clientIds()[1],
                          "the API keeps a client id forever, so a landed answer's id is never reused")
    }

    func test_the_same_words_to_a_new_version_of_the_ticket_are_a_new_message() async {
        let step1 = RoomTicket(id: "t1", title: "T", body: "## Decision\nQuestion: Step 1?\nOptions: Yes · No", version: 1)
        let step2 = RoomTicket(id: "t1", title: "T", body: "## Decision\nQuestion: Step 2?\nOptions: Yes · No", version: 2)
        let sender = FlakySender(failures: 1)
        let coordinator = RoomTicketsCoordinator(
            sessionId: "room_1",
            transport: SteppingTicketTransport(step1, then: step2),
            sender: sender,
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            onReauthenticationRequired: {}
        )
        await coordinator.refresh()
        coordinator.send(.answerDecision(ticketId: "t1", answer: "Yes", detail: ""))
        await waitUntil("first failed") { coordinator.state.retryableDecisions.contains("t1") }
        await coordinator.refresh()
        coordinator.send(.answerDecision(ticketId: "t1", answer: "Yes", detail: ""))
        await waitUntil("sent") { coordinator.state.decisionStatus["t1"] == "Answer sent to the room." }
        XCTAssertEqual(sender.clientIds().count, 2)
        XCTAssertNotEqual(sender.clientIds()[0], sender.clientIds()[1], "an answer to the next step is a new message")
    }
}
