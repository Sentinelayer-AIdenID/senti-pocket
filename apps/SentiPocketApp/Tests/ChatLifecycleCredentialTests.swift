import Foundation
import PocketSyncClient
import XCTest
@testable import SentiPocketApp

private final class LifecycleCredentialStore: @unchecked Sendable {
    private let lock = NSLock()
    private var token = "fixture-first"
    func get() -> String { lock.lock(); defer { lock.unlock() }; return token }
    func rotate() { lock.lock(); token = "fixture-second"; lock.unlock() }
}

private final class LifecycleIdentityURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> String)?

    static func install(_ handler: @escaping (URLRequest) -> String) -> URLSession {
        lock.lock(); self.handler = handler; lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        let body = handler?(request) ?? "{}"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
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
                return #"{"id":"account-a","github_username":""}"#
            }
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/chat-1/kill")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-second")
            write.fulfill()
            return #"{"ok":true,"sessionId":"chat-1","status":"killed"}"#
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
                return #"{"id":"account-a","github_username":""}"#
            }
            return #"{"id":"account-b","github_username":""}"#
        }
        defer { session.invalidateAndCancel() }
        let credentials = ChatLifecycleAccountCredentials(apiBaseURL: URL(string: "https://api.example.test"),
            urlSession: session, tokenProvider: { store.get() })
        let client = HTTPChatLifecycleClient(apiBaseURL: URL(string: "https://api.example.test"), urlSession: session,
            credentialProvider: { try await credentials.current() })
        do { try await client.endChat("chat-1", accountId: "account-a"); XCTFail("sent another account's confirmation") }
        catch { XCTAssertEqual(error as? ChatLifecycleError, .accountChanged) }
    }
}
