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
        XCTAssertNil(sent["templateId"], "a kind of the phone's own carries no templateId")
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

    /// A chat started from one of the server's ways to start sends its templateId and never a roomType: the server
    /// derives the type, and refuses the two together.
    func test_a_way_to_start_sends_its_templateId_and_no_roomType() async throws {
        CreateURLProtocol.reset(status: 200, answer: #"{"ok":true,"sessionId":"server-id"}"#)
        let template = RoomTemplate(id: "sample-week", name: "Sample week", roomType: "study")
        let id = try await sender().create(title: "Exam prep", start: NewChatChoice.template(template).start)
        XCTAssertEqual(id, "server-id")
        let (request, body) = try XCTUnwrap(CreateURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/sessions")
        let sent = json(body)
        XCTAssertEqual(sent["templateId"] as? String, "sample-week")
        XCTAssertNil(sent["roomType"], "the server derives the type; a roomType beside a templateId is refused")
        XCTAssertEqual(sent["title"] as? String, "Exam prep")
        XCTAssertEqual(sent["visibility"] as? String, "private")
        XCTAssertEqual(sent["maxMembers"] as? Int, 25)
        let sessionId = try XCTUnwrap(sent["sessionId"] as? String)
        let key = try XCTUnwrap(request.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sentinelayer-Session-Mutation"), "session-mutation")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-Token"),
                       SessionMutationCSRF.token(bearer: "test-bearer-token", sessionId: sessionId,
                                                 routeTemplate: "POST /api/v1/sessions", idempotencyKey: key),
                       "signed as every new room is")
    }

    /// Blank is the general chat every chat was before: neither a templateId nor a roomType.
    func test_blank_sends_neither_a_templateId_nor_a_roomType() async throws {
        CreateURLProtocol.reset(status: 200, answer: #"{"ok":true}"#)
        _ = try await sender().create(title: "Team", start: NewChatChoice.blank.start)
        let (_, body) = try XCTUnwrap(CreateURLProtocol.requests().first)
        XCTAssertNil(json(body)["templateId"])
        XCTAssertNil(json(body)["roomType"])
    }

    func test_start_with_is_blank_first_then_the_servers_in_its_order_and_none_offered_keeps_the_kinds() {
        let a = RoomTemplate(id: "sample-a", name: "Sample A")
        let b = RoomTemplate(id: "sample-b", name: "Sample B")
        XCTAssertEqual(NewChatChoice.startWith([a, b]), [.blank, .template(a), .template(b)])
        XCTAssertNil(NewChatChoice.startWith(nil), "none offered (a 404, or no answer yet): the phone's own kinds")
        XCTAssertNil(NewChatChoice.startWith([]), "an empty list offers none either")
    }

    func test_each_card_starts_the_chat_it_shows() {
        let a = RoomTemplate(id: "sample-a", name: "Sample A", symbol: "calendar", summary: "One line.")
        XCTAssertEqual(NewChatChoice.blank.start, .kind(.general))
        XCTAssertEqual(NewChatChoice.template(a).start, .template(id: "sample-a"))
        XCTAssertEqual(NewChatChoice.blank.untitled, "New chat")
        XCTAssertEqual(NewChatChoice.template(a).untitled, "Sample A", "an unnamed chat takes its way to start's name")
        XCTAssertEqual(NewChatChoice.template(a).symbol, "calendar")
        let unknown = RoomTemplate(id: "sample-b", name: "Sample B", symbol: "no.such.symbol.anywhere")
        XCTAssertEqual(NewChatChoice.template(unknown).symbol, NewChatChoice.plainSymbol,
                       "a symbol this phone doesn't have draws a plain one, never nothing")
    }

    /// A New agent's chat goes out under the id and key kept with its start, every time: private, general, for four.
    func test_a_new_agents_chat_is_made_under_its_kept_id_and_key() async throws {
        CreateURLProtocol.reset(status: 200, answer: #"{"ok":true,"sessionId":"chat-kept"}"#)
        try await sender().createAgentChat(sessionId: "chat-kept", title: "reviewer · Review it", idempotencyKey: "create-kept")
        let (request, body) = try XCTUnwrap(CreateURLProtocol.requests().first)
        XCTAssertEqual(request.url?.path, "/api/v1/sessions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "create-kept")
        let sent = json(body)
        XCTAssertEqual(sent["sessionId"] as? String, "chat-kept")
        XCTAssertEqual(sent["title"] as? String, "reviewer · Review it")
        XCTAssertEqual(sent["visibility"] as? String, "private")
        XCTAssertEqual(sent["maxMembers"] as? Int, 4)
        XCTAssertNil(sent["roomType"], "a general room")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-Token"),
                       SessionMutationCSRF.token(bearer: "test-bearer-token", sessionId: "chat-kept",
                                                 routeTemplate: "POST /api/v1/sessions", idempotencyKey: "create-kept"))
    }

    /// The agent is sent to the id kept with its start: a chat the API made under any other id is not that chat.
    func test_a_chat_made_under_another_id_is_not_the_new_agents() async {
        CreateURLProtocol.reset(status: 200, answer: #"{"ok":true,"sessionId":"another-room"}"#)
        do {
            try await sender().createAgentChat(sessionId: "chat-kept", title: "x", idempotencyKey: "create-kept")
            XCTFail("the agent would go to a chat that is not the one made")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .rejected)
        }
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

/// Answers the ways to start from the test, one answer per read.
private final class ScriptedTemplates: RoomTemplatesServing, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<[RoomTemplate], RoomTemplatesError>]
    private var count = 0

    init(_ answers: [Result<[RoomTemplate], RoomTemplatesError>]) {
        self.answers = answers
    }

    var asked: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func templates() async throws -> [RoomTemplate] {
        try next().get()
    }

    private func next() -> Result<[RoomTemplate], RoomTemplatesError> {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return answers.removeFirst()
    }
}

/// New chat's ways to start show once the server lists them, and where it offers none the phone keeps its own kinds and
/// says nothing about it.
@MainActor
final class RoomTemplatesCenterTests: XCTestCase {
    func test_ways_to_start_show_once_offered_and_go_quietly_when_the_server_stops_offering_them() async {
        let a = RoomTemplate(id: "sample-a", name: "Sample A")
        let client = ScriptedTemplates([.success([a]), .failure(.retryable), .failure(.unavailable), .success([])])
        var signIns = 0
        let center = RoomTemplatesCenter(client: client, onReauthenticationRequired: { signIns += 1 })
        XCTAssertNil(center.templates, "nothing before the server answers: the phone's own kinds")
        await center.refresh()
        XCTAssertEqual(center.templates, [a])
        await center.refresh()
        XCTAssertEqual(center.templates, [a], "a failure that says nothing either way keeps what was read")
        await center.refresh()
        XCTAssertNil(center.templates, "a 404 or 403: none offered any more, and nothing to show the person")
        await center.refresh()
        XCTAssertNil(center.templates, "an empty list offers none")
        XCTAssertEqual(signIns, 0)
        XCTAssertEqual(client.asked, 4)
    }

    func test_a_refused_sign_in_asks_to_sign_in_again_and_a_preview_never_asks() async {
        let client = ScriptedTemplates([.failure(.reauthenticationRequired)])
        var signIns = 0
        let center = RoomTemplatesCenter(client: client, onReauthenticationRequired: { signIns += 1 })
        await center.refresh()
        XCTAssertEqual(signIns, 1)
        XCTAssertNil(center.templates)
        let preview = RoomTemplatesCenter(client: nil)
        await preview.refresh()
        XCTAssertNil(preview.templates, "no client: New chat shows the phone's own kinds")
    }

    func test_a_fresh_read_is_not_asked_again() async {
        let a = RoomTemplate(id: "sample-a", name: "Sample A")
        let client = ScriptedTemplates([.success([a]), .success([])])
        let center = RoomTemplatesCenter(client: client)
        await center.refresh()
        await center.refresh(ifOlderThan: RoomTemplatesCenter.freshness)
        XCTAssertEqual(client.asked, 1, "read moments ago: not asked again")
        XCTAssertEqual(center.templates, [a])
    }
}
