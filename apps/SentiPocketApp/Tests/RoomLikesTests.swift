import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

// Ticket ce169567 (Carter: "likes and unlikes not yet"; earlier, taps that showed nothing stacked to 10 likes and a
// dislike in 30 seconds): one like per person, a tap on your lit thumb takes it back, like and dislike are exclusive,
// the tap shows at once and is undone if the API refuses it, and taps while one is on its way never stack.

// MARK: - HTTP action sender

private final class LikeActionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var answer = Data(#"{"ok":true}"#.utf8)
    private static var captured: [URLRequest] = []

    static func reset(status: Int, body: String = #"{"ok":true}"#) {
        lock.lock()
        self.status = status
        answer = Data(body.utf8)
        captured = []
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(request)
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

final class RoomLikeActionSenderTests: XCTestCase {
    private func makeSender(status: Int, body: String = #"{"ok":true}"#) -> HTTPRoomActionSender {
        LikeActionURLProtocol.reset(status: status, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LikeActionURLProtocol.self]
        return HTTPRoomActionSender(
            apiBaseURL: URL(string: "https://api.example.test"),
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { "user-token" }
        )
    }

    /// The API refuses taking back a like or dislike you do not hold (409, REACTION_NOT_ACTIVE): what the tap wanted is
    /// already so, and it is not undone. A 409 on a like is still a failure to retry.
    func test_taking_back_a_like_or_dislike_that_is_not_there_is_done() async throws {
        let sender = makeSender(status: 409, body: #"{"detail":{"code":"REACTION_NOT_ACTIVE"}}"#)
        try await sender.sendAction(.reaction("unlike", sessionId: "room_1", sequenceId: 5, actor: "human-alex"))
        try await sender.sendAction(.reaction("undislike", sessionId: "room_1", sequenceId: 5, actor: "human-alex"))
        do {
            try await sender.sendAction(.reaction("like", sessionId: "room_1", sequenceId: 5, actor: "human-alex"))
            XCTFail("a 409 on a like is not taken as done")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .retryable(retryAfterSeconds: nil))
        }
        XCTAssertEqual(LikeActionURLProtocol.requests().count, 3)
    }

    /// Each tap is its own request: like, unlike, like again are three writes, never a replay of the first.
    func test_each_tap_carries_its_own_request_id() {
        let keys = (0..<3).map { _ in
            RoomActionRequest.reaction("like", sessionId: "room_1", sequenceId: 5, actor: "human-alex").idempotencyKey
        }
        XCTAssertEqual(Set(keys).count, 3)
    }

    /// Like and dislike are exclusive: choosing one first takes back the other you hold.
    func test_one_tap_sends_the_reaction_after_taking_back_the_opposite_one() {
        XCTAssertEqual(RoomChatCoordinator.reactionWrites("like", liked: false, disliked: false), ["like"])
        XCTAssertEqual(RoomChatCoordinator.reactionWrites("like", liked: false, disliked: true), ["undislike", "like"])
        XCTAssertEqual(RoomChatCoordinator.reactionWrites("dislike", liked: true, disliked: false), ["unlike", "dislike"])
        XCTAssertEqual(RoomChatCoordinator.reactionWrites("unlike", liked: true, disliked: false), ["unlike"])
        XCTAssertEqual(RoomChatCoordinator.reactionWrites("ack", liked: true, disliked: true), ["ack"])
    }
}

// MARK: - The room

private final class LikeRoomTransport: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var page: RoomActionsPage
    private var fails = false
    private var reads = 0
    let history: [RoomMessage]

    init(history: [RoomMessage], page: RoomActionsPage = RoomActionsPage()) {
        self.history = history
        self.page = page
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
        reads += 1
        if fails { throw SessionTransportError.invalidRequest }
        return page
    }
}

private final class LikeActionSender: RoomActionSending, @unchecked Sendable {
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
final class RoomLikesCoordinatorTests: XCTestCase {
    private func message(_ seq: Int64) -> RoomMessage {
        RoomMessage(
            id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: "review-agent",
            authorName: "review-agent", isHuman: false, text: "message \(seq)",
            timestamp: "2026-11-06T06:00:00.000000+00:00"
        )
    }

    private func opened(_ transport: LikeRoomTransport, _ actions: LikeActionSender) async -> RoomChatCoordinator {
        let coordinator = RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            actionSender: actions,
            membershipRole: "owner",
            ownAuthorIds: ["human-alex"],
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            onReauthenticationRequired: {}
        )
        coordinator.resume()
        await waitUntil("first projection") { transport.actionReads() >= 1 && !coordinator.state.isLoadingInitial }
        return coordinator
    }

    private func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    /// Your own taps on message `seq` as its row counts them: the like thumb's pops, the dislike thumb's, and the taps of
    /// your hand.
    private func taps(_ coordinator: RoomChatCoordinator, _ seq: Int64) -> [Int] {
        for row in coordinator.state.rows {
            if case .message(let message) = row, message.sequenceId == seq, !message.isInlineReply {
                return [message.ownTaps.pops("like"), message.ownTaps.pops("dislike"), message.ownTaps.placed]
            }
        }
        return []
    }

    /// The like and dislike chips under message `seq`, as the row shows them.
    private func thumbs(_ coordinator: RoomChatCoordinator, _ seq: Int64) -> [RoomChatReactions.Chip] {
        for row in coordinator.state.rows {
            if case .message(let message) = row, message.sequenceId == seq, !message.isInlineReply {
                return (message.reactions?.chips ?? []).filter { $0.type == "like" || $0.type == "dislike" }
            }
        }
        return []
    }

    private static func summary(likes: Int = 0, dislikes: Int = 0, liked: Bool = false,
                                disliked: Bool = false) -> RoomActionsPage {
        var counts: [String: Int] = [:]
        if likes > 0 { counts["like"] = likes }
        if dislikes > 0 { counts["dislike"] = dislikes }
        return RoomActionsPage(byTarget: [5: RoomReactionSummary(targetSequenceId: 5, counts: counts,
                                                                 likedByViewer: liked, dislikedByViewer: disliked)])
    }

    func test_taps_while_a_like_is_on_its_way_never_stack() async {
        let transport = LikeRoomTransport(history: [message(5)])
        let sender = LikeActionSender(holding: true)
        let coordinator = await opened(transport, sender)

        coordinator.send(.react(sequenceId: 5, type: "like"))
        XCTAssertEqual(thumbs(coordinator, 5), [.init(type: "like", count: 1, isMine: true)], "the tap shows at once")
        // The row now offers "unlike"; more taps before the like lands are ignored, whatever they ask.
        coordinator.send(.react(sequenceId: 5, type: "unlike"))
        coordinator.send(.react(sequenceId: 5, type: "like"))
        coordinator.send(.react(sequenceId: 5, type: "dislike"))
        XCTAssertEqual(thumbs(coordinator, 5), [.init(type: "like", count: 1, isMine: true)])
        await waitUntil("the like sent") { !sender.requests().isEmpty }
        transport.answer(Self.summary(likes: 1, liked: true))
        sender.release()
        await waitUntil("the server's count") { transport.actionReads() >= 2 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sender.requests().map(\.actionType), ["like"], "one like, however many taps")
        XCTAssertEqual(thumbs(coordinator, 5), [.init(type: "like", count: 1, isMine: true)])

        // Once it has landed, the next tap goes: tapping your lit thumb takes the like back.
        transport.answer(Self.summary())
        coordinator.send(.react(sequenceId: 5, type: "unlike"))
        XCTAssertEqual(thumbs(coordinator, 5), [], "taken back at once")
        await waitUntil("the unlike sent") { sender.requests().count == 2 }
        XCTAssertEqual(sender.requests().map(\.actionType), ["like", "unlike"])
        coordinator.pause()
    }

    func test_a_like_takes_back_your_dislike_first_and_a_dislike_your_like() async {
        let transport = LikeRoomTransport(history: [message(5)], page: Self.summary(likes: 2, dislikes: 1, disliked: true))
        let sender = LikeActionSender()
        let coordinator = await opened(transport, sender)
        await waitUntil("the summary") { !self.thumbs(coordinator, 5).isEmpty }
        XCTAssertEqual(thumbs(coordinator, 5), [.init(type: "like", count: 2, isMine: false),
                                                .init(type: "dislike", count: 1, isMine: true)])

        transport.answer(Self.summary(likes: 3, liked: true))
        coordinator.send(.react(sequenceId: 5, type: "like"))
        XCTAssertEqual(thumbs(coordinator, 5), [.init(type: "like", count: 3, isMine: true)],
                       "your like lit, your dislike gone, at once")
        await waitUntil("both sent") { sender.requests().count == 2 }
        XCTAssertEqual(sender.requests().map(\.actionType), ["undislike", "like"])
        await waitUntil("landed") { transport.actionReads() >= 2 }

        transport.answer(Self.summary(likes: 2, dislikes: 1, disliked: true))
        coordinator.send(.react(sequenceId: 5, type: "dislike"))
        XCTAssertEqual(thumbs(coordinator, 5), [.init(type: "like", count: 2, isMine: false),
                                                .init(type: "dislike", count: 1, isMine: true)])
        await waitUntil("both sent") { sender.requests().count == 4 }
        XCTAssertEqual(sender.requests().map(\.actionType), ["undislike", "like", "unlike", "dislike"])
        coordinator.pause()
    }

    /// A like or dislike you place, and only that, pops its thumb and taps your hand (Carter, 2026-11-06: "Likes and
    /// stuff still don't have animation"). Taking one back is quiet, and so are a tap ignored while one is on its way
    /// and a refresh's new count: those counts only roll.
    func test_only_a_like_or_dislike_you_place_pops_and_taps_your_hand() async {
        let transport = LikeRoomTransport(history: [message(5)])
        let sender = LikeActionSender(holding: true)
        let coordinator = await opened(transport, sender)
        XCTAssertEqual(taps(coordinator, 5), [0, 0, 0])

        coordinator.send(.react(sequenceId: 5, type: "like"))
        XCTAssertEqual(taps(coordinator, 5), [1, 0, 1], "your like pops its thumb and taps your hand")
        coordinator.send(.react(sequenceId: 5, type: "unlike"))
        coordinator.send(.react(sequenceId: 5, type: "dislike"))
        XCTAssertEqual(taps(coordinator, 5), [1, 0, 1], "taps ignored while the like is on its way never pop")

        // Someone else liked it too: the refresh's count rolls, and nothing pops or taps your hand.
        transport.answer(Self.summary(likes: 2, liked: true))
        sender.release()
        await waitUntil("the server's count") {
            self.thumbs(coordinator, 5) == [.init(type: "like", count: 2, isMine: true)]
        }
        XCTAssertEqual(taps(coordinator, 5), [1, 0, 1], "a refresh never pops")

        // A dislike takes your like back first: only the dislike's thumb pops.
        transport.answer(Self.summary(likes: 1, dislikes: 1, disliked: true))
        let reads = transport.actionReads()
        coordinator.send(.react(sequenceId: 5, type: "dislike"))
        XCTAssertEqual(taps(coordinator, 5), [1, 1, 2])
        await waitUntil("both sent and landed") { sender.requests().count == 3 && transport.actionReads() > reads }

        // Taking it back is quiet: no bounce, and no tap of your hand.
        coordinator.send(.react(sequenceId: 5, type: "undislike"))
        XCTAssertEqual(taps(coordinator, 5), [1, 1, 2], "a take-back never pops or taps your hand")
        await waitUntil("the undislike sent") { sender.requests().count == 4 }
        coordinator.pause()
    }

    func test_a_like_the_api_refuses_is_taken_back() async {
        let transport = LikeRoomTransport(history: [message(5)], page: Self.summary(likes: 1))
        let sender = LikeActionSender(failures: [RoomSendError.rejected], holding: true)
        let coordinator = await opened(transport, sender)
        await waitUntil("the summary") { !self.thumbs(coordinator, 5).isEmpty }
        // The refresh after the refusal fails too, so only the undo can put it back.
        transport.answer(Self.summary(likes: 1), fails: true)

        coordinator.send(.react(sequenceId: 5, type: "like"))
        XCTAssertEqual(thumbs(coordinator, 5), [.init(type: "like", count: 2, isMine: true)], "the tap shows at once")
        sender.release()
        await waitUntil("undone") { self.thumbs(coordinator, 5) == [.init(type: "like", count: 1, isMine: false)] }
        coordinator.pause()
    }
}

// MARK: - The chip

@MainActor
final class RoomLikeChipViewTests: XCTestCase {
    /// One like shows its "1", lit when it is yours and plain when it is only someone else's, and VoiceOver reads the
    /// same (ticket ce169567: the number showed only from two).
    func test_one_like_shows_its_count_and_voiceover_reads_it() throws {
        for yours in [true, false] {
            let message = RoomChatMessageInput(
                id: "evt-5", sequenceId: 5, kind: .message, authorId: "review-agent", authorName: "review-agent",
                isHuman: false, text: "The site is ready for review.", timestamp: "2026-11-06T06:00:00.000000+00:00",
                reactions: RoomChatReactions(chips: [.init(type: "like", count: 1, isMine: yours)])
            )
            let state = RoomChatPresentationState(sessionId: "room-likes", title: "Site", messages: [message],
                                                  connection: .live, canReact: true)
            let window = try HostedSummary.host(NavigationStack { RoomChatView(state: state) { _ in } })
            let label = yours ? "Like, 1, yours" : "Like, 1"
            XCTAssertNotNil(HostedSummary.wait(for: "pocket.room.reaction.5.like", in: window, label: label),
                            "the chip reads \(label)")
            HostedSummary.close(window)
        }
    }
}
