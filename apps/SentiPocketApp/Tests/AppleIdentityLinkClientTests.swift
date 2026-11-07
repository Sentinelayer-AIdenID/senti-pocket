import Foundation
import XCTest
@testable import SentiPocketApp

private final class IdentityLinkHTTP: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) -> (Int, String))?
    static var requests: [(URLRequest, Data?)] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody
        if bytes == nil, let stream = request.httpBodyStream {
            stream.open()
            var result = Data(), buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                result.append(buffer, count: count)
            }
            stream.close()
            bytes = result
        }
        let handler = Self.lock.withLock { () -> ((URLRequest) -> (Int, String))? in
            Self.requests.append((request, bytes))
            return Self.handler
        }
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset(_ handler: @escaping (URLRequest) -> (Int, String)) {
        lock.withLock { Self.handler = handler; requests = [] }
    }
    static var sent: [(URLRequest, Data?)] { lock.withLock { requests } }
}

private final class LinkTestToken: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    init(_ token: String?) { self.token = token }
    var value: String? { lock.withLock { token } }
    func set(_ value: String?) { lock.withLock { token = value } }
}

@MainActor
final class AppleIdentityLinkClientTests: XCTestCase {
    private let state = "link_" + String(repeating: "s", count: 43)
    private let nonce = String(repeating: "n", count: 43)

    private func makeClient(token: LinkTestToken = LinkTestToken("current-human-jwt"),
                        handler: @escaping (URLRequest) -> (Int, String)) -> AppleIdentityLinkClient {
        IdentityLinkHTTP.reset(handler)
        let config = SentiHTTPTransportPolicy.makeProtectedReadConfiguration()
        config.protocolClasses = [IdentityLinkHTTP.self]
        return AppleIdentityLinkClient(baseURL: URL(string: "https://api.example.invalid"),
                                       session: URLSession(configuration: config), tokenProvider: { token.value })
    }

    func test_exact_link_routes_use_current_bearer_server_state_and_never_send_raw_nonce_or_login() async throws {
        let token = LinkTestToken("current-human-jwt")
        let challenge = "{\"state\":\"\(state)\",\"nonce\":\"\(nonce)\",\"expiresIn\":300}"
        let client = makeClient(token: token) { request in
            switch request.url!.lastPathComponent {
            case "challenge": return (200, challenge)
            case "complete": return (200, #"{"provider":"apple","linked":true,"token":"never-install-this"}"#)
            default: return (200, #"{"google":false,"apple":false,"github":true}"#)
            }
        }
        let links = try await client.identities()
        let issued = try await client.challenge()
        try await client.complete(AppleLinkProof(state: issued.state, identityToken: "apple-proof", authorizationCode: "code"))
        XCTAssertEqual(links, LinkedSignIns(google: false, apple: false, github: true))
        XCTAssertEqual(issued.nonce, nonce)
        XCTAssertEqual(token.value, "current-human-jwt", "link completion cannot install any returned login token")
        let sent = IdentityLinkHTTP.sent
        XCTAssertEqual(sent.map { $0.0.httpMethod }, ["GET", "POST", "POST"])
        XCTAssertEqual(sent.map { $0.0.url?.path }, ["/api/v1/auth/identities", "/api/v1/auth/identities/apple/challenge",
                                                  "/api/v1/auth/identities/apple/complete"])
        XCTAssertTrue(sent.allSatisfy { $0.0.value(forHTTPHeaderField: "Authorization") == "Bearer current-human-jwt" })
        XCTAssertNil(sent[0].1)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(sent[1].1)) as? [String: String], [:])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(sent[2].1)) as? [String: String],
                       ["state": state, "identityToken": "apple-proof", "authorizationCode": "code"])
        let config = SentiHTTPTransportPolicy.makeProtectedReadConfiguration()
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCredentialStorage)
    }

    func test_old_or_missing_account_sends_nothing_and_late_response_is_discarded() async {
        for initial: String? in [nil, "", "old-account"] {
            let token = LinkTestToken(initial)
            let client = makeClient(token: token) { _ in (200, #"{"google":false,"apple":false,"github":true}"#) }
            if initial == "old-account" { token.set("new-account") }
            do { _ = try await client.identities(); XCTFail("expected account refusal") }
            catch { XCTAssertEqual(error as? IdentityLinkFailure, .sessionChanged) }
            XCTAssertTrue(IdentityLinkHTTP.sent.isEmpty)
        }
        let token = LinkTestToken("old-account")
        let late = makeClient(token: token) { _ in token.set("new-account"); return (200, #"{"google":false,"apple":true,"github":true}"#) }
        do { _ = try await late.identities(); XCTFail("expected late response refusal") }
        catch { XCTAssertEqual(error as? IdentityLinkFailure, .sessionChanged) }
    }

    func test_receipt_requires_apple_link_confirmation_and_never_treats_authresponse_as_link() async {
        for body in [#"{"token":"login-token","user":{"id":"other-user"}}"#,
                     #"{"provider":"google","linked":true}"#, #"{"provider":"apple","linked":false}"#,
                     "not JSON"] {
            let client = makeClient { _ in (200, body) }
            do {
                try await client.complete(AppleLinkProof(state: state, identityToken: "proof", authorizationCode: "code"))
                XCTFail("expected invalid receipt refusal")
            } catch { XCTAssertEqual(error as? IdentityLinkFailure, .unreadable) }
        }
    }

    func test_feature_off_conflict_and_auth_failures_preserve_status_without_echoing_provider_data() async {
        for status in [401, 403, 404, 409, 429, 503] {
            let client = makeClient { _ in (status, #"{"detail":"sensitive provider response must not be displayed"}"#) }
            do {
                try await client.complete(AppleLinkProof(state: state, identityToken: "proof", authorizationCode: "code"))
                XCTFail("expected HTTP refusal")
            } catch { XCTAssertEqual(error as? IdentityLinkFailure, .refused(status)) }
        }
    }

    func test_unbounded_credential_and_malformed_challenge_are_refused() async {
        let client = makeClient { _ in (200, #"{"state":"bad","nonce":"bad","expiresIn":9999}"#) }
        do { _ = try await client.challenge(); XCTFail("expected bad challenge refusal") }
        catch { XCTAssertEqual(error as? IdentityLinkFailure, .unreadable) }
        for proof in [
            AppleLinkProof(state: "not-state", identityToken: "proof", authorizationCode: "code"),
            AppleLinkProof(state: state, identityToken: String(repeating: "x", count: 16_385), authorizationCode: "code"),
            AppleLinkProof(state: state, identityToken: "proof", authorizationCode: String(repeating: "x", count: 4_097)),
        ] {
            do { try await client.complete(proof); XCTFail("expected bounded proof refusal") }
            catch { XCTAssertEqual(error as? IdentityLinkFailure, .unreadable) }
        }
        XCTAssertEqual(IdentityLinkHTTP.sent.count, 1, "only the challenge read reached the transport")
    }
}
