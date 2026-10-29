import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

// MARK: - HTTP

private final class ReceiptsURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var body = Data("{}".utf8)
    private static var captured: [(URLRequest, Data)] = []

    static func reset(status: Int = 200, body: String = "{}") {
        lock.lock()
        self.status = status
        self.body = Data(body.utf8)
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
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.captured.append((request, data))
        let status = Self.status
        let body = Self.body
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "7"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HTTPRoomReceiptsTests: XCTestCase {
    private let room = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
    private let message = "7c3e9f10-2a4b-4c5d-8e6f-0a1b2c3d4e5f"
    private let reply = "5d2c8a1e-7b3f-4c9d-8e6a-0f1b2c3d4e5f"

    private func client(status: Int = 200, body: String = "{}") -> HTTPRoomReceipts {
        ReceiptsURLProtocol.reset(status: status, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReceiptsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return HTTPRoomReceipts(
            apiBaseURL: URL(string: "https://api.example.test"),
            writeSession: session,
            readSession: session,
            tokenProvider: { "test-bearer-token" }
        )
    }

    func test_the_view_route_signature_matches_the_api_known_answer() {
        XCTAssertEqual(
            SessionMutationCSRF.token(bearer: "test-bearer-token", sessionId: room,
                                      routeTemplate: HTTPRoomReceipts.viewRouteTemplate, idempotencyKey: "view-kav-1"),
            "e98cfb96f22cc2e5ee1f232ba64adb069db6ff505a62619c7847aef4c0066188",
            "computed with the API's own rule (routes/sessions.py, route POST .../view-receipts)"
        )
    }

    func test_a_view_report_is_signed_and_names_no_agent() async throws {
        let receipts = client(body: #"{"ok":true,"recorded":2}"#)
        let targets = [
            try XCTUnwrap(RoomViewTarget(kind: .message, id: message, revision: 2)),
            try XCTUnwrap(RoomViewTarget(kind: .reply, id: reply, revision: 1))
        ]
        try await receipts.recordViews(sessionId: room, targets: targets)
        let (request, body) = try XCTUnwrap(ReceiptsURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(room)/view-receipts")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer-token")
        let key = try XCTUnwrap(request.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertTrue(key.hasPrefix("view-"), key)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sentinelayer-Session-Mutation"), "session-mutation")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-Token"),
                       SessionMutationCSRF.token(bearer: "test-bearer-token", sessionId: room,
                                                 routeTemplate: HTTPRoomReceipts.viewRouteTemplate, idempotencyKey: key))
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"), "a native client sends no browser headers")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["targets"], "a person sends no agentId; extra fields are refused")
        let sent = try XCTUnwrap(json["targets"] as? [[String: Any]])
        XCTAssertEqual(sent.map { $0["kind"] as? String }, ["message", "reply"])
        XCTAssertEqual(sent.map { $0["id"] as? String }, [message, reply])
        XCTAssertEqual(sent.map { $0["targetRevision"] as? Int }, [2, 1])
        XCTAssertEqual(Set(sent[0].keys), ["kind", "id", "targetRevision"])
    }

    func test_who_viewed_is_read_by_kind_and_errors_keep_their_class() async throws {
        let receipts = client(body: """
        {"targets":[{"kind":"message","id":"\(message)","messageRevision":1,"viewedCount":1,"selfViewed":true,
          "viewers":[{"actorKind":"human","actorId":"\(reply)","viewedAt":"2026-10-28T23:00:00+00:00"}],"viewersTruncated":false}]}
        """)
        let summaries = try await receipts.views(sessionId: room, targets: [
            try XCTUnwrap(RoomViewTarget(kind: .message, id: message, revision: 1)),
            try XCTUnwrap(RoomViewTarget(kind: .reply, id: reply, revision: 1))
        ])
        XCTAssertEqual(summaries.first?.viewedCount, 1)
        let (request, _) = try XCTUnwrap(ReceiptsURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod ?? "GET", "GET")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "messageIds" }?.value, message)
        XCTAssertEqual(query.first { $0.name == "replyIds" }?.value, reply)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-CSRF-Token"), "reads need no signature")

        let refused = client(status: 429)
        do {
            _ = try await refused.views(sessionId: room, targets: [try XCTUnwrap(RoomViewTarget(kind: .message, id: message, revision: 1))])
            XCTFail("expected a retryable error")
        } catch {
            XCTAssertEqual(error as? RoomSendError, .retryable(retryAfterSeconds: 7))
        }
    }

    func test_presence_publishes_this_device_and_reads_the_room() async throws {
        let receipts = client(body: #"{"status":"ok","recorded":true,"kind":"human","ttlSeconds":60,"state":"active"}"#)
        let lifetime = try await receipts.publishPresence(sessionId: room, active: true, clientInstanceId: "ios-device-1")
        XCTAssertEqual(lifetime, 60)
        let (request, body) = try XCTUnwrap(ReceiptsURLProtocol.requests().first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(room)/presence")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json as? [String: String], ["state": "active", "clientInstanceId": "ios-device-1"],
                       "no agentId: a person is named by the server")

        let leaving = client()
        _ = try await leaving.publishPresence(sessionId: room, active: false, clientInstanceId: "ios-device-1")
        let stopped = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(ReceiptsURLProtocol.requests().first).1) as? [String: Any])
        XCTAssertEqual(stopped["state"] as? String, "stopped")

        let reading = client(body: #"{"status":"ok","present":[{"agentId":"human-x","kind":"human","displayName":"griff","state":"active"}],"humansOnline":1,"agentsOnline":0,"ttlSeconds":90}"#)
        let presence = try await reading.presence(sessionId: room)
        XCTAssertEqual(presence.humansOnline, 1)
        XCTAssertEqual(presence.participants.first?.displayName, "griff")
    }
}

// MARK: - Tracker and room

private final class FakeReceipts: RoomReceiptsClient, @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [[RoomViewTarget]] = []
    private var reads: [[RoomViewTarget]] = []
    private var heartbeats: [Bool] = []
    private var failReports: Int
    var summaries: [RoomViewSummary] = []
    var presenceSnapshot = RoomPresence(isAvailable: true, participants: [], humansOnline: 0, agentsOnline: 0, ttlSeconds: 90)

    init(failReports: Int = 0) { self.failReports = failReports }

    func recordViews(sessionId: String, targets: [RoomViewTarget]) async throws {
        lock.lock()
        reports.append(targets)
        let fail = failReports > 0
        if fail { failReports -= 1 }
        lock.unlock()
        if fail { throw RoomSendError.retryable(retryAfterSeconds: nil) }
    }

    func views(sessionId: String, targets: [RoomViewTarget]) async throws -> [RoomViewSummary] {
        lock.lock()
        reads.append(targets)
        let result = summaries.filter { summary in targets.contains { $0.id == summary.id } }
        lock.unlock()
        return result
    }

    func publishPresence(sessionId: String, active: Bool, clientInstanceId: String) async throws -> Int? {
        lock.lock()
        heartbeats.append(active)
        lock.unlock()
        return 90
    }

    func presence(sessionId: String) async throws -> RoomPresence {
        lock.lock()
        defer { lock.unlock() }
        return presenceSnapshot
    }

    func reported() -> [[RoomViewTarget]] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }

    func readTargets() -> [[RoomViewTarget]] {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func presenceCalls() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return heartbeats
    }
}

private final class OneMessageTransport: RoomTransport, @unchecked Sendable {
    let history: [RoomMessage]
    init(_ history: [RoomMessage]) { self.history = history }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: beforeSequence == nil ? history : [])
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }
}

private struct KnownAccount: AccountIdentityProviding {
    let account: SignedInAccount?
    func currentAccount() async -> SignedInAccount? { account }
}

@MainActor
final class RoomReceiptsTrackerTests: XCTestCase {
    private let first = "7c3e9f10-2a4b-4c5d-8e6f-0a1b2c3d4e5f"
    private let second = "5d2c8a1e-7b3f-4c9d-8e6a-0f1b2c3d4e5f"
    private let me = "aaaaaaaa-0000-4000-8000-000000000001"

    private func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    private func tracker(_ client: FakeReceipts, changes: (() -> Void)? = nil) -> RoomReceiptsTracker {
        RoomReceiptsTracker(
            sessionId: "room_1",
            client: client,
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            now: { Date() },
            onChange: { changes?() }
        )
    }

    func test_a_row_on_screen_is_reported_once_per_revision() async throws {
        let client = FakeReceipts()
        let receipts = tracker(client)
        receipts.start()
        let v1 = try XCTUnwrap(RoomViewTarget(kind: .message, id: first, revision: 1))
        receipts.setOnScreen(v1, true)
        await waitUntil("reported") { client.reported().count == 1 }
        receipts.setOnScreen(v1, false)
        receipts.setOnScreen(v1, true)
        let v2 = try XCTUnwrap(RoomViewTarget(kind: .message, id: first, revision: 2))
        receipts.setOnScreen(v2, true)
        await waitUntil("the edit is reported") { client.reported().count == 2 }
        XCTAssertEqual(client.reported().flatMap { $0 }.map(\.revision), [1, 2],
                       "the same revision is never reported twice in a visit; an edit is")
        receipts.stop()
    }

    func test_a_row_that_leaves_before_the_dwell_is_not_reported() async throws {
        let client = FakeReceipts()
        let receipts = tracker(client)
        receipts.start()
        let passing = try XCTUnwrap(RoomViewTarget(kind: .message, id: first, revision: 1))
        let staying = try XCTUnwrap(RoomViewTarget(kind: .message, id: second, revision: 1))
        receipts.setOnScreen(passing, true)
        receipts.setOnScreen(passing, false)
        receipts.setOnScreen(staying, true)
        await waitUntil("the staying row is reported") { client.reported().count == 1 }
        XCTAssertEqual(client.reported().flatMap { $0 }.map(\.id), [second])
        receipts.stop()
    }

    func test_a_failed_report_is_retried_while_the_row_stays() async throws {
        let client = FakeReceipts(failReports: 2)
        let receipts = tracker(client)
        receipts.start()
        receipts.setOnScreen(try XCTUnwrap(RoomViewTarget(kind: .message, id: first, revision: 1)), true)
        await waitUntil("third attempt") { client.reported().count == 3 }
        XCTAssertEqual(Set(client.reported().map { $0.map(\.id) }), [[first]])
        receipts.stop()
    }

    func test_presence_runs_only_while_the_room_is_open() async {
        let client = FakeReceipts()
        let receipts = tracker(client)
        receipts.start()
        await waitUntil("first heartbeat") { client.presenceCalls() == [true] }
        receipts.stop()
        await waitUntil("stopped") { client.presenceCalls() == [true, false] }
        XCTAssertFalse(receipts.clientInstanceId.isEmpty)
        XCTAssertTrue(receipts.clientInstanceId.hasPrefix("ios-"))
    }

    func test_the_room_reports_chat_rows_shows_who_viewed_and_skips_rows_the_api_refuses() async throws {
        let client = FakeReceipts()
        client.summaries = [RoomViewSummary(
            kind: .message, id: first, revision: 1, viewedCount: 2, selfViewed: true,
            viewers: [
                RoomViewer(isHuman: true, actorId: me, viewedAt: "2026-10-28T23:00:00+00:00"),
                RoomViewer(isHuman: false, actorId: "cobalt-warden", viewedAt: "2026-10-28T23:01:00+00:00")
            ]
        )]
        client.presenceSnapshot = RoomPresence(
            isAvailable: true,
            participants: [RoomPresentParticipant(id: "human-\(me)", isHuman: true, displayName: "mrrCarter")],
            humansOnline: 1, agentsOnline: 0, ttlSeconds: 90
        )
        let mine = RoomMessage(id: first, sequenceId: 10, kind: .message, authorId: "human-mrrcarter",
                               authorName: "mrrCarter", isHuman: true, text: "ship it", timestamp: "2026-10-28T22:59:00Z")
        let relayed = RoomMessage(id: second, sequenceId: 11, kind: .message, authorId: "human-griff", authorName: "griff",
                                  isHuman: true, text: "relayed", timestamp: "2026-10-28T23:00:00Z", eventType: "human_relay")
        let coordinator = RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: OneMessageTransport([mine, relayed]),
            identity: KnownAccount(account: SignedInAccount(githubUsername: "mrrCarter", accountId: me)),
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            receipts: client,
            onReauthenticationRequired: {}
        )
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }
        coordinator.send(.messageOnScreen(id: second, isOnScreen: true))
        coordinator.send(.messageOnScreen(id: first, isOnScreen: true))
        await waitUntil("reported") { !client.reported().isEmpty }
        XCTAssertEqual(client.reported().flatMap { $0 }.map(\.id), [first],
                       "a relayed row is not a session_message: the API would refuse the whole batch")

        func row(_ id: String) -> RoomChatMessageRow? {
            for case .message(let message) in coordinator.state.rows where message.id == id { return message }
            return nil
        }
        await waitUntil("who viewed") { row(self.first)?.views != nil && coordinator.state.presence != nil }
        XCTAssertEqual(row(first)?.views?.line, "Viewed by mrrCarter and cobalt-warden")
        XCTAssertEqual(row(first)?.views?.ticks, .seen, "an agent viewed your message")
        XCTAssertTrue(row(first)?.views?.seenBy.hasPrefix("Seen by cobalt-warden at ") == true,
                      row(first)?.views?.seenBy ?? "nil")
        XCTAssertNil(row(second)?.views)
        XCTAssertEqual(coordinator.state.presence?.label, "1 human here")
        XCTAssertEqual(coordinator.state.presence?.people.map(\.name), ["mrrCarter"])
        coordinator.pause()
    }
}
