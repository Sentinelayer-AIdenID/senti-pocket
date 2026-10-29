import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private let viewer = "6f1c2b9e-0000-4000-8000-00000000000a"
private let otherAgent = "review-agent"
/// 09:00Z on the day the fixtures' leases run to 09:15Z.
private let nineAM = ParsedSessionTimestamp("2026-10-29T09:00:00+00:00").date ?? Date()

private final class TicketsFeed: RoomTicketsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let baseline: [RoomTicket]
    private var events: [RoomTicketEventsPage]
    private(set) var eventCalls = 0

    init(_ baseline: [RoomTicket], events: [RoomTicketEventsPage] = []) {
        self.baseline = baseline
        self.events = events
    }

    func roomTicketSnapshot(sessionId: String, afterId: String?, limit: Int) async throws -> RoomTicketSnapshotPage {
        RoomTicketSnapshotPage(items: baseline, hasMore: false, cursor: 10)
    }

    func roomTicketEvents(sessionId: String, after: Int64, limit: Int) async throws -> RoomTicketEventsPage {
        lock.withLock {
            eventCalls += 1
            return events.isEmpty ? RoomTicketEventsPage(tickets: [], eventCount: 0, cursor: after) : events.removeFirst()
        }
    }

    var refreshes: Int { lock.withLock { eventCalls } }
}

private final class ScriptedTicketWriter: RoomTicketWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<RoomTicketWriteResult, RoomTicketWriteError>]
    private var sent: [(write: RoomTicketWrite, key: String)] = []

    init(_ results: [Result<RoomTicketWriteResult, RoomTicketWriteError>]) { self.results = results }

    func write(_ write: RoomTicketWrite, sessionId: String, idempotencyKey: String) async throws -> RoomTicketWriteResult {
        let next: Result<RoomTicketWriteResult, RoomTicketWriteError> = lock.withLock {
            sent.append((write, idempotencyKey))
            return results.isEmpty ? .failure(.retryable(retryAfterSeconds: nil)) : results.removeFirst()
        }
        return try next.get()
    }

    var calls: [(write: RoomTicketWrite, key: String)] { lock.withLock { sent } }
}

private final class CapturingLines: RoomMessageSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []

    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        lock.withLock { sent.append(text) }
    }

    var lines: [String] { lock.withLock { sent } }
}

private final class ScriptedExtras: RoomTicketExtrasReading, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [RoomTicketCommentsPage]
    private var directory: [Result<RoomDirectoryPage, RoomTicketExtrasError>]
    private var commentAfters: [Int64] = []

    init(pages: [RoomTicketCommentsPage] = [], directory: [Result<RoomDirectoryPage, RoomTicketExtrasError>] = []) {
        self.pages = pages
        self.directory = directory
    }

    func comments(sessionId: String, ticketId: String, after: Int64) async throws -> RoomTicketCommentsPage {
        lock.withLock {
            commentAfters.append(after)
            return pages.isEmpty ? RoomTicketCommentsPage(comments: [], cursor: after) : pages.removeFirst()
        }
    }

    func memberDirectory(sessionId: String, cursor: String?) async throws -> RoomDirectoryPage {
        let next: Result<RoomDirectoryPage, RoomTicketExtrasError> = lock.withLock {
            directory.isEmpty ? .failure(.unavailable) : directory.removeFirst()
        }
        return try next.get()
    }

    var afters: [Int64] { lock.withLock { commentAfters } }
}

private struct SignedInAsViewer: AccountIdentityProviding {
    func currentAccount() async -> SignedInAccount? { SignedInAccount(githubUsername: "mrrcarter", accountId: viewer) }
}

@MainActor
final class RoomTicketWritesTests: XCTestCase {
    private func ticket(
        _ id: String,
        version: Int64 = 1,
        status: String = "open",
        assignee: String? = nil,
        lease: RoomTicketLease? = nil
    ) -> RoomTicket {
        RoomTicket(id: id, title: "Ticket \(id)", status: status, assignee: assignee, version: version, lease: lease)
    }

    private func lease(_ holder: String, fence: Int64 = 1, until expiry: String = "2026-10-29T09:15:00+00:00") -> RoomTicketLease {
        RoomTicketLease(holder: holder, holderKind: holder == viewer ? "human" : "agent", fence: fence, expiresAt: expiry)
    }

    private func credential(fence: Int64 = 1, claimedVersion: Int64 = 2, until expiry: String = "2026-10-29T09:15:00+00:00") -> RoomTicketLeaseCredential {
        RoomTicketLeaseCredential(leaseId: "0b5c6a52-1d3e-4f70-8a9b-1c2d3e4f5a6b", fence: fence, expiresAt: expiry, claimedVersion: claimedVersion)
    }

    private func makeCoordinator(
        _ feed: TicketsFeed,
        writer: ScriptedTicketWriter,
        leases: TicketLeaseStoring = InMemoryTicketLeaseStore(),
        sender: (any RoomMessageSending)? = nil,
        roster: [String] = [],
        extras: (any RoomTicketExtrasReading)? = nil
    ) -> RoomTicketsCoordinator {
        RoomTicketsCoordinator(
            sessionId: "room_1",
            transport: feed,
            sender: sender,
            writer: writer,
            leases: leases,
            identity: SignedInAsViewer(),
            canWriteTickets: true,
            assignRoster: roster,
            extras: extras,
            now: { nineAM },
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            onReauthenticationRequired: {}
        )
    }

    func test_filing_lands_once_and_filing_the_same_fields_again_reuses_its_key() async {
        let writer = ScriptedTicketWriter([
            .failure(.retryable(retryAfterSeconds: nil)),
            .success(RoomTicketWriteResult(ticket: ticket("n1")))
        ])
        let coordinator = makeCoordinator(TicketsFeed([ticket("a")]), writer: writer)
        await coordinator.refresh()
        XCTAssertTrue(coordinator.state.canFileTickets)

        coordinator.send(.fileTicket(title: "  Ship the build  ", body: "", assignee: nil))
        await coordinator.lastWrite?.value
        XCTAssertEqual(coordinator.state.filedCount, 0)
        XCTAssertEqual(coordinator.state.ticketWriteStatus[RoomTicketsPresentationState.fileStatusKey],
                       RoomTicketWriteError.retryable(retryAfterSeconds: nil).userMessage)

        coordinator.send(.fileTicket(title: "  Ship the build  ", body: "", assignee: nil))
        await coordinator.lastWrite?.value
        XCTAssertEqual(coordinator.state.filedCount, 1)
        XCTAssertEqual(Set(coordinator.state.rows.map(\.id)), ["a", "n1"], "the filed ticket is on the board at once")

        let calls = writer.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].write, .file(title: "  Ship the build  ", body: nil, assignee: nil))
        XCTAssertEqual(calls[0].key, calls[1].key, "a first attempt that did land is replayed by the API, never filed twice")
    }

    func test_a_claim_keeps_the_lease_and_release_gives_it_back() async {
        let leases = InMemoryTicketLeaseStore()
        let claimed = RoomTicketWriteResult(
            ticket: ticket("a", version: 2, status: "working", assignee: viewer, lease: lease(viewer)),
            lease: credential(),
            replayed: false
        )
        let released = RoomTicketWriteResult(ticket: ticket("a", version: 3))
        let writer = ScriptedTicketWriter([.success(claimed), .success(released)])
        let coordinator = makeCoordinator(TicketsFeed([ticket("a")]), writer: writer, leases: leases)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.actions["a"]?.claim, .claim)

        coordinator.send(.claim(ticketId: "a"))
        await coordinator.lastWrite?.value
        XCTAssertEqual(leases.credential(sessionId: "room_1", ticketId: "a"), credential())
        XCTAssertEqual(coordinator.state.actions["a"]?.canRelease, true)
        XCTAssertEqual(coordinator.state.actions["a"]?.canEdit, true, "the live holder may edit (the API allows it)")
        XCTAssertEqual(coordinator.state.actions["a"]?.canAssign, false, "a leased ticket is not reassigned")

        coordinator.send(.release(ticketId: "a"))
        await coordinator.lastWrite?.value
        XCTAssertNil(leases.credential(sessionId: "room_1", ticketId: "a"))
        XCTAssertEqual(coordinator.state.actions["a"]?.claim, .claim)

        let calls = writer.calls.map(\.write)
        XCTAssertEqual(calls, [
            .claim(ticketId: "a", expectedVersion: 1),
            .release(ticketId: "a", lease: credential(), expectedVersion: 2)
        ])
    }

    func test_a_lapsed_lease_is_dropped_and_never_offered_for_release() async {
        let leases = InMemoryTicketLeaseStore()
        leases.save(credential(until: "2026-10-29T08:50:00+00:00"), sessionId: "room_1", ticketId: "a")
        let feed = TicketsFeed([ticket("a", version: 2, status: "working", assignee: viewer,
                                      lease: lease(viewer, until: "2026-10-29T08:50:00+00:00"))])
        let coordinator = makeCoordinator(feed, writer: ScriptedTicketWriter([]), leases: leases)
        await coordinator.refresh()
        XCTAssertNil(leases.credential(sessionId: "room_1", ticketId: "a"), "no renew, so a lapsed lease is forgotten")
        XCTAssertEqual(coordinator.state.actions["a"]?.canRelease, false)
        XCTAssertEqual(coordinator.state.actions["a"]?.claim, .takeOver)
        XCTAssertEqual(coordinator.state.actions["a"]?.canEdit, false, "an expired lease still protects the text")
    }

    func test_a_stale_lease_on_release_drops_the_credential_and_refreshes() async {
        let leases = InMemoryTicketLeaseStore()
        leases.save(credential(), sessionId: "room_1", ticketId: "a")
        let feed = TicketsFeed([ticket("a", version: 2, status: "working", assignee: viewer, lease: lease(viewer))])
        let writer = ScriptedTicketWriter([.failure(.conflict(code: "STALE_LEASE"))])
        let coordinator = makeCoordinator(feed, writer: writer, leases: leases)
        await coordinator.refresh()
        let before = feed.refreshes

        coordinator.send(.release(ticketId: "a"))
        await coordinator.lastWrite?.value
        XCTAssertNil(leases.credential(sessionId: "room_1", ticketId: "a"))
        XCTAssertEqual(coordinator.state.ticketWriteStatus["a"], "Your lease on this ticket ended or was taken over.")
        XCTAssertGreaterThan(feed.refreshes, before, "the board is read again at once")
    }

    func test_editing_a_ticket_someone_else_leased_meanwhile_gets_the_409_and_refreshes() async {
        // Unleased when the edit began; an agent claimed it before the save reached the API.
        let feed = TicketsFeed(
            [ticket("a")],
            events: [RoomTicketEventsPage(
                tickets: [ticket("a", version: 2, status: "working", assignee: otherAgent, lease: lease(otherAgent))],
                cursor: 11
            )]
        )
        let writer = ScriptedTicketWriter([.failure(.conflict(code: "TICKET_CONFLICT"))])
        let coordinator = makeCoordinator(feed, writer: writer)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.actions["a"]?.canEdit, true)

        coordinator.send(.edit(ticketId: "a", title: "Ship it", body: ""))
        await coordinator.lastWrite?.value
        XCTAssertEqual(writer.calls.map(\.write), [.edit(ticketId: "a", title: "Ship it", body: nil, expectedVersion: 1)],
                       "only the changed field is sent, with the version the edit began from")
        XCTAssertEqual(coordinator.state.ticketWriteStatus["a"], RoomTicketWriteError.conflict(code: "TICKET_CONFLICT").userMessage)
        XCTAssertEqual(coordinator.state.rows.first?.lease?.holder, otherAgent, "the refresh shows who holds it now")
        XCTAssertNotEqual(coordinator.state.actions["a"]?.canEdit, true, "a ticket leased by someone else offers no Edit")
    }

    func test_assigning_posts_the_line_the_web_posts_and_unassign_sends_an_empty_assignee() async {
        let lines = CapturingLines()
        let writer = ScriptedTicketWriter([
            .success(RoomTicketWriteResult(ticket: ticket("a", version: 2, status: "assigned", assignee: "cobalt-warden"))),
            .success(RoomTicketWriteResult(ticket: ticket("a", version: 3)))
        ])
        let coordinator = makeCoordinator(TicketsFeed([ticket("a")]), writer: writer, sender: lines, roster: ["Cobalt-Warden", "human-x"])
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.assignChoices.map(\.label), ["Me (mrrcarter)", "@cobalt-warden"],
                       "you first, then the room's agents; never a person by user id or sender")

        coordinator.send(.assign(ticketId: "a", assignee: "cobalt-warden"))
        await coordinator.lastWrite?.value
        coordinator.send(.assign(ticketId: "a", assignee: nil))
        await coordinator.lastWrite?.value

        XCTAssertEqual(writer.calls.map(\.write), [
            .assign(ticketId: "a", assignee: "cobalt-warden", expectedVersion: 1),
            .assign(ticketId: "a", assignee: "", expectedVersion: 2)
        ])
        XCTAssertEqual(lines.lines, [
            "Assigned [Ticket: Ticket a](/dashboard/sessions/room_1?ticket=a) to @cobalt-warden",
            "Unassigned [Ticket: Ticket a](/dashboard/sessions/room_1?ticket=a)"
        ])
    }

    // MARK: - The HTTP writer

    private let base = URL(string: "https://api.example.test")

    func test_requests_carry_the_bearer_the_key_and_only_the_api_fields() throws {
        let claim = try HTTPRoomTicketWriter.request(
            for: .claim(ticketId: "a", expectedVersion: 4), sessionId: "room_1", idempotencyKey: "tk_1",
            apiBaseURL: base, token: "secret-token"
        )
        XCTAssertEqual(claim.httpMethod, "POST")
        XCTAssertEqual(claim.url?.path, "/api/v1/sessions/room_1/tickets/a/claim")
        XCTAssertEqual(claim.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(claim.value(forHTTPHeaderField: "Idempotency-Key"), "tk_1")
        XCTAssertEqual(String(data: claim.httpBody ?? Data(), encoding: .utf8), #"{"expectedVersion":4}"#)

        let file = try HTTPRoomTicketWriter.request(
            for: .file(title: " Ship ", body: nil, assignee: nil), sessionId: "room_1", idempotencyKey: "tk_2",
            apiBaseURL: base, token: "t"
        )
        XCTAssertEqual(file.url?.path, "/api/v1/sessions/room_1/tickets")
        XCTAssertEqual(String(data: file.httpBody ?? Data(), encoding: .utf8), #"{"assignee":null,"body":null,"title":"Ship"}"#)

        let unassign = try HTTPRoomTicketWriter.request(
            for: .assign(ticketId: "a", assignee: "", expectedVersion: 3), sessionId: "room_1", idempotencyKey: "tk_3",
            apiBaseURL: base, token: "t"
        )
        XCTAssertEqual(unassign.httpMethod, "PATCH")
        XCTAssertEqual(String(data: unassign.httpBody ?? Data(), encoding: .utf8), #"{"assignee":"","expectedVersion":3}"#)

        let release = try HTTPRoomTicketWriter.request(
            for: .release(ticketId: "a", lease: credential(), expectedVersion: 2), sessionId: "room_1",
            idempotencyKey: "tk_4", apiBaseURL: base, token: "t"
        )
        XCTAssertEqual(release.url?.path, "/api/v1/sessions/room_1/tickets/a/lease/release")
        XCTAssertEqual(String(data: release.httpBody ?? Data(), encoding: .utf8),
                       #"{"expectedVersion":2,"fence":1,"leaseId":"0b5c6a52-1d3e-4f70-8a9b-1c2d3e4f5a6b"}"#)
    }

    func test_requests_the_api_would_refuse_are_never_sent() {
        let refused: [(RoomTicketWrite, String)] = [
            (.file(title: "   ", body: nil, assignee: nil), "tk"),
            (.file(title: String(repeating: "x", count: 201), body: nil, assignee: nil), "tk"),
            (.edit(ticketId: "a", title: nil, body: nil, expectedVersion: 1), "tk"),
            (.release(ticketId: "a", lease: RoomTicketLeaseCredential(leaseId: "not-a-uuid", fence: 1, expiresAt: nil, claimedVersion: 1),
                      expectedVersion: 1), "tk"),
            (.claim(ticketId: "a", expectedVersion: 1), ""),
            (.claim(ticketId: "a", expectedVersion: 1), String(repeating: "k", count: 129))
        ]
        for (write, key) in refused {
            XCTAssertThrowsError(try HTTPRoomTicketWriter.request(
                for: write, sessionId: "room_1", idempotencyKey: key, apiBaseURL: base, token: "t"
            )) { error in
                XCTAssertEqual(error as? RoomTicketWriteError, .rejected, "\(write)")
            }
        }
        XCTAssertThrowsError(try HTTPRoomTicketWriter.request(
            for: .claim(ticketId: "a", expectedVersion: 1), sessionId: "room_1", idempotencyKey: "tk", apiBaseURL: base, token: nil
        )) { error in
            XCTAssertEqual(error as? RoomTicketWriteError, .reauthenticationRequired)
        }
    }

    func test_errors_map_by_status_and_the_apis_code_in_either_shape() throws {
        let wrapped = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"detail":{"error":{"code":"STALE_LEASE"}}}"#.utf8))
        let bare = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"error":{"code":"TICKET_NOT_FOUND"}}"#.utf8))
        XCTAssertEqual(HTTPRoomTicketWriter.errorCode(wrapped), "STALE_LEASE")
        XCTAssertEqual(HTTPRoomTicketWriter.errorCode(bare), "TICKET_NOT_FOUND")

        XCTAssertEqual(HTTPRoomTicketWriter.error(status: 409, code: "STALE_LEASE", retryAfter: nil), .conflict(code: "STALE_LEASE"))
        XCTAssertEqual(HTTPRoomTicketWriter.error(status: 409, code: nil, retryAfter: nil), .conflict(code: "TICKET_CONFLICT"))
        XCTAssertEqual(HTTPRoomTicketWriter.error(status: 404, code: "TICKET_NOT_FOUND", retryAfter: nil), .notFound)
        XCTAssertEqual(HTTPRoomTicketWriter.error(status: 404, code: nil, retryAfter: nil), .notAllowed)
        XCTAssertEqual(HTTPRoomTicketWriter.error(status: 403, code: nil, retryAfter: nil), .notAllowed)
        XCTAssertEqual(HTTPRoomTicketWriter.error(status: 401, code: nil, retryAfter: nil), .reauthenticationRequired)
        XCTAssertEqual(HTTPRoomTicketWriter.error(status: 503, code: "TICKET_WRITES_PAUSED", retryAfter: 30), .retryable(retryAfterSeconds: 30))
        XCTAssertEqual(HTTPRoomTicketWriter.error(status: 422, code: nil, retryAfter: nil), .rejected)
    }

    func test_results_read_the_ticket_the_lease_and_a_replay() throws {
        let claim = RoomTicketWriteResult(json: try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"ticket":{"id":"a","title":"A","status":"working","version":2,"assignee":"\(viewer)",
                   "lease":{"holderKind":"human","holder":"\(viewer)","fence":1,"expiresAt":"2026-10-29T09:15:00+00:00","live":true}},
         "version":2,"cursor":12,
         "lease":{"leaseId":"0b5c6a52-1d3e-4f70-8a9b-1c2d3e4f5a6b","fence":1,"expiresAt":"2026-10-29T09:15:00+00:00"}}
        """.utf8)))
        XCTAssertEqual(claim.ticket?.status, "working")
        XCTAssertEqual(claim.lease, credential())
        XCTAssertFalse(claim.replayed)

        let replay = RoomTicketWriteResult(json: try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":"n1","title":"Ship","status":"open","version":1,"replayed":true}
        """.utf8)))
        XCTAssertEqual(replay.ticket?.id, "n1")
        XCTAssertTrue(replay.replayed)
        XCTAssertNil(replay.lease)
    }

    // MARK: - Comments and people

    private let priya = "1d2e3f40-0000-4000-8000-00000000000b"

    func test_comments_page_in_order_and_a_retried_comment_reuses_its_key_and_lands_once() async {
        let extras = ScriptedExtras(pages: [
            RoomTicketCommentsPage(comments: [RoomTicketComment(id: "c1", body: "First", actorId: priya, cursor: 5)], cursor: 5, hasMore: true),
            RoomTicketCommentsPage(comments: [RoomTicketComment(id: "c2", body: "Second", actorId: otherAgent, actorKind: "agent", cursor: 9)], cursor: 9)
        ])
        let posted = RoomTicketWriteResult(
            ticket: ticket("a", version: 2),
            comment: RoomTicketComment(id: "c3", body: "Looks good", actorId: viewer, cursor: 12)
        )
        let writer = ScriptedTicketWriter([.failure(.retryable(retryAfterSeconds: nil)), .success(posted)])
        let coordinator = makeCoordinator(TicketsFeed([ticket("a")]), writer: writer, extras: extras)
        await coordinator.refresh()

        await coordinator.loadComments("a")
        XCTAssertEqual(coordinator.state.comments["a"]?.map(\.id), ["c1", "c2"])
        XCTAssertEqual(extras.afters, [0, 5], "the second page reads on from the first page's cursor")

        coordinator.send(.comment(ticketId: "a", body: "Looks good"))
        await coordinator.lastComment?.value
        XCTAssertTrue(coordinator.state.retryableComments.contains("a"))
        XCTAssertEqual(coordinator.state.comments["a"]?.count, 2, "nothing is shown until the ticket has it")

        coordinator.send(.retryComment(ticketId: "a"))
        await coordinator.lastComment?.value
        XCTAssertEqual(coordinator.state.commentStatus["a"], RoomTicketsPresentationState.commentPostedStatus)
        XCTAssertEqual(coordinator.state.comments["a"]?.map(\.id), ["c1", "c2", "c3"])
        let calls = writer.calls
        XCTAssertEqual(calls.map(\.write), [.comment(ticketId: "a", body: "Looks good"), .comment(ticketId: "a", body: "Looks good")])
        XCTAssertEqual(calls[0].key, calls[1].key, "a comment that did land the first time is replayed, never posted twice")
    }

    func test_the_directory_names_people_and_offers_them_to_assign_after_a_membership_change() async {
        let extras = ScriptedExtras(directory: [
            .failure(.directoryChanged),
            .success(RoomDirectoryPage(members: [
                RoomDirectoryMember(userId: viewer, displayName: "Carter", githubLogin: "mrrcarter"),
                RoomDirectoryMember(userId: priya, displayName: "Priya", githubLogin: "priya-dev")
            ]))
        ])
        let feed = TicketsFeed([ticket("a", status: "assigned", assignee: priya)])
        let coordinator = makeCoordinator(feed, writer: ScriptedTicketWriter([]), roster: ["build-agent"], extras: extras)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.assignChoices.map(\.label), ["Me (mrrcarter)", "Priya (@priya-dev)", "@build-agent"],
                       "you, then people by user id, then the room's agents")
        XCTAssertEqual(coordinator.state.assignChoices[1].id, priya)
        XCTAssertEqual(coordinator.state.personNames[priya], "Priya")
    }

    func test_without_the_directory_assign_offers_you_and_the_agents_only() async {
        let extras = ScriptedExtras(directory: [.failure(.unavailable)])
        let coordinator = makeCoordinator(TicketsFeed([ticket("a")]), writer: ScriptedTicketWriter([]), roster: ["build-agent"], extras: extras)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.assignChoices.map(\.label), ["Me (mrrcarter)", "@build-agent"])
        XCTAssertTrue(coordinator.state.personNames.isEmpty)
    }

    func test_a_comment_request_carries_only_its_body_and_kind() throws {
        let request = try HTTPRoomTicketWriter.request(
            for: .comment(ticketId: "a", body: "Looks good"), sessionId: "room_1", idempotencyKey: "tk_5",
            apiBaseURL: base, token: "t"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/sessions/room_1/tickets/a/comments")
        XCTAssertEqual(String(data: request.httpBody ?? Data(), encoding: .utf8), #"{"body":"Looks good","kind":"comment"}"#)
        for body in ["   ", String(repeating: "x", count: 4_001)] {
            XCTAssertThrowsError(try HTTPRoomTicketWriter.request(
                for: .comment(ticketId: "a", body: body), sessionId: "room_1", idempotencyKey: "tk", apiBaseURL: base, token: "t"
            ))
        }
    }
}
