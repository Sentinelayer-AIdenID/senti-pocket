import Foundation
import XCTest
import PocketContracts
@testable import PocketSyncClient

/// Carter, 11-05: "So fix the progress thing. I hate it." The server reads a ticket's step from typed facts (taken,
/// in review, merged, shipped) and sends it beside the old estimate; the exact field names come with the API's change,
/// so the phone reads the agreed shape tolerantly, and anything it cannot read in full is no step, never a guess.
final class RoomTicketStepTests: XCTestCase {
    private func ticket(_ fields: String, version: Int64 = 1, status: String = "in_review") throws -> RoomTicket {
        let extra = fields.isEmpty ? "" : "," + fields
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":"t1","title":"T","status":"\(status)","version":\(version)\(extra)}
        """.utf8))
        return try XCTUnwrap(RoomTicket(json: json))
    }

    func test_the_step_is_read_beside_the_old_estimate() throws {
        let read = try ticket(#"""
        "progress":{"value":0.62,"basis":"b","at":"2026-11-05T19:00:00Z",
          "step":{"index":2,"count":4,"name":"In review","stalledSince":"2026-11-05T19:10:00Z","extra":1},
          "stalledReason":"Box X was stopped","waitingOn":"your OK of the shots"}
        """#)
        XCTAssertEqual(read.step, RoomTicketStep(index: 2, count: 4, name: "In review",
                                                 stalledSince: "2026-11-05T19:10:00Z",
                                                 stalledReason: "Box X was stopped",
                                                 waitingOn: "your OK of the shots"))
        XCTAssertEqual(read.progress?.value, 0.62, "the old estimate is still read, for older builds")
    }

    func test_the_step_may_sit_on_the_ticket_in_either_case_with_people_as_objects() throws {
        let top = try ticket(#"""
        "step":{"index":1,"count":4,"name":"Taken","stalled_since":"2026-11-03T19:10:00Z"},
        "last_holder":{"id":"forge-box-7","name":"build box 7"}
        """#)
        XCTAssertEqual(top.step, RoomTicketStep(index: 1, count: 4, name: "Taken", stalledSince: "2026-11-03T19:10:00Z",
                                                lastHolder: "build box 7"))
        let inside = try ticket(#""step":{"index":3,"count":4,"name":"  Merged\n","waiting_on":{"id":"human-alex"}}"#)
        XCTAssertEqual(inside.step?.name, "Merged", "one line")
        XCTAssertEqual(inside.step?.waitingOn, "human-alex")
    }

    func test_no_step_or_one_it_cannot_read_is_no_step() throws {
        XCTAssertNil(try ticket("").step, "an older server sends none")
        XCTAssertNil(try ticket(#""progress":{"value":0.62,"basis":"b","at":"a"}"#).step, "the estimate alone is no step")
        let unreadable = [
            #""step":{"index":0,"count":4,"name":"Taken"}"#,
            #""step":{"index":5,"count":4,"name":"Shipped"}"#,
            #""step":{"index":1,"count":0,"name":"Taken"}"#,
            #""step":{"index":1,"count":13,"name":"Taken"}"#,
            #""step":{"index":"2","count":4,"name":"In review"}"#,
            #""step":{"index":2.5,"count":4,"name":"In review"}"#,
            #""step":{"index":2,"count":4,"name":"  "}"#,
            #""step":{"index":2,"count":4}"#,
            #""step":"in review""#,
            #""progress":{"step":[2,4,"In review"]}"#
        ]
        for fields in unreadable {
            XCTAssertNil(try ticket(fields).step, fields)
        }
    }

    func test_the_board_keeps_a_step_only_while_the_status_stands() throws {
        var board = RoomTicketBoard()
        board.upsert(try ticket(#""step":{"index":2,"count":4,"name":"In review"}"#, version: 1))
        XCTAssertTrue(board.upsert(try ticket("", version: 2)), "a feed event of the same status")
        XCTAssertEqual(board.tickets["t1"]?.step?.name, "In review", "keeps the step it had")

        XCTAssertTrue(board.upsert(try ticket("", version: 3, status: "done")))
        XCTAssertNil(board.tickets["t1"]?.step, "the status moved: no step from before the move")

        XCTAssertTrue(board.upsert(try ticket(#""step":{"index":4,"count":4,"name":"Shipped"}"#, version: 3, status: "done")),
                      "a read of the same version brings the server's step")
        XCTAssertEqual(board.tickets["t1"]?.step?.name, "Shipped")
        XCTAssertFalse(board.upsert(try ticket(#""step":{"index":4,"count":4,"name":"Shipped"}"#, version: 3, status: "done")),
                       "the same step again changes nothing")
        XCTAssertFalse(board.upsert(try ticket(#""step":{"index":1,"count":4,"name":"Taken"}"#, version: 2)),
                       "an older version changes nothing")
        XCTAssertEqual(board.tickets["t1"]?.step?.name, "Shipped")
    }
}
