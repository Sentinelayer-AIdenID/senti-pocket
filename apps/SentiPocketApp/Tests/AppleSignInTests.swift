import XCTest
@testable import SentiPocketApp

/// Sign in with Apple's API half: the exact route and body, and only a real token reaches the Keychain.
@MainActor
final class AppleSignInTests: XCTestCase {
    private final class Saved { var tokens: [String] = [] }

    private func makeAuth(saved: Saved, status: Int, body: String) -> SentiNativeAuth {
        AppleSignInURLProtocol.reset(status: status, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppleSignInURLProtocol.self]
        return SentiNativeAuth(apiBaseURL: URL(string: "https://api.example.test")!, appVersion: "1",
                               urlSession: URLSession(configuration: configuration),
                               saveToken: { saved.tokens.append($0) })
    }

    func test_the_api_gets_the_apple_credential_and_raw_nonce_and_the_token_is_kept() async throws {
        let saved = Saved()
        let auth = makeAuth(saved: saved, status: 200, body: #"{"token":"session-1","user":{"id":"u1"}}"#)
        try await auth.finishAppleSignIn(identityToken: "id-token", authorizationCode: "code-1", nonce: "raw-nonce")
        let last = try XCTUnwrap(AppleSignInURLProtocol.last())
        XCTAssertEqual(last.request.httpMethod, "POST")
        XCTAssertEqual(last.request.url?.absoluteString, "https://api.example.test/api/v1/auth/apple/native")
        let body = try XCTUnwrap(last.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["identityToken": "id-token", "authorizationCode": "code-1", "nonce": "raw-nonce"])
        XCTAssertEqual(saved.tokens, ["session-1"])
    }

    /// The browser sign-in's poll: an expired session the server no longer knows starts over cleanly; other refusals
    /// stay the server's.
    func test_a_poll_for_a_sign_in_the_server_no_longer_knows_is_a_clean_start_over() {
        XCTAssertEqual(SentiNativeAuth.pollRefusal(404), .rejected)
        XCTAssertEqual(SentiNativeAuth.pollRefusal(410), .rejected)
        XCTAssertEqual(SentiNativeAuth.pollRefusal(403), .refused(403))
        XCTAssertEqual(SentiNativeAuth.pollRefusal(500), .refused(500))
    }

    func test_a_refusal_or_an_empty_token_keeps_nothing() async {
        let answers: [(Int, String, NativeAuthError)] = [
            (404, #"{"detail":"Not Found"}"#, .refused(404)),
            (401, #"{"detail":"x"}"#, .refused(401)),
            (429, "{}", .rateLimited),
            (200, #"{"token":""}"#, .malformedResponse),
            (200, "not json", .malformedResponse)
        ]
        for (status, body, expected) in answers {
            let saved = Saved()
            let auth = makeAuth(saved: saved, status: status, body: body)
            do {
                try await auth.finishAppleSignIn(identityToken: "id-token", authorizationCode: "c", nonce: "n")
                XCTFail("\(status) \(body) must fail")
            } catch {
                XCTAssertEqual(error as? NativeAuthError, expected, "\(status) \(body)")
            }
            XCTAssertTrue(saved.tokens.isEmpty, "\(status) \(body)")
        }
    }

    func test_the_nonce_is_fresh_and_apple_gets_its_lowercase_sha256() {
        let first = AppleSignInNonce.make(), second = AppleSignInNonce.make()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, 43)
        XCTAssertTrue(first.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        XCTAssertEqual(AppleSignInNonce.digest("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func test_apple_is_offered_only_for_a_boolean_true() {
        XCTAssertTrue(AppleSignInSetting.isEnabled(in: ["SentiAppleSignIn": true]))
        XCTAssertFalse(AppleSignInSetting.isEnabled(in: ["SentiAppleSignIn": false]))
        XCTAssertFalse(AppleSignInSetting.isEnabled(in: ["SentiAppleSignIn": "true"]))
        XCTAssertFalse(AppleSignInSetting.isEnabled(in: ["SentiAppleSignIn": NSNumber(value: 1)]))
        XCTAssertFalse(AppleSignInSetting.isEnabled(in: [:]))
        XCTAssertFalse(AppleSignInSetting.isEnabled(in: nil))
        XCTAssertTrue(AppleSignInSetting.isEnabled(in: Bundle.main.infoDictionary), "this build offers it")
    }
}

private final class AppleSignInURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var answer: (status: Int, body: Data) = (200, Data())
    private static var captured: (request: URLRequest, body: Data?)?

    static func reset(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        answer = (status, Data(body.utf8))
        captured = nil
    }

    static func last() -> (request: URLRequest, body: Data?)? {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured = (request, Self.body(of: request))
        let answer = Self.answer
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
