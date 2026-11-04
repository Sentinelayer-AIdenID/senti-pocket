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
    private static var rule: ((String, Data) -> (status: Int, body: String)?)?
    private static var captured: [(request: URLRequest, body: Data)] = []

    /// `rule`, when it answers, answers by what was sent; else `answers` by method and path.
    static func reset(_ answers: [String: (status: Int, body: String)],
                      rule: ((String, Data) -> (status: Int, body: String)?)? = nil) {
        lock.withLock {
            self.answers = answers
            self.rule = rule
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
            return Self.rule?(key, body) ?? Self.answers[key] ?? (404, "{}")
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
    private var _references: [BlockReference?] = []

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
    /// The post each block the server took was chosen on.
    var references: [BlockReference?] { lock.withLock { _references } }

    func blocks() async throws -> [ServerBlock] {
        try lock.withLock {
            _calls.append("GET")
            guard _online else { throw RoomSendError.retryable(retryAfterSeconds: nil) }
            return _server.map { ServerBlock(actorId: $0, createdAt: nil) }
        }
    }

    func block(_ actorId: String, from reference: BlockReference?) async throws {
        try lock.withLock {
            _calls.append("POST \(actorId)")
            guard _online else { throw RoomSendError.retryable(retryAfterSeconds: nil) }
            _references.append(reference)
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

/// A blocks API whose first list answers only when released, and that cannot take changes (as if it went offline).
/// A later list answers at once with the same blocks, so a sync that should have stopped fails its test, never hangs.
private final class HeldListAPI: BlockListClient, @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<[ServerBlock], Never>?
    private var released: [ServerBlock]?

    var isListing: Bool { lock.withLock { waiter != nil } }

    func blocks() async throws -> [ServerBlock] {
        if let released = lock.withLock({ released }) { return released }
        return await withCheckedContinuation { waiter in lock.withLock { self.waiter = waiter } }
    }

    func release(with actorIds: [String]) {
        let list = actorIds.map { ServerBlock(actorId: $0, createdAt: nil) }
        let waiter = lock.withLock { () -> CheckedContinuation<[ServerBlock], Never>? in
            defer { self.waiter = nil }
            released = list
            return self.waiter
        }
        waiter?.resume(returning: list)
    }

    func block(_ actorId: String, from reference: BlockReference?) async throws {
        throw RoomSendError.retryable(retryAfterSeconds: nil)
    }
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
    private var _actions: [String] = []
    var messages: [String] { lock.withLock { _messages } }
    var replies: [String] { lock.withLock { _replies } }
    /// Every action's type, replies and reactions alike.
    var actions: [String] { lock.withLock { _actions } }

    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        lock.withLock { _messages.append(text) }
    }

    func sendAction(_ action: RoomActionRequest) async throws {
        lock.withLock {
            _actions.append(action.actionType)
            if action.actionType == "reply" { _replies.append(action.note ?? "") }
        }
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

/// Who is signed in, as an API with `sender_id` says it, after `/auth/me` failed `failures` times.
private final class SenderAccount: AccountIdentityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: Int
    private var _asked = 0
    var asked: Int { lock.withLock { _asked } }

    init(failures: Int = 0) {
        self.failures = failures
    }

    func currentAccount() async -> SignedInAccount? {
        lock.withLock { () -> SignedInAccount? in
            _asked += 1
            if failures > 0 {
                failures -= 1
                return nil
            }
            return SignedInAccount(githubUsername: "sam", accountId: "6F1C2B9E-0000-4000-8000-00000000000A",
                                   senderId: "HUMAN-G.6f1c2b9e00004000800000000000000a")
        }
    }
}

/// A Google account (its email name is `sam-rivera`), as an API with `sender_id` says it: it posts under its account id
/// now, and posted as `human-sam-rivera` before sentinelayer-api #1105.
private struct GoogleAccount: AccountIdentityProviding {
    func currentAccount() async -> SignedInAccount? {
        SignedInAccount(githubUsername: "sam-rivera", accountId: "6F1C2B9E-0000-4000-8000-00000000000A",
                        senderId: "human-g.6f1c2b9e00004000800000000000000a")
    }
}

/// Room search that finds `results` for any words.
private struct FoundSearch: RoomSearching {
    let results: [RoomSearchResult]

    func searchRoom(sessionId: String, query: String, beforeSequence: Int64?, limit: Int) async throws -> RoomSearchPage {
        RoomSearchPage(query: query, results: results)
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

        // A reply goes under its own id, on the message it answers.
        SafetyURLProtocol.reset(["POST /api/v1/sessions/room_1/reports": (201, #"{"report":{"id":"r-2","status":"open"}}"#)])
        let reply = RoomReportTarget(sequenceId: 9, replyId: "3f0c2a8e-2c4d-4c38-9e0f-2b1f5f1d7a10", authorId: "review-agent",
                                     authorName: "review-agent")
        try await sender.report(sessionId: "room_1", RoomReportRequest(target: reply, reason: .harassment, note: "again"))
        let replyBody = try XCTUnwrap(JSONSerialization.jsonObject(with: SafetyURLProtocol.requests[0].body) as? [String: Any])
        XCTAssertEqual(Set(replyBody.keys), ["sequenceId", "replyId", "reason", "note"])
        XCTAssertEqual(replyBody["sequenceId"] as? Int, 9)
        XCTAssertEqual(replyBody["replyId"] as? String, "3f0c2a8e-2c4d-4c38-9e0f-2b1f5f1d7a10")
        XCTAssertEqual(replyBody["note"] as? String, "again", "the note is only what was written")

        // The API without the route yet (a bare 404), or offline: not sent, and worth trying again.
        SafetyURLProtocol.reset([:])
        do {
            try await sender.report(sessionId: "room_1", RoomReportRequest(target: target, reason: .spam, note: ""))
            XCTFail("a 404 is not a report sent")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .retryable(retryAfterSeconds: nil))
        }
        // The server's own 404: that message can't be reported.
        SafetyURLProtocol.reset(["POST /api/v1/sessions/room_1/reports":
            (404, #"{"error":{"code":"MESSAGE_NOT_FOUND","message":"No message","request_id":"req-1"}}"#)])
        do {
            try await sender.report(sessionId: "room_1", RoomReportRequest(target: target, reason: .spam, note: ""))
            XCTFail("a refusal is not a report sent")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .rejected)
        }
    }

    func test_what_a_reports_answer_means() {
        // As the API sends it (its error handler lifts the error out of `detail`); `detail` is read too.
        func outcome(_ status: Int, _ code: String? = nil, underDetail: Bool = false) -> RoomSendError? {
            let error = code.map { #"{"code":"\#($0)","message":"No","request_id":"req-1"}"# }
            let json = error.map { underDetail ? #"{"detail":{"error":\#($0)}}"# : #"{"error":\#($0)}"# } ?? "{}"
            do {
                try HTTPRoomMessageSender.reportOutcome(status: status, body: Data(json.utf8))
                return nil
            } catch {
                return error as? RoomSendError
            }
        }
        XCTAssertNil(outcome(201))
        for underDetail in [false, true] {
            XCTAssertEqual(outcome(404, "SESSION_NOT_FOUND", underDetail: underDetail), .rejected,
                           "not in that room: can't be reported")
            XCTAssertEqual(outcome(404, "MESSAGE_NOT_FOUND", underDetail: underDetail), .rejected)
            XCTAssertEqual(outcome(422, "CANNOT_REPORT_OWN_MESSAGE", underDetail: underDetail), .rejected)
        }
        XCTAssertEqual(outcome(403), .notAllowed)
        XCTAssertEqual(outcome(404), .retryable(retryAfterSeconds: nil), "a bare 404 is an API without the route yet")
        XCTAssertEqual(outcome(429), .retryable(retryAfterSeconds: nil))
        XCTAssertEqual(outcome(401), .reauthenticationRequired)
    }

    func test_a_report_the_server_refuses_says_so_and_is_not_sent_again() async {
        let reporter = FakeReporter(results: [RoomSendError.rejected])
        let room = room(reporter: reporter)
        room.handle(.message(message(2, author: "human-sam", text: "Something unkind")))
        room.send(.openReport(RoomReportTarget(sequenceId: 2, authorId: "human-sam", authorName: "sam")))
        room.send(.sendReport(reason: .spam, note: ""))
        await waitUntil("refused") { room.state.report?.phase == .refused }
        room.send(.sendReport(reason: .spam, note: ""))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reporter.requests.count, 1, "a refusal is final")
    }

    func test_only_a_posted_message_or_a_reply_is_offered_for_report() {
        let room = room(reporter: FakeReporter(), blocks: BlockList(account: "sub:a", store: temporaryStore(), client: nil))
        var notice = message(3, author: "human-sam", text: "Attachment uploaded: photo.png")
        notice = RoomMessage(id: notice.id, sequenceId: notice.sequenceId, kind: .message, authorId: notice.authorId,
                             authorName: notice.authorName, isHuman: true, text: notice.text, timestamp: notice.timestamp,
                             eventType: "human_relay")
        room.handle(.message(message(2, author: "human-sam", text: "Hello")))
        room.handle(.message(notice))
        XCTAssertNotNil(rows(room)["evt-2"]?.reportTarget)
        XCTAssertNil(rows(room)["evt-3"]?.reportTarget, "a relayed line takes no report")
        XCTAssertEqual(rows(room)["evt-3"]?.isBlockable, true, "its author can still be blocked")
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

    func test_your_own_posts_are_the_servers_sender_id_when_it_says() async {
        let identity = SenderAccount()
        let room = RoomChatCoordinator(
            sessionId: "room_1", title: "Room", transport: QuietRoom(), identity: identity,
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            reporter: FakeReporter(), onReauthenticationRequired: {}
        )
        room.resume()
        room.handle(.message(message(2, author: "human-g.6f1c2b9e00004000800000000000000a", text: "Mine")))
        room.handle(.message(message(3, author: "human-alex", text: "Someone else")))
        await waitUntil("yours") { self.rows(room)["evt-2"]?.isOwn == true }
        XCTAssertEqual(rows(room)["evt-3"]?.isOwn, false)
        XCTAssertNotNil(rows(room)["evt-3"]?.reportTarget)
        room.pause()
    }

    func test_your_posts_under_your_old_id_are_never_offered_to_report_or_block() async {
        let room = RoomChatCoordinator(
            sessionId: "room_1", title: "Room", transport: QuietRoom(), identity: GoogleAccount(),
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            reporter: FakeReporter(), blocks: BlockList(account: "sub:a", store: temporaryStore(), client: nil),
            onReauthenticationRequired: {}
        )
        room.resume()
        room.handle(.message(message(2, author: "human-g.6f1c2b9e00004000800000000000000a", text: "Mine")))
        room.handle(.message(message(3, author: "human-sam-rivera", text: "Mine, from before the change")))
        room.handle(.message(message(4, author: "human-alex", text: "Someone else")))
        await waitUntil("yours") { self.rows(room)["evt-2"]?.isOwn == true }
        let old = rows(room)["evt-3"]
        XCTAssertNil(old?.reportTarget, "your own old post: no Report")
        XCTAssertEqual(old?.isBlockable, false, "and no Block")
        XCTAssertEqual(old?.isOwn, false, "it shows as it did: a GitHub login of that name may post under that id too")
        XCTAssertNotNil(rows(room)["evt-4"]?.reportTarget)
        XCTAssertEqual(rows(room)["evt-4"]?.isBlockable, true)
        room.pause()
    }

    func test_auth_me_is_asked_again_when_it_fails_as_the_room_opens() async {
        let identity = SenderAccount(failures: 2)
        // Only the waits before /auth/me is asked again pass at once; the room's polls wait as they would.
        let retries = RoomChatCoordinator.identityRetries
        let room = RoomChatCoordinator(
            sessionId: "room_1", title: "Room", transport: QuietRoom(), identity: identity,
            sleep: { seconds in
                if !retries.contains(seconds) { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            onReauthenticationRequired: {}
        )
        room.resume()
        room.handle(.message(message(2, author: "human-g.6f1c2b9e00004000800000000000000a", text: "Mine")))
        await waitUntil("learned on the third look") { self.rows(room)["evt-2"]?.isOwn == true }
        XCTAssertEqual(identity.asked, 3)
        room.pause()
    }

    // MARK: Block

    func test_room_search_shows_the_one_line_for_someone_you_blocked() async {
        let found = FoundSearch(results: [
            RoomSearchResult(sequenceId: 2, snippet: "Something unkind about paste", message: message(2, author: "human-sam")),
            RoomSearchResult(sequenceId: 3, snippet: "Paste is fixed", message: message(3, author: "review-agent"))
        ])
        let model = RoomSearchModel(sessionId: "room_1", searcher: found,
                                    sleep: { _ in }, isBlocked: { $0.lowercased() == "human-sam" },
                                    onReauthenticationRequired: {})
        model.send(.submit("paste"))
        await waitUntil("found") { model.state.rows.count == 2 }
        XCTAssertEqual(model.state.rows.first { $0.sequenceId == 2 }?.snippet, RoomBlocking.hiddenLine)
        XCTAssertEqual(model.state.rows.first { $0.sequenceId == 3 }?.snippet, "Paste is fixed")
    }

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
        try await client.block("review-agent", from: nil)
        try await client.unblock("human-sam")
        let sent = SafetyURLProtocol.requests
        XCTAssertEqual(sent.map { "\($0.request.httpMethod ?? "") \($0.request.url?.path ?? "")" },
                       ["GET /api/v1/me/blocks", "POST /api/v1/me/blocks", "DELETE /api/v1/me/blocks/human-sam"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: sent[1].body) as? [String: String], ["actorId": "review-agent"])
        XCTAssertTrue(sent.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token(subject: "user-a"))" })

        // Before the API has the route (404): may work later, so the change is kept.
        SafetyURLProtocol.reset([:])
        do {
            try await client.block("human-x", from: nil)
            XCTFail("a 404 is not a block taken")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .retryable(retryAfterSeconds: nil))
        }
        // Yourself (422): never, so the change goes.
        SafetyURLProtocol.reset(["POST /api/v1/me/blocks":
            (422, #"{"error":{"code":"CANNOT_BLOCK_SELF","message":"No","request_id":"req-1"}}"#)])
        do {
            try await client.block("human-me", from: nil)
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

    func test_a_block_names_the_message_or_reply_it_was_chosen_on() async throws {
        SafetyURLProtocol.reset(["POST /api/v1/me/blocks": (201, #"{"block":{"actorId":"human-sam"}}"#)])
        let client = HTTPBlockListClient(apiBaseURL: URL(string: "https://api.example.test"), account: "sub:user-a",
                                         urlSession: SafetyURLProtocol.session, tokenProvider: { token(subject: "user-a") })
        let reply = "3f0c2a8e-2c4d-4c38-9e0f-2b1f5f1d7a10"
        try await client.block("human-sam", from: BlockReference(sessionId: "room_1", sequenceId: 42, replyId: reply))
        try await client.block("human-sam", from: BlockReference(sessionId: "room_1", sequenceId: 42, replyId: nil))
        let bodies = try SafetyURLProtocol.requests.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body) as? [String: Any])
        }
        guard bodies.count == 2 else { return XCTFail("expected two blocks sent, got \(bodies.count)") }
        XCTAssertEqual(Set(bodies[0].keys), ["actorId", "sessionId", "sequenceId", "replyId"], "the report route's names")
        XCTAssertEqual(bodies[0]["actorId"] as? String, "human-sam")
        XCTAssertEqual(bodies[0]["sessionId"] as? String, "room_1")
        XCTAssertEqual(bodies[0]["sequenceId"] as? Int, 42)
        XCTAssertEqual(bodies[0]["replyId"] as? String, reply)
        XCTAssertEqual(Set(bodies[1].keys), ["actorId", "sessionId", "sequenceId"], "a message: no replyId")

        // The API's own refusal (yourself) is final: not sent again without the post.
        SafetyURLProtocol.reset(["POST /api/v1/me/blocks":
            (422, #"{"error":{"code":"CANNOT_BLOCK_SELF","message":"No","request_id":"req-1"}}"#)])
        do {
            try await client.block("human-me", from: BlockReference(sessionId: "room_1", sequenceId: 7, replyId: nil))
            XCTFail("a refusal")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .rejected)
        }
        XCTAssertEqual(SafetyURLProtocol.requests.count, 1)
    }

    func test_an_api_from_before_the_post_reference_still_takes_the_block_by_id() async throws {
        // As the API before the reference: it refuses any field it doesn't know, with a validation error and no code.
        SafetyURLProtocol.reset([:], rule: { key, body in
            guard key == "POST /api/v1/me/blocks",
                  let sent = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
            if Set(sent.keys) == ["actorId"] { return (201, #"{"block":{"actorId":"human-sam"}}"#) }
            return (422, #"{"detail":[{"type":"extra_forbidden","loc":["body","sessionId"],"msg":"Extra inputs are not permitted"}]}"#)
        })
        let client = HTTPBlockListClient(apiBaseURL: URL(string: "https://api.example.test"), account: "sub:user-a",
                                         urlSession: SafetyURLProtocol.session, tokenProvider: { token(subject: "user-a") })
        try await client.block("human-sam", from: BlockReference(sessionId: "room_1", sequenceId: 42, replyId: nil))
        let bodies = try SafetyURLProtocol.requests.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body) as? [String: Any])
        }
        guard bodies.count == 2 else { return XCTFail("sent again, by id alone: expected two requests, got \(bodies.count)") }
        XCTAssertEqual(Set(bodies[0].keys), ["actorId", "sessionId", "sequenceId"])
        XCTAssertEqual(bodies[1] as? [String: String], ["actorId": "human-sam"])
    }

    func test_block_from_a_message_or_reply_sends_that_post_and_keeps_it_offline() async {
        let store = temporaryStore()
        // Blocked with no way to the server yet; a later launch has one.
        let blocks = BlockList(account: "sub:a", store: store, client: nil)
        let reply = RoomReply(id: "act-1", targetSequenceId: 3, authorId: "review-agent", text: "A reply",
                              createdAt: "2026-11-03T18:00:05.000000+00:00")
        let room = room(QuietRoom(replies: [reply]), blocks: blocks)
        room.handle(.message(message(2, author: "human-sam", text: "Something unkind")))
        room.handle(.message(message(3, author: "human-alex", text: "Build 319 is green")))
        await waitUntil("reply in the room") { self.rows(room)["reply-act-1"] != nil }
        room.send(.block(rows(room)["evt-2"]!.blockTarget))
        room.send(.block(rows(room)["reply-act-1"]!.blockTarget))
        XCTAssertEqual(blocks.changes.map(\.reference), [
            BlockReference(sessionId: "room_1", sequenceId: 2, replyId: nil),
            BlockReference(sessionId: "room_1", sequenceId: 3, replyId: "act-1")
        ])

        // Kept on the phone with the post, and sent with it once the server can take it.
        let api = FakeBlocksAPI(online: true)
        let relaunched = BlockList(account: "sub:a", store: store, client: api)
        XCTAssertEqual(relaunched.changes, blocks.changes)
        await relaunched.sync()
        XCTAssertEqual(api.references, [
            BlockReference(sessionId: "room_1", sequenceId: 2, replyId: nil),
            BlockReference(sessionId: "room_1", sequenceId: 3, replyId: "act-1")
        ])

        // Unblocking (Blocked people) is by id, and so is a block chosen anywhere but on a post.
        relaunched.unblock("human-sam")
        await waitUntil("unblocked on the server") { api.calls.contains("DELETE human-sam") }
        relaunched.block(RoomBlockTarget(actorId: "build-agent", name: "build-agent"))
        await waitUntil("blocked by id") { api.references.count == 3 }
        XCTAssertEqual(api.references.last, .some(nil))
    }

    // MARK: AI consent

    func test_ai_consent_is_asked_once_per_account_and_again_after_withdrawing() {
        let defaults = temporaryDefaults()
        let consent = AIConsent(account: "sub:a", defaults: defaults)
        XCTAssertTrue(consent.asks)

        consent.grant()
        XCTAssertFalse(consent.asks, "asked once")
        XCTAssertFalse(AIConsent(account: "sub:a", defaults: defaults).asks, "kept across launches")
        XCTAssertTrue(AIConsent(account: "sub:b", defaults: defaults).asks, "another account on this phone is asked for itself")

        consent.withdraw()
        XCTAssertTrue(consent.asks, "withdrawn: asked again")
        XCTAssertTrue(AIConsent(account: "sub:a", defaults: defaults).asks)
    }

    func test_every_room_write_waits_for_the_ok_whatever_the_room() async {
        let consent = AIConsent(account: "sub:a", defaults: temporaryDefaults())
        let sender = RecordingSender()
        let room = room(sender: sender, aiConsent: consent)
        // People only: no agent here, and still it asks.
        room.handle(.message(message(1, author: "human-alex", text: "Hello")))
        room.handle(.message(message(2, author: "human-sam", text: "Hi")))
        XCTAssertTrue(room.state.asksAIConsent)

        room.send(.sendMessage(text: "Ship it"))
        room.send(.sendReply(sequenceId: 2, text: "Thanks"))
        room.send(.react(sequenceId: 2, type: "like"))
        room.send(.editMessage(sequenceId: 1, text: "Hello all"))
        room.send(.setPinned(sequenceId: 2, isPinned: true))
        XCTAssertTrue(room.state.consentRequested, "the room asks")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sender.messages.isEmpty && sender.actions.isEmpty, "nothing went before the answer")

        // Not now: nothing goes; what was written stays, to edit and send again.
        room.send(.declineAIAgents)
        XCTAssertFalse(room.state.consentRequested)
        XCTAssertEqual(room.state.pending.map(\.text), ["Ship it"])
        XCTAssertEqual(room.state.pending.first?.status, .failed(reason: RoomChatCoordinator.consentReason, canRetry: false))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sender.messages.isEmpty && sender.actions.isEmpty)
        XCTAssertFalse(consent.isGiven)

        // OK: the held writes go, in order, and the next ones go at once.
        room.send(.sendMessage(text: "Ship it now"))
        room.send(.react(sequenceId: 2, type: "like"))
        XCTAssertTrue(room.state.consentRequested)
        room.send(.allowAIAgents)
        XCTAssertTrue(consent.isGiven)
        XCTAssertFalse(room.state.asksAIConsent)
        await waitUntil("held writes sent") { sender.messages == ["Ship it now"] && sender.actions == ["like"] }
        room.send(.sendReply(sequenceId: 2, text: "Thanks"))
        await waitUntil("next write sent at once") { sender.replies == ["Thanks"] }
        XCTAssertFalse(room.state.consentRequested)

        consent.withdraw()
        await waitUntil("asks again") { room.state.asksAIConsent }
        room.send(.react(sequenceId: 2, type: "dislike"))
        XCTAssertTrue(room.state.consentRequested, "withdrawn: the next write waits again")
    }

    func test_a_crash_report_without_the_ok_is_kept_not_sent() async {
        let consent = AIConsent(account: "sub:a", defaults: temporaryDefaults())
        let sender = RecordingSender()
        let room = room(sender: sender, aiConsent: consent)
        var handled = false
        room.sendCrashReport("Pocket closed unexpectedly") { handled = true }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sender.messages.isEmpty)
        XCTAssertFalse(handled, "offered again next time")
        XCTAssertEqual(room.state.pending.map(\.text), ["Pocket closed unexpectedly"])
    }

    func test_every_ticket_write_asks_and_reading_never_does() {
        let writes: [RoomTicketsIntent] = [
            .answerDecision(ticketId: "t1", answer: "Yes", detail: ""), .retryDecision(ticketId: "t1"),
            .fileTicket(title: "T", body: "B", assignee: nil), .claim(ticketId: "t1"), .release(ticketId: "t1"),
            .assign(ticketId: "t1", assignee: "review-agent"), .edit(ticketId: "t1", title: "T", body: "B"),
            .comment(ticketId: "t1", body: "C"), .retryComment(ticketId: "t1"), .chatAboutIt(ticketId: "t1", note: ""),
            .startAgent(ticketId: "t1")
        ]
        XCTAssertTrue(writes.allSatisfy(\.writesToTheRoom))
        let reads: [RoomTicketsIntent] = [.setShowsArchived(true), .search("x"), .refresh,
                                          .openSourceMessage(sequenceId: 1), .loadComments(ticketId: "t1")]
        XCTAssertFalse(reads.contains(where: \.writesToTheRoom))
    }

    func test_the_pocket_sheet_drafts_what_you_dictate_only_after_the_ok() {
        OutboxStore.clear()
        defer { OutboxStore.clear() }
        let consent = AIConsent(account: "sub:a", defaults: temporaryDefaults())
        let write = PhoneWriteViewModel(sessionId: "6cf7e861", receiptTrustAvailable: true,
                                        client: PocketWriteClient(apiBaseURL: nil, tokenProvider: { nil }))
        var asked: (() -> Void)?
        PocketPhoneView.review("Ship it", write: write, aiConsent: consent) { asked = $0 }
        XCTAssertNotNil(asked, "asked first, with the rooms' question")
        XCTAssertEqual(write.state, .composing, "nothing drafted before the answer (Not now leaves it in the box)")

        consent.grant()
        asked?()
        guard case .confirming = write.state else { return XCTFail("drafted after OK, got \(write.state)") }

        write.cancel()
        var askedAgain = false
        PocketPhoneView.review("Ship it now", write: write, aiConsent: consent) { _ in askedAgain = true }
        XCTAssertFalse(askedAgain, "said once: not asked again")
        guard case .confirming = write.state else { return XCTFail("drafted at once, got \(write.state)") }
    }

    func test_a_dial_asks_the_same_question_and_goes_on_only_after_ok() async {
        let consent = AIConsent(account: "sub:a", defaults: temporaryDefaults())
        let asker = AIConsentAsker(storedConsent: { consent })

        // Not now: the dial doesn't go on.
        let declined = Task { await asker.allows() }
        await waitUntil("asked") { asker.held != nil }
        let first = asker.held
        asker.held = nil
        first?.decline()
        let declinedAnswer = await declined.value
        XCTAssertFalse(declinedAnswer)
        XCTAssertFalse(consent.isGiven)

        // OK: it does.
        let allowed = Task { await asker.allows() }
        await waitUntil("asked again") { asker.held != nil }
        let second = asker.held
        asker.held = nil
        consent.grant()
        second?.proceed()
        let allowedAnswer = await allowed.value
        XCTAssertTrue(allowedAnswer)

        // Said: at once, with nothing asked.
        let atOnce = await asker.allows()
        XCTAssertTrue(atOnce)
        XCTAssertNil(asker.held)

        // Hung up while it asks: it doesn't go on, and the question goes.
        consent.withdraw()
        let hungUp = Task { await asker.allows() }
        await waitUntil("asked") { asker.held != nil }
        hungUp.cancel()
        let hungUpAnswer = await hungUp.value
        XCTAssertFalse(hungUpAnswer)
        await waitUntil("question gone") { asker.held == nil }

        // The signed-in screens' consent is the one asked.
        let screens = AIConsent(account: "sub:a", defaults: temporaryDefaults())
        screens.grant()
        asker.consent = screens
        let fromScreens = await asker.allows()
        XCTAssertTrue(fromScreens)
    }

    // MARK: Support

    func test_blocked_people_says_what_the_question_says() {
        XCTAssertTrue(BlockedPeopleView.covers.contains(RoomBlocking.calls))
        XCTAssertTrue(BlockedPeopleView.covers.contains(RoomBlocking.byId))
    }

    func test_the_support_contact_is_one_address() {
        XCTAssertEqual(PocketSupport.email, "help@plexaura.io")
        XCTAssertEqual(PocketSupport.mailURL?.absoluteString, "mailto:help@plexaura.io")
    }
}
