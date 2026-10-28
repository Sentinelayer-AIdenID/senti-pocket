import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

// MARK: - HTTP sender

private final class RoomSendURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var headers: [String: String] = [:]
    private static var captured: [URLRequest] = []
    private static var bodies: [Data] = []

    static func reset(status: Int, headers: [String: String] = [:]) {
        lock.lock()
        self.status = status
        self.headers = headers
        captured = []
        bodies = []
        lock.unlock()
    }

    static func requests() -> [(URLRequest, Data)] {
        lock.lock()
        defer { lock.unlock() }
        return Array(zip(captured, bodies))
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
        Self.captured.append(request)
        Self.bodies.append(body)
        let status = Self.status
        let headers = Self.headers
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RoomMessageSenderTests: XCTestCase {
    private func makeSender(status: Int, headers: [String: String] = [:], token: String? = "user-token") -> HTTPRoomMessageSender {
        RoomSendURLProtocol.reset(status: status, headers: headers)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoomSendURLProtocol.self]
        return HTTPRoomMessageSender(
            apiBaseURL: URL(string: "https://api.example.test"),
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { token }
        )
    }

    func test_posts_the_web_human_message_shape_with_the_client_id_as_idempotency_key() async throws {
        let sender = makeSender(status: 200)
        try await sender.sendHumanMessage(sessionId: "room_1", text: "hello @cobalt-warden", clientId: "hm_abc")

        let (request, body) = try XCTUnwrap(RoomSendURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/api/v1/sessions/room_1/human-message")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "hm_abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["text": "hello @cobalt-warden", "clientId": "hm_abc"],
                       "no author field: the API authors human messages itself")
    }

    func test_status_classes_map_to_retry_or_stop() async {
        let cases: [(Int, [String: String], RoomSendError)] = [
            (401, [:], .reauthenticationRequired),
            (403, [:], .notAllowed),
            (404, [:], .notAllowed),
            (429, ["Retry-After": "7"], .retryable(retryAfterSeconds: 7)),
            (503, [:], .retryable(retryAfterSeconds: nil)),
            (409, [:], .retryable(retryAfterSeconds: nil)),
            (422, [:], .rejected)
        ]
        for (status, headers, expected) in cases {
            let sender = makeSender(status: status, headers: headers)
            do {
                try await sender.sendHumanMessage(sessionId: "room_1", text: "x", clientId: "hm_1")
                XCTFail("status \(status) should throw")
            } catch {
                XCTAssertEqual(error as? RoomSendError, expected, "status \(status)")
            }
        }
    }

    func test_refuses_before_the_network_without_a_token_or_with_an_oversized_body() async {
        let noToken = makeSender(status: 200, token: nil)
        do {
            try await noToken.sendHumanMessage(sessionId: "room_1", text: "x", clientId: "hm_1")
            XCTFail("expected reauth")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .reauthenticationRequired)
        }
        let sender = makeSender(status: 200)
        do {
            let huge = String(repeating: "a", count: HTTPRoomMessageSender.maximumLength + 1)
            try await sender.sendHumanMessage(sessionId: "room_1", text: huge, clientId: "hm_1")
            XCTFail("expected rejected")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .rejected)
        }
        XCTAssertTrue(RoomSendURLProtocol.requests().isEmpty)
    }

    func test_room_stream_session_outlives_the_server_keepalive() {
        let configuration = SentiHTTPTransportPolicy.makeRoomStreamConfiguration()
        XCTAssertGreaterThan(configuration.timeoutIntervalForRequest, 15, "idle deadline above the 15s keep-alive")
        XCTAssertGreaterThanOrEqual(configuration.timeoutIntervalForResource, 3_600)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
    }
}

// MARK: - Coordinator

private final class QuietRoomTransport: RoomTransport, @unchecked Sendable {
    let history: [RoomMessage]
    init(history: [RoomMessage] = []) { self.history = history }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: beforeSequence == nil ? history : [])
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> {
        AsyncStream { _ in }
    }
}

private final class ScriptedSender: RoomMessageSending, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Void, RoomSendError>]
    private(set) var calls: [(text: String, clientId: String)] = []

    init(_ results: [Result<Void, RoomSendError>]) { self.results = results }

    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        let result: Result<Void, RoomSendError> = {
            lock.lock()
            defer { lock.unlock() }
            calls.append((text, clientId))
            return results.isEmpty ? .success(()) : results.removeFirst()
        }()
        try result.get()
    }

    func snapshot() -> [(text: String, clientId: String)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private struct FixedIdentity: AccountIdentityProviding {
    let authorId: String?
    func currentAuthorId() async -> String? { authorId }
}

@MainActor
final class RoomComposerCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        sender: ScriptedSender?,
        role: String = "owner",
        identity: (any AccountIdentityProviding)? = nil,
        onReauth: @escaping @MainActor () -> Void = {}
    ) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: QuietRoomTransport(),
            sender: sender,
            identity: identity,
            membershipRole: role,
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            onReauthenticationRequired: onReauth
        )
    }

    private func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    private func echo(_ text: String, clientId: String, seq: Int64, author: String = "human-mrrcarter") -> RoomMessage {
        RoomMessage(
            id: "evt-\(seq)",
            sequenceId: seq,
            kind: .message,
            authorId: author,
            authorName: "mrrCarter",
            isHuman: true,
            text: text,
            timestamp: "2026-10-28T19:00:00.000000+00:00",
            clientMessageId: clientId
        )
    }

    func test_a_sent_message_shows_pending_then_is_replaced_by_its_echo() async {
        let sender = ScriptedSender([.success(())])
        let coordinator = makeCoordinator(sender: sender)
        coordinator.resume()
        XCTAssertEqual(coordinator.state.composer, .enabled)

        coordinator.send(.sendMessage(text: "  ship it  "))
        XCTAssertEqual(coordinator.state.pending.first?.text, "ship it", "the text is trimmed")
        await waitUntil("sent") { coordinator.state.pending.first?.status == .sent }

        let clientId = sender.snapshot()[0].clientId
        XCTAssertTrue(clientId.hasPrefix("hm_"))
        coordinator.handle(.message(echo("ship it", clientId: clientId, seq: 50)))
        XCTAssertTrue(coordinator.state.pending.isEmpty, "the room's own copy replaces the pending row")
        XCTAssertTrue(coordinator.state.ownMentionHandles.contains("mrrcarter"), "your echo teaches the app who you are")
        coordinator.pause()
    }

    func test_a_failed_send_can_be_retried_with_the_same_client_id_and_discarded() async {
        let sender = ScriptedSender([.failure(.retryable(retryAfterSeconds: nil)), .success(())])
        let coordinator = makeCoordinator(sender: sender)
        coordinator.resume()

        coordinator.send(.sendMessage(text: "hello"))
        await waitUntil("failed") {
            if case .failed(_, true)? = coordinator.state.pending.first?.status { return true }
            return false
        }
        let clientId = coordinator.state.pending[0].clientId
        coordinator.send(.retrySend(clientId: clientId))
        await waitUntil("sent on retry") { coordinator.state.pending.first?.status == .sent }
        XCTAssertEqual(sender.snapshot().map(\.clientId), [clientId, clientId], "a retry reuses the client id")

        coordinator.send(.discardSend(clientId: clientId))
        XCTAssertTrue(coordinator.state.pending.isEmpty)
        coordinator.pause()
    }

    func test_viewers_cannot_post_and_a_server_refusal_disables_the_composer() async {
        let viewer = makeCoordinator(sender: ScriptedSender([]), role: "viewer")
        XCTAssertFalse(viewer.state.composer.canPost)
        XCTAssertEqual(viewer.state.composer.disabledReason, RoomChatCoordinator.viewerReason)
        viewer.send(.sendMessage(text: "hi"))
        XCTAssertTrue(viewer.state.pending.isEmpty, "a viewer's send is ignored")

        let refused = ScriptedSender([.failure(.notAllowed)])
        let coordinator = makeCoordinator(sender: refused)
        coordinator.resume()
        coordinator.send(.sendMessage(text: "hi"))
        await waitUntil("refused") { !coordinator.state.composer.canPost }
        if case .failed(_, let canRetry)? = coordinator.state.pending.first?.status {
            XCTAssertFalse(canRetry, "a refused post is not retryable")
        } else {
            XCTFail("expected a failed pending row")
        }
        coordinator.pause()
    }

    func test_an_expired_token_on_send_asks_for_sign_in() async {
        var asked = 0
        let coordinator = makeCoordinator(sender: ScriptedSender([.failure(.reauthenticationRequired)])) { asked += 1 }
        coordinator.resume()
        coordinator.send(.sendMessage(text: "hi"))
        await waitUntil("reauth asked") { asked == 1 }
        coordinator.pause()
    }

    func test_identity_is_learned_from_the_account_and_no_sender_hides_the_composer() async {
        let coordinator = makeCoordinator(sender: nil, identity: FixedIdentity(authorId: "human-mrrcarter"))
        XCTAssertEqual(coordinator.state.composer, .hidden)
        coordinator.resume()
        await waitUntil("identity") { coordinator.state.ownMentionHandles.contains("mrrcarter") }
        XCTAssertTrue(coordinator.state.ownMentionHandles.contains("all"))
        coordinator.pause()
    }
}
