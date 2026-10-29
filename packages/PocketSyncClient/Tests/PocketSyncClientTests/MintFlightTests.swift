import Foundation
import PocketContracts
import XCTest
@testable import PocketSyncClient

final class MintFlightTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func test_lives_decode_tolerantly_and_only_https_consoles_open() throws {
        let page = try json("""
        {"lives": [
          {"lifeId": "0d7010eb4e60", "agentName": "astra-breakout-api2", "model": "model-a", "phase": "ready",
           "expiresAt": "2026-10-29T21:54:14.548Z", "job": {"description": "Ticket 36d92287: fix round 2"},
           "ticket": {"id": "36d92287", "title": "Breakouts API fix round 2"},
           "consoleUrl": "https://sl-mint.eastus.cloudapp.azure.com/console?life=0d7010eb4e60"},
          {"lifeId": "a71fc80c2408", "agentName": "astra-breakout-api", "phase": "destroyed", "consoleUrl": "http://insecure"},
          {"agentName": "no id"}
        ]}
        """)
        let lives = (page["lives"]?.arrayValue ?? []).compactMap(MintLife.init(json:))
        XCTAssertEqual(lives.map(\.id), ["0d7010eb4e60", "a71fc80c2408"], "a life without an id is skipped")
        XCTAssertTrue(lives[0].isActive)
        XCTAssertFalse(lives[1].isActive, "destroyed boxes are finished")
        XCTAssertEqual(lives[0].ticketTitle, "Breakouts API fix round 2")
        XCTAssertNotNil(lives[0].consoleURL)
        XCTAssertNil(lives[1].consoleURL, "only an https console link is offered")
    }

    func test_a_flight_record_keeps_thoughts_and_commands_newest_last() throws {
        let record = MintFlightRecord(json: try json("""
        {"thinking": {"narration": [{"at": "2026-10-29T19:24:23Z", "text": "Reading the brief."},
                                    {"at": "2026-10-29T19:25:03Z", "text": "Setting up PostgreSQL."}]},
         "tools": {"list": [{"at": "2026-10-29T19:41:42Z", "cmd": "git add src", "exitCode": 0},
                            {"at": "2026-10-29T19:41:43Z", "cmd": "pytest -q"}]},
         "room": {"posts": 19},
         "time": {"phase": "ready", "lastActivity": "2026-10-29T21:23:25Z", "expiresAt": "2026-10-29T21:54:14Z"}}
        """))
        XCTAssertEqual(record.narration.map(\.text), ["Reading the brief.", "Setting up PostgreSQL."])
        XCTAssertEqual(record.commands.map(\.exitCode), [0, nil])
        XCTAssertEqual(record.posts, 19)
        XCTAssertEqual(record.phase, "ready")
    }

    func test_working_on_updates_decode_and_know_when_they_are_done() throws {
        let page = try JSONDecoder().decode(RoomActionsPage.self, from: Data("""
        {"actions": [
          {"id": "w1", "actionType": "working_on", "targetSequenceId": 54823, "actorId": "ticket-keeper",
           "note": "done: filed 1 ticket · 20:01Z", "createdAt": "2026-10-29T20:01:28Z"},
          {"id": "w2", "actionType": "working_on", "targetSequenceId": 54823, "actorId": "review-agent",
           "note": "reviewing #202", "createdAt": "2026-10-29T20:02:00Z"},
          {"id": "r1", "actionType": "reply", "targetSequenceId": 54823, "actorId": "x", "note": "hi", "createdAt": "2026-10-29T20:03:00Z"}
        ], "projection": {"workingOnStaleAfterSeconds": 600}}
        """.utf8))
        XCTAssertEqual(page.workingOn.map(\.id), ["w1", "w2"])
        XCTAssertEqual(page.workingOn.map(\.isDone), [true, false])
        XCTAssertEqual(page.workingOnStaleAfter, 600)
        XCTAssertEqual(page.replies.map(\.id), ["r1"], "replies still decode beside them")
    }

    func test_requests_carry_the_token_to_the_mint_origin_only() throws {
        let base = try XCTUnwrap(URL(string: "https://sl-mint.eastus.cloudapp.azure.com"))
        let request = try XCTUnwrap(HTTPMintClient.request(baseURL: base, path: "/api/mint/lives",
                                                            query: [URLQueryItem(name: "sessionId", value: "room 1")], token: "t"))
        XCTAssertEqual(request.url?.host, "sl-mint.eastus.cloudapp.azure.com")
        XCTAssertEqual(request.url?.query, "sessionId=room%201")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertNil(HTTPMintClient(baseURL: URL(string: "http://plain.example"), tokenProvider: { "t" }).baseURLForTesting,
                     "the token never goes to a plain-http origin")
    }
}
