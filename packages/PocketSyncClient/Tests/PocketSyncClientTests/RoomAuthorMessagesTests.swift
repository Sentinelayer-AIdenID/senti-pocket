import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PocketSyncClient

private final class AuthorPageURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var answer: (Int, String) = (200, "{}")
    private static var requests: [URLRequest] = []

    static func reset(status: Int = 200, body: String) {
        lock.lock()
        answer = (status, body)
        requests = []
        lock.unlock()
    }

    static func captured() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let (status, body) = Self.answer
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// One author's messages (sentinelayer-api #1136): `/events/before`'s rows, the API's own cursor, and `connection`.
final class RoomAuthorMessagesTests: XCTestCase {
    private func transport() -> HTTPSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthorPageURLProtocol.self]
        return HTTPSessionTransport(apiBaseURL: URL(string: "https://api.example.test")!,
                                    urlSession: URLSession(configuration: configuration),
                                    tokenProvider: { "session-token" })
    }

    private static let page = """
    {"events":[
      {"id":"e2","event":"session_message","sequenceId":140,"ts":"2026-11-04T10:02:00Z","agentId":"agent-a1",
       "payload":{"text":"second"}},
      {"id":"e1","event":"session_message","sequenceId":120,"ts":"2026-11-04T10:01:00Z","agentId":"agent-a1",
       "payload":{"text":"first"}}
     ],"count":2,"nextBeforeSequence":120,"hasMore":true,"connection":"MCP"}
    """

    func test_a_page_is_the_events_rows_newest_first_with_the_api_cursor_and_connection() throws {
        let page = try JSONDecoder().decode(RoomAuthorPage.self, from: Data(Self.page.utf8))
        XCTAssertEqual(page.messages.map(\.sequenceId), [140, 120], "newest first, as the API answers")
        XCTAssertEqual(page.messages.first?.text, "second")
        XCTAssertEqual(page.messages.first?.authorId, "agent-a1")
        XCTAssertEqual(page.nextBeforeSequence, 120)
        XCTAssertEqual(page.connection, .mcp)

        let last = try JSONDecoder().decode(RoomAuthorPage.self, from: Data("""
        {"events":[],"count":0,"nextBeforeSequence":null,"hasMore":false,"connection":null}
        """.utf8))
        XCTAssertNil(last.nextBeforeSequence, "the start of the room")
        XCTAssertNil(last.connection, "unknown is nothing")
        let odd = try JSONDecoder().decode(RoomAuthorPage.self, from: Data("""
        {"events":[],"nextBeforeSequence":null,"connection":"carrier-pigeon"}
        """.utf8))
        XCTAssertNil(odd.connection, "a value this app does not know is nothing, never a guess")
    }

    func test_the_read_names_the_author_and_the_apis_own_cursor() async throws {
        AuthorPageURLProtocol.reset(body: Self.page)
        let api = transport()
        _ = try await api.roomMessages(by: "human-g.0123abcd", sessionId: "room_1", beforeSequence: 300, limit: 20)
        _ = try await api.roomMessages(by: "agent-a1", sessionId: "room_1", beforeSequence: nil, limit: 50)
        let requests = AuthorPageURLProtocol.captured()
        XCTAssertEqual(requests.first?.url?.path, "/api/v1/sessions/room_1/events/by-author")
        let first = Dictionary(uniqueKeysWithValues: (URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(first, ["author": "human-g.0123abcd", "before_sequence": "300", "limit": "20"])
        let second = Dictionary(uniqueKeysWithValues: (URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(second, ["author": "agent-a1", "limit": "50"], "the first page names no cursor")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer session-token")

        for bad in [("", 20), ("human pat", 20), ("agent-a1", 0), ("agent-a1", 51)] {
            do {
                _ = try await api.roomMessages(by: bad.0, sessionId: "room_1", beforeSequence: nil, limit: bad.1)
                XCTFail("refused before the network: \(bad)")
            } catch {
                XCTAssertEqual(error as? SessionTransportError, .invalidRequest)
            }
        }
        XCTAssertEqual(AuthorPageURLProtocol.captured().count, 2)
    }

    func test_a_public_rooms_alias_for_a_person_is_known() {
        XCTAssertTrue(RoomAuthor.isPublicAlias("human-public.9f2c"))
        XCTAssertTrue(RoomAuthor.isPublicAlias("Human-Public.9F2C"))
        XCTAssertFalse(RoomAuthor.isPublicAlias("human-pat"))
        XCTAssertFalse(RoomAuthor.isPublicAlias("human-g.0123abcd"))
        XCTAssertFalse(RoomAuthor.isPublicAlias("agent-public.1"))
    }
}
