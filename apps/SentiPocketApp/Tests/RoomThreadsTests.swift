import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

// MARK: - HTTP action sender

private final class RoomActionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var captured: [(URLRequest, Data)] = []

    static func reset(status: Int) {
        lock.lock()
        self.status = status
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
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true,"duplicate":false}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class AuthMeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var body = Data()
    private static var path: String?

    static func respond(_ json: String) {
        lock.lock()
        body = Data(json.utf8)
        path = nil
        lock.unlock()
    }

    static func lastPath() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return path
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.path = request.url?.path
        let body = Self.body
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RoomActionSenderTests: XCTestCase {
    private func makeSender(status: Int = 200) -> HTTPRoomActionSender {
        RoomActionURLProtocol.reset(status: status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoomActionURLProtocol.self]
        return HTTPRoomActionSender(
            apiBaseURL: URL(string: "https://api.example.test"),
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { "user-token" }
        )
    }

    func test_a_reply_posts_the_web_action_shape() async throws {
        let sender = makeSender()
        let request = RoomActionRequest.reply(sessionId: "room_1", sequenceId: 1234, text: "on it", actor: "mrrCarter", nonce: "n-1")
        try await sender.sendAction(request)

        let (http, body) = try XCTUnwrap(RoomActionURLProtocol.requests().first)
        XCTAssertEqual(http.url?.absoluteString, "https://api.example.test/api/v1/sessions/room_1/actions")
        XCTAssertEqual(http.httpMethod, "POST")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Authorization"), "Bearer user-token")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["actionType"] as? String, "reply")
        XCTAssertEqual(json["targetSequenceId"] as? Int, 1234)
        XCTAssertEqual(json["note"] as? String, "on it")
        let key = try XCTUnwrap(json["idempotencyKey"] as? String)
        XCTAssertEqual(key, "reply:room_1:1234:mrrCarter:n-1", "the web's key; a retry with the same nonce is the same reply")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Idempotency-Key"), key)
        XCTAssertNil(json["actorId"], "the API takes the actor from the token")
    }

    func test_ack_keys_are_stable_but_likes_get_a_fresh_key_each_tap() {
        let ack1 = RoomActionRequest.reaction("ack", sessionId: "s", sequenceId: 9, actor: "human-a")
        let ack2 = RoomActionRequest.reaction("ack", sessionId: "s", sequenceId: 9, actor: "human-a")
        XCTAssertEqual(ack1.idempotencyKey, "ack:s:9:human-a", "a second ack is a duplicate, as on the web")
        XCTAssertEqual(ack1.idempotencyKey, ack2.idempotencyKey)
        let like1 = RoomActionRequest.reaction("like", sessionId: "s", sequenceId: 9, actor: "human-a")
        let like2 = RoomActionRequest.reaction("like", sessionId: "s", sequenceId: 9, actor: "human-a")
        XCTAssertNotEqual(like1.idempotencyKey, like2.idempotencyKey, "like, unlike, like again must not collapse")
        let long = RoomActionRequest.reaction("ack", sessionId: String(repeating: "x", count: 300), sequenceId: 9, actor: "a")
        XCTAssertLessThanOrEqual(long.idempotencyKey.count, 180, "the API caps the key at 180")
    }

    func test_invalid_actions_are_refused_before_the_network() async {
        let sender = makeSender()
        let invalid = [
            RoomActionRequest(sessionId: "room_1", actionType: "working_on", targetSequenceId: 1, targetActionId: nil, note: nil, idempotencyKey: "k"),
            RoomActionRequest(sessionId: "room_1", actionType: "reply", targetSequenceId: 1, targetActionId: nil, note: "  ", idempotencyKey: "k"),
            RoomActionRequest(sessionId: "room_1", actionType: "reply", targetSequenceId: 1, targetActionId: nil,
                              note: String(repeating: "a", count: RoomActionRequest.replyLimit + 1), idempotencyKey: "k"),
            RoomActionRequest(sessionId: "room_1", actionType: "like", targetSequenceId: 0, targetActionId: nil, note: nil, idempotencyKey: "k")
        ]
        for action in invalid {
            do {
                try await sender.sendAction(action)
                XCTFail("expected a refusal for \(action.actionType)")
            } catch {
                XCTAssertEqual(error as? RoomSendError, .rejected)
            }
        }
        XCTAssertTrue(RoomActionURLProtocol.requests().isEmpty)
    }

    func test_your_account_names_you_in_action_keys_as_the_web_does() {
        let github = SignedInAccount(githubUsername: "mrrCarter", accountId: "6f1c2d3e-0000-4000-8000-000000000001")
        XCTAssertEqual(github?.actorRef, "mrrCarter", "the GitHub username, as the web writes it")
        XCTAssertEqual(github?.authorId, "human-mrrcarter")
        let noLogin = SignedInAccount(githubUsername: "", accountId: "6f1c2d3e-0000-4000-8000-000000000001")
        XCTAssertEqual(noLogin?.actorRef, "6f1c2d3e-0000-4000-8000-000000000001", "no GitHub username: the account id")
        XCTAssertEqual(noLogin?.authorId, "human-6f1c2d3e-0000-4000-8000-000000000001", "as the API authors your messages")
        let odd = SignedInAccount(githubUsername: nil, accountId: "A b/c")
        XCTAssertEqual(odd?.actorRef, "A-b-c", "the web's key normalization")
        XCTAssertEqual(odd?.authorId, "human-a-b-c", "the API's author normalization")
        XCTAssertNil(SignedInAccount(githubUsername: " ", accountId: nil), "nothing names you: no shared placeholder")
    }

    func test_the_account_is_read_from_auth_me() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthMeURLProtocol.self]
        let identity = HTTPAccountIdentity(
            apiBaseURL: URL(string: "https://api.example.test"),
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { "user-token" }
        )
        AuthMeURLProtocol.respond(#"{"id":"6f1c2d3e-0000-4000-8000-000000000001","github_username":"mrrCarter","is_admin":false}"#)
        let account = await identity.currentAccount()
        XCTAssertEqual(account?.actorRef, "mrrCarter")
        XCTAssertEqual(account?.authorId, "human-mrrcarter")
        XCTAssertEqual(AuthMeURLProtocol.lastPath(), "/api/v1/auth/me")

        AuthMeURLProtocol.respond(#"{"id":"6f1c2d3e-0000-4000-8000-000000000001","github_username":""}"#)
        let noLogin = await identity.currentAccount()
        XCTAssertEqual(noLogin?.actorRef, "6f1c2d3e-0000-4000-8000-000000000001")
        XCTAssertEqual(noLogin?.authorId, "human-6f1c2d3e-0000-4000-8000-000000000001")
    }
}

// MARK: - Coordinator

private final class ActionsRoomTransport: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var projections: [RoomActionsPage]
    private let threads: [Int64: [RoomReply]]
    private(set) var actionCalls: [Int64?] = []
    let history: [RoomMessage]

    init(history: [RoomMessage], projections: [RoomActionsPage], threads: [Int64: [RoomReply]] = [:]) {
        self.history = history
        self.projections = projections
        self.threads = threads
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: beforeSequence == nil ? history : [])
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> {
        AsyncStream { _ in }
    }

    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        lock.lock()
        defer { lock.unlock() }
        actionCalls.append(targetSequenceId)
        if let target = targetSequenceId { return RoomActionsPage(replies: threads[target] ?? []) }
        return projections.count > 1 ? projections.removeFirst() : (projections.first ?? RoomActionsPage())
    }

    func calls() -> [Int64?] {
        lock.lock()
        defer { lock.unlock() }
        return actionCalls
    }
}

private final class RecordingActionSender: RoomActionSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [RoomActionRequest] = []
    private let failure: RoomSendError?
    private var failFirst: [RoomSendError]

    /// Fails every request with `failure`, or just the first ones with `failFirst`, in order.
    init(failure: RoomSendError? = nil, failFirst: [RoomSendError] = []) {
        self.failure = failure
        self.failFirst = failFirst
    }

    func sendAction(_ action: RoomActionRequest) async throws {
        lock.lock()
        sent.append(action)
        let scripted = failFirst.isEmpty ? nil : failFirst.removeFirst()
        lock.unlock()
        if let error = scripted ?? failure { throw error }
    }

    func requests() -> [RoomActionRequest] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }
}

private struct AccountStub: AccountIdentityProviding {
    let account: SignedInAccount?
    func currentAccount() async -> SignedInAccount? { account }
}

/// An account that becomes known only later (the first look fails).
private final class LateAccount: AccountIdentityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var account: SignedInAccount?

    func arrive(_ account: SignedInAccount?) {
        lock.lock()
        self.account = account
        lock.unlock()
    }

    func currentAccount() async -> SignedInAccount? {
        lock.lock()
        defer { lock.unlock() }
        return account
    }
}

@MainActor
final class RoomThreadsCoordinatorTests: XCTestCase {
    private func message(_ seq: Int64) -> RoomMessage {
        RoomMessage(
            id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: "cobalt-warden",
            authorName: "cobalt-warden", isHuman: false, text: "message \(seq)",
            timestamp: "2026-10-28T18:00:00.000000+00:00"
        )
    }

    private func makeCoordinator(
        _ transport: ActionsRoomTransport,
        actions: RecordingActionSender?,
        role: String = "owner",
        identity: (any AccountIdentityProviding)? = nil,
        ownAuthorIds: Set<String> = ["human-mrrcarter"]
    ) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            actionSender: actions,
            identity: identity,
            membershipRole: role,
            ownAuthorIds: ownAuthorIds,
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            onReauthenticationRequired: {}
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

    private func reactions(_ coordinator: RoomChatCoordinator, _ seq: Int64) -> RoomChatReactions? {
        for row in coordinator.state.rows {
            if case .message(let message) = row, message.sequenceId == seq { return message.reactions }
        }
        return nil
    }

    func test_reactions_load_after_the_room_opens_and_show_under_their_message() async {
        let transport = ActionsRoomTransport(
            history: [message(1), message(2)],
            projections: [RoomActionsPage(byTarget: [
                2: RoomReactionSummary(targetSequenceId: 2, counts: ["ack": 1, "reply": 2],
                                       actorsByType: ["ack": ["ticket-keeper"]], replyTotal: 2)
            ])]
        )
        let coordinator = makeCoordinator(transport, actions: RecordingActionSender())
        coordinator.resume()
        await waitUntil("reactions") { self.reactions(coordinator, 2) != nil }
        XCTAssertEqual(reactions(coordinator, 2)?.chips.map(\.type), ["ack"])
        XCTAssertEqual(reactions(coordinator, 2)?.ackedBy, "Acked by ticket-keeper")
        XCTAssertEqual(reactions(coordinator, 2)?.replyCount, 2)
        XCTAssertNil(reactions(coordinator, 1))
        XCTAssertTrue(coordinator.state.canReact)
        coordinator.pause()
    }

    func test_a_like_shows_at_once_posts_as_you_and_then_takes_the_server_count() async {
        let transport = ActionsRoomTransport(
            history: [message(5)],
            projections: [
                RoomActionsPage(),
                RoomActionsPage(byTarget: [5: RoomReactionSummary(targetSequenceId: 5, counts: ["like": 3], likedByViewer: true)])
            ]
        )
        let sender = RecordingActionSender()
        let coordinator = makeCoordinator(transport, actions: sender)
        coordinator.resume()
        await waitUntil("first projection") { transport.calls().count >= 1 }

        coordinator.send(.react(sequenceId: 5, type: "like"))
        XCTAssertEqual(reactions(coordinator, 5)?.chips.first, RoomChatReactions.Chip(type: "like", count: 1, isMine: true),
                       "optimistic: the tap shows before the server answers")
        await waitUntil("server count") { self.reactions(coordinator, 5)?.chips.first?.count == 3 }
        XCTAssertEqual(sender.requests().map(\.actionType), ["like"])
        XCTAssertEqual(sender.requests().first?.targetSequenceId, 5)
        coordinator.pause()
    }

    func test_opening_a_thread_loads_its_replies_and_a_reply_posts_then_reloads() async {
        let replies = [
            RoomReply(id: "r1", targetSequenceId: 9, authorId: "cobalt-warden", text: "first", createdAt: "2026-10-28T10:00:00Z"),
            RoomReply(id: "r2", targetSequenceId: 9, authorId: "human-mrrcarter", text: "mine", createdAt: "2026-10-28T10:01:00Z")
        ]
        let transport = ActionsRoomTransport(history: [message(9)], projections: [RoomActionsPage()], threads: [9: replies])
        let sender = RecordingActionSender()
        let coordinator = makeCoordinator(transport, actions: sender)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }

        coordinator.send(.openThread(sequenceId: 9))
        await waitUntil("thread loaded") { coordinator.state.thread?.isLoading == false }
        XCTAssertEqual(coordinator.state.thread?.replies.map(\.text), ["first", "mine"])
        XCTAssertEqual(coordinator.state.thread?.replies.map(\.isOwn), [false, true])
        XCTAssertEqual(coordinator.state.thread?.canReply, true)

        coordinator.send(.sendReply(sequenceId: 9, text: "  thanks  "))
        await waitUntil("reply sent") { sender.requests().count == 1 && coordinator.state.thread?.pending.isEmpty == true }
        XCTAssertEqual(sender.requests().first?.note, "thanks")
        XCTAssertEqual(sender.requests().first?.actionType, "reply")
        XCTAssertGreaterThanOrEqual(transport.calls().filter { $0 == 9 }.count, 2, "the thread reloads after a reply")

        coordinator.send(.closeThread)
        XCTAssertNil(coordinator.state.thread)
        coordinator.pause()
    }

    func test_a_viewer_can_react_but_cannot_reply() async {
        let transport = ActionsRoomTransport(history: [message(3)], projections: [RoomActionsPage()])
        let sender = RecordingActionSender()
        let coordinator = makeCoordinator(transport, actions: sender, role: "viewer")
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }
        XCTAssertTrue(coordinator.state.canReact)

        coordinator.send(.openThread(sequenceId: 3))
        await waitUntil("thread") { coordinator.state.thread != nil }
        XCTAssertEqual(coordinator.state.thread?.canReply, false)
        coordinator.send(.sendReply(sequenceId: 3, text: "hi"))
        coordinator.send(.react(sequenceId: 3, type: "ack"))
        await waitUntil("ack sent") { sender.requests().count == 1 }
        XCTAssertEqual(sender.requests().map(\.actionType), ["ack"], "the viewer's reply was never sent")
        coordinator.pause()
    }

    private func failedRetryably(_ coordinator: RoomChatCoordinator) -> Bool {
        if case .failed(_, true)? = coordinator.state.thread?.pending.first?.status { return true }
        return false
    }

    func test_an_ack_and_a_reply_are_keyed_by_your_account_as_on_the_web() async {
        let transport = ActionsRoomTransport(history: [message(3)], projections: [RoomActionsPage()])
        let sender = RecordingActionSender()
        let account = SignedInAccount(githubUsername: "mrrCarter", accountId: "6f1c2d3e-0000-4000-8000-000000000001")
        let coordinator = makeCoordinator(transport, actions: sender, identity: AccountStub(account: account), ownAuthorIds: [])
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }

        coordinator.send(.react(sequenceId: 3, type: "ack"))
        await waitUntil("ack sent") { sender.requests().count == 1 }
        XCTAssertEqual(sender.requests().first?.idempotencyKey, "ack:room_1:3:mrrCarter", "the key the web writes")

        coordinator.send(.openThread(sequenceId: 3))
        coordinator.send(.sendReply(sequenceId: 3, text: "on it"))
        await waitUntil("reply sent") { sender.requests().count == 2 }
        let replyKey = sender.requests()[1].idempotencyKey
        XCTAssertTrue(replyKey.hasPrefix("reply:room_1:3:mrrCarter:"), replyKey)
        coordinator.pause()
    }

    func test_nothing_is_sent_under_a_placeholder_name_while_you_are_unknown() async {
        let transport = ActionsRoomTransport(history: [message(3)], projections: [RoomActionsPage()])
        let sender = RecordingActionSender()
        let coordinator = makeCoordinator(transport, actions: sender, identity: AccountStub(account: nil), ownAuthorIds: [])
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }

        coordinator.send(.openThread(sequenceId: 3))
        coordinator.send(.sendReply(sequenceId: 3, text: "hello"))
        await waitUntil("held for retry") { self.failedRetryably(coordinator) }
        XCTAssertEqual(coordinator.state.thread?.pending.first?.text, "hello")
        XCTAssertTrue(sender.requests().isEmpty)
        coordinator.pause()
    }

    func test_a_failed_reply_keeps_its_text_and_a_retry_resends_the_same_key() async {
        let transport = ActionsRoomTransport(history: [message(9)], projections: [RoomActionsPage()])
        let sender = RecordingActionSender(failFirst: [.retryable(retryAfterSeconds: nil)])
        let coordinator = makeCoordinator(transport, actions: sender)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }

        coordinator.send(.openThread(sequenceId: 9))
        coordinator.send(.sendReply(sequenceId: 9, text: "on it"))
        await waitUntil("failed") { self.failedRetryably(coordinator) }
        XCTAssertEqual(coordinator.state.thread?.pending.first?.text, "on it")
        let clientId = coordinator.state.thread?.pending.first?.clientId ?? ""

        coordinator.send(.retrySend(clientId: clientId))
        await waitUntil("sent") { sender.requests().count == 2 && coordinator.state.thread?.pending.isEmpty == true }
        XCTAssertEqual(sender.requests()[0].idempotencyKey, sender.requests()[1].idempotencyKey,
                       "a retry is the same reply to the API")
        coordinator.pause()
    }

    func test_a_retry_keeps_the_name_its_first_attempt_used_even_if_your_account_loads_in_between() async {
        let transport = ActionsRoomTransport(history: [message(9)], projections: [RoomActionsPage()])
        let sender = RecordingActionSender(failFirst: [.retryable(retryAfterSeconds: nil)])
        let account = LateAccount()
        let coordinator = makeCoordinator(transport, actions: sender, identity: account)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }

        coordinator.send(.openThread(sequenceId: 9))
        coordinator.send(.sendReply(sequenceId: 9, text: "on it"))
        await waitUntil("failed") { self.failedRetryably(coordinator) }
        account.arrive(SignedInAccount(githubUsername: "mrrCarter", accountId: "6f1c2d3e-0000-4000-8000-000000000001"))
        coordinator.send(.retrySend(clientId: coordinator.state.thread?.pending.first?.clientId ?? ""))
        await waitUntil("sent") { sender.requests().count == 2 }
        XCTAssertEqual(sender.requests()[0].idempotencyKey, sender.requests()[1].idempotencyKey,
                       "the first attempt went out as mrrcarter; the retry must be the same request")
        XCTAssertTrue(sender.requests()[0].idempotencyKey.contains(":mrrcarter:"))
        coordinator.pause()
    }

    func test_closing_a_thread_keeps_its_unsent_replies_for_when_it_reopens() async {
        let transport = ActionsRoomTransport(history: [message(9), message(10)], projections: [RoomActionsPage()])
        let sender = RecordingActionSender(failure: .retryable(retryAfterSeconds: nil))
        let coordinator = makeCoordinator(transport, actions: sender)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }

        coordinator.send(.openThread(sequenceId: 9))
        coordinator.send(.sendReply(sequenceId: 9, text: "keep me"))
        await waitUntil("failed") { self.failedRetryably(coordinator) }
        coordinator.send(.closeThread)
        XCTAssertNil(coordinator.state.thread)

        coordinator.send(.openThread(sequenceId: 10))
        XCTAssertEqual(coordinator.state.thread?.pending.isEmpty, true, "a reply shows only under its own thread")
        coordinator.send(.closeThread)
        coordinator.send(.openThread(sequenceId: 9))
        XCTAssertEqual(coordinator.state.thread?.pending.map(\.text), ["keep me"])
        coordinator.pause()
    }

    func test_a_reply_over_the_limit_keeps_every_character_and_is_never_sent() async {
        let transport = ActionsRoomTransport(history: [message(9)], projections: [RoomActionsPage()])
        let sender = RecordingActionSender()
        let coordinator = makeCoordinator(transport, actions: sender)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }

        coordinator.send(.openThread(sequenceId: 9))
        let long = String(repeating: "r", count: RoomActionRequest.replyLimit + 1)
        XCTAssertNotNil(coordinator.state.thread?.replyLengthProblem(for: long), "the reply box holds it")
        coordinator.send(.sendReply(sequenceId: 9, text: long))
        XCTAssertEqual(coordinator.state.thread?.pending.first?.text.count, RoomActionRequest.replyLimit + 1)
        XCTAssertTrue(sender.requests().isEmpty)
        coordinator.pause()
    }
}
