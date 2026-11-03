import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

// MARK: - HTTP action sender

private final class EmojiActionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var answer = Data(#"{"ok":true}"#.utf8)
    private static var captured: [(URLRequest, Data)] = []

    static func reset(status: Int, body: String = #"{"ok":true}"#) {
        lock.lock()
        self.status = status
        answer = Data(body.utf8)
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

final class RoomEmojiActionSenderTests: XCTestCase {
    private func makeSender(status: Int = 200, body: String = #"{"ok":true}"#) -> HTTPRoomActionSender {
        EmojiActionURLProtocol.reset(status: status, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmojiActionURLProtocol.self]
        return HTTPRoomActionSender(
            apiBaseURL: URL(string: "https://api.example.test"),
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { "user-token" }
        )
    }

    private func body(_ index: Int = 0) throws -> [String: Any] {
        let (_, data) = try XCTUnwrap(EmojiActionURLProtocol.requests().dropFirst(index).first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_react_and_unreact_post_the_emoji_as_metadata_on_the_like_route() async throws {
        let sender = makeSender()
        try await sender.sendAction(.emoji("🎉", isOn: true, sessionId: "room_1", sequenceId: 42, actor: "alex"))
        try await sender.sendAction(.emoji("🎉", isOn: false, sessionId: "room_1", sequenceId: 42, actor: "alex"))
        try await sender.sendAction(.emoji("🎉", isOn: true, sessionId: "room_1", sequenceId: 42, actor: "alex"))

        let (http, _) = try XCTUnwrap(EmojiActionURLProtocol.requests().first)
        XCTAssertEqual(http.url?.absoluteString, "https://api.example.test/api/v1/sessions/room_1/actions")
        XCTAssertEqual(http.httpMethod, "POST")
        let react = try body(0)
        XCTAssertEqual(react["actionType"] as? String, "react")
        XCTAssertEqual(react["targetSequenceId"] as? Int, 42)
        XCTAssertEqual(react["metadata"] as? [String: String], ["emoji": "🎉"])
        XCTAssertNil(react["targetActionId"])
        XCTAssertNil(react["note"])
        let unreact = try body(1)
        XCTAssertEqual(unreact["actionType"] as? String, "unreact")
        XCTAssertEqual(unreact["metadata"] as? [String: String], ["emoji": "🎉"])
        let reactAgain = try body(2)
        let keys = [react, unreact, reactAgain].compactMap { $0["idempotencyKey"] as? String }
        XCTAssertEqual(keys.count, 3)
        XCTAssertNotEqual(keys[0], keys[2], "the same emoji reacted again has its own key: react, unreact, react never collapse")
        XCTAssertTrue(keys[0].hasPrefix("react:room_1:42:alex:"), keys[0])
        XCTAssertTrue(keys.allSatisfy { $0.unicodeScalars.allSatisfy(\.isASCII) }, "the emoji never goes in a header")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Idempotency-Key"), keys[0])
    }

    func test_an_emoji_on_a_reply_shown_in_the_room_targets_the_reply() async throws {
        let sender = makeSender()
        try await sender.sendAction(.emoji("👀", isOn: true, sessionId: "room_1", sequenceId: 42, actor: "a", toReply: "r-1"))
        let json = try body()
        XCTAssertEqual(json["targetSequenceId"] as? Int, 42, "the thread's message")
        XCTAssertEqual(json["targetActionId"] as? String, "r-1", "the reply itself")
        XCTAssertEqual(json["metadata"] as? [String: String], ["emoji": "👀"])
    }

    func test_an_emoji_reaction_without_exactly_one_emoji_is_refused_before_the_network() async {
        let sender = makeSender()
        var noEmoji = RoomActionRequest.emoji("🎉", isOn: true, sessionId: "room_1", sequenceId: 1, actor: "a")
        noEmoji.emoji = nil
        let invalid = [
            RoomActionRequest.emoji("@all", isOn: true, sessionId: "room_1", sequenceId: 1, actor: "a"),
            RoomActionRequest.emoji("abc", isOn: false, sessionId: "room_1", sequenceId: 1, actor: "a"),
            noEmoji
        ]
        for action in invalid {
            do {
                try await sender.sendAction(action)
                XCTFail("expected a refusal for \(action.emoji ?? "no emoji")")
            } catch {
                XCTAssertEqual(error as? RoomSendError, .rejected)
            }
        }
        XCTAssertTrue(EmojiActionURLProtocol.requests().isEmpty)
    }

    func test_a_refused_emoji_reaction_is_read_by_its_code_then_its_status() async {
        let validation = #"{"detail":[{"loc":["body","actionType"],"msg":"Value error, unsupported message action type"}]}"#
        let cases: [(Int, String, Error, String)] = [
            (409, #"{"error":{"code":"EMOJI_MESSAGE_LIMIT","message":"Message has 20"}}"#, RoomEmojiRefusal.full,
             "the message holds 20 emoji"),
            (409, #"{"detail":{"error":{"code":"EMOJI_ACTOR_LIMIT"}}}"#, RoomEmojiRefusal.full, "10 of yours, wrapped"),
            (409, #"{"detail":{"code":"EMOJI_ACTOR_LIMIT"}}"#, RoomEmojiRefusal.full, "10 of yours, as detail.code"),
            (409, #"{"error":{"code":"REACTION_NOT_ACTIVE"}}"#, RoomEmojiRefusal.notActive, "nothing of yours to take back"),
            (409, #"{"error":{"code":"IDEMPOTENCY_KEY_CONFLICT"}}"#, RoomSendError.retryable(retryAfterSeconds: nil),
             "another conflict is not a full message"),
            (409, "", RoomSendError.retryable(retryAfterSeconds: nil), "a 409 without a code is not a full message"),
            (422, validation, RoomEmojiRefusal.unavailable, "an API without the action type refuses it in validation"),
            (422, #"{"error":{"code":"INVALID_SESSION_TITLE"}}"#, RoomEmojiRefusal.unavailable, "a 422 with no emoji code"),
            (400, #"{"error":{"code":"INVALID_REQUEST","message":"unsupported message action type"}}"#,
             RoomEmojiRefusal.unavailable, "a 400 naming the action type"),
            (400, #"{"error":{"code":"INVALID_REQUEST","message":"emoji must be exactly one emoji"}}"#,
             RoomSendError.rejected, "a 400 about the request itself"),
            (401, "", RoomSendError.reauthenticationRequired, "sign in again"),
            (403, "", RoomSendError.notAllowed, "not allowed"),
            (429, "", RoomSendError.retryable(retryAfterSeconds: nil), "too many"),
            (503, "", RoomSendError.retryable(retryAfterSeconds: nil), "unavailable for now")
        ]
        for (status, body, expected, why) in cases {
            let sender = makeSender(status: status, body: body)
            do {
                try await sender.sendAction(.emoji("🎉", isOn: true, sessionId: "room_1", sequenceId: 1, actor: "a"))
                XCTFail("expected \(expected): \(why)")
            } catch {
                XCTAssertEqual(String(reflecting: error), String(reflecting: expected), why)
            }
        }
        // A like keeps its own meaning of the same answers.
        do {
            try await makeSender(status: 409, body: #"{"error":{"code":"EMOJI_MESSAGE_LIMIT"}}"#)
                .sendAction(.reaction("like", sessionId: "room_1", sequenceId: 1, actor: "a"))
            XCTFail("expected a retryable 409")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .retryable(retryAfterSeconds: nil))
        }
        do {
            try await makeSender(status: 422)
                .sendAction(.reaction("like", sessionId: "room_1", sequenceId: 1, actor: "a"))
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .rejected)
        }
    }
}

// MARK: - Coordinator

private final class EmojiRoomTransport: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var page: RoomActionsPage
    private var fails = false
    private var reads = 0
    let history: [RoomMessage]
    /// The room refuses this account (a terminal failure).
    let denies: Bool

    init(history: [RoomMessage], page: RoomActionsPage = RoomActionsPage(), denies: Bool = false) {
        self.history = history
        self.page = page
        self.denies = denies
    }

    /// What the next reads of the room's actions answer; `fails` makes them fail.
    func answer(_ page: RoomActionsPage, fails: Bool = false) {
        lock.lock()
        self.page = page
        self.fails = fails
        lock.unlock()
    }

    func actionReads() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        if denies { throw SessionTransportError.accessDenied }
        return RoomEventPage(messages: beforeSequence == nil ? history : [])
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
        reads += 1
        if fails { throw SessionTransportError.invalidRequest }
        return page
    }
}

/// Records each action; answers with the scripted errors in order (then success), and can hold its answers.
private final class EmojiActionSender: RoomActionSending, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [RoomActionRequest] = []
    private var failures: [Error]
    private var holding: Bool

    init(failures: [Error] = [], holding: Bool = false) {
        self.failures = failures
        self.holding = holding
    }

    func release() {
        lock.lock()
        holding = false
        lock.unlock()
    }

    private var isHolding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return holding
    }

    func sendAction(_ action: RoomActionRequest) async throws {
        lock.lock()
        sent.append(action)
        lock.unlock()
        while isHolding { try? await Task.sleep(nanoseconds: 2_000_000) }
        lock.lock()
        let failure = failures.isEmpty ? nil : failures.removeFirst()
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
final class RoomEmojiReactionsCoordinatorTests: XCTestCase {
    private func message(_ seq: Int64) -> RoomMessage {
        RoomMessage(
            id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: "review-agent",
            authorName: "review-agent", isHuman: false, text: "message \(seq)",
            timestamp: "2026-10-28T18:00:00.000000+00:00"
        )
    }

    private func makeCoordinator(_ transport: EmojiRoomTransport, actions: EmojiActionSender,
                                 emojiReactions: Bool = true) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            actionSender: actions,
            membershipRole: "owner",
            ownAuthorIds: ["human-alex"],
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            emojiReactions: emojiReactions,
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

    private func emoji(_ coordinator: RoomChatCoordinator, _ seq: Int64) -> [RoomChatReactions.EmojiChip]? {
        for row in coordinator.state.rows {
            if case .message(let message) = row, message.sequenceId == seq, !message.isInlineReply {
                return message.reactions?.emojiChips
            }
        }
        return nil
    }

    private func opened(_ transport: EmojiRoomTransport, _ actions: EmojiActionSender,
                        emojiReactions: Bool = true) async -> RoomChatCoordinator {
        let coordinator = makeCoordinator(transport, actions: actions, emojiReactions: emojiReactions)
        coordinator.resume()
        await waitUntil("first projection") { transport.actionReads() >= 1 && !coordinator.state.isLoadingInitial }
        return coordinator
    }

    private static let summary = { (emoji: [RoomEmojiReaction]) in
        RoomActionsPage(byTarget: [5: RoomReactionSummary(targetSequenceId: 5, counts: ["like": 1], emojiReactions: emoji)])
    }

    func test_an_emoji_shows_at_once_posts_as_you_and_then_takes_the_server_count() async {
        let transport = EmojiRoomTransport(history: [message(5)])
        let sender = EmojiActionSender()
        let coordinator = await opened(transport, sender)
        XCTAssertTrue(coordinator.state.canAddEmoji)
        transport.answer(Self.summary([RoomEmojiReaction(emoji: "🎉", count: 3, viewerReacted: true)]))

        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "🎉", isOn: true))
        XCTAssertEqual(emoji(coordinator, 5), [.init(emoji: "🎉", count: 1, isMine: true)],
                       "optimistic: the tap shows before the server answers")
        await waitUntil("server count") { self.emoji(coordinator, 5)?.first?.count == 3 }
        XCTAssertEqual(sender.requests().map(\.actionType), ["react"])
        XCTAssertEqual(sender.requests().first?.emoji, "🎉")
        XCTAssertEqual(sender.requests().first?.targetSequenceId, 5)
        XCTAssertNil(coordinator.state.notice)
        coordinator.pause()
    }

    func test_tapping_your_own_emoji_takes_it_back_and_leaves_the_others() async {
        let transport = EmojiRoomTransport(history: [message(5)], page: Self.summary([
            RoomEmojiReaction(emoji: "🎉", count: 2, viewerReacted: true),
            RoomEmojiReaction(emoji: "👀", count: 1, viewerReacted: true)
        ]))
        let sender = EmojiActionSender()
        let coordinator = await opened(transport, sender)
        await waitUntil("emoji") { self.emoji(coordinator, 5)?.count == 2 }
        // The server's next answers fail: what shows is the tap.
        transport.answer(RoomActionsPage(), fails: true)
        let reads = transport.actionReads()

        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "🎉", isOn: false))
        XCTAssertEqual(emoji(coordinator, 5), [.init(emoji: "🎉", count: 1, isMine: false), .init(emoji: "👀", count: 1, isMine: true)])
        await waitUntil("re-read") { transport.actionReads() > reads }
        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "👀", isOn: false))
        XCTAssertEqual(emoji(coordinator, 5), [.init(emoji: "🎉", count: 1, isMine: false)], "the last one of an emoji goes")
        await waitUntil("re-read") { transport.actionReads() > reads + 1 }
        XCTAssertEqual(sender.requests().map(\.actionType), ["unreact", "unreact"])
        XCTAssertEqual(emoji(coordinator, 5), [.init(emoji: "🎉", count: 1, isMine: false)],
                       "a reaction that landed keeps showing when the re-read fails")
        coordinator.pause()
    }

    func test_an_api_without_emoji_reactions_undoes_the_tap_hides_the_picker_and_says_so() async {
        let transport = EmojiRoomTransport(history: [message(5)])
        let sender = EmojiActionSender(failures: [RoomEmojiRefusal.unavailable])
        let coordinator = await opened(transport, sender)

        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "🎉", isOn: true))
        XCTAssertEqual(emoji(coordinator, 5)?.map(\.emoji), ["🎉"])
        await waitUntil("refused") { coordinator.state.notice != nil }
        XCTAssertEqual(coordinator.state.notice, "Emoji reactions aren't available yet.")
        XCTAssertEqual(emoji(coordinator, 5) ?? [], [], "the tap is undone")
        XCTAssertFalse(coordinator.state.canAddEmoji, "the picker is hidden in this room")
        XCTAssertTrue(coordinator.state.canReact, "likes and acks still work")
        coordinator.pause()
    }

    func test_a_message_that_holds_all_the_reactions_it_can_undoes_the_tap_and_says_so() async {
        let transport = EmojiRoomTransport(history: [message(5)],
                                           page: Self.summary([RoomEmojiReaction(emoji: "👀", count: 4, viewerReacted: false)]))
        let sender = EmojiActionSender(failures: [RoomEmojiRefusal.full])
        let coordinator = await opened(transport, sender)
        await waitUntil("emoji") { self.emoji(coordinator, 5) != nil && self.emoji(coordinator, 5)?.isEmpty == false }

        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "🎉", isOn: true))
        await waitUntil("refused") { coordinator.state.notice != nil }
        XCTAssertEqual(coordinator.state.notice, "That message has as many reactions as it can take.")
        XCTAssertEqual(emoji(coordinator, 5), [.init(emoji: "👀", count: 4, isMine: false)])
        XCTAssertTrue(coordinator.state.canAddEmoji, "another message may still take one")
        coordinator.pause()
    }

    func test_a_failed_send_undoes_the_tap_without_a_notice() async {
        let transport = EmojiRoomTransport(history: [message(5)])
        let sender = EmojiActionSender(failures: [RoomSendError.retryable(retryAfterSeconds: nil)])
        let coordinator = await opened(transport, sender)

        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "🎉", isOn: true))
        await waitUntil("undone") { sender.requests().count == 1 && (self.emoji(coordinator, 5) ?? []).isEmpty }
        XCTAssertNil(coordinator.state.notice)
        XCTAssertTrue(coordinator.state.canAddEmoji)
        coordinator.pause()
    }

    func test_undoing_a_refused_tap_never_overwrites_a_newer_read() async {
        let transport = EmojiRoomTransport(history: [message(5)])
        let sender = EmojiActionSender(failures: [RoomEmojiRefusal.unavailable], holding: true)
        let coordinator = await opened(transport, sender)

        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "🎉", isOn: true))
        await waitUntil("sending") { sender.requests().count == 1 }
        // While the API thinks, a read brings someone else's reactions; the read after the refusal fails.
        transport.answer(Self.summary([RoomEmojiReaction(emoji: "🎉", count: 5, viewerReacted: false)]))
        for _ in 0..<100 where emoji(coordinator, 5)?.first?.count != 5 {
            await coordinator.refreshActions(force: true)
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(emoji(coordinator, 5), [.init(emoji: "🎉", count: 5, isMine: false)], "the newer read shows")
        transport.answer(RoomActionsPage(), fails: true)
        sender.release()
        await waitUntil("refused") { coordinator.state.notice != nil }
        XCTAssertEqual(emoji(coordinator, 5), [.init(emoji: "🎉", count: 5, isMine: false)])
        coordinator.pause()
    }

    func test_a_like_keeps_the_emoji_reactions_shown() async {
        let transport = EmojiRoomTransport(history: [message(5)],
                                           page: Self.summary([RoomEmojiReaction(emoji: "🎉", count: 2, viewerReacted: false)]))
        let coordinator = await opened(transport, EmojiActionSender())
        await waitUntil("emoji") { self.emoji(coordinator, 5)?.isEmpty == false }

        coordinator.send(.react(sequenceId: 5, type: "like"))
        XCTAssertEqual(emoji(coordinator, 5), [.init(emoji: "🎉", count: 2, isMine: false)])
        coordinator.pause()
    }

    func test_an_emoji_on_a_reply_shown_in_the_room_or_anything_but_one_emoji_is_never_sent() async {
        let transport = EmojiRoomTransport(history: [message(5)])
        let sender = EmojiActionSender()
        let coordinator = await opened(transport, sender)

        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "@all", isOn: true))
        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "abc", isOn: true))
        XCTAssertNil(emoji(coordinator, 5), "nothing shows for what is not one emoji")
        // A reply's emoji reactions are not read: one sent there could be neither seen nor taken back.
        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: "r-1", emoji: "👀", isOn: true))
        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: "r-1", emoji: "👀", isOn: false))
        XCTAssertNil(emoji(coordinator, 5), "nor on the message it answers")
        coordinator.send(.react(sequenceId: 5, type: "like"))
        await waitUntil("the like sent") { !sender.requests().isEmpty }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sender.requests().map(\.actionType), ["like"])
        coordinator.pause()
    }

    func test_taking_back_a_reaction_that_was_not_there_is_undone_quietly() async {
        let transport = EmojiRoomTransport(history: [message(5)],
                                           page: Self.summary([RoomEmojiReaction(emoji: "🎉", count: 1, viewerReacted: true)]))
        let sender = EmojiActionSender(failures: [RoomEmojiRefusal.notActive])
        let coordinator = await opened(transport, sender)
        await waitUntil("emoji") { self.emoji(coordinator, 5)?.isEmpty == false }
        transport.answer(RoomActionsPage(), fails: true)

        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "🎉", isOn: false))
        XCTAssertEqual(emoji(coordinator, 5), [], "the tap shows at once")
        await waitUntil("undone") { self.emoji(coordinator, 5) == [.init(emoji: "🎉", count: 1, isMine: true)] }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(coordinator.state.notice, "nothing to say")
        XCTAssertTrue(coordinator.state.canAddEmoji)
        coordinator.pause()
    }

    func test_once_the_room_refuses_emoji_reactions_nothing_more_is_sent() async {
        let transport = EmojiRoomTransport(history: [message(5)],
                                           page: Self.summary([RoomEmojiReaction(emoji: "👀", count: 1, viewerReacted: true)]))
        let sender = EmojiActionSender(failures: [RoomEmojiRefusal.unavailable])
        let coordinator = await opened(transport, sender)
        await waitUntil("emoji") { self.emoji(coordinator, 5)?.isEmpty == false }

        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "🎉", isOn: true))
        await waitUntil("refused") { coordinator.state.notice != nil }
        // The picker is gone, but the chips are still there to tap.
        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "👀", isOn: false))
        coordinator.send(.react(sequenceId: 5, type: "like"))
        await waitUntil("the like sent") { sender.requests().count >= 2 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sender.requests().map(\.actionType), ["react", "like"])
        coordinator.pause()
    }

    func test_with_emoji_reactions_off_no_chip_or_picker_shows_and_no_react_or_unreact_is_sent() async {
        let transport = EmojiRoomTransport(history: [message(5)],
                                           page: Self.summary([RoomEmojiReaction(emoji: "🎉", count: 2, viewerReacted: true)]))
        let sender = EmojiActionSender()
        let coordinator = await opened(transport, sender, emojiReactions: false)
        await waitUntil("the like") { self.emoji(coordinator, 5) != nil }
        XCTAssertEqual(emoji(coordinator, 5), [], "the summary's emoji reactions never show")
        XCTAssertFalse(coordinator.state.canAddEmoji, "no picker, no Add reaction")
        XCTAssertTrue(coordinator.state.canReact)

        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "👀", isOn: true))
        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "🎉", isOn: false))
        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: "r-1", emoji: "👀", isOn: true))
        coordinator.send(.react(sequenceId: 5, type: "like"))
        await waitUntil("the like sent") { !sender.requests().isEmpty }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sender.requests().map(\.actionType), ["like"], "react and unreact are never sent")
        coordinator.pause()
    }

    func test_the_app_ships_with_emoji_reactions_off() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: RoomEmojiReactions.infoKey) as? Bool, false,
                       "the Info.plist says so, as a boolean")
        XCTAssertFalse(RoomEmojiReactions.isEnabled)
    }

    func test_nothing_is_sent_from_a_room_this_account_may_not_read() async {
        let transport = EmojiRoomTransport(history: [message(5)], denies: true)
        let sender = EmojiActionSender()
        let coordinator = makeCoordinator(transport, actions: sender)
        coordinator.resume()
        await waitUntil("denied") { coordinator.state.failure == .accessDenied }
        XCTAssertFalse(coordinator.state.canAddEmoji)

        coordinator.send(.setEmojiReaction(sequenceId: 5, replyId: nil, emoji: "🎉", isOn: true))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sender.requests().isEmpty)
        coordinator.pause()
    }

    func test_setting_an_emoji_adds_yours_counts_up_or_down_and_changes_nothing_twice() {
        let empty = RoomReactionSummary(targetSequenceId: 5, counts: ["like": 1], likedByViewer: true)
        let added = empty.settingEmoji("🎉", isOn: true)
        XCTAssertEqual(added?.emojiReactions, [RoomEmojiReaction(emoji: "🎉", count: 1, viewerReacted: true)])
        XCTAssertEqual(added?.counts, ["like": 1])
        XCTAssertEqual(added?.likedByViewer, true, "the rest of the summary is kept")
        XCTAssertNil(added?.settingEmoji("🎉", isOn: true), "already yours")
        XCTAssertNil(empty.settingEmoji("🎉", isOn: false), "nothing of yours to take back")

        let theirs = RoomReactionSummary(targetSequenceId: 5, emojiReactions: [
            RoomEmojiReaction(emoji: "👀", count: 2, viewerReacted: false, actors: ["a", "b"]),
            RoomEmojiReaction(emoji: "🎉", count: 1, viewerReacted: false)
        ])
        XCTAssertEqual(theirs.settingEmoji("👀", isOn: true)?.emojiReactions.first,
                       RoomEmojiReaction(emoji: "👀", count: 3, viewerReacted: true, actors: ["a", "b"]),
                       "joins in its place")
        let mine = theirs.settingEmoji("👀", isOn: true)
        XCTAssertEqual(mine?.settingEmoji("👀", isOn: false)?.emojiReactions, theirs.emojiReactions)
    }
}
