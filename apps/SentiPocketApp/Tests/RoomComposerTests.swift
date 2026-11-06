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

    /// Warden, #298 review: a sender bound to the account that queued the work sends only while that account is the
    /// one signed in. After another account signs in (a forced sign-in on a shared phone), it sends nothing at all.
    func test_a_sender_bound_to_one_account_never_sends_with_another_accounts_token() async throws {
        func jwt(_ sub: String) -> String {
            let payload = Data("{\"sub\":\"\(sub)\"}".utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            return "e30.\(payload).sig"
        }
        final class Current: @unchecked Sendable { var token: String? }
        let current = Current()
        RoomSendURLProtocol.reset(status: 200, headers: [:])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoomSendURLProtocol.self]
        let sender = HTTPRoomMessageSender(apiBaseURL: URL(string: "https://api.example.test"),
                                           urlSession: URLSession(configuration: configuration),
                                           tokenProvider: { current.token }).bound(toAccount: "sub:alice")
        current.token = jwt("alice")
        try await sender.sendHumanMessage(sessionId: "room_1", text: "from alice", clientId: "hm_1")
        XCTAssertEqual(RoomSendURLProtocol.requests().count, 1, "sent while its account is signed in")

        current.token = jwt("bob")
        do {
            try await sender.sendHumanMessage(sessionId: "room_1", text: "from alice", clientId: "hm_2")
            XCTFail("never sent with another account's token")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .reauthenticationRequired)
        }
        XCTAssertEqual(RoomSendURLProtocol.requests().count, 1, "nothing went out as bob")
        let none = HTTPRoomMessageSender(apiBaseURL: URL(string: "https://api.example.test"),
                                         urlSession: URLSession(configuration: configuration),
                                         tokenProvider: { current.token }).bound(toAccount: nil)
        do {
            try await none.sendHumanMessage(sessionId: "room_1", text: "x", clientId: "hm_3")
            XCTFail("a sender bound to no account never sends")
        } catch {}
        XCTAssertEqual(RoomSendURLProtocol.requests().count, 1)
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

    func test_protected_room_reads_keep_no_disk_cache_cookies_or_credentials() {
        let configuration = SentiHTTPTransportPolicy.makeProtectedReadConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, SentiHTTPTransportPolicy.requestTimeout)
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
    let account: SignedInAccount?
    func currentAccount() async -> SignedInAccount? { account }
}

@MainActor
final class RoomComposerCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        sender: ScriptedSender?,
        role: String = "owner",
        identity: (any AccountIdentityProviding)? = nil,
        outbox: RoomSendOutbox? = nil,
        account: String? = "sub:carter",
        ownAuthorIds: Set<String> = [],
        onReauth: @escaping @MainActor () -> Void = {}
    ) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: QuietRoomTransport(),
            sender: sender,
            identity: identity,
            membershipRole: role,
            ownAuthorIds: ownAuthorIds,
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            outbox: outbox,
            outboxAccount: outbox == nil ? nil : account,
            onReauthenticationRequired: onReauth
        )
    }

    private func temporaryOutbox() -> RoomSendOutbox {
        RoomSendOutbox(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-\(UUID().uuidString).json"))
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
        XCTAssertTrue(coordinator.state.composer.canPost)
        XCTAssertEqual(coordinator.state.composer.maximumLength, HTTPRoomMessageSender.maximumLength)

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

    /// A shared crash report is marked handled only once the room accepted it: a failed send keeps it for next time.
    func test_a_crash_report_is_handled_only_after_the_room_accepts_it() async {
        let failing = ScriptedSender([.failure(.retryable(retryAfterSeconds: nil))])
        let lost = makeCoordinator(sender: failing)
        lost.resume()
        var handledAfterFailure = 0
        lost.sendCrashReport("Pocket closed unexpectedly") { handledAfterFailure += 1 }
        await waitUntil("the send failed") {
            if case .failed = lost.state.pending.first?.status { return true }
            return false
        }
        XCTAssertEqual(handledAfterFailure, 0, "a lost send leaves the report unhandled")
        lost.pause()

        let sender = ScriptedSender([.success(())])
        let coordinator = makeCoordinator(sender: sender)
        coordinator.resume()
        var handled = 0
        coordinator.sendCrashReport("Pocket closed unexpectedly") { handled += 1 }
        XCTAssertEqual(handled, 0, "not before the room answers")
        await waitUntil("sent") { coordinator.state.pending.first?.status == .sent }
        XCTAssertEqual(handled, 1)
        coordinator.pause()
    }

    /// The room kept the message but the answer was lost, then the app was killed. After the relaunch
    /// the message comes back unconfirmed under its own client id; Retry sends that same id, so the room keeps one copy.
    func test_a_send_cut_off_by_a_kill_comes_back_under_its_own_client_id_and_retries_once() async {
        let outbox = temporaryOutbox()
        let first = ScriptedSender([.failure(.retryable(retryAfterSeconds: nil))])
        let before = makeCoordinator(sender: first, outbox: outbox)
        before.resume()
        before.send(.sendMessage(text: "ship it"))
        await waitUntil("the answer was lost") {
            if case .failed = before.state.pending.first?.status { return true }
            return false
        }
        let original = first.snapshot()[0].clientId
        before.pause()

        // A new process: the same room, a new coordinator, nothing in memory.
        let second = ScriptedSender([.success(())])
        let after = makeCoordinator(sender: second, outbox: outbox)
        XCTAssertEqual(after.state.pending.map(\.clientId), [original], "the unsent message is back")
        XCTAssertEqual(after.state.pending.first?.text, "ship it")
        guard case .failed(let reason, true) = after.state.pending.first?.status else {
            return XCTFail("offered to retry, not sent on its own")
        }
        XCTAssertEqual(reason, RoomChatCoordinator.unconfirmedReason)
        XCTAssertTrue(second.snapshot().isEmpty, "nothing is sent until the person chooses Retry")
        after.resume()
        after.send(.retrySend(clientId: original))
        await waitUntil("sent") { after.state.pending.first?.status == .sent }
        XCTAssertEqual(second.snapshot().map(\.clientId), [original], "the same client id, never a new one")
        XCTAssertTrue(outbox.items(account: "sub:carter", sessionId: "room_1").isEmpty, "confirmed, so forgotten")
        after.pause()
    }

    /// Review of #298: with no account passed in, sends are kept under the one from your author ids, and a relaunch
    /// must restore them from that same account, not look for none.
    func test_a_send_kept_under_the_author_id_account_comes_back_after_a_kill() async {
        let outbox = temporaryOutbox()
        let first = ScriptedSender([.failure(.retryable(retryAfterSeconds: nil))])
        let before = makeCoordinator(sender: first, outbox: outbox, account: nil, ownAuthorIds: ["human-mrrcarter"])
        before.resume()
        before.send(.sendMessage(text: "ship it"))
        await waitUntil("the answer was lost") {
            if case .failed = before.state.pending.first?.status { return true }
            return false
        }
        let original = first.snapshot()[0].clientId
        before.pause()
        XCTAssertEqual(outbox.items(account: "human-mrrcarter", sessionId: "room_1").map(\.clientId), [original])

        let after = makeCoordinator(sender: ScriptedSender([]), outbox: outbox, account: nil,
                                    ownAuthorIds: ["human-mrrcarter"])
        XCTAssertEqual(after.state.pending.map(\.clientId), [original], "the unsent message is back, same client id")
    }

    /// Review of #298: a write the phone could not make is reported, and the send still goes.
    func test_an_outbox_the_phone_cannot_write_reports_it_and_the_send_still_goes() async {
        let unwritable = RoomSendOutbox(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)/outbox.json"))
        let item = RoomSendOutbox.Item(clientId: "c1", text: "hi", createdAt: Date())
        XCTAssertFalse(unwritable.add(item, account: "sub:carter", sessionId: "room_1"))
        let writable = temporaryOutbox()
        XCTAssertTrue(writable.add(item, account: "sub:carter", sessionId: "room_1"))
        XCTAssertTrue(writable.remove(clientId: "c1", account: "sub:carter", sessionId: "room_1"))

        let sender = ScriptedSender([.success(())])
        let coordinator = makeCoordinator(sender: sender, outbox: unwritable)
        coordinator.resume()
        coordinator.send(.sendMessage(text: "still sent"))
        await waitUntil("sent") { coordinator.state.pending.first?.status == .sent }
        XCTAssertEqual(sender.snapshot().map(\.text), ["still sent"])
        coordinator.pause()
    }

    func test_discarding_an_unsent_message_forgets_it_and_another_account_never_sees_it() async {
        let outbox = temporaryOutbox()
        let sender = ScriptedSender([.failure(.retryable(retryAfterSeconds: nil))])
        let coordinator = makeCoordinator(sender: sender, outbox: outbox)
        coordinator.resume()
        coordinator.send(.sendMessage(text: "draft for later"))
        await waitUntil("failed") {
            if case .failed = coordinator.state.pending.first?.status { return true }
            return false
        }
        XCTAssertTrue(outbox.items(account: "sub:someone-else", sessionId: "room_1").isEmpty)
        coordinator.send(.discardSend(clientId: sender.snapshot()[0].clientId))
        XCTAssertTrue(outbox.items(account: "sub:carter", sessionId: "room_1").isEmpty)
        coordinator.pause()
    }

    /// Warden, #298 review: unsent text is kept per account, so another account signing in on this phone (a forced
    /// sign-in, say) never finds the last one's draft in its composer; the old key shared by everyone goes.
    func test_drafts_are_kept_per_account_and_the_old_shared_key_goes() {
        let legacy = RoomComposerDraft.savedKey(sessionId: "room_1")
        UserDefaults.standard.set("the last person's text", forKey: legacy)
        let coordinator = makeCoordinator(sender: ScriptedSender([]), outbox: temporaryOutbox())
        XCTAssertEqual(coordinator.state.draftKey, RoomComposerDraft.savedKey(sessionId: "room_1", account: "sub:carter"))
        XCTAssertNil(UserDefaults.standard.string(forKey: legacy), "no one can tell whose the old text was: it goes")
        XCTAssertNotEqual(RoomComposerDraft.savedKey(sessionId: "room_1", account: "sub:carter"),
                          RoomComposerDraft.savedKey(sessionId: "room_1", account: "sub:someone-else"))
        XCTAssertNil(makeCoordinator(sender: ScriptedSender([])).state.draftKey, "no account, no draft kept")
    }

    func test_the_account_comes_from_the_tokens_subject() {
        let payload = Data(#"{"sub":"user-42","exp":1}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        XCTAssertEqual(RoomSendOutbox.account(token: "h.\(payload).s"), "sub:user-42")
        XCTAssertNil(RoomSendOutbox.account(token: "not-a-jwt"))
        XCTAssertNil(RoomSendOutbox.account(token: nil))
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

    func test_a_message_over_the_limit_keeps_every_character_and_is_never_sent() async {
        let sender = ScriptedSender([])
        let coordinator = makeCoordinator(sender: sender)
        coordinator.resume()
        let huge = String(repeating: "a", count: HTTPRoomMessageSender.maximumLength + 1)
        coordinator.send(.sendMessage(text: huge))
        XCTAssertEqual(coordinator.state.pending.first?.text.count, huge.count, "nothing typed is lost")
        guard case .failed(_, let canRetry)? = coordinator.state.pending.first?.status else {
            return XCTFail("an oversized message is refused before the network")
        }
        XCTAssertFalse(canRetry)
        XCTAssertTrue(sender.snapshot().isEmpty)
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
        let coordinator = makeCoordinator(sender: nil, identity: FixedIdentity(account: SignedInAccount(githubUsername: "mrrCarter", accountId: "u-1")))
        XCTAssertEqual(coordinator.state.composer, .hidden)
        coordinator.resume()
        await waitUntil("identity") { coordinator.state.ownMentionHandles.contains("mrrcarter") }
        XCTAssertTrue(coordinator.state.ownMentionHandles.contains("all"))
        coordinator.pause()
    }
}
