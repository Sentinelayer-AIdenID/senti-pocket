import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts
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

    /// Ticket f7254a3b: how each post says it was sent, as the API stores it. Hosted MCP stamps `source: "hosted_mcp"`,
    /// which outranks what a client says of itself; MCP admissions (the CLI's MCP server) stamp `clientKind: "mcp"`; the
    /// CLI says "cli"; anything else is not known.
    func test_each_post_says_how_it_was_sent() throws {
        func sent(_ agent: String, _ payload: String, source: String? = nil) throws -> RoomPostClient? {
            let top = source.map { #","source":"\#($0)""# } ?? ""
            let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
            {"id":"e1","event":"session_message","sequenceId":1,"ts":"2026-11-07T10:00:00Z","agent":\(agent),
             "payload":\(payload)\(top)}
            """.utf8))
            return try XCTUnwrap(RoomMessage(json: json)).sentThrough
        }
        // A post through the CLI's MCP server, as the server stores it: the event's source "cli", the agent's clientKind
        // "mcp", the payload's source "mcp".
        XCTAssertEqual(try sent(#"{"id":"claude-warden","clientKind":"mcp"}"#, #"{"text":"hi","source":"mcp"}"#,
                                source: "cli"), .cliMCP, "the CLI's MCP server, never the CLI alone")
        XCTAssertEqual(try sent(#"{"id":"claude-warden","clientKind":"mcp"}"#, #"{"text":"hi"}"#), .cliMCP,
                       "clientKind mcp alone means the CLI's MCP server: hosted connectors say hosted_mcp")
        XCTAssertEqual(try sent(#"{"id":"gpt-helper","clientKind":"hosted_mcp"}"#,
                                #"{"text":"hi","source":"hosted_mcp"}"#), .hostedMCP)
        XCTAssertEqual(try sent(#"{"id":"gpt-helper","clientKind":"mcp"}"#, #"{"text":"hi","source":"hosted_mcp"}"#),
                       .hostedMCP, "the hosted marker outranks what the client says")
        XCTAssertEqual(try sent(#"{"id":"ticket-keeper","clientKind":"cli"}"#, #"{"text":"hi"}"#), .cli)
        XCTAssertNil(try sent(#"{"id":"someone","clientKind":"telegraph"}"#, #"{"text":"hi"}"#), "not known: nothing")
        XCTAssertNil(try sent(#"{"id":"someone"}"#, #"{"text":"hi"}"#))
    }

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

    /// Ticket 386081b1, the API's answer for an agent and for a person, as it is shaped (sentinelayer-api a199151c,
    /// src/routes/sessions.py:6778: `events`, `count`, `nextBeforeSequence`, `hasMore`, `connection`), through the
    /// phone's own transport: each comes back as their rows, with who wrote them.
    func test_an_agents_page_and_a_persons_page_read_as_their_rows() async throws {
        AuthorPageURLProtocol.reset(body: """
        {"events":[
          {"id":"e9","event":"session_message","sequenceId":62390,"ts":"2026-11-06T06:00:00Z","agentId":"build-agent",
           "payload":{"text":"The build is up."}},
          {"id":"e7","event":"session_message","sequenceId":62310,"ts":"2026-11-06T05:40:00Z","agentId":"build-agent",
           "payload":{"text":"Starting the build."}}
         ],"count":2,"nextBeforeSequence":62000,"hasMore":true,"connection":"box"}
        """)
        let agent = try await transport().roomMessages(by: "build-agent", sessionId: "room_1", beforeSequence: nil, limit: 20)
        XCTAssertEqual(agent.messages.map(\.sequenceId), [62390, 62310])
        XCTAssertEqual(agent.messages.map(\.authorId), ["build-agent", "build-agent"])
        XCTAssertEqual(agent.messages.map(\.isHuman), [false, false], "an agent's rows")
        XCTAssertEqual(agent.nextBeforeSequence, 62000)
        XCTAssertEqual(agent.connection, .box)

        AuthorPageURLProtocol.reset(body: """
        {"events":[
          {"id":"e8","event":"session_message","sequenceId":62392,"ts":"2026-11-06T06:04:00Z","agentId":"human-alex",
           "payload":{"text":"Thanks."}}
         ],"count":1,"nextBeforeSequence":null,"hasMore":false,"connection":null}
        """)
        let person = try await transport().roomMessages(by: "human-alex", sessionId: "room_1", beforeSequence: nil,
                                                        limit: 20)
        XCTAssertEqual(person.messages.map(\.sequenceId), [62392])
        XCTAssertEqual(person.messages.map(\.authorId), ["human-alex"])
        XCTAssertEqual(person.messages.map(\.isHuman), [true], "a person's rows")
        XCTAssertNil(person.nextBeforeSequence, "the start of the room")
        XCTAssertNil(person.connection)
    }

    /// Ticket 386081b1: while the server did not answer this read it gave 503 with an empty body, for an agent and
    /// a person alike. That is an error the card offers to retry, never an empty page (which would read as "no
    /// messages from them yet").
    func test_an_empty_503_is_an_error_never_an_empty_page() async {
        for author in ["build-agent", "human-alex"] {
            AuthorPageURLProtocol.reset(status: 503, body: "")
            do {
                let page = try await transport().roomMessages(by: author, sessionId: "room_1", beforeSequence: nil, limit: 20)
                XCTFail("\(author): a 503 read as a page of \(page.messages.count) messages")
            } catch {
                XCTAssertEqual(error as? SessionTransportError, .service(statusCode: 503), "\(author)")
            }
        }
    }

    /// Exactly the API's rule for `author` (`^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$`): what it would refuse is never sent.
    func test_the_author_id_check_is_the_apis_own() {
        for good in ["agent-a1", "human-pat", "human-g.0123abcd", "human-public.9f2c", "a", "Ab:c.d_e-f",
                     "7-agent", String(repeating: "a", count: 64)] {
            XCTAssertTrue(RoomAuthor.isValidId(good), good)
        }
        for bad in ["", "-agent", ".agent", "_agent", ":agent", "pat@example.com", "human-pat@box",
                    String(repeating: "a", count: 65), "human pat", "agent/a1", "agent\u{e9}"] {
            XCTAssertFalse(RoomAuthor.isValidId(bad), bad)
        }
    }

    func test_a_public_rooms_alias_for_a_person_is_known() {
        XCTAssertTrue(RoomAuthor.isPublicAlias("human-public.9f2c"))
        XCTAssertTrue(RoomAuthor.isPublicAlias("Human-Public.9F2C"))
        XCTAssertFalse(RoomAuthor.isPublicAlias("human-pat"))
        XCTAssertFalse(RoomAuthor.isPublicAlias("human-g.0123abcd"))
        XCTAssertFalse(RoomAuthor.isPublicAlias("agent-public.1"))
    }
}
