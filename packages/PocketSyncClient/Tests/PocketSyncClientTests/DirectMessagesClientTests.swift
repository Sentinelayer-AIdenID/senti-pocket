import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts
import XCTest
@testable import PocketSyncClient

/// Answers the personal routes (direct messages, room folders) from the test, and keeps what was asked.
final class PersonalRoutesURLProtocol: URLProtocol {
    struct Seen {
        let method: String
        let path: String
        let authorization: String?
        let contentType: String?
        let body: JSONValue?
    }

    private static let lock = NSLock()
    private static var handler: ((Seen) -> (Int, String))?
    private static var seen: [Seen] = []
    /// Runs while the request is out, before the answer is given (to sign another account in, say).
    private static var during: (() -> Void)?

    static func reset(during: (() -> Void)? = nil, handler: @escaping (Seen) -> (Int, String)) {
        lock.lock()
        self.handler = handler
        self.during = during
        seen = []
        lock.unlock()
    }

    static var requests: [Seen] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PersonalRoutesURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                bytes.append(buffer, count: read)
            }
            stream.close()
            data = bytes
        }
        let item = Seen(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: data.flatMap { $0.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: $0) }
        )
        Self.lock.lock()
        Self.seen.append(item)
        let handler = Self.handler
        let during = Self.during
        Self.lock.unlock()
        during?()
        let (status, body) = handler?(item) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    init(_ token: String?) { self.token = token }
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return token }
        set { lock.lock(); token = newValue; lock.unlock() }
    }
}

/// Direct messages phase 1 against the pinned contract (2026-11-04): request shapes, the `dm` object, and every refusal
/// read as one answer. Ids and names are made up.
final class DirectMessagesClientTests: XCTestCase {
    private let origin = URL(string: "https://api.example.test")!
    private let tokens = TokenBox("person-token")

    private func client(during: (() -> Void)? = nil,
                        _ handler: @escaping (PersonalRoutesURLProtocol.Seen) -> (Int, String)) -> HTTPDirectMessagesClient {
        PersonalRoutesURLProtocol.reset(during: during, handler: handler)
        let tokens = self.tokens
        return HTTPDirectMessagesClient(apiBaseURL: origin, urlSession: PersonalRoutesURLProtocol.session(),
                                        tokenProvider: { tokens.value })
    }

    static let dm = """
    {"dm": {"sessionId": "dm-0001", "kind": "direct",
            "counterpart": {"senderId": "review-agent", "kind": "agent", "displayName": "Review Agent"},
            "originRoom": {"sessionId": "room-0001", "title": "Design review"},
            "mutualRooms": [{"sessionId": "room-0001", "title": "Design review"},
                            {"sessionId": "room-0002", "title": "Release train"},
                            {"sessionId": "room-0001", "title": "Design review"}],
            "memoryShare": [],
            "created": true}}
    """

    func test_message_posts_the_target_and_the_room_you_are_in_and_reads_the_dm() async throws {
        let dms = client { _ in (201, Self.dm) }
        let dm = try await dms.openDirectMessage(with: "review-agent", from: "room-0001")
        let request = try XCTUnwrap(PersonalRoutesURLProtocol.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/dms")
        XCTAssertEqual(request.authorization, "Bearer person-token")
        XCTAssertEqual(request.contentType, "application/json")
        XCTAssertEqual(request.body?["targetSenderId"]?.stringValue, "review-agent")
        XCTAssertEqual(request.body?["contextRoomId"]?.stringValue, "room-0001")
        XCTAssertEqual(dm.sessionId, "dm-0001")
        XCTAssertEqual(dm.counterpart, SessionCounterpart(senderId: "review-agent", kind: "agent", displayName: "Review Agent"))
        XCTAssertEqual(dm.originRoom, DirectRoomReference(sessionId: "room-0001", title: "Design review"))
        XCTAssertEqual(dm.mutualRooms.map(\.sessionId), ["room-0001", "room-0002"], "a room listed twice counts once")
        XCTAssertTrue(dm.created)
        XCTAssertFalse(dm.sharesMemory(in: "room-0001"), "no switch for the room is the server's default: off")
    }

    func test_every_refusal_and_the_flag_off_read_as_one_answer() async {
        for (status, body) in [(404, #"{"error":{"code":"DM_TARGET_UNAVAILABLE"}}"#), (404, #"{"detail":"Not Found"}"#),
                               (404, ""), (403, #"{"detail":"forbidden"}"#)] {
            let dms = client { _ in (status, body) }
            do {
                _ = try await dms.openDirectMessage(with: "human-someone", from: "room-0001")
                XCTFail("\(status) opened a direct message")
            } catch {
                XCTAssertEqual(error as? DirectMessageError, .unavailable, "\(status) \(body)")
            }
            do {
                _ = try await dms.directMessageSettings()
                XCTFail("\(status) read settings")
            } catch {
                XCTAssertEqual(error as? DirectMessageError, .unavailable, "settings \(status)")
            }
        }
    }

    func test_other_failures_are_told_apart_from_a_refusal() async {
        let cases: [(Int, DirectMessageError)] = [(401, .reauthenticationRequired), (429, .retryable), (500, .retryable),
                                                  (503, .retryable), (400, .rejected), (422, .rejected)]
        for (status, expected) in cases {
            let dms = client { _ in (status, "{}") }
            do {
                _ = try await dms.directMessage("dm-0001")
                XCTFail("\(status) answered")
            } catch {
                XCTAssertEqual(error as? DirectMessageError, expected, "\(status)")
            }
        }
    }

    func test_the_dm_reads_with_or_without_its_wrapper_and_needs_a_counterpart() async throws {
        let bare = """
        {"sessionId": "dm-0002", "kind": "direct",
         "counterpart": {"senderId": "human-sam", "kind": "human", "displayName": "Sam"},
         "originRoom": null, "mutualRooms": [], "memoryShare": [{"roomId": "room-0001", "enabled": true}],
         "created": false}
        """
        var dms = client { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.path, "/api/v1/dms/dm-0002")
            return (200, bare)
        }
        let dm = try await dms.directMessage("dm-0002")
        XCTAssertNil(dm.originRoom, "a room gone or no longer visible is null")
        XCTAssertFalse(dm.counterpart.isAgent)
        XCTAssertTrue(dm.sharesMemory(in: "room-0001"))
        XCTAssertFalse(dm.created)

        for broken in [#"{"dm": {"sessionId": "dm-0003", "kind": "direct"}}"#,
                       #"{"dm": {"sessionId": "dm-0003", "kind": "room", "counterpart": {"senderId": "x", "kind": "human"}}}"#,
                       #"{"dm": {"kind": "direct", "counterpart": {"senderId": "x", "kind": "human"}}}"#, "[]"] {
            dms = client { _ in (200, broken) }
            do {
                _ = try await dms.directMessage("dm-0003")
                XCTFail("read \(broken)")
            } catch {
                XCTAssertEqual(error as? DirectMessageError, .invalidData, broken)
            }
        }
    }

    func test_the_memory_switch_sends_the_room_and_reads_the_servers_switches() async throws {
        let dms = client { _ in (200, #"{"memoryShare": [{"roomId": "room-0001", "enabled": true}]}"#) }
        let shares = try await dms.setMemoryShare("dm-0001", roomId: "room-0001", enabled: true)
        let request = try XCTUnwrap(PersonalRoutesURLProtocol.requests.first)
        XCTAssertEqual(request.method, "PATCH")
        XCTAssertEqual(request.path, "/api/v1/dms/dm-0001/memory-share")
        XCTAssertEqual(request.body?["roomId"]?.stringValue, "room-0001")
        XCTAssertEqual(request.body?["enabled"]?.boolValue, true)
        XCTAssertEqual(shares, [DirectMemoryShare(roomId: "room-0001", enabled: true)])
    }

    func test_who_can_message_me_reads_and_writes_the_servers_word() async throws {
        var dms = client { request in
            request.method == "GET" ? (200, #"{"allowDms": "shared_rooms"}"#) : (200, #"{"allowDms": "nobody"}"#)
        }
        let read = try await dms.directMessageSettings()
        XCTAssertEqual(read, .sharedRooms)
        let written = try await dms.setDirectMessageSettings(.nobody)
        XCTAssertEqual(written, .nobody)
        let patch = try XCTUnwrap(PersonalRoutesURLProtocol.requests.last)
        XCTAssertEqual(patch.method, "PATCH")
        XCTAssertEqual(patch.path, "/api/v1/me/dm-settings")
        XCTAssertEqual(patch.body?["allowDms"]?.stringValue, "nobody")

        dms = client { _ in (200, #"{"allowDms": "everyone"}"#) }
        let unknown = try await dms.directMessageSettings()
        XCTAssertNil(unknown, "a value this build does not know is no value, but the feature answered: it is on")
    }

    func test_no_request_without_a_sign_in_or_with_an_id_that_is_not_one() async {
        tokens.value = nil
        let dms = client { _ in (200, Self.dm) }
        do {
            _ = try await dms.openDirectMessage(with: "review-agent", from: "room-0001")
            XCTFail("sent without a token")
        } catch {
            XCTAssertEqual(error as? DirectMessageError, .reauthenticationRequired)
        }
        tokens.value = "person-token"
        for (target, room) in [("", "room-0001"), ("   ", "room-0001"), ("review-agent", "../room"),
                               ("review-agent", "room/0001")] {
            do {
                _ = try await dms.openDirectMessage(with: target, from: room)
                XCTFail("sent \(target) from \(room)")
            } catch {
                XCTAssertEqual(error as? DirectMessageError, .rejected)
            }
        }
        XCTAssertTrue(PersonalRoutesURLProtocol.requests.isEmpty)
    }

    func test_an_answer_for_an_account_that_signed_out_meanwhile_is_dropped() async {
        let tokens = self.tokens
        let dms = client(during: { tokens.value = "another-token" }) { _ in (201, Self.dm) }
        do {
            _ = try await dms.openDirectMessage(with: "review-agent", from: "room-0001")
            XCTFail("an answer for the last account was used")
        } catch {
            XCTAssertEqual(error as? DirectMessageError, .accountChanged)
        }
    }
}
