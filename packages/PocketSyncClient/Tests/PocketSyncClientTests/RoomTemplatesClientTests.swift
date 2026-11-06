import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts
import XCTest
@testable import PocketSyncClient

/// Ways to start a chat against the contract (`GET /api/v1/rooms/templates`): the list as the server sends it, each
/// once, and a 404 or 403 read as "none offered", never as something to show. Names are made up.
final class RoomTemplatesClientTests: XCTestCase {
    private func client(
        _ handler: @escaping (PersonalRoutesURLProtocol.Seen) -> (Int, String)
    ) -> HTTPRoomTemplatesClient {
        PersonalRoutesURLProtocol.reset(handler: handler)
        return HTTPRoomTemplatesClient(apiBaseURL: URL(string: "https://api.example.test"),
                                       urlSession: PersonalRoutesURLProtocol.session(),
                                       tokenProvider: { "person-token" })
    }

    private func refusal(_ status: Int, _ body: String = #"{"detail":"Not Found"}"#) async -> RoomTemplatesError? {
        do {
            _ = try await client { _ in (status, body) }.templates()
            return nil
        } catch {
            return error as? RoomTemplatesError
        }
    }

    func test_the_list_reads_each_template_as_sent_once_and_skips_what_it_cannot_read() async throws {
        let templates = client { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.path, "/api/v1/rooms/templates")
            XCTAssertEqual(request.authorization, "Bearer person-token")
            XCTAssertNil(request.body)
            return (200, """
            {"templates": [
              {"id": "sample-planner", "name": "Sample planner", "symbol": "calendar",
               "summary": "Plans made up for a test.", "roomType": "general",
               "starterAgents": ["sample-agent-1"], "firstMessage": "I can plan a made-up week."},
              {"id": "sample-study", "name": "Sample study", "summary": "Made-up notes.", "roomType": "study"},
              {"id": "sample-study", "name": "Sample study again"},
              {"name": "No id"},
              {"id": "no-name", "name": "   "},
              {"id": "not an id!", "name": "Odd id"},
              {"id": "sample-bare", "name": "  Sample bare \\n", "starterAgents": ["sample-agent-2", 7]}
            ]}
            """)
        }
        let list = try await templates.templates()
        XCTAssertEqual(list.map(\.id), ["sample-planner", "sample-study", "sample-bare"],
                       "as sent, one listed twice once")
        XCTAssertEqual(list[0], RoomTemplate(id: "sample-planner", name: "Sample planner", symbol: "calendar",
                                             summary: "Plans made up for a test.", roomType: "general",
                                             starterAgents: ["sample-agent-1"],
                                             firstMessage: "I can plan a made-up week."))
        XCTAssertEqual(list[1].roomType, "study")
        XCTAssertNil(list[1].firstMessage)
        let bare = RoomTemplate(id: "sample-bare", name: "Sample bare", starterAgents: ["sample-agent-2"])
        XCTAssertEqual(list[2], bare, "missing parts read as empty: no symbol, no summary, a general room")
        XCTAssertEqual(list[2].starterAgents, ["sample-agent-2"], "a starter that isn't text is skipped")
    }

    /// The server offers none until its templates are on: the phone keeps its own kinds and shows no error.
    func test_none_offered_is_a_404_or_a_403() async {
        for status in [404, 403] {
            let error = await refusal(status)
            XCTAssertEqual(error, .unavailable, "\(status) is none offered")
        }
    }

    func test_an_account_refusal_asks_to_sign_in_again_and_a_busy_server_is_tried_later() async {
        let account = await refusal(403, #"{"error": {"code": "ACCOUNT_INACTIVE", "message": "x", "request_id": "r"}}"#)
        XCTAssertEqual(account, .reauthenticationRequired, "the account refused, not none offered")
        let signedOut = await refusal(401)
        XCTAssertEqual(signedOut, .reauthenticationRequired)
        for status in [429, 503] {
            let busy = await refusal(status)
            XCTAssertEqual(busy, .retryable, "\(status)")
        }
        let odd = await refusal(422)
        XCTAssertEqual(odd, .rejected)
    }

    func test_an_answer_without_a_list_is_not_a_list_of_none() async {
        for body in [#"{"templates": {}}"#, #"{}"#, "not json"] {
            let error = await refusal(200, body)
            XCTAssertEqual(error, .invalidData, body)
        }
    }

    func test_signed_out_asks_nothing() async {
        PersonalRoutesURLProtocol.reset { _ in (200, #"{"templates": []}"#) }
        let signedOut = HTTPRoomTemplatesClient(apiBaseURL: URL(string: "https://api.example.test"),
                                                urlSession: PersonalRoutesURLProtocol.session(), tokenProvider: { nil })
        do {
            _ = try await signedOut.templates()
            XCTFail("listed with no sign-in")
        } catch {
            XCTAssertEqual(error as? RoomTemplatesError, .reauthenticationRequired)
        }
        XCTAssertTrue(PersonalRoutesURLProtocol.requests.isEmpty, "nothing goes out without a sign-in")
    }
}
