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

    /// sentinelayer-web `useRoomLives`: a mint that ignores the room filter lists everyone's boxes; only this room's
    /// count, and the room's totals come with them.
    func test_room_lives_keep_this_room_only_and_read_the_room_totals() throws {
        let room = MintRoomLives(json: try json("""
        {"lives": [
          {"lifeId": "a1", "sessionId": "room-1", "agentName": "astra", "phase": "working", "costUsd": 1.5,
           "timing": {"working": {"seconds": 3600, "coverage": "stream_turns", "quality": "exact"},
                      "allocation": {"endAt": "2026-10-29T22:00:00Z"}}},
          {"lifeId": "b2", "sessionId": "room-2", "agentName": "elsewhere", "phase": "working"},
          {"lifeId": "c3", "sessionId": "room-1", "agentName": "old", "phase": "killed", "usage": {"totalCostUsd": 2}}
        ],
         "timingSummary": {"truncated": true},
         "roomTotals": {"schema": "respawn.room-totals/1", "lifeCount": 12, "endedCount": 9,
                        "firstBornAt": "2026-10-27T10:00:00Z", "lastEndAt": null, "workingSeconds": 144000,
                        "exactLives": 8, "exactWorkingSeconds": 108000, "exactCostUsd": 120, "costUsd": 150.25}}
        """), sessionId: "room-1")
        XCTAssertEqual(room.lives.map(\.id), ["a1", "c3"])
        XCTAssertTrue(room.fleetList, "another room's box was listed")
        XCTAssertTrue(room.truncated)
        XCTAssertEqual(room.totals?.lifeCount, 12)
        XCTAssertNil(room.totals?.lastEndAt, "an explicit null is kept as unknown")
        XCTAssertEqual(room.lives[0].costUsd, 1.5)
        XCTAssertEqual(room.lives[0].workingSeconds, 3600)
        XCTAssertTrue(room.lives[0].workingIsExact)
        XCTAssertEqual(room.lives[1].costUsd, 2, "a cost under usage counts, as on the web")
        XCTAssertFalse(room.lives[1].isActive, "a killed box no longer runs")
    }

    func test_malformed_room_totals_are_absent_never_zero() throws {
        let good = """
        "lifeCount": 2, "endedCount": 1, "firstBornAt": null, "lastEndAt": null, "workingSeconds": 1,
        "exactLives": 1, "exactWorkingSeconds": 1, "exactCostUsd": 1, "costUsd": 1
        """
        XCTAssertNotNil(MintRoomTotals(json: try json("{\"schema\": \"respawn.room-totals/1\", \(good)}")))
        XCTAssertNil(MintRoomTotals(json: try json("{\"schema\": \"respawn.room-totals/2\", \(good)}")), "another schema")
        XCTAssertNil(MintRoomTotals(json: try json("""
        {"schema": "respawn.room-totals/1", "lifeCount": 1, "endedCount": 2, "firstBornAt": null, "lastEndAt": null,
         "workingSeconds": 1, "exactLives": 1, "exactWorkingSeconds": 1, "exactCostUsd": 1, "costUsd": 1}
        """)), "more ended than minted")
        XCTAssertNil(MintRoomTotals(json: try json("""
        {"schema": "respawn.room-totals/1", "lifeCount": 2, "endedCount": 1, "firstBornAt": "yesterday", "lastEndAt": null,
         "workingSeconds": 1, "exactLives": 1, "exactWorkingSeconds": 1, "exactCostUsd": 1, "costUsd": 1}
        """)), "a date that does not parse")
        XCTAssertNil(MintRoomTotals(json: try json("""
        {"schema": "respawn.room-totals/1", "lifeCount": 2, "endedCount": 1, "firstBornAt": null, "lastEndAt": null,
         "workingSeconds": -5, "exactLives": 1, "exactWorkingSeconds": 1, "exactCostUsd": 1, "costUsd": 1}
        """)), "a negative amount")
        XCTAssertNil(MintRoomTotals(json: nil))
    }

    /// The web's `roomWorkMetrics` over the mint's room totals.
    func test_the_room_figures_from_totals_match_the_web() {
        let now = ParsedSessionTimestamp("2026-10-29T10:00:00Z").date!
        let totals = MintRoomTotals(lifeCount: 10, endedCount: 7, firstBornAt: "2026-10-27T10:00:00Z", lastEndAt: nil,
                                    workingSeconds: 144_000, exactLives: 8, exactWorkingSeconds: 108_000,
                                    exactCostUsd: 120, costUsd: 150)
        let summary = MintRoomSummary(room: MintRoomLives(lives: [], totals: totals), now: now)
        XCTAssertEqual(summary.minted, 10)
        XCTAssertEqual(summary.active, 3)
        XCTAssertEqual(summary.finished, 7)
        XCTAssertFalse(summary.listCut, "totals cover every box, so nothing is a minimum because of the list")
        XCTAssertEqual(summary.costUsd, 150)
        XCTAssertEqual(summary.workingHours, 40)
        XCTAssertTrue(summary.workIsPartial, "8 of 10 boxes have an exact record")
        XCTAssertTrue(summary.workKnown)
        XCTAssertEqual(summary.elapsedDays, 2, accuracy: 0.0001, "still running, so the span runs to now")
        XCTAssertEqual(summary.savedDays ?? -1, 3, accuracy: 0.0001, "40 h is 5 engineer days, less the 2 days it took")
        XCTAssertEqual(summary.costPercent ?? -1, 5, accuracy: 0.0001, "$120 against 30 h at $80")
        XCTAssertEqual(summary.pricedLives, 8)
    }

    /// Without totals (an older mint) the listed boxes are added up, and a cut list makes the counts and the time saved
    /// unknowable as exact figures.
    func test_the_room_figures_add_up_the_list_without_totals() {
        let now = ParsedSessionTimestamp("2026-10-29T12:00:00Z").date!
        let lives = [
            MintLife(id: "a", agentName: "a", model: "", phase: "destroyed", bornAt: "2026-10-29T00:00:00Z",
                     costUsd: 4, workingSeconds: 7200, workingIsExact: true, endedAt: "2026-10-29T06:00:00Z"),
            MintLife(id: "b", agentName: "b", model: "", phase: "killed", bornAt: "2026-10-29T03:00:00Z",
                     costUsd: 1, workingSeconds: 3600, workingIsExact: false, endedAt: "2026-10-29T09:00:00Z")
        ]
        let finished = MintRoomSummary(room: MintRoomLives(lives: lives), now: now)
        XCTAssertEqual(finished.minted, 2)
        XCTAssertEqual(finished.active, 0, "destroyed and killed both ended")
        XCTAssertEqual(finished.costUsd, 5)
        XCTAssertEqual(finished.workingHours, 3)
        XCTAssertTrue(finished.workIsPartial, "one record is not exact")
        XCTAssertEqual(finished.elapsedDays, 9.0 / 24, accuracy: 0.0001, "a finished room's span stops at its last end")
        XCTAssertEqual(finished.pricedLives, 1)
        XCTAssertEqual(finished.costPercent ?? -1, 2.5, accuracy: 0.0001, "$4 against 2 h at $80")

        let cut = MintRoomSummary(room: MintRoomLives(lives: lives, truncated: true), now: now)
        XCTAssertTrue(cut.listCut)
        XCTAssertNil(cut.savedDays, "the room's oldest boxes are missing, so its span is unknown")

        let unpriced = MintRoomSummary(room: MintRoomLives(lives: [MintLife(id: "x", agentName: "x", model: "", phase: "ready")]), now: now)
        XCTAssertNil(unpriced.costUsd, "a box without a cost leaves the total unknown")
        XCTAssertFalse(unpriced.workKnown, "no working record yet: no hours rather than at least 0")
    }

    /// sentinelayer-web `listMintModels` and `mintAgent`.
    func test_models_and_a_started_agent_read_as_the_web_reads_them() throws {
        let models = (try json("""
        {"models": [{"id": "model-a", "label": "Model A", "vendor": "v", "efforts": ["low", "turbo", "high"],
                     "defaultEffort": "turbo"},
                    {"id": "model-b", "label": "Model B", "note": "fast", "defaultEffort": "high"},
                    {"label": "no id"}]}
        """)["models"]?.arrayValue ?? []).compactMap(MintModel.init(json:))
        XCTAssertEqual(models.map(\.id), ["model-a", "model-b"])
        XCTAssertEqual(models[0].efforts, ["low", "high"], "only the efforts the web knows")
        XCTAssertNil(models[0].defaultEffort, "a default it does not offer is no default")
        XCTAssertNil(models[1].defaultEffort)
        XCTAssertEqual(models[1].note, "fast")

        let request = MintUpRequest(model: "model-a", effort: "high", jobDescription: "Do it", sessionId: "room-1",
                                    agentName: "", ticketId: "t1", ticketTitle: "Fix it")
        let body = request.body
        XCTAssertEqual(body["model"] as? String, "model-a")
        XCTAssertEqual(body["effort"] as? String, "high")
        XCTAssertNil(body["agentName"], "an empty name lets the mint choose")
        XCTAssertEqual((body["ticket"] as? [String: String])?["id"], "t1")
        XCTAssertNil(MintUpRequest(model: "m", jobDescription: "j", sessionId: "r").body["ticket"])

        let started = MintUpResponse(json: try json("""
        {"lifeId": "life-1", "agentName": "mint-36d92287", "model": "model-a", "sessionId": "room-1", "phase": "booting",
         "consoleUrl": "http://insecure/console", "shell": true}
        """))
        XCTAssertEqual(started?.agentName, "mint-36d92287")
        XCTAssertNil(started?.consoleURL, "only an https console is offered")
        XCTAssertNil(MintUpResponse(json: try json(#"{"lifeId": "x"}"#)), "no name, no agent")
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
