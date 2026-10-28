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
        let request = RoomActionRequest.reply(sessionId: "room_1", sequenceId: 1234, text: "on it", actor: "human-mrrcarter")
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
        XCTAssertTrue(key.hasPrefix("reply:room_1:1234:human-mrrcarter:"), key)
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
            RoomActionRequest(sessionId: "room_1", actionType: "pin", targetSequenceId: 1, targetActionId: nil, note: nil, idempotencyKey: "k"),
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

    init(failure: RoomSendError? = nil) { self.failure = failure }

    func sendAction(_ action: RoomActionRequest) async throws {
        lock.lock()
        sent.append(action)
        lock.unlock()
        if let failure { throw failure }
    }

    func requests() -> [RoomActionRequest] {
        lock.lock()
        defer { lock.unlock() }
        return sent
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
        role: String = "owner"
    ) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            actionSender: actions,
            membershipRole: role,
            ownAuthorIds: ["human-mrrcarter"],
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
}
