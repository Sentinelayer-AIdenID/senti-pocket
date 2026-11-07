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

    /// How a post says it was sent (tickets f7254a3b, c96649c0): the agent's JSON, the payload's, and the event's
    /// top-level `source` (absent from a copy that does not carry it).
    private func sent(_ agent: String, _ payload: String, source: String? = nil) throws -> RoomPostClient? {
        let top = source.map { #","source":"\#($0)""# } ?? ""
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":"e1","event":"session_message","sequenceId":1,"ts":"2026-11-07T10:00:00Z","agent":\(agent),
         "payload":\(payload)\(top)}
        """.utf8))
        return try XCTUnwrap(RoomMessage(json: json)).sentThrough
    }

    // One rule with the web (sentinelayer-web #812, `agentConnection.test.tsx`), its six cases in order.

    /// Case 1: the server's stamp (`source` "hosted_mcp", in the payload or at the top level) is MCP, whatever
    /// `clientKind` says, or if it says nothing (web: "the hosted connector's stamp ... is MCP with no clientKind at
    /// all", "the hosted stamp outranks a clientKind \"cli\""). A `clientKind` "hosted_mcp" is MCP too.
    func test_case_1_the_hosted_stamp_is_mcp_whatever_the_client_kind_says() throws {
        XCTAssertEqual(try sent(#"{"id":"someone"}"#, #"{"text":"hi","source":"hosted_mcp"}"#), .mcp,
                       "the stamp with no clientKind at all")
        XCTAssertEqual(try sent(#"{"id":"someone"}"#, #"{"text":"hi","source":"hosted_mcp"}"#, source: "mcp"), .mcp)
        XCTAssertEqual(try sent(#"{"id":"ticket-keeper","clientKind":"cli"}"#, #"{"text":"hi","source":"hosted_mcp"}"#,
                                source: "mcp"), .mcp, "the stamp outranks a client that says it is the CLI")
        XCTAssertEqual(try sent(#"{"id":"ticket-keeper","clientKind":"cli"}"#, #"{"text":"hi"}"#, source: "hosted_mcp"),
                       .mcp, "a top-level stamp reads the same")
        XCTAssertEqual(try sent(#"{"id":"review-agent","clientKind":"mcp"}"#, #"{"text":"hi","source":"hosted_mcp"}"#,
                                source: "cli"), .mcp, "the stamp outranks mcp from the CLI")
        XCTAssertEqual(try sent(#"{"id":"helper-agent","clientKind":"hosted_mcp"}"#, #"{"text":"hi"}"#, source: "api"),
                       .mcp)
    }

    /// Case 2: `clientKind` "mcp" with the top-level `source` "cli" is the CLI's MCP server (web: "clientKind \"mcp\"
    /// from the CLI (top-level source \"cli\") is the CLI's MCP server").
    func test_case_2_mcp_from_the_cli_is_the_clis_mcp_server() throws {
        XCTAssertEqual(try sent(#"{"id":"review-agent","clientKind":"mcp"}"#, #"{"text":"hi","source":"mcp"}"#,
                                source: "cli"), .cliMCP, "as the server stores a post through the CLI's MCP server")
        XCTAssertEqual(try sent(#"{"id":"review-agent","clientKind":"mcp"}"#, #"{"text":"hi"}"#, source: "cli"),
                       .cliMCP)
        XCTAssertEqual(try sent(#"{"id":"review-agent"}"#, #"{"text":"hi","clientKind":"mcp"}"#, source: "cli"),
                       .cliMCP, "the payload's kind, when the agent declares none")
    }

    /// Case 3: "mcp" with no top-level source says nothing, so it never overturns an older post that did (web: "a live
    /// copy (no stored source) decides nothing").
    func test_case_3_mcp_with_no_top_level_source_says_nothing() throws {
        XCTAssertNil(try sent(#"{"id":"review-agent","clientKind":"mcp"}"#, #"{"text":"hi"}"#))
        XCTAssertNil(try sent(#"{"id":"review-agent","clientKind":"mcp"}"#, #"{"text":"hi","source":"cli"}"#),
                     "the payload's source is not the post's: only the top-level source says the CLI sent it")
    }

    /// Case 4: "mcp" with any other top-level source is MCP, true either way (web: "clientKind \"mcp\" stored with
    /// source %j is MCP, true either way").
    func test_case_4_mcp_with_any_other_top_level_source_is_mcp() throws {
        for source in ["web", "api", "mcp"] {
            XCTAssertEqual(try sent(#"{"id":"review-agent","clientKind":"mcp"}"#, #"{"text":"hi"}"#, source: source),
                           .mcp, "source \(source)")
        }
    }

    /// Case 5: "cli" with no stamp is the CLI (web: "\"cli\" is the CLI").
    func test_case_5_cli_with_no_stamp_is_the_cli() throws {
        XCTAssertEqual(try sent(#"{"id":"ticket-keeper","clientKind":"cli"}"#, #"{"text":"hi"}"#, source: "cli"), .cli)
        XCTAssertEqual(try sent(#"{"id":"ticket-keeper","clientKind":" CLI "}"#, #"{"text":"hi"}"#), .cli)
    }

    /// Case 6: any other kind says nothing (no line), and no kind at all is nothing said (web: "clientKind %j says
    /// nothing", "with no clientKind declared ... says nothing").
    func test_case_6_any_other_kind_or_none_says_nothing() throws {
        for kind in ["claude", "codex", "web", "sdk", "telegraph"] {
            XCTAssertEqual(try sent(#"{"id":"someone","clientKind":"\#(kind)"}"#, #"{"text":"hi"}"#, source: "cli"),
                           .other, "clientKind \(kind)")
        }
        XCTAssertNil(try sent(#"{"id":"someone"}"#, #"{"text":"hi"}"#, source: "cli"), "a source alone is no kind")
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
