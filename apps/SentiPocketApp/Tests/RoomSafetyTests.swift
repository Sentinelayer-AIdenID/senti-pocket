import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

// Report and Block (App Store guideline 1.2) and the AI consent (5.1.2(i)), against fakes of the API's contract:
// `POST /api/v1/sessions/{id}/reports` and `GET`, `POST`, `DELETE /api/v1/me/blocks`.

// MARK: - Fakes

/// Answers each request by method and path, and keeps every request with its body.
private final class SafetyURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var answers: [String: (status: Int, body: String)] = [:]
    private static var captured: [(request: URLRequest, body: Data)] = []

    static func reset(_ answers: [String: (status: Int, body: String)]) {
        lock.withLock {
            self.answers = answers
            captured = []
        }
    }

    static var requests: [(request: URLRequest, body: Data)] { lock.withLock { captured } }

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
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        let answer = Self.lock.withLock { () -> (status: Int, body: String) in
            Self.captured.append((request, body))
            return Self.answers[key] ?? (404, "{}")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SafetyURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// A session token whose subject is `subject`, built here so no token-shaped text sits in the source.
private func token(subject: String) -> String {
    let claims = try! JSONSerialization.data(withJSONObject: ["sub": subject])
    let payload = claims.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "h.\(payload).s"
}

/// The blocks API: online or not, with the server's list, and every call kept.
private final class FakeBlocksAPI: BlockListClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _online: Bool
    private var _server: [String]
    private var _calls: [String] = []

    init(online: Bool, server: [String] = []) {
        _online = online
        _server = server
    }

    var online: Bool {
        get { lock.withLock { _online } }
        set { lock.withLock { _online = newValue } }
    }
    var server: [String] { lock.withLock { _server } }
    var calls: [String] { lock.withLock { _calls } }

    func blocks() async throws -> [ServerBlock] {
        try lock.withLock {
            _calls.append("GET")
            guard _online else { throw RoomSendError.retryable(retryAfterSeconds: nil) }
            return _server.map { ServerBlock(actorId: $0, createdAt: nil) }
        }
    }

    func block(_ actorId: String) async throws {
        try lock.withLock {
            _calls.append("POST \(actorId)")
            guard _online else { throw RoomSendError.retryable(retryAfterSeconds: nil) }
            if !_server.contains(actorId) { _server.append(actorId) }
        }
    }

    func unblock(_ actorId: String) async throws {
        try lock.withLock {
            _calls.append("DELETE \(actorId)")
            guard _online else { throw RoomSendError.retryable(retryAfterSeconds: nil) }
            _server.removeAll { $0 == actorId }
        }
    }
}

/// A blocks API whose list answers only when released, and that cannot take changes (as if it went offline).
private final class HeldListAPI: BlockListClient, @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<[ServerBlock], Never>?

    var isListing: Bool { lock.withLock { waiter != nil } }

    func blocks() async throws -> [ServerBlock] {
        await withCheckedContinuation { waiter in lock.withLock { self.waiter = waiter } }
    }

    func release(with actorIds: [String]) {
        let waiter = lock.withLock { () -> CheckedContinuation<[ServerBlock], Never>? in
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: actorIds.map { ServerBlock(actorId: $0, createdAt: nil) })
    }

    func block(_ actorId: String) async throws { throw RoomSendError.retryable(retryAfterSeconds: nil) }
    func unblock(_ actorId: String) async throws { throw RoomSendError.retryable(retryAfterSeconds: nil) }
}

/// Reports, answered in turn by `results` (then taken), and every request kept.
private final class FakeReporter: RoomReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Error?]
    private var _requests: [RoomReportRequest] = []

    init(results: [Error?] = []) {
        self.results = results
    }

    var requests: [RoomReportRequest] { lock.withLock { _requests } }

    func report(sessionId: String, _ request: RoomReportRequest) async throws {
        let result = lock.withLock { () -> Error? in
            _requests.append(request)
            return results.isEmpty ? nil : results.removeFirst()
        }
        if let result { throw result }
    }
}

/// Every message and reply that reached the room.
private final class RecordingSender: RoomMessageSending, RoomActionSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []
    private var _replies: [String] = []
    var messages: [String] { lock.withLock { _messages } }
    var replies: [String] { lock.withLock { _replies } }

    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        lock.withLock { _messages.append(text) }
    }

    func sendAction(_ action: RoomActionRequest) async throws {
        lock.withLock { if action.actionType == "reply" { _replies.append(action.note ?? "") } }
    }
}

/// A quiet room whose replies are `replies`.
private struct QuietRoom: RoomTransport {
    var replies: [RoomReply] = []

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> {
        AsyncStream { _ in }
    }

    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        RoomActionsPage(replies: replies.filter { targetSequenceId == nil || $0.targetSequenceId == targetSequenceId })
    }
}

/// Who is signed in: an account without a verified GitHub login.
private struct UnlinkedAccount: AccountIdentityProviding {
    func currentAccount() async -> SignedInAccount? {
        SignedInAccount(githubUsername: nil, accountId: "6F1C2B9E-0000-4000-8000-00000000000A")
    }
}

// MARK: - Tests

@MainActor
final class RoomSafetyTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups = []
        super.tearDown()
    }

    private func temporaryStore() -> BlockListStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("room-blocks-\(UUID().uuidString).json")
        cleanups.append { try? FileManager.default.removeItem(at: url) }
        return BlockListStore(url: url)
    }

    private func temporaryDefaults() -> UserDefaults {
        let suite = "ai-consent-\(UUID().uuidString)"
        cleanups.append { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func message(_ seq: Int64, author: String, text: String = "hi") -> RoomMessage {
        RoomMessage(id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: author, authorName: author,
                    isHuman: RoomMessage.isHumanAuthor(author), text: text,
                    timestamp: "2026-11-03T18:00:0\(seq).000000+00:00")
    }

    private func room(_ transport: any RoomTransport = QuietRoom(), sender: RecordingSender? = nil,
                      reporter: (any RoomReporting)? = nil, blocks: BlockList? = nil,
                      aiConsent: AIConsent? = nil) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            sender: sender,
            actionSender: sender,
            ownAuthorIds: ["human-me"],
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            reporter: reporter,
            blocks: blocks,
            aiConsent: aiConsent,
            onReauthenticationRequired: {}
        )
    }

    private func rows(_ room: RoomChatCoordinator) -> [String: RoomChatMessageRow] {
        var rows: [String: RoomChatMessageRow] = [:]
        for row in room.state.rows {
            if case .message(let message) = row { rows[message.id] = message }
        }
        return rows
    }

    private func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)", file: file, line: line)
    }

    // MARK: Report

    func test_a_report_posts_the_contracts_body_to_the_rooms_reports() async throws {
        SafetyURLProtocol.reset(["POST /api/v1/sessions/room_1/reports": (201, #"{"report":{"id":"r-1","status":"open"}}"#)])
        let sender = HTTPRoomMessageSender(apiBaseURL: URL(string: "https://api.example.test"),
                                           urlSession: SafetyURLProtocol.session,
                                           tokenProvider: { token(subject: "user-a") })
        let target = RoomReportTarget(sequenceId: 42, authorId: "human-sam", authorName: "sam")
        try await sender.report(sessionId: "room_1", RoomReportRequest(target: target, reason: .selfHarm, note: " worried "))
        try await sender.report(sessionId: "room_1", RoomReportRequest(target: target, reason: .spam, note: ""))

        let sent = SafetyURLProtocol.requests
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].request.httpMethod, "POST")
        XCTAssertEqual(sent[0].request.url?.path, "/api/v1/sessions/room_1/reports")
        XCTAssertEqual(sent[0].request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token(subject: "user-a"))")
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[0].body) as? [String: Any])
        XCTAssertEqual(Set(first.keys), ["sequenceId", "reason", "note"], "exactly the contract's fields")
        XCTAssertEqual(first["sequenceId"] as? Int, 42)
        XCTAssertEqual(first["reason"] as? String, "self_harm")
        XCTAssertEqual(first["note"] as? String, "worried")
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1].body) as? [String: Any])
        XCTAssertTrue(second["note"] is NSNull, "no note is sent as null")

        // The API without the route yet (404), or offline: not sent.
        SafetyURLProtocol.reset([:])
        do {
            try await sender.report(sessionId: "room_1", RoomReportRequest(target: target, reason: .spam, note: ""))
            XCTFail("a 404 is not a report sent")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .retryable(retryAfterSeconds: nil))
        }
    }

    func test_a_reply_is_reported_on_its_thread_and_named_in_the_note() {
        let target = RoomReportTarget(sequenceId: 9, replyId: "act-77", authorId: "review-agent", authorName: "review-agent")
        let request = RoomReportRequest(target: target, reason: .harassment, note: "again")
        XCTAssertEqual(request.sequenceId, 9)
        XCTAssertEqual(request.note, "Reply act-77\nagain")
    }

    func test_the_report_sheet_goes_choosing_sending_then_not_sent_then_sent() async {
        let reporter = FakeReporter(results: [RoomSendError.retryable(retryAfterSeconds: nil), nil])
        let blocks = BlockList(account: "sub:a", store: temporaryStore(), client: nil)
        let room = room(reporter: reporter, blocks: blocks)
        room.handle(.message(message(2, author: "human-sam", text: "Something unkind")))
        let target = RoomReportTarget(sequenceId: 2, authorId: "human-sam", authorName: "human-sam")
        XCTAssertTrue(room.state.canReport)

        room.send(.openReport(target))
        XCTAssertEqual(room.state.report?.phase, .choosing)
        XCTAssertEqual(room.state.report?.canBlock, true)

        room.send(.sendReport(reason: .harassment, note: "please look"))
        XCTAssertEqual(room.state.report?.phase, .sending)
        await waitUntil("not sent") { room.state.report?.phase == .failed }

        room.send(.sendReport(reason: .harassment, note: "please look"))
        await waitUntil("sent") { room.state.report?.phase == .sent }
        XCTAssertEqual(reporter.requests, Array(repeating: RoomReportRequest(target: target, reason: .harassment,
                                                                             note: "please look"), count: 2))

        // "Block <name> too", from the thanks.
        XCTAssertEqual(room.state.report?.authorIsBlocked, false)
        room.send(.block(RoomBlockTarget(actorId: "human-sam", name: "sam")))
        XCTAssertEqual(room.state.report?.authorIsBlocked, true)

        room.send(.closeReport)
        XCTAssertNil(room.state.report)
    }

    func test_an_account_bound_author_id_is_yours_and_never_offered_to_report_or_block() async {
        let account = await UnlinkedAccount().currentAccount()
        XCTAssertEqual(account?.accountBoundAuthorId, "human-g.6f1c2b9e00004000800000000000000a",
                       "the API's form (sentinelayer-api #1105)")
        let room = RoomChatCoordinator(
            sessionId: "room_1", title: "Room", transport: QuietRoom(), identity: UnlinkedAccount(),
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            reporter: FakeReporter(), blocks: BlockList(account: "sub:a", store: temporaryStore(), client: nil),
            onReauthenticationRequired: {}
        )
        room.resume()
        room.handle(.message(message(2, author: "human-g.6f1c2b9e00004000800000000000000a", text: "Mine")))
        await waitUntil("yours") { self.rows(room)["evt-2"]?.isOwn == true }
        XCTAssertNil(rows(room)["evt-2"]?.reportTarget)
        room.pause()
    }

    // MARK: Block

    func test_blocking_hides_the_authors_messages_and_replies_in_every_room_and_show_reveals_one() async {
        let blocks = BlockList(account: "sub:a", store: temporaryStore(), client: nil)
        let reply = RoomReply(id: "act-1", targetSequenceId: 3, authorId: "human-sam", text: "A reply",
                              createdAt: "2026-11-03T18:00:05.000000+00:00")
        let here = room(QuietRoom(replies: [reply]), blocks: blocks)
        let there = room(blocks: blocks)
        here.handle(.message(message(2, author: "human-sam", text: "Something unkind")))
        here.handle(.message(message(3, author: "review-agent", text: "Build 319 is green")))
        here.handle(.message(message(4, author: "human-sam", text: "More of the same")))
        there.handle(.message(message(7, author: "human-sam", text: "Elsewhere")))
        await waitUntil("reply in the room") { self.rows(here)["reply-act-1"] != nil }
        XCTAssertTrue(here.state.canBlock)

        here.send(.block(RoomBlockTarget(actorId: "human-sam", name: "sam")))
        XCTAssertEqual(rows(here)["evt-2"]?.hidesAsBlocked, true)
        XCTAssertEqual(rows(here)["evt-4"]?.hidesAsBlocked, true)
        XCTAssertEqual(rows(here)["reply-act-1"]?.hidesAsBlocked, true, "their reply too")
        XCTAssertEqual(rows(here)["evt-3"]?.hidesAsBlocked, false)
        await waitUntil("hidden in the other room") { self.rows(there)["evt-7"]?.hidesAsBlocked == true }

        here.send(.revealBlocked(key: RoomBlocking.revealKey(message: "evt-2")))
        XCTAssertEqual(rows(here)["evt-2"]?.hidesAsBlocked, false, "Show opens that one")
        XCTAssertEqual(rows(here)["evt-4"]?.hidesAsBlocked, true, "and no other")
        XCTAssertEqual(rows(there)["evt-7"]?.hidesAsBlocked, true)

        // In the thread, too.
        here.send(.openThread(sequenceId: 3))
        await waitUntil("thread loaded") { here.state.thread?.replies.isEmpty == false }
        XCTAssertEqual(here.state.thread?.replies.first?.authorId, "human-sam")
        XCTAssertEqual(here.state.thread?.replies.first?.hidesAsBlocked, true)
    }

    func test_unblocking_shows_them_again_everywhere() async {
        let api = FakeBlocksAPI(online: true)
        let blocks = BlockList(account: "sub:a", store: temporaryStore(), client: api)
        let room = room(blocks: blocks)
        room.handle(.message(message(2, author: "human-sam")))
        room.send(.block(RoomBlockTarget(actorId: "human-sam", name: "sam")))
        await waitUntil("blocked on the server") { api.server == ["human-sam"] }

        blocks.unblock("human-sam")
        XCTAssertFalse(blocks.isBlocked("human-sam"))
        XCTAssertTrue(blocks.blocked.isEmpty)
        await waitUntil("shown again") { self.rows(room)["evt-2"]?.hidesAsBlocked == false }
        await waitUntil("unblocked on the server") { api.server.isEmpty }
        XCTAssertEqual(api.calls.filter { !$0.hasPrefix("GET") }, ["POST human-sam", "DELETE human-sam"])
        XCTAssertTrue(blocks.changes.isEmpty)
    }

    func test_blocks_are_kept_per_account_and_never_shown_to_another_account() {
        let store = temporaryStore()
        let first = BlockList(account: "sub:a", store: store, client: nil)
        first.block(RoomBlockTarget(actorId: "human-sam", name: "Sam"))
        first.block(RoomBlockTarget(actorId: "build-agent", name: "build-agent"))

        let second = BlockList(account: "sub:b", store: store, client: nil)
        XCTAssertTrue(second.blocked.isEmpty, "another account on this phone starts with none")
        XCTAssertFalse(second.isBlocked("human-sam"))
        second.block(RoomBlockTarget(actorId: "human-alex", name: "Alex"))

        let againFirst = BlockList(account: "sub:a", store: store, client: nil)
        XCTAssertEqual(againFirst.actorIds, ["human-sam", "build-agent"], "kept across launches, for its account")
        XCTAssertEqual(againFirst.blocked.first { $0.actorId == "human-sam" }?.name, "Sam")
        XCTAssertEqual(BlockList(account: "sub:b", store: store, client: nil).actorIds, ["human-alex"])
        XCTAssertTrue(BlockList(account: nil, store: store, client: nil).blocked.isEmpty, "no account reads nothing")
    }

    func test_offline_or_before_the_api_has_blocks_the_phones_copy_stands_and_syncs_later() async {
        let store = temporaryStore()
        let api = FakeBlocksAPI(online: false, server: ["human-webblock"])
        let blocks = BlockList(account: "sub:a", store: store, client: api)
        blocks.block(RoomBlockTarget(actorId: "Human-Sam", name: "Sam"))
        XCTAssertTrue(blocks.isBlocked("human-sam"), "blocked at once, offline")
        await waitUntil("tried the server") { api.calls.contains("POST human-sam") }
        await blocks.sync()
        XCTAssertEqual(blocks.changes, [BlockChange(actorId: "human-sam", blocks: true)], "kept for later")
        XCTAssertEqual(BlockListStore(url: store.url).load(account: "sub:a").changes.count, 1, "and kept on the phone")

        // A relaunch, still offline, still has it.
        let relaunched = BlockList(account: "sub:a", store: store, client: api)
        XCTAssertTrue(relaunched.isBlocked("human-sam"))

        api.online = true
        await relaunched.sync()
        XCTAssertEqual(api.server.sorted(), ["human-sam", "human-webblock"], "the block reached the server")
        XCTAssertEqual(relaunched.actorIds, ["human-sam", "human-webblock"], "and one made on the web came back")
        XCTAssertEqual(relaunched.blocked.first { $0.actorId == "human-sam" }?.name, "Sam", "names the phone knows stay")
        XCTAssertEqual(relaunched.blocked.first { $0.actorId == "human-webblock" }?.name, "webblock")
        XCTAssertTrue(relaunched.changes.isEmpty)
    }

    func test_the_servers_list_never_undoes_a_change_made_while_it_was_read() async {
        let api = HeldListAPI()
        let blocks = BlockList(account: "sub:a", store: temporaryStore(), client: api)
        let reading = Task { await blocks.sync() }
        await waitUntil("reading the server's list") { api.isListing }
        blocks.block(RoomBlockTarget(actorId: "human-new", name: "new"))
        blocks.unblock("human-old")
        api.release(with: ["human-old"])
        await reading.value
        XCTAssertEqual(blocks.actorIds, ["human-new"], "the block made meanwhile stays, the unblock stays undone")
        XCTAssertEqual(blocks.changes, [BlockChange(actorId: "human-new", blocks: true),
                                        BlockChange(actorId: "human-old", blocks: false)], "both still on their way")
    }

    func test_a_newer_change_for_an_author_replaces_one_not_sent_yet() async {
        let api = FakeBlocksAPI(online: false, server: ["human-old"])
        let blocks = BlockList(account: "sub:a", store: temporaryStore(), client: api)
        blocks.block(RoomBlockTarget(actorId: "human-old", name: "old"))
        blocks.unblock("human-old")
        blocks.block(RoomBlockTarget(actorId: "human-new", name: "new"))
        XCTAssertEqual(blocks.changes, [BlockChange(actorId: "human-old", blocks: false),
                                        BlockChange(actorId: "human-new", blocks: true)],
                       "one change per author, the newest")
        api.online = true
        await blocks.sync()
        XCTAssertEqual(blocks.actorIds, ["human-new"])
        XCTAssertEqual(api.server, ["human-new"])
    }

    func test_the_blocks_client_speaks_the_contract_and_only_for_its_own_account() async throws {
        SafetyURLProtocol.reset([
            "GET /api/v1/me/blocks": (200, #"{"blocks":[{"actorId":"human-sam","createdAt":"2026-11-03T18:00:00Z"}]}"#),
            "POST /api/v1/me/blocks": (201, #"{"block":{"actorId":"review-agent"}}"#),
            "DELETE /api/v1/me/blocks/human-sam": (204, "")
        ])
        let client = HTTPBlockListClient(apiBaseURL: URL(string: "https://api.example.test"), account: "sub:user-a",
                                         urlSession: SafetyURLProtocol.session, tokenProvider: { token(subject: "user-a") })
        let listed = try await client.blocks()
        XCTAssertEqual(listed.map(\.actorId), ["human-sam"])
        XCTAssertNotNil(listed.first?.createdAt)
        try await client.block("review-agent")
        try await client.unblock("human-sam")
        let sent = SafetyURLProtocol.requests
        XCTAssertEqual(sent.map { "\($0.request.httpMethod ?? "") \($0.request.url?.path ?? "")" },
                       ["GET /api/v1/me/blocks", "POST /api/v1/me/blocks", "DELETE /api/v1/me/blocks/human-sam"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: sent[1].body) as? [String: String], ["actorId": "review-agent"])
        XCTAssertTrue(sent.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token(subject: "user-a"))" })

        // Before the API has the route (404): may work later, so the change is kept.
        SafetyURLProtocol.reset([:])
        do {
            try await client.block("human-x")
            XCTFail("a 404 is not a block taken")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .retryable(retryAfterSeconds: nil))
        }
        // Yourself (422): never, so the change goes.
        SafetyURLProtocol.reset(["POST /api/v1/me/blocks": (422, #"{"detail":{"code":"CANNOT_BLOCK_SELF"}}"#)])
        do {
            try await client.block("human-me")
            XCTFail("a 422 is a refusal")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .rejected)
        }

        // Another account's token is never used for this account's list.
        SafetyURLProtocol.reset(["GET /api/v1/me/blocks": (200, #"{"blocks":[]}"#)])
        let other = HTTPBlockListClient(apiBaseURL: URL(string: "https://api.example.test"), account: "sub:user-a",
                                        urlSession: SafetyURLProtocol.session, tokenProvider: { token(subject: "user-b") })
        do {
            _ = try await other.blocks()
            XCTFail("another account's token must not read this list")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .reauthenticationRequired)
        }
        XCTAssertTrue(SafetyURLProtocol.requests.isEmpty, "nothing was sent")
    }

    // MARK: AI consent

    func test_ai_consent_is_asked_once_per_account_and_again_after_withdrawing() {
        let defaults = temporaryDefaults()
        let consent = AIConsent(account: "sub:a", defaults: defaults)
        XCTAssertTrue(consent.asks(roomHasAgents: true))
        XCTAssertFalse(consent.asks(roomHasAgents: false), "a room without agents never asks")

        consent.grant()
        XCTAssertFalse(consent.asks(roomHasAgents: true), "asked once")
        XCTAssertFalse(AIConsent(account: "sub:a", defaults: defaults).asks(roomHasAgents: true), "kept across launches")
        XCTAssertTrue(AIConsent(account: "sub:b", defaults: defaults).asks(roomHasAgents: true),
                      "another account on this phone is asked for itself")

        consent.withdraw()
        XCTAssertTrue(consent.asks(roomHasAgents: true), "withdrawn: asked again")
        XCTAssertTrue(AIConsent(account: "sub:a", defaults: defaults).asks(roomHasAgents: true))
    }

    func test_a_room_with_agents_asks_first_and_sends_nothing_without_the_ok() async {
        let consent = AIConsent(account: "sub:a", defaults: temporaryDefaults())
        let sender = RecordingSender()
        let room = room(sender: sender, aiConsent: consent)
        room.handle(.message(message(1, author: "human-alex", text: "Hello")))
        XCTAssertFalse(room.state.asksAIConsent, "no agents here yet")
        room.handle(.message(message(2, author: "review-agent", text: "Build 319 is green")))
        XCTAssertTrue(room.roomHasAgents)
        XCTAssertTrue(room.state.asksAIConsent, "an agent wrote here: the first send asks")

        // A send that came without the OK goes nowhere, and keeps its words to edit and send again.
        room.send(.sendMessage(text: "Ship it"))
        room.send(.sendReply(sequenceId: 2, text: "Thanks"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sender.messages.isEmpty)
        XCTAssertTrue(sender.replies.isEmpty)
        XCTAssertEqual(room.state.pending.map(\.text), ["Ship it"])
        XCTAssertEqual(room.state.pending.first?.status, .failed(reason: RoomChatCoordinator.consentReason, canRetry: false))

        room.send(.allowAIAgents)
        XCTAssertTrue(consent.isGiven)
        XCTAssertFalse(room.state.asksAIConsent)
        room.send(.sendMessage(text: "Ship it"))
        room.send(.sendReply(sequenceId: 2, text: "Thanks"))
        await waitUntil("sent") { sender.messages == ["Ship it"] && sender.replies == ["Thanks"] }

        consent.withdraw()
        await waitUntil("asks again") { room.state.asksAIConsent }
    }

    func test_a_room_without_agents_never_asks() async {
        let consent = AIConsent(account: "sub:a", defaults: temporaryDefaults())
        let sender = RecordingSender()
        let room = room(sender: sender, aiConsent: consent)
        room.handle(.message(message(1, author: "human-alex", text: "Hello")))
        room.send(.sendMessage(text: "Hi Alex"))
        await waitUntil("sent") { sender.messages == ["Hi Alex"] }
        XCTAssertFalse(consent.isGiven, "nothing was asked")
    }

    func test_ticket_answers_and_chat_about_it_are_what_ask() {
        XCTAssertTrue(RoomTicketsIntent.answerDecision(ticketId: "t1", answer: "Yes", detail: "").postsToTheRoom)
        XCTAssertTrue(RoomTicketsIntent.chatAboutIt(ticketId: "t1", note: "").postsToTheRoom)
        XCTAssertTrue(RoomTicketsIntent.retryDecision(ticketId: "t1").postsToTheRoom)
        XCTAssertFalse(RoomTicketsIntent.refresh.postsToTheRoom)
    }

    // MARK: Support

    func test_the_support_contact_is_one_address() {
        XCTAssertEqual(PocketSupport.email, "support@sentinelayer.com")
        XCTAssertEqual(PocketSupport.mailURL?.absoluteString, "mailto:support@sentinelayer.com")
    }
}
