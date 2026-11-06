import Foundation
import PocketSyncClient
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// The made-up server for the client tests: one scripted answer, and every request it was asked.
private final class DeletionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    /// nil answers as a dropped connection.
    private static var answer: (status: Int, body: Data)?
    private static var captured: [URLRequest] = []

    static func reset(status: Int, body: String = "") {
        lock.lock()
        answer = (status, Data(body.utf8))
        captured = []
        lock.unlock()
    }

    static func resetUnreachable() {
        lock.lock()
        answer = nil
        captured = []
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(request)
        let answer = Self.answer
        Self.lock.unlock()
        guard let answer else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DeletionURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func iso(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

/// The bodies exactly as the Senti API sends them (sentinelayer-api origin/main 4269755): the status route's own
/// shape, and every refusal in the app-wide error envelope (`{"error": {...}}`, not FastAPI's bare `detail`).
private enum Wire {
    static let none = #"{"status":"none","requested_at":null,"delete_after":null}"#
    static let pending = #"{"status":"pending","requested_at":"2026-11-06T06:12:34.567890+00:00","delete_after":"2026-11-13T06:12:34.567890+00:00"}"#
    static let pendingTwoDays = #"{"status":"pending","requested_at":"2026-11-06T06:12:34.567890+00:00","delete_after":"2026-11-08T06:12:34.567890+00:00","grace_days":2}"#
    static let notFound = #"{"error":{"code":"HTTP_ERROR","message":"Not found","details":null,"request_id":"req-1"}}"#
    static let revoked = #"{"error":{"code":"HTTP_ERROR","message":"Session revoked; sign in again","details":null,"request_id":"req-1"}}"#
    static let notASession = #"{"error":{"code":"HTTP_ERROR","message":"Account deletion requires a signed-in user session","details":null,"request_id":"req-1"}}"#
    static let limited = #"{"error":{"code":"RATE_LIMITED","message":"Too many account deletion requests","request_id":"req-1"}}"#
    static let ended = #"{"error":{"code":"HTTP_ERROR","message":"Deletion grace period has ended","details":null,"request_id":"req-1"}}"#
    static let pendingRefusal = #"{"error":{"code":"ACCOUNT_DELETION_PENDING","message":"Account is pending deletion","request_id":"req-1"}}"#
}

/// The account-deletion routes: GET and POST /me/account/deletion and POST .../cancel, as yourself.
final class AccountDeletionClientTests: XCTestCase {
    private func client(token: String? = "test-bearer-token") -> HTTPAccountDeletionClient {
        HTTPAccountDeletionClient(apiBaseURL: URL(string: "https://api.example.invalid"),
                                  urlSession: stubbedSession(),
                                  tokenProvider: { token })
    }

    private func expect(_ expected: AccountDeletionError, file: StaticString = #filePath, line: UInt = #line,
                        _ call: () async throws -> Void) async {
        do {
            try await call()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AccountDeletionError, expected, file: file, line: line)
        }
    }

    func test_status_is_a_get_of_the_deletion_route_with_your_bearer() async throws {
        DeletionURLProtocol.reset(status: 200, body: Wire.none)
        let status = try await client().status()
        XCTAssertEqual(status, AccountDeletionStatus(isPending: false, requestedAt: nil, deleteAfter: nil))
        XCTAssertNil(status.graceDays, "the server sent no grace_days, so there is no number of days")
        let request = try XCTUnwrap(DeletionURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/v1/me/account/deletion")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer-token")
    }

    func test_a_pending_status_reads_both_dates_as_the_server_writes_them() async throws {
        DeletionURLProtocol.reset(status: 200, body: Wire.pending)
        let status = try await client().status()
        XCTAssertTrue(status.isPending)
        XCTAssertEqual(try XCTUnwrap(status.requestedAt).timeIntervalSince1970,
                       iso("2026-11-06T06:12:34Z").timeIntervalSince1970 + 0.56789, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(status.deleteAfter).timeIntervalSince1970,
                       iso("2026-11-13T06:12:34Z").timeIntervalSince1970 + 0.56789, accuracy: 0.001)
    }

    func test_grace_days_is_read_only_as_a_whole_number_of_days_the_server_allows() async throws {
        let cases: [(value: String, days: Int?)] = [
            ("7", 7), ("1", 1), ("365", 365),
            ("0", nil), ("366", nil), ("-1", nil), ("2.5", nil), (#""7""#, nil), ("true", nil), ("null", nil)
        ]
        for (value, days) in cases {
            DeletionURLProtocol.reset(status: 200, body: """
            {"status":"none","requested_at":null,"delete_after":null,"grace_days":\(value)}
            """)
            let status = try await client().status()
            XCTAssertEqual(status.graceDays, days, "grace_days \(value)")
        }
    }

    func test_a_404_means_this_server_does_not_offer_deletion() async {
        DeletionURLProtocol.reset(status: 404, body: Wire.notFound)
        await expect(.notOffered) { _ = try await self.client().status() }
        await expect(.notOffered) { _ = try await self.client().requestDeletion() }
        await expect(.notOffered) { try await self.client().cancelDeletion() }
    }

    func test_a_status_of_any_other_shape_is_a_failure() async {
        for body in [#"{"status":"deleted"}"#, #"{"state":"none"}"#, "not json", ""] {
            DeletionURLProtocol.reset(status: 200, body: body)
            await expect(.failed) { _ = try await self.client().status() }
        }
    }

    func test_a_request_is_a_post_and_only_a_202_means_scheduled() async throws {
        DeletionURLProtocol.reset(status: 202, body: Wire.pendingTwoDays)
        let status = try await client().requestDeletion()
        XCTAssertTrue(status.isPending)
        XCTAssertEqual(status.graceDays, 2)
        XCTAssertEqual(try XCTUnwrap(status.deleteAfter).timeIntervalSince1970,
                       iso("2026-11-08T06:12:34Z").timeIntervalSince1970 + 0.56789, accuracy: 0.001)
        let request = try XCTUnwrap(DeletionURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/me/account/deletion")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer-token")

        for other in [200, 204, 403, 409, 500, 502] {
            DeletionURLProtocol.reset(status: other, body: Wire.pending)
            await expect(.failed) { _ = try await self.client().requestDeletion() }
        }
    }

    func test_an_accepted_request_whose_body_cannot_be_read_is_still_scheduled() async throws {
        DeletionURLProtocol.reset(status: 202, body: "")
        let status = try await client().requestDeletion()
        XCTAssertEqual(status, AccountDeletionStatus(isPending: true, requestedAt: nil, deleteAfter: nil))
    }

    func test_cancel_posts_to_its_route_and_a_409_means_the_deadline_passed() async throws {
        DeletionURLProtocol.reset(status: 200, body: Wire.none)
        try await client().cancelDeletion()
        let request = try XCTUnwrap(DeletionURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/me/account/deletion/cancel")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer-token")

        DeletionURLProtocol.reset(status: 409, body: Wire.ended)
        await expect(.deadlinePassed) { try await self.client().cancelDeletion() }
        DeletionURLProtocol.reset(status: 500)
        await expect(.failed) { try await self.client().cancelDeletion() }
    }

    func test_each_refusal_is_read_from_its_status_and_never_from_its_words() async {
        DeletionURLProtocol.reset(status: 401, body: Wire.revoked)
        await expect(.signedOut) { _ = try await self.client().requestDeletion() }
        DeletionURLProtocol.reset(status: 429, body: Wire.limited)
        await expect(.rateLimited) { _ = try await self.client().status() }
        await expect(.rateLimited) { _ = try await self.client().requestDeletion() }
        await expect(.rateLimited) { try await self.client().cancelDeletion() }
        DeletionURLProtocol.reset(status: 403, body: Wire.notASession)
        await expect(.failed) { _ = try await self.client().status() }
        await expect(.failed) { _ = try await self.client().requestDeletion() }
    }

    func test_a_refused_token_is_signed_out_and_no_token_sends_nothing() async {
        DeletionURLProtocol.reset(status: 401, body: Wire.revoked)
        await expect(.signedOut) { _ = try await self.client().status() }
        DeletionURLProtocol.reset(status: 200, body: Wire.none)
        await expect(.signedOut) { _ = try await self.client(token: nil).requestDeletion() }
        await expect(.signedOut) { _ = try await self.client(token: "").status() }
        XCTAssertTrue(DeletionURLProtocol.requests().isEmpty)
    }

    func test_a_dropped_connection_is_unreachable() async {
        DeletionURLProtocol.resetUnreachable()
        await expect(.unreachable) { _ = try await self.client().requestDeletion() }
        await expect(.unreachable) { try await self.client().cancelDeletion() }
    }

    func test_the_deletion_routes_keep_no_cache_and_no_cookies() {
        let client = HTTPAccountDeletionClient(apiBaseURL: URL(string: "https://api.example.invalid"))
        XCTAssertTrue(client.urlSession === SentiHTTPTransportPolicy.protectedReadSession)
        XCTAssertNil(client.urlSession.configuration.urlCache)
        XCTAssertNil(client.urlSession.configuration.httpCookieStorage)
    }
}

/// Holds calls until the test lets them answer.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let continuations = waiting
        waiting = []
        lock.unlock()
        continuations.forEach { $0.resume() }
    }
}

/// What happened, in order, across the client and the call-ring steps.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func note(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

private struct RevokeFailure: Error {}

private final class ScriptedDeletionClient: AccountDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private var statusAnswers: [Result<AccountDeletionStatus, AccountDeletionError>]
    private let requestAnswer: Result<AccountDeletionStatus, AccountDeletionError>
    private let cancelAnswer: Result<Void, AccountDeletionError>
    private let requestGate: Gate?
    private let log: EventLog?
    private var counts: [String: Int] = [:]

    init(status: [Result<AccountDeletionStatus, AccountDeletionError>] = [.success(.unrequested)],
         request: Result<AccountDeletionStatus, AccountDeletionError> = .success(.scheduled),
         cancel: Result<Void, AccountDeletionError> = .success(()),
         requestGate: Gate? = nil,
         log: EventLog? = nil) {
        statusAnswers = status
        requestAnswer = request
        cancelAnswer = cancel
        self.requestGate = requestGate
        self.log = log
    }

    func count(_ call: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[call, default: 0]
    }

    private func note(_ call: String) {
        lock.lock()
        counts[call, default: 0] += 1
        lock.unlock()
    }

    func status() async throws -> AccountDeletionStatus {
        note("status")
        let answer: Result<AccountDeletionStatus, AccountDeletionError> = lock.withLock {
            statusAnswers.count > 1 ? statusAnswers.removeFirst() : statusAnswers[0]
        }
        return try answer.get()
    }

    func requestDeletion() async throws -> AccountDeletionStatus {
        note("request")
        log?.note("post")
        await requestGate?.wait()
        return try requestAnswer.get()
    }

    func cancelDeletion() async throws {
        note("cancel")
        log?.note("cancel")
        try cancelAnswer.get()
    }
}

private extension AccountDeletionStatus {
    static let due = iso("2026-11-09T15:04:05Z")
    static let unrequested = AccountDeletionStatus(isPending: false, requestedAt: nil, deleteAfter: nil)
    static let scheduled = AccountDeletionStatus(isPending: true, requestedAt: iso("2026-11-02T15:04:05Z"),
                                                 deleteAfter: due)
}

@MainActor
private final class Calls {
    var count = 0
}

/// Waits, up to a second, for work already started to land.
@MainActor
private func settle(for ticks: Int = 500, _ until: () -> Bool = { false }) async {
    for _ in 0..<ticks {
        if until() { return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// Both yeses, as the screen gives them: "Delete my account", then the confirmation's own button.
@MainActor
private func deleteAccount(_ coordinator: AccountDeletionCoordinator, signOut: @escaping @MainActor () -> Void) async {
    coordinator.askToDelete()
    await coordinator.confirmDeletion(signOut: signOut)?.value
}

/// Deleting your account from the app (App Review 5.1.1(v)): the Settings row, the two yeses, the request, the
/// pending notice and Keep my account.
@MainActor
final class AccountDeletionCoordinatorTests: XCTestCase {
    func test_the_row_shows_before_and_after_the_server_answers_200() async {
        let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(status: [.success(.unrequested)]))
        XCTAssertTrue(coordinator.isOffered, "the way to delete an account is there before the server answers")
        await coordinator.start().value
        XCTAssertTrue(coordinator.isOffered)
        XCTAssertNil(coordinator.pending)
    }

    func test_only_the_servers_404_hides_the_row() async {
        for failure in [AccountDeletionError.unreachable, .signedOut, .failed, .rateLimited] {
            let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(status: [.failure(failure)]))
            await coordinator.start().value
            XCTAssertTrue(coordinator.isOffered, "\(failure) hid the row")
            XCTAssertNil(coordinator.pending)
        }
        let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(status: [.failure(.notOffered)]))
        await coordinator.start().value
        XCTAssertFalse(coordinator.isOffered, "a server that does not offer deletion still shows the row")
    }

    func test_a_shown_row_hides_on_a_later_404_and_comes_back_on_a_200() async {
        let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(
            status: [.success(.unrequested), .failure(.notOffered), .failure(.unreachable), .success(.unrequested)]))
        await coordinator.start().value
        XCTAssertTrue(coordinator.isOffered)
        await coordinator.refresh().value
        XCTAssertFalse(coordinator.isOffered)
        await coordinator.refresh().value
        XCTAssertFalse(coordinator.isOffered, "a failure says nothing new about whether deletion is offered")
        await coordinator.refresh().value
        XCTAssertTrue(coordinator.isOffered)
    }

    func test_the_number_of_days_is_the_servers_and_only_when_it_says() async {
        let withDays = AccountDeletionStatus(isPending: false, requestedAt: nil, deleteAfter: nil, graceDays: 7)
        let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(
            status: [.success(withDays), .success(.unrequested)]))
        await coordinator.start().value
        XCTAssertEqual(coordinator.graceDays, 7)
        await coordinator.refresh().value
        XCTAssertNil(coordinator.graceDays, "no grace_days, no number of days")
    }

    func test_the_first_yes_only_asks() async {
        let client = ScriptedDeletionClient()
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value

        coordinator.askToDelete()
        await settle(for: 50) { client.count("request") > 0 }
        XCTAssertEqual(coordinator.request, .confirming)
        XCTAssertEqual(client.count("request"), 0, "Delete my account sent the request without the confirmation")
    }

    func test_nothing_is_sent_without_the_confirmations_own_yes() async {
        let client = ScriptedDeletionClient()
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value
        let signOuts = Calls()

        XCTAssertNil(coordinator.confirmDeletion(signOut: { signOuts.count += 1 }), "a yes nobody was asked for")
        coordinator.askToDelete()
        coordinator.dismissConfirmation()
        XCTAssertEqual(coordinator.request, .idle)
        XCTAssertNil(coordinator.confirmDeletion(signOut: { signOuts.count += 1 }), "a yes after Cancel")
        await settle(for: 50) { client.count("request") > 0 }
        XCTAssertEqual(client.count("request"), 0)
        XCTAssertEqual(signOuts.count, 0)
    }

    func test_the_confirmations_yes_sends_once() async {
        let gate = Gate()
        let client = ScriptedDeletionClient(requestGate: gate)
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value
        let signOuts = Calls()

        coordinator.askToDelete()
        let first = coordinator.confirmDeletion(signOut: { signOuts.count += 1 })
        XCTAssertNotNil(first)
        XCTAssertEqual(coordinator.request, .sending)
        coordinator.askToDelete()
        XCTAssertNil(coordinator.confirmDeletion(signOut: { signOuts.count += 1 }), "a second yes while it is sent")
        XCTAssertEqual(coordinator.request, .sending)
        gate.open()
        await first?.value
        XCTAssertEqual(client.count("request"), 1)
        XCTAssertEqual(signOuts.count, 1)
    }

    func test_sign_out_happens_only_after_the_server_answers_202() async {
        let gate = Gate()
        let client = ScriptedDeletionClient(requestGate: gate)
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value
        let signOuts = Calls()

        let request = Task { await deleteAccount(coordinator, signOut: { signOuts.count += 1 }) }
        await settle { client.count("request") == 1 }
        XCTAssertEqual(client.count("request"), 1)
        XCTAssertEqual(coordinator.request, .sending)
        XCTAssertEqual(signOuts.count, 0, "nothing signs out while the request is on its way")
        XCTAssertNil(coordinator.scheduled)

        gate.open()
        await request.value
        XCTAssertEqual(signOuts.count, 1)
        XCTAssertEqual(coordinator.scheduled, AccountDeletionScheduled(deleteAfter: AccountDeletionStatus.due))
        XCTAssertEqual(coordinator.request, .idle)
    }

    func test_a_request_that_does_not_go_through_keeps_the_person_signed_in_and_says_why() async {
        for failure in [AccountDeletionError.unreachable, .notOffered, .signedOut, .failed, .rateLimited] {
            let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(request: .failure(failure)))
            await coordinator.start().value
            let signOuts = Calls()
            await deleteAccount(coordinator, signOut: { signOuts.count += 1 })
            XCTAssertEqual(signOuts.count, 0, "\(failure)")
            XCTAssertNil(coordinator.scheduled)
            XCTAssertEqual(coordinator.request, .failed(AccountDeletionCopy.requestFailure(failure)))
            XCTAssertTrue(coordinator.isOffered, "the row stays so the person can try again")
            coordinator.askToDelete()
            XCTAssertEqual(coordinator.request, .confirming, "after a failure, Delete my account asks again")
        }
    }

    func test_opening_the_screen_again_forgets_a_failure_and_an_open_confirmation_but_not_a_request() async {
        let gate = Gate()
        let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(request: .failure(.failed)))
        await coordinator.start().value
        await deleteAccount(coordinator, signOut: {})
        coordinator.resetRequest()
        XCTAssertEqual(coordinator.request, .idle)
        coordinator.askToDelete()
        coordinator.resetRequest()
        XCTAssertEqual(coordinator.request, .idle)

        let held = AccountDeletionCoordinator(client: ScriptedDeletionClient(requestGate: gate))
        await held.start().value
        held.askToDelete()
        let sending = held.confirmDeletion(signOut: {})
        held.resetRequest()
        XCTAssertEqual(held.request, .sending, "a request on its way is not forgotten")
        gate.open()
        await sending?.value
    }

    func test_a_202_that_arrives_after_another_sign_in_signs_nobody_out() async {
        let gate = Gate()
        let client = ScriptedDeletionClient(requestGate: gate)
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value
        let signOuts = Calls()

        let request = Task { await deleteAccount(coordinator, signOut: { signOuts.count += 1 }) }
        await settle { client.count("request") == 1 }
        await coordinator.start().value
        gate.open()
        await request.value
        XCTAssertEqual(signOuts.count, 0)
        XCTAssertNil(coordinator.scheduled)
    }

    /// The call-ring steps, logged; either can be made to fail, and the last can be held.
    private func wireCallRing(_ coordinator: AccountDeletionCoordinator, log: EventLog, beginFails: Bool = false,
                              finishFails: Bool = false, finishGate: Gate? = nil) {
        coordinator.beginCallRingRevoke = {
            log.note("begin")
            if beginFails { throw RevokeFailure() }
        }
        coordinator.finishCallRingRevoke = {
            await finishGate?.wait()
            log.note("finish")
            if finishFails { throw RevokeFailure() }
        }
        coordinator.rearmCallRing = { log.note("rearm") }
    }

    func test_calls_stop_ringing_before_the_request_and_sign_out_follows_its_202() async {
        let log = EventLog()
        let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(log: log))
        wireCallRing(coordinator, log: log)
        await coordinator.start().value

        coordinator.askToDelete()
        XCTAssertEqual(log.events, [], "the first yes stops nothing")
        await coordinator.confirmDeletion(signOut: { log.note("signOut") })?.value
        XCTAssertEqual(log.events, ["begin", "finish", "post", "signOut"])
    }

    func test_a_revoke_that_fails_sends_no_request_and_keeps_the_person_signed_in() async {
        let cases: [(beginFails: Bool, finishFails: Bool, events: [String])] = [
            (true, false, ["begin", "rearm"]),
            (false, true, ["begin", "finish", "rearm"])
        ]
        for (beginFails, finishFails, events) in cases {
            let log = EventLog()
            let client = ScriptedDeletionClient(log: log)
            let coordinator = AccountDeletionCoordinator(client: client)
            wireCallRing(coordinator, log: log, beginFails: beginFails, finishFails: finishFails)
            await coordinator.start().value

            await deleteAccount(coordinator, signOut: { log.note("signOut") })
            XCTAssertEqual(log.events, events, "no request, no sign-out, and calls ring again")
            XCTAssertEqual(client.count("request"), 0)
            XCTAssertEqual(coordinator.request, .failed(AccountDeletionCopy.requestFailure(.unreachable)))
            XCTAssertNil(coordinator.scheduled)
        }
    }

    func test_a_request_that_fails_after_the_revoke_turns_calls_back_on_and_keeps_the_person_signed_in() async {
        for failure in [AccountDeletionError.unreachable, .notOffered, .signedOut, .failed, .rateLimited] {
            let log = EventLog()
            let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(
                request: .failure(failure), log: log))
            wireCallRing(coordinator, log: log)
            await coordinator.start().value

            await deleteAccount(coordinator, signOut: { log.note("signOut") })
            XCTAssertEqual(log.events, ["begin", "finish", "post", "rearm"], "\(failure)")
            XCTAssertEqual(coordinator.request, .failed(AccountDeletionCopy.requestFailure(failure)))
            XCTAssertNil(coordinator.scheduled)
        }
    }

    func test_a_new_sign_in_while_calls_are_being_stopped_sends_no_request() async {
        let log = EventLog()
        let gate = Gate()
        let client = ScriptedDeletionClient(log: log)
        let coordinator = AccountDeletionCoordinator(client: client)
        wireCallRing(coordinator, log: log, finishGate: gate)
        await coordinator.start().value

        let request = Task { await deleteAccount(coordinator, signOut: { log.note("signOut") }) }
        await settle { log.events == ["begin"] }
        await coordinator.start().value
        gate.open()
        await request.value
        XCTAssertEqual(log.events, ["begin", "finish"], "the new sign-in's token never carries the request")
        XCTAssertEqual(client.count("request"), 0)
    }

    func test_a_pending_status_after_sign_in_shows_the_notice_with_its_date() async {
        let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(status: [.success(.scheduled)]))
        await coordinator.start().value
        XCTAssertEqual(coordinator.pending,
                       AccountDeletionPendingNotice(deleteAfter: AccountDeletionStatus.due, phase: .waiting))
        XCTAssertEqual(coordinator.pending?.offersKeepAccount, true)
    }

    func test_keeping_the_account_cancels_registers_this_phone_again_then_continues_into_the_app() async {
        let log = EventLog()
        let client = ScriptedDeletionClient(status: [.success(.scheduled)], cancel: .success(()), log: log)
        let coordinator = AccountDeletionCoordinator(client: client)
        coordinator.registerAgain = { log.note("register") }
        await coordinator.start().value

        await coordinator.keepAccount(onContinue: { log.note("continue") })
        XCTAssertEqual(client.count("cancel"), 1)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(log.events, ["cancel", "register", "continue"],
                       "the server removed this phone's registrations with the request and keeping brings none back")
    }

    func test_a_409_on_cancel_offers_only_sign_out() async {
        let client = ScriptedDeletionClient(status: [.success(.scheduled)], cancel: .failure(.deadlinePassed))
        let coordinator = AccountDeletionCoordinator(client: client)
        let registrations = Calls()
        coordinator.registerAgain = { registrations.count += 1 }
        await coordinator.start().value
        let continues = Calls()

        await coordinator.keepAccount(onContinue: { continues.count += 1 })
        XCTAssertEqual(coordinator.pending?.phase, .deadlinePassed)
        XCTAssertEqual(coordinator.pending?.offersKeepAccount, false)
        XCTAssertEqual(continues.count, 0)
        XCTAssertEqual(registrations.count, 0)

        await coordinator.keepAccount(onContinue: { continues.count += 1 })
        XCTAssertEqual(client.count("cancel"), 1, "once the date has passed, nothing more is asked")
    }

    func test_a_cancel_that_does_not_go_through_keeps_the_notice_and_both_choices() async {
        for failure in [AccountDeletionError.unreachable, .signedOut, .rateLimited, .failed] {
            let client = ScriptedDeletionClient(status: [.success(.scheduled)], cancel: .failure(failure))
            let coordinator = AccountDeletionCoordinator(client: client)
            let registrations = Calls()
            coordinator.registerAgain = { registrations.count += 1 }
            await coordinator.start().value
            let continues = Calls()

            await coordinator.keepAccount(onContinue: { continues.count += 1 })
            XCTAssertEqual(coordinator.pending?.phase, .failed(AccountDeletionCopy.keepFailure(failure)), "\(failure)")
            XCTAssertEqual(coordinator.pending?.offersKeepAccount, true)
            XCTAssertEqual(continues.count, 0)
            XCTAssertEqual(registrations.count, 0, "nothing is registered for an account still being deleted")
        }
    }

    func test_a_reported_refusal_asks_the_server_once_for_the_date() async {
        let client = ScriptedDeletionClient(status: [.success(.unrequested), .success(.scheduled)])
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value
        XCTAssertNil(coordinator.pending)

        coordinator.pendingReported()
        coordinator.pendingReported()
        coordinator.pendingReported()
        await settle { coordinator.pending != nil }
        XCTAssertEqual(client.count("status"), 2)
        XCTAssertEqual(coordinator.pending?.deleteAfter, AccountDeletionStatus.due)

        coordinator.pendingReported()
        await settle(for: 25)
        XCTAssertEqual(client.count("status"), 2, "a notice already up asks nothing more")
    }

    func test_a_new_sign_in_forgets_the_last_accounts_answers() async {
        let withDays = AccountDeletionStatus(isPending: true, requestedAt: nil, deleteAfter: AccountDeletionStatus.due,
                                             graceDays: 7)
        let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(
            status: [.success(withDays), .failure(.notOffered)]))
        await coordinator.start().value
        XCTAssertNotNil(coordinator.pending)
        XCTAssertEqual(coordinator.graceDays, 7)
        await coordinator.start().value
        XCTAssertNil(coordinator.pending)
        XCTAssertNil(coordinator.graceDays)
        XCTAssertFalse(coordinator.isOffered)
    }
}

/// The words the screens use say what the server does, with the server's date and number of days only.
final class AccountDeletionCopyTests: XCTestCase {
    func test_before_a_request_no_number_of_days_is_given_unless_the_server_gives_one() {
        for words in [AccountDeletionCopy.later(graceDays: nil), AccountDeletionCopy.confirmMessage(graceDays: nil),
                      AccountDeletionCopy.rightAway, AccountDeletionCopy.stays, AccountDeletionCopy.keep,
                      AccountDeletionCopy.deleteHint] {
            XCTAssertNil(words.rangeOfCharacter(from: .decimalDigits), "a number the server did not give: \(words)")
        }
        XCTAssertTrue(AccountDeletionCopy.later(graceDays: 2).hasPrefix("After 2 days, "))
        XCTAssertTrue(AccountDeletionCopy.later(graceDays: 1).hasPrefix("After 1 day, "))
        XCTAssertTrue(AccountDeletionCopy.confirmMessage(graceDays: 30).hasSuffix("after 30 days."))
    }

    func test_the_date_is_the_servers_with_its_weekday_and_time_in_the_phones_time_zone() throws {
        let due = iso("2026-11-13T06:12:34Z")
        let now = iso("2026-11-06T06:00:00Z")
        let english = Locale(identifier: "en_US")
        let gregorian = Calendar(identifier: .gregorian)
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let words = AccountDeletionCopy.when(due, now: now, locale: english, calendar: gregorian, timeZone: newYork)
        XCTAssertTrue(words.contains("Friday"), words)
        XCTAssertTrue(words.contains("November 13"), words)
        XCTAssertTrue(words.contains("1:12"), "06:12 UTC is 1:12 in New York: \(words)")
        XCTAssertFalse(words.contains("2026"), "this year's date has no year: \(words)")

        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let there = AccountDeletionCopy.when(due, now: now, locale: english, calendar: gregorian, timeZone: tokyo)
        XCTAssertTrue(there.contains("3:12"), "06:12 UTC is 15:12 in Tokyo: \(there)")

        let nextYear = AccountDeletionCopy.when(iso("2027-01-04T17:00:00Z"), now: iso("2026-12-30T12:00:00Z"),
                                                locale: english, calendar: gregorian, timeZone: newYork)
        XCTAssertTrue(nextYear.contains("2027"), nextYear)
    }

    func test_the_titles_carry_the_servers_date() {
        let due = iso("2026-11-13T06:12:34Z")
        let when = AccountDeletionCopy.when(due)
        XCTAssertEqual(AccountDeletionCopy.scheduledTitle(deleteAfter: due), "Your account will be deleted on \(when).")
        XCTAssertEqual(AccountDeletionCopy.pendingTitle(deleteAfter: due), "Your account will be deleted on \(when).")
        XCTAssertEqual(AccountDeletionCopy.scheduledTitle(deleteAfter: nil), "Your account will be deleted.")
    }

    func test_the_words_say_only_keep_my_account_stops_it_not_signing_in() {
        let due = iso("2026-11-13T06:12:34Z")
        XCTAssertTrue(AccountDeletionCopy.keep.contains("tap Keep my account"))
        XCTAssertTrue(AccountDeletionCopy.keep.contains("Signing in alone doesn't stop it"))
        XCTAssertTrue(AccountDeletionCopy.scheduledDetail(deleteAfter: due).contains("tap Keep my account"))
        XCTAssertTrue(AccountDeletionCopy.pendingDetail.contains("Keep my account"))
        for words in [AccountDeletionCopy.keep, AccountDeletionCopy.scheduledDetail(deleteAfter: due),
                      AccountDeletionCopy.scheduledDetail(deleteAfter: nil), AccountDeletionCopy.pendingDetail] {
            XCTAssertFalse(words.contains("lets you keep"), "signing in alone keeps nothing: \(words)")
        }
    }

    func test_nothing_was_deleted_is_said_only_where_the_servers_answer_shows_it() {
        for sure in [AccountDeletionError.notOffered, .rateLimited] {
            XCTAssertTrue(AccountDeletionCopy.requestFailure(sure).contains("Nothing was deleted"), "\(sure)")
        }
        for unsure in [AccountDeletionError.unreachable, .failed, .signedOut, .deadlinePassed] {
            let words = AccountDeletionCopy.requestFailure(unsure)
            XCTAssertFalse(words.contains("Nothing was deleted"), "\(unsure) may have gone through: \(words)")
            XCTAssertFalse(words.contains("still signed in"), "\(unsure) may have ended every sign-in: \(words)")
        }
    }
}

/// The deletion screen hosted in a window, read the way VoiceOver reads it: "Delete my account" says what it does and
/// only brings up the confirmation, whose own "Delete my account" is the destructive one.
@MainActor
final class AccountDeletionSheetHostedTests: XCTestCase {
    func test_the_first_tap_only_asks_and_sends_nothing() async throws {
        let client = ScriptedDeletionClient()
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value
        let signOuts = Calls()
        let window = try HostedSummary.host(AccountDeletionSheet(coordinator: coordinator,
                                                                 onSignOut: { signOuts.count += 1 }))
        defer { HostedSummary.close(window) }
        guard let button = HostedSummary.wait(for: "account.delete.request", in: window) else {
            return XCTFail("no Delete my account: \(HostedSummary.identifiers(in: window))")
        }
        XCTAssertEqual(button.accessibilityLabel, AccountDeletionCopy.deleteButton)
        XCTAssertEqual(button.accessibilityHint, AccountDeletionCopy.deleteHint, "VoiceOver says what it deletes")

        XCTAssertTrue(button.accessibilityActivate())
        HostedSummary.pump(0.5)
        await settle(for: 100) { client.count("request") > 0 }
        XCTAssertEqual(client.count("request"), 0, "the first tap sent the request")
        XCTAssertEqual(signOuts.count, 0)
        XCTAssertEqual(coordinator.request, .confirming)
        let alert = try XCTUnwrap(window.rootViewController?.presentedViewController as? UIAlertController,
                                  "no confirmation came up")
        XCTAssertEqual(alert.title, AccountDeletionCopy.confirmTitle)
        XCTAssertEqual(Set(alert.actions.compactMap(\.title)), [AccountDeletionCopy.deleteButton, "Cancel"])
        XCTAssertEqual(alert.actions.first { $0.title == AccountDeletionCopy.deleteButton }?.style, .destructive)
        alert.dismiss(animated: false)
        HostedSummary.pump(0.3)
    }
}

/// The 403 a protected read gets while deletion is pending reaches the notice; no other 403 does.
@MainActor
final class AccountDeletionPendingRefusalTests: XCTestCase {
    private func transport(status: Int, body: String, coordinator: AccountDeletionCoordinator) -> HTTPSessionTransport {
        DeletionURLProtocol.reset(status: status, body: body)
        return HTTPSessionTransport(
            apiBaseURL: URL(string: "https://api.example.invalid"),
            urlSession: stubbedSession(),
            tokenProvider: { "test-bearer-token" },
            onAccountDeletionPending: { Task { @MainActor in coordinator.pendingReported() } }
        )
    }

    func test_a_read_refused_because_deletion_is_pending_brings_up_the_notice_with_its_date() async {
        let client = ScriptedDeletionClient(status: [.success(.unrequested), .success(.scheduled)])
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value
        let reads = transport(status: 403, body: Wire.pendingRefusal, coordinator: coordinator)

        _ = try? await reads.listSessions(includeArchived: false, limit: 50, cursor: nil)
        await settle { coordinator.pending != nil }
        XCTAssertEqual(coordinator.pending,
                       AccountDeletionPendingNotice(deleteAfter: AccountDeletionStatus.due, phase: .waiting))
    }

    func test_any_other_403_brings_up_no_notice() async {
        let client = ScriptedDeletionClient(status: [.success(.unrequested), .success(.scheduled)])
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value
        let reads = transport(status: 403, body: #"{"error":{"code":"FORBIDDEN"}}"#, coordinator: coordinator)

        _ = try? await reads.listSessions(includeArchived: false, limit: 50, cursor: nil)
        await settle(for: 25)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(client.count("status"), 1)
    }
}

#if canImport(CallKit) && canImport(PushKit)
/// The app's call host, wired as the app wires it: calls stop before the request, and ring again if it fails.
@MainActor
final class AccountDeletionCallRingTests: XCTestCase {
    private func signedInHost() -> DialHost {
        let host = DialHost(
            gatewayURL: URL(string: "https://api.pocket.test")!,
            registryStateStore: DeviceRingRegistryStateStore(
                storage: TestDeviceRingSecureStorage(),
                authorityDenyStore: TestDeviceRingAuthorityDenyStore()
            ),
            isSignedIn: { true }
        )
        host.onLoginCompleted()
        host.selectSession("room-1")
        return host
    }

    func test_calls_are_off_while_the_request_is_on_its_way_and_ring_again_for_the_same_room_if_it_fails() async {
        let host = signedInHost()
        let gate = Gate()
        let client = ScriptedDeletionClient(request: .failure(.unreachable), requestGate: gate)
        let coordinator = AccountDeletionCoordinator(client: client)
        SentiPocketApp.wire(coordinator, to: host)
        await coordinator.start().value
        XCTAssertEqual(host.callManager?.takesVoipPushes, true)
        XCTAssertEqual(host.selectedSession, "room-1")

        let signOuts = Calls()
        let request = Task { await deleteAccount(coordinator, signOut: { signOuts.count += 1 }) }
        await settle { client.count("request") == 1 }
        XCTAssertEqual(host.callManager?.takesVoipPushes, false, "calls stop before the request goes")
        XCTAssertNil(host.selectedSession)

        gate.open()
        await request.value
        XCTAssertEqual(signOuts.count, 0)
        XCTAssertEqual(host.callManager?.takesVoipPushes, true, "still signed in, so calls ring again")
        XCTAssertEqual(host.selectedSession, "room-1")
    }

    func test_the_first_yes_leaves_calls_ringing() async {
        let host = signedInHost()
        let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient())
        SentiPocketApp.wire(coordinator, to: host)
        await coordinator.start().value

        coordinator.askToDelete()
        XCTAssertEqual(host.callManager?.takesVoipPushes, true, "only the confirmation's yes stops calls")
        XCTAssertEqual(host.selectedSession, "room-1")
        coordinator.dismissConfirmation()
    }

    func test_after_a_202_calls_stay_off_and_the_sign_out_that_follows_has_nothing_left_to_remove() async throws {
        let host = signedInHost()
        let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(request: .success(.scheduled)))
        SentiPocketApp.wire(coordinator, to: host)
        await coordinator.start().value

        let signOuts = Calls()
        await deleteAccount(coordinator, signOut: { signOuts.count += 1 })
        XCTAssertEqual(signOuts.count, 1)
        XCTAssertEqual(host.callManager?.takesVoipPushes, false)
        XCTAssertNil(host.selectedSession)
        try host.beginSignOut()
        try await host.prepareForSignOut()
    }
}
#endif
