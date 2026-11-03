import Foundation
import PocketSyncClient
import XCTest
@testable import SentiPocketApp

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
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: [:])!
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
        DeletionURLProtocol.reset(status: 200, body: #"{"status":"none","requested_at":null,"delete_after":null}"#)
        let status = try await client().status()
        XCTAssertEqual(status, AccountDeletionStatus(isPending: false, requestedAt: nil, deleteAfter: nil))
        let request = try XCTUnwrap(DeletionURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/v1/me/account/deletion")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer-token")
    }

    func test_a_pending_status_reads_both_dates_as_the_server_writes_them() async throws {
        DeletionURLProtocol.reset(status: 200, body: """
        {"status":"pending","requested_at":"2026-11-02T15:04:05.123456+00:00","delete_after":"2026-11-09T15:04:05+00:00"}
        """)
        let status = try await client().status()
        XCTAssertTrue(status.isPending)
        XCTAssertEqual(try XCTUnwrap(status.requestedAt).timeIntervalSince1970,
                       iso("2026-11-02T15:04:05Z").timeIntervalSince1970 + 0.123456, accuracy: 0.001)
        XCTAssertEqual(status.deleteAfter, iso("2026-11-09T15:04:05Z"))
    }

    func test_a_404_means_this_server_does_not_offer_deletion() async {
        DeletionURLProtocol.reset(status: 404, body: #"{"error":{"code":"HTTP_ERROR","message":"Not found"}}"#)
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
        DeletionURLProtocol.reset(status: 202, body: """
        {"status":"pending","requested_at":"2026-11-02T15:04:05+00:00","delete_after":"2026-11-09T15:04:05+00:00"}
        """)
        let status = try await client().requestDeletion()
        XCTAssertEqual(status, AccountDeletionStatus(isPending: true, requestedAt: iso("2026-11-02T15:04:05Z"),
                                                     deleteAfter: iso("2026-11-09T15:04:05Z")))
        let request = try XCTUnwrap(DeletionURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/me/account/deletion")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer-token")

        for other in [200, 204, 403, 409, 429, 500] {
            DeletionURLProtocol.reset(status: other, body: #"{"status":"pending"}"#)
            await expect(.failed) { _ = try await self.client().requestDeletion() }
        }
    }

    func test_an_accepted_request_whose_body_cannot_be_read_is_still_scheduled() async throws {
        DeletionURLProtocol.reset(status: 202, body: "")
        let status = try await client().requestDeletion()
        XCTAssertEqual(status, AccountDeletionStatus(isPending: true, requestedAt: nil, deleteAfter: nil))
    }

    func test_cancel_posts_to_its_route_and_a_409_means_the_deadline_passed() async throws {
        DeletionURLProtocol.reset(status: 200, body: #"{"status":"none","requested_at":null,"delete_after":null}"#)
        try await client().cancelDeletion()
        let request = try XCTUnwrap(DeletionURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/me/account/deletion/cancel")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer-token")

        DeletionURLProtocol.reset(status: 409, body: #"{"error":{"code":"HTTP_ERROR"}}"#)
        await expect(.deadlinePassed) { try await self.client().cancelDeletion() }
        DeletionURLProtocol.reset(status: 500)
        await expect(.failed) { try await self.client().cancelDeletion() }
    }

    func test_a_refused_token_is_signed_out_and_no_token_sends_nothing() async {
        DeletionURLProtocol.reset(status: 401)
        await expect(.signedOut) { _ = try await self.client().status() }
        DeletionURLProtocol.reset(status: 200, body: #"{"status":"none"}"#)
        await expect(.signedOut) { _ = try await self.client(token: nil).requestDeletion() }
        await expect(.signedOut) { _ = try await self.client(token: "").status() }
        XCTAssertTrue(DeletionURLProtocol.requests().isEmpty)
    }

    func test_a_dropped_connection_is_unreachable() async {
        DeletionURLProtocol.resetUnreachable()
        await expect(.unreachable) { _ = try await self.client().requestDeletion() }
        await expect(.unreachable) { try await self.client().cancelDeletion() }
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

private final class ScriptedDeletionClient: AccountDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private var statusAnswers: [Result<AccountDeletionStatus, AccountDeletionError>]
    private let requestAnswer: Result<AccountDeletionStatus, AccountDeletionError>
    private let cancelAnswer: Result<Void, AccountDeletionError>
    private let requestGate: Gate?
    private var counts: [String: Int] = [:]

    init(status: [Result<AccountDeletionStatus, AccountDeletionError>] = [.success(.unrequested)],
         request: Result<AccountDeletionStatus, AccountDeletionError> = .success(.scheduled),
         cancel: Result<Void, AccountDeletionError> = .success(()),
         requestGate: Gate? = nil) {
        statusAnswers = status
        requestAnswer = request
        cancelAnswer = cancel
        self.requestGate = requestGate
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
        await requestGate?.wait()
        return try requestAnswer.get()
    }

    func cancelDeletion() async throws {
        note("cancel")
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

/// Deleting your account from the app (App Review 5.1.1(v)): the Settings row, the request, the pending notice.
@MainActor
final class AccountDeletionCoordinatorTests: XCTestCase {
    func test_the_row_shows_once_the_status_route_answers_200() async {
        let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(status: [.success(.unrequested)]))
        XCTAssertFalse(coordinator.isOffered, "nothing shows before the server answers")
        await coordinator.start().value
        XCTAssertTrue(coordinator.isOffered)
        XCTAssertNil(coordinator.pending)
    }

    func test_the_row_stays_hidden_when_the_server_does_not_offer_deletion_or_cannot_be_reached() async {
        for failure in [AccountDeletionError.notOffered, .unreachable, .signedOut, .failed] {
            let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(status: [.failure(failure)]))
            await coordinator.start().value
            XCTAssertFalse(coordinator.isOffered, "\(failure)")
            XCTAssertNil(coordinator.pending)
        }
    }

    func test_a_shown_row_hides_again_when_a_later_answer_fails() async {
        let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(
            status: [.success(.unrequested), .failure(.notOffered)]))
        await coordinator.start().value
        XCTAssertTrue(coordinator.isOffered)
        await coordinator.refresh().value
        XCTAssertFalse(coordinator.isOffered)
    }

    func test_sign_out_happens_only_after_the_server_answers_202() async {
        let gate = Gate()
        let client = ScriptedDeletionClient(requestGate: gate)
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value
        let signOuts = Calls()

        let request = Task { await coordinator.requestDeletion(signOut: { signOuts.count += 1 }) }
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

    func test_a_request_that_does_not_go_through_keeps_the_person_signed_in_and_says_so() async {
        for failure in [AccountDeletionError.unreachable, .notOffered, .signedOut, .failed] {
            let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(request: .failure(failure)))
            await coordinator.start().value
            let signOuts = Calls()
            await coordinator.requestDeletion(signOut: { signOuts.count += 1 })
            XCTAssertEqual(signOuts.count, 0, "\(failure)")
            XCTAssertNil(coordinator.scheduled)
            XCTAssertEqual(coordinator.request, .failed(AccountDeletionCopy.requestFailure(failure)))
            XCTAssertTrue(coordinator.isOffered, "the row stays so the person can try again")
        }
        XCTAssertTrue(AccountDeletionCopy.requestFailure(.unreachable).contains("still signed in"))
    }

    func test_a_second_tap_while_the_request_is_on_its_way_sends_nothing_more() async {
        let gate = Gate()
        let client = ScriptedDeletionClient(requestGate: gate)
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value
        let signOuts = Calls()

        let first = Task { await coordinator.requestDeletion(signOut: { signOuts.count += 1 }) }
        await settle { client.count("request") == 1 }
        let second = Task { await coordinator.requestDeletion(signOut: { signOuts.count += 1 }) }
        await settle(for: 50) { client.count("request") > 1 }
        gate.open()
        await first.value
        await second.value
        XCTAssertEqual(client.count("request"), 1)
        XCTAssertEqual(signOuts.count, 1)
    }

    func test_a_202_that_arrives_after_another_sign_in_signs_nobody_out() async {
        let gate = Gate()
        let client = ScriptedDeletionClient(requestGate: gate)
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value
        let signOuts = Calls()

        let request = Task { await coordinator.requestDeletion(signOut: { signOuts.count += 1 }) }
        await settle { client.count("request") == 1 }
        await coordinator.start().value
        gate.open()
        await request.value
        XCTAssertEqual(signOuts.count, 0)
        XCTAssertNil(coordinator.scheduled)
    }

    func test_a_pending_status_after_sign_in_shows_the_notice_with_its_date() async {
        let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(status: [.success(.scheduled)]))
        await coordinator.start().value
        XCTAssertEqual(coordinator.pending,
                       AccountDeletionPendingNotice(deleteAfter: AccountDeletionStatus.due, phase: .waiting))
        XCTAssertEqual(coordinator.pending?.offersKeepAccount, true)
    }

    func test_keeping_the_account_cancels_then_continues_into_the_app() async {
        let client = ScriptedDeletionClient(status: [.success(.scheduled)], cancel: .success(()))
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value
        let continues = Calls()

        await coordinator.keepAccount(onContinue: { continues.count += 1 })
        XCTAssertEqual(client.count("cancel"), 1)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(continues.count, 1)
    }

    func test_a_409_on_cancel_offers_only_sign_out() async {
        let client = ScriptedDeletionClient(status: [.success(.scheduled)], cancel: .failure(.deadlinePassed))
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value
        let continues = Calls()

        await coordinator.keepAccount(onContinue: { continues.count += 1 })
        XCTAssertEqual(coordinator.pending?.phase, .deadlinePassed)
        XCTAssertEqual(coordinator.pending?.offersKeepAccount, false)
        XCTAssertEqual(continues.count, 0)

        await coordinator.keepAccount(onContinue: { continues.count += 1 })
        XCTAssertEqual(client.count("cancel"), 1, "once the date has passed, nothing more is asked")
    }

    func test_a_cancel_that_does_not_go_through_keeps_the_notice_and_both_choices() async {
        let client = ScriptedDeletionClient(status: [.success(.scheduled)], cancel: .failure(.unreachable))
        let coordinator = AccountDeletionCoordinator(client: client)
        await coordinator.start().value
        let continues = Calls()

        await coordinator.keepAccount(onContinue: { continues.count += 1 })
        XCTAssertEqual(coordinator.pending?.phase, .failed(AccountDeletionCopy.keepFailure(.unreachable)))
        XCTAssertEqual(coordinator.pending?.offersKeepAccount, true)
        XCTAssertEqual(continues.count, 0)
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
        let coordinator = AccountDeletionCoordinator(client: ScriptedDeletionClient(
            status: [.success(.scheduled), .failure(.notOffered)]))
        await coordinator.start().value
        XCTAssertNotNil(coordinator.pending)
        await coordinator.start().value
        XCTAssertNil(coordinator.pending)
        XCTAssertFalse(coordinator.isOffered)
    }

    func test_the_words_give_the_date_when_the_server_gives_one() {
        let due = AccountDeletionStatus.due
        let day = due.formatted(date: .long, time: .omitted)
        XCTAssertEqual(AccountDeletionCopy.pendingTitle(deleteAfter: due),
                       "Your account is scheduled for deletion on \(day).")
        XCTAssertTrue(AccountDeletionCopy.scheduled(deleteAfter: due).contains("deleted on \(day)"))
        XCTAssertTrue(AccountDeletionCopy.scheduled(deleteAfter: nil).contains("deleted after 7 days"))
        XCTAssertEqual(AccountDeletionCopy.consequences, [
            "Your account and your data will be deleted after 7 days.",
            "You'll be signed out on every device now.",
            "Signing in again before then lets you keep your account.",
            "Messages you posted in shared rooms stay with the room."
        ])
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
        let reads = transport(status: 403, body: #"{"error":{"code":"ACCOUNT_DELETION_PENDING","message":"x"}}"#,
                              coordinator: coordinator)

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
