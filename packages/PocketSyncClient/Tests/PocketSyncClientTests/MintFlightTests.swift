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
          {"lifeId": "life-aaaa0001", "agentName": "box-one", "model": "model-a", "phase": "ready",
           "expiresAt": "2026-10-29T21:54:14.548Z", "job": {"description": "Ticket tkt00001: fix round 2"},
           "ticket": {"id": "tkt00001", "title": "Breakouts API fix round 2"},
           "consoleUrl": "https://mint.example.invalid/console?life=life-aaaa0001"},
          {"lifeId": "life-aaaa0002", "agentName": "box-two", "phase": "destroyed", "consoleUrl": "http://insecure"},
          {"agentName": "no id"}
        ]}
        """)
        let lives = (page["lives"]?.arrayValue ?? []).compactMap(MintLife.init(json:))
        XCTAssertEqual(lives.map(\.id), ["life-aaaa0001", "life-aaaa0002"], "a life without an id is skipped")
        XCTAssertTrue(lives[0].isActive)
        XCTAssertFalse(lives[1].isActive, "destroyed boxes are finished")
        XCTAssertEqual(lives[0].ticketTitle, "Breakouts API fix round 2")
        XCTAssertNotNil(lives[0].consoleURL)
        XCTAssertNil(lives[1].consoleURL, "only an https console link is offered")
        let base = URL(string: "https://mint.example.invalid")
        XCTAssertNotNil(lives[0].consolePinned(to: base).consoleURL, "a console on the Flight record's own host stays")
        XCTAssertNil(lives[0].consolePinned(to: URL(string: "https://elsewhere.example.invalid")).consoleURL,
                     "the console opens in the app, so one on any other host is dropped")
        XCTAssertNil(lives[0].consolePinned(to: nil).consoleURL)
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
        let base = try XCTUnwrap(URL(string: "https://mint.example.invalid"))
        let request = try XCTUnwrap(HTTPMintClient.request(baseURL: base, path: "/api/mint/lives",
                                                            query: [URLQueryItem(name: "sessionId", value: "room 1")], token: "t"))
        XCTAssertEqual(request.url?.host, "mint.example.invalid")
        XCTAssertEqual(request.url?.query, "sessionId=room%201")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertNil(HTTPMintClient(baseURL: URL(string: "http://plain.example"), urlSession: .shared, tokenProvider: { "t" })
            .baseURLForTesting, "the token never goes to a plain-http origin")
        XCTAssertNil(HTTPMintClient(baseURL: nil, urlSession: .shared, tokenProvider: { "t" }).baseURLForTesting,
                     "a build without the service reads nothing")
    }
}
