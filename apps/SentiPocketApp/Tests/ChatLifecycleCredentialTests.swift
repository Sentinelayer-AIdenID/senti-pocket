import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class LifecycleCredentialStore: @unchecked Sendable {
    private let lock = NSLock()
    private var token = "fixture-first"
    private var revoked = false
    func get() -> String { lock.lock(); defer { lock.unlock() }; return token }
    func rotate() { lock.lock(); token = "fixture-second"; lock.unlock() }
    func revoke() { lock.withLock { revoked = true } }
    var isRevoked: Bool { lock.withLock { revoked } }
}

private final class LifecycleIdentityURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, String))?
    private static var seen: [URLRequest] = []

    static func install(_ handler: @escaping (URLRequest) -> (Int, String)) -> URLSession {
        lock.lock(); self.handler = handler; seen = []; lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }

    static var requests: [URLRequest] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock {
            Self.seen.append(request)
            return Self.handler
        }
        let (status, body) = handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ChatLifecycleCredentialTests: XCTestCase {
    func test_a_refresh_during_identity_resolution_sends_the_verified_rotated_bearer() async throws {
        let store = LifecycleCredentialStore()
        let write = expectation(description: "one end request")
        write.expectedFulfillmentCount = 1
        write.assertForOverFulfill = true
        let session = LifecycleIdentityURLProtocol.install { request in
            if request.url?.path == "/api/v1/auth/me" {
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-first" { store.rotate() }
                return (200, #"{"id":"account-a","github_username":""}"#)
            }
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/chat-1/kill")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-second")
            write.fulfill()
            return (200, #"{"ok":true,"sessionId":"chat-1","status":"killed"}"#)
        }
        defer { session.invalidateAndCancel() }
        let credentials = ChatLifecycleAccountCredentials(apiBaseURL: URL(string: "https://api.example.test"),
            urlSession: session, tokenProvider: { store.get() })
        let client = HTTPChatLifecycleClient(apiBaseURL: URL(string: "https://api.example.test"), urlSession: session,
            credentialProvider: { try await credentials.current() })
        try await client.endChat("chat-1", accountId: "account-a")
        await fulfillment(of: [write], timeout: 1)
    }

    func test_an_account_switch_during_identity_resolution_never_pairs_the_old_account_with_the_new_bearer() async {
        let store = LifecycleCredentialStore()
        let session = LifecycleIdentityURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/me", "the write must not be sent")
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-first" {
                store.rotate()
                return (200, #"{"id":"account-a","github_username":""}"#)
            }
            return (200, #"{"id":"account-b","github_username":""}"#)
        }
        defer { session.invalidateAndCancel() }
        let credentials = ChatLifecycleAccountCredentials(apiBaseURL: URL(string: "https://api.example.test"),
            urlSession: session, tokenProvider: { store.get() })
        let client = HTTPChatLifecycleClient(apiBaseURL: URL(string: "https://api.example.test"), urlSession: session,
            credentialProvider: { try await credentials.current() })
        do { try await client.endChat("chat-1", accountId: "account-a"); XCTFail("sent another account's confirmation") }
        catch { XCTAssertEqual(error as? ChatLifecycleError, .accountChanged) }
    }

    @MainActor
    func test_identity_401_before_or_after_the_write_reauthenticates_once_without_acknowledging_the_change() async throws {
        for afterWrite in [false, true] {
            try await assertIdentityRevocation(status: 401, body: #"{"error":{"code":"UNAUTHORIZED"}}"#,
                                               afterWrite: afterWrite)
        }
        try await assertIdentityRevocation(status: 401, body: #"{"error":{"code":"UNAUTHORIZED"}}"#,
                                           afterWrite: true, acceptedWrite: true)
    }

    @MainActor
    func test_account_403_before_or_after_the_write_reauthenticates_once_without_acknowledging_the_change() async throws {
        for afterWrite in [false, true] {
            try await assertIdentityRevocation(status: 403, body: #"{"detail":{"error":{"code":"ACCOUNT_BLOCKED"}}}"#,
                                               afterWrite: afterWrite)
        }
        try await assertIdentityRevocation(status: 403, body: #"{"detail":{"error":{"code":"ACCOUNT_BLOCKED"}}}"#,
                                           afterWrite: true, acceptedWrite: true)
    }

    /// Uses the real resolver, client and center. A false confirmation result keeps the alert's onChanged hook from
    /// removing the chat; opening another sign-in is the only acknowledged effect of this authentication failure.
    @MainActor
    private func assertIdentityRevocation(status: Int, body: String, afterWrite: Bool,
                                         acceptedWrite: Bool = false) async throws {
        let store = LifecycleCredentialStore()
        let session = LifecycleIdentityURLProtocol.install { request in
            if request.url?.path == "/api/v1/auth/me" {
                if !afterWrite || store.isRevoked { return (status, body) }
                return (200, #"{"id":"account-a","github_username":""}"#)
            }
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/chat-1/kill")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-first")
            store.revoke()
            return acceptedWrite ? (200, #"{"ok":true,"sessionId":"chat-1","status":"killed"}"#) : (status, body)
        }
        defer { session.invalidateAndCancel() }
        let credentials = ChatLifecycleAccountCredentials(apiBaseURL: URL(string: "https://api.example.test"),
            urlSession: session, tokenProvider: { store.get() })
        let client = HTTPChatLifecycleClient(apiBaseURL: URL(string: "https://api.example.test"), urlSession: session,
            credentialProvider: { try await credentials.current() })
        var signIns = 0
        let center = ChatLifecycleCenter(client: client, lookup: { _ in .end },
                                         onReauthenticationRequired: { signIns += 1 })
        center.setAccountId("account-a")
        center.request("chat-1")
        let pending = try XCTUnwrap(center.confirmation)
        let accepted = await center.confirm(pending)
        let replayed = await center.confirm(pending)

        XCTAssertFalse(accepted, "an identity refusal must never acknowledge a UI change")
        XCTAssertFalse(replayed)
        XCTAssertEqual(signIns, 1, "the actionable authentication failure must not be masked or repeated")
        XCTAssertNil(center.notice)
        XCTAssertFalse(center.isSaving)
        let requests = LifecycleIdentityURLProtocol.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, afterWrite ? 1 : 0)
        XCTAssertEqual(requests.filter { $0.url?.path == "/api/v1/auth/me" }.count, afterWrite ? 2 : 1)
    }
}
