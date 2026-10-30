import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class CreateURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var answer = Data("{}".utf8)
    private static var captured: [(URLRequest, Data)] = []

    static func reset(status: Int, answer: String = "{}") {
        lock.lock()
        self.status = status
        self.answer = Data(answer.utf8)
        captured = []
        lock.unlock()
    }

    static func requests() -> [(URLRequest, Data)] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.captured.append((request, body))
        let status = Self.status
        let answer = Self.answer
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Carter, #55287 ("rooms optimized just for specific things like study together") and #55414 (invites): the new
/// writes are signed exactly as the API checks them.
final class RoomCreateTests: XCTestCase {
    private func sender() -> HTTPRoomMessageSender {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CreateURLProtocol.self]
        return HTTPRoomMessageSender(apiBaseURL: URL(string: "https://api.example.invalid"),
                                     urlSession: URLSession(configuration: configuration),
                                     tokenProvider: { "test-bearer-token" })
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func test_a_new_room_is_a_signed_create_of_its_type() async throws {
        CreateURLProtocol.reset(status: 200, answer: #"{"ok":true,"sessionId":"server-id"}"#)
        let id = try await sender().create(title: "Exam prep", kind: .study)
        XCTAssertEqual(id, "server-id")
        let (request, body) = try XCTUnwrap(CreateURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/sessions")
        let sent = json(body)
        XCTAssertEqual(sent["title"] as? String, "Exam prep")
        XCTAssertEqual(sent["roomType"] as? String, "study")
        XCTAssertEqual(sent["visibility"] as? String, "private")
        XCTAssertEqual(sent["maxMembers"] as? Int, 25)
        let sessionId = try XCTUnwrap(sent["sessionId"] as? String)
        let key = try XCTUnwrap(request.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sentinelayer-Session-Mutation"), "session-mutation")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-Token"),
                       SessionMutationCSRF.token(bearer: "test-bearer-token", sessionId: sessionId,
                                                 routeTemplate: "POST /api/v1/sessions", idempotencyKey: key),
                       "signed over the new room's id and the create route")
    }

    func test_a_general_room_leaves_the_type_to_the_api_default() async throws {
        CreateURLProtocol.reset(status: 200, answer: #"{"ok":true}"#)
        let id = try await sender().create(title: "Team", kind: .general)
        let (_, body) = try XCTUnwrap(CreateURLProtocol.requests().first)
        XCTAssertNil(json(body)["roomType"], "general is the default, so it isn't sent")
        XCTAssertEqual(json(body)["sessionId"] as? String, id, "the id made here is the room's when the API echoes none")
    }

    func test_a_refused_create_says_so() async {
        CreateURLProtocol.reset(status: 403)
        do {
            _ = try await sender().create(title: "x", kind: .general)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .notAllowed)
        }
    }

    func test_invites_are_signed_over_their_routes() async throws {
        CreateURLProtocol.reset(status: 200, answer: #"{"inviteUrl":"https://sentinelayer.com/dashboard/sessions/r1?invite=t"}"#)
        let link = try await sender().createInviteLink(sessionId: "r1", role: .viewer)
        XCTAssertEqual(link.absoluteString, "https://sentinelayer.com/dashboard/sessions/r1?invite=t")
        var (request, body) = try XCTUnwrap(CreateURLProtocol.requests().last)
        XCTAssertEqual(request.url?.path, "/api/v1/sessions/r1/invitations/join-links")
        XCTAssertEqual(json(body)["role"] as? String, "viewer")
        var key = try XCTUnwrap(request.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-Token"),
                       SessionMutationCSRF.token(bearer: "test-bearer-token", sessionId: "r1",
                                                 routeTemplate: "POST /api/v1/sessions/{session_id}/invitations/join-links",
                                                 idempotencyKey: key))

        CreateURLProtocol.reset(status: 200, answer: #"{"member":{"githubLogin":"simone"}}"#)
        let outcome = try await sender().invite(sessionId: "r1", who: "simone", role: .contributor)
        XCTAssertEqual(outcome, .added("simone"))
        (request, body) = try XCTUnwrap(CreateURLProtocol.requests().last)
        XCTAssertEqual(request.url?.path, "/api/v1/sessions/r1/members")
        XCTAssertEqual(json(body)["userIdentifier"] as? String, "simone")
        key = try XCTUnwrap(request.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-Token"),
                       SessionMutationCSRF.token(bearer: "test-bearer-token", sessionId: "r1",
                                                 routeTemplate: "POST /api/v1/sessions/{session_id}/members",
                                                 idempotencyKey: key))
    }
}
