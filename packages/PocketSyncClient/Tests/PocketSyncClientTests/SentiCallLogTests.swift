import Foundation
import XCTest
@testable import PocketSyncClient

/// The call log read from `GET /api/v1/me/calls` (API #1060), for "Calls & briefings".
final class SentiCallLogTests: XCTestCase {
    func test_a_voice_room_and_a_ring_are_read_and_malformed_rows_skipped() throws {
        let page = try JSONDecoder().decode(SentiCallLogPage.self, from: Data("""
        {"nextCursor": "c-2", "calls": [
          {"kind": "voice_room", "id": "d73346d1-6daf-4417-8876-d44c5b0763fc",
           "sessionId": "e9e8dc5e-8d57-4603-975f-09156e3b4473", "roomTitle": "Senti-expansion-proj",
           "with": ["pocket-forge"], "meeting": false, "status": "ended",
           "startedAt": "2026-10-30T17:38:19.740000+00:00", "endedAt": "2026-10-30T17:41:00.016000+00:00",
           "durationText": "2 min 40 s", "turns": 7, "timingsText": "Timings: you stop → answer heard 2.1 s",
           "transcriptAttachmentId": null,
           "summaries": [{"author": "pocket-forge", "text": "Call summary: next build rings.", "createdAt": "x"},
                         {"author": "x", "text": "  "}],
           "startSequenceId": 55589, "endSequenceId": 55598},
          {"kind": "ring", "id": "r-1", "sessionId": "room-2", "roomTitle": "Lab", "direction": "incoming",
           "callerName": "claude-warden", "callerKind": "agent", "calleeName": "mrrCarter", "reason": "Review is ready",
           "status": "missed", "createdAt": "2026-10-30T12:00:00Z", "answeredAt": null, "endedAt": "2026-10-30T12:01:00Z"},
          {"kind": "voice_room", "id": "bad", "sessionId": "../etc"},
          {"kind": "fax", "id": "x", "sessionId": "room-3"}
        ]}
        """.utf8))
        XCTAssertEqual(page.nextCursor, "c-2")
        XCTAssertEqual(page.calls.map(\.id), ["d73346d1-6daf-4417-8876-d44c5b0763fc", "r-1"])
        let call = page.calls[0]
        XCTAssertEqual(call.kind, .voiceRoom)
        XCTAssertEqual(call.with, ["pocket-forge"])
        XCTAssertEqual(call.turns, 7)
        XCTAssertEqual(call.endSequenceId, 55598)
        XCTAssertNil(call.transcriptAttachmentId)
        XCTAssertEqual(call.summaries.map(\.author), ["pocket-forge"], "an empty summary is dropped")
        let ring = page.calls[1]
        XCTAssertEqual(ring.kind, .ring)
        XCTAssertEqual(ring.startedAt, "2026-10-30T12:00:00Z", "a ring starts when it was made")
        XCTAssertEqual(ring.direction, "incoming")
        XCTAssertEqual(ring.status, "missed")
    }

    /// Warden (#272): a reply without its list is an error, not "no calls yet".
    func test_a_reply_without_the_list_is_an_error() {
        XCTAssertThrowsError(try JSONDecoder().decode(SentiCallLogPage.self, from: Data(#"{"nextCursor": null}"#.utf8)))
        XCTAssertEqual(try JSONDecoder().decode(SentiCallLogPage.self, from: Data(#"{"calls": []}"#.utf8)).calls, [])
    }
}
