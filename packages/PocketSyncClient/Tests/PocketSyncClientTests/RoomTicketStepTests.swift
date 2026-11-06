import Foundation
import XCTest
import PocketContracts
@testable import PocketSyncClient

/// Carter, 11-05: "So fix the progress thing. I hate it." The server reads a ticket's step from typed facts and sends it
/// in `progress.step`, with warden's exact names (11-05): `{index, count, name, stalledSince?, stalledReason?,
/// lastHolder?, waitingOn?}`. Anything unknown or malformed is no step, never a guess.
final class RoomTicketStepTests: XCTestCase {
    private func ticket(_ fields: String, version: Int64 = 1, status: String = "in_review") throws -> RoomTicket {
        let extra = fields.isEmpty ? "" : "," + fields
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":"t1","title":"T","status":"\(status)","version":\(version)\(extra)}
        """.utf8))
        return try XCTUnwrap(RoomTicket(json: json))
    }

    /// `progress` carrying `step` with the given fields (JSON, without braces).
    private func stepped(_ step: String, version: Int64 = 1, status: String = "in_review") throws -> RoomTicket {
        try ticket(#""progress":{"step":{"# + step + "}}", version: version, status: status)
    }

    func test_the_step_is_read_from_progress_with_its_exact_names_beside_the_old_estimate() throws {
        let read = try ticket(#"""
        "progress":{"value":0.62,"basis":"b","at":"2026-11-05T19:00:00Z",
          "step":{"index":2,"count":5,"name":"in_review","stalledSince":"2026-11-05T19:10:00Z",
                  "stalledReason":"waiting_on_review","lastHolder":"forge-box-7","waitingOn":"human-alex","extra":1}}
        """#)
        XCTAssertEqual(read.step, RoomTicketStep(index: 2, count: 5, name: .inReview,
                                                 stalledSince: "2026-11-05T19:10:00Z",
                                                 stalledReason: .waitingOnReview,
                                                 lastHolder: "forge-box-7", waitingOn: "human-alex"))
        XCTAssertEqual(read.progress?.value, 0.62, "the old estimate is still read, for older builds")
        XCTAssertEqual(try stepped(#""index":1,"count":5,"name":"taken","stalledReason":null,"waitingOn":null"#).step,
                       RoomTicketStep(index: 1, count: 5, name: .taken), "a field left null is left out")
    }

    func test_every_name_and_every_reason_the_server_sends_is_read() throws {
        let names: [(Int, String, RoomTicketStep.Name)] = [
            (0, "not_started", .notStarted), (1, "taken", .taken), (2, "in_review", .inReview), (3, "merged", .merged),
            (4, "shipped", .shipped), (5, "done", .done)
        ]
        XCTAssertEqual(names.map { $0.2 }, RoomTicketStep.Name.allCases)
        for (index, wire, name) in names {
            XCTAssertEqual(try stepped(#""index":\#(index),"count":5,"name":"\#(wire)""#).step?.name, name, wire)
        }
        let reasons: [(String, RoomTicketStep.StallReason)] = [
            ("holder_lease_expired", .holderLeaseExpired), ("waiting_on_assignee", .waitingOnAssignee),
            ("waiting_on_review", .waitingOnReview), ("waiting_on_owner", .waitingOnOwner), ("blocked", .blocked),
            ("no_activity", .noActivity)
        ]
        XCTAssertEqual(reasons.map { $0.1 }, RoomTicketStep.StallReason.allCases)
        for (wire, reason) in reasons {
            let read = try stepped(#""index":2,"count":5,"name":"in_review","stalledSince":"2026-11-05T19:10:00Z","#
                                   + #""stalledReason":"\#(wire)""#)
            XCTAssertEqual(read.step?.stalledReason, reason, wire)
        }
    }

    /// The index counts from 1 as it is said ("Step 2 of 5"); 0 is `not_started`. It is read as it came: 0 is neither
    /// the first step nor no step.
    func test_the_index_counts_from_one_and_zero_is_not_started() throws {
        let zero = try XCTUnwrap(try stepped(#""index":0,"count":5,"name":"not_started""#, status: "assigned").step,
                                 "index 0 is a step: not started, not no step")
        XCTAssertEqual(zero.index, 0, "not the first step")
        XCTAssertEqual(zero.count, 5)
        XCTAssertEqual(zero.name, .notStarted)

        let first = try stepped(#""index":1,"count":5,"name":"taken""#).step
        XCTAssertEqual(first?.index, 1)
        XCTAssertEqual(first?.name, .taken)
        let last = try stepped(#""index":5,"count":5,"name":"done""#, status: "done").step
        XCTAssertEqual(last?.index, 5, "the last step is the count")
        XCTAssertEqual(last?.name, .done)
        XCTAssertNil(try ticket("").step, "absent: no step")
    }

    func test_anything_unknown_or_malformed_is_no_step() throws {
        XCTAssertNil(try ticket("").step, "an older server sends none")
        XCTAssertNil(try ticket(#""progress":{"value":0.62,"basis":"b","at":"a"}"#).step, "the estimate alone is no step")
        XCTAssertNil(try ticket(#""step":{"index":2,"count":5,"name":"in_review"}"#).step,
                     "only progress.step is the step")
        let unreadable = [
            #""index":2,"count":5,"name":"reviewing""#,
            #""index":2,"count":5,"name":"In review""#,
            #""index":2,"count":5"#,
            #""index":2,"count":5,"name":2"#,
            #""index":0,"count":5,"name":"taken""#,
            #""index":1,"count":5,"name":"not_started""#,
            #""index":-1,"count":5,"name":"taken""#,
            #""index":6,"count":5,"name":"done""#,
            #""index":0,"count":0,"name":"not_started""#,
            #""index":1,"count":13,"name":"taken""#,
            #""index":"2","count":5,"name":"in_review""#,
            #""index":2.5,"count":5,"name":"in_review""#,
            #""index":2,"count":5,"name":"in_review","stalledSince":"2026-11-05T19:10:00Z","stalledReason":"lunch""#,
            #""index":2,"count":5,"name":"in_review","stalledSince":"2026-11-05T19:10:00Z","stalledReason":3"#,
            #""index":2,"count":5,"name":"in_review","stalledSince":"yesterday""#,
            #""index":2,"count":5,"name":"in_review","stalledSince":1793905800"#,
            #""index":2,"count":5,"name":"in_review","lastHolder":{"id":"forge-box-7"}"#,
            #""index":2,"count":5,"name":"in_review","waitingOn":7"#
        ]
        for fields in unreadable {
            XCTAssertNil(try stepped(fields).step, fields)
        }
        XCTAssertNil(try ticket(#""progress":{"step":"in_review"}"#).step)
        XCTAssertNil(try ticket(#""progress":{"step":[2,5,"in_review"]}"#).step)
    }

    func test_the_board_keeps_a_step_only_while_the_status_stands() throws {
        var board = RoomTicketBoard()
        board.upsert(try stepped(#""index":2,"count":5,"name":"in_review""#, version: 1))
        XCTAssertTrue(board.upsert(try ticket("", version: 2)), "a feed event of the same status")
        XCTAssertEqual(board.tickets["t1"]?.step?.name, .inReview, "keeps the step it had")

        XCTAssertTrue(board.upsert(try ticket("", version: 3, status: "done")))
        XCTAssertNil(board.tickets["t1"]?.step, "the status moved: no step from before the move")

        XCTAssertTrue(board.upsert(try stepped(#""index":5,"count":5,"name":"done""#, version: 3, status: "done")),
                      "a read of the same version brings the server's step")
        XCTAssertEqual(board.tickets["t1"]?.step?.name, .done)
        XCTAssertFalse(board.upsert(try stepped(#""index":5,"count":5,"name":"done""#, version: 3, status: "done")),
                       "the same step again changes nothing")
        XCTAssertFalse(board.upsert(try stepped(#""index":1,"count":5,"name":"taken""#, version: 2)),
                       "an older version changes nothing")
        XCTAssertEqual(board.tickets["t1"]?.step?.name, .done)
    }
}
