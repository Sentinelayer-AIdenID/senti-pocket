import Foundation
import XCTest
import PocketContracts
@testable import PocketSyncClient

/// Carter, #55238 (progress judged by the signal layer), API #1052: `progress` rides on ticket reads, never on feed
/// events, so the board keeps the last estimate until a read brings a newer one.
final class RoomTicketProgressTests: XCTestCase {
    private func ticket(_ version: Int64, progress: String? = nil) throws -> RoomTicket {
        let extra = progress.map { #","progress":\#($0)"# } ?? ""
        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"id":"t1","title":"T","status":"working","version":\(version)\(extra)}
        """.utf8))
        return try XCTUnwrap(RoomTicket(json: json))
    }

    func test_a_read_carries_the_estimate_bounded() throws {
        let read = try ticket(1, progress: #"{"value":0.62,"basis":"stage: working; 3 progress notes","at":"2026-10-30T13:00:00Z"}"#)
        XCTAssertEqual(read.progress, RoomTicketProgress(value: 0.62, basis: "stage: working; 3 progress notes", at: "2026-10-30T13:00:00Z"))
        XCTAssertEqual(try ticket(1, progress: #"{"value":7}"#).progress?.value, 1, "out of range is clamped")
        XCTAssertNil(try ticket(1, progress: #"{"basis":"no value"}"#).progress)
        XCTAssertNil(try ticket(1).progress, "absent until scored")
    }

    func test_the_board_keeps_the_last_estimate_across_feed_events() throws {
        var board = RoomTicketBoard()
        board.upsert(try ticket(1, progress: #"{"value":0.5,"basis":"b","at":"a"}"#))
        XCTAssertTrue(board.upsert(try ticket(2)), "a newer version from the feed still lands")
        XCTAssertEqual(board.tickets["t1"]?.version, 2)
        XCTAssertEqual(board.tickets["t1"]?.progress?.value, 0.5, "and keeps the estimate it had")

        XCTAssertTrue(board.upsert(try ticket(2, progress: #"{"value":0.8,"basis":"b","at":"a"}"#)),
                      "a read of the same version brings a fresh estimate")
        XCTAssertEqual(board.tickets["t1"]?.progress?.value, 0.8)
        XCTAssertFalse(board.upsert(try ticket(1, progress: #"{"value":0.1,"basis":"b","at":"a"}"#)), "an older version changes nothing")
        XCTAssertEqual(board.tickets["t1"]?.progress?.value, 0.8)
    }
}
