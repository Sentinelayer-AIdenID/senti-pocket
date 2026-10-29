import Foundation
import XCTest
@testable import PocketSyncClient

final class RoomSearchTests: XCTestCase {
    func test_a_search_page_reads_matches_newest_first_and_where_the_next_page_starts() throws {
        let data = Data(#"""
        {"query":"paste","count":3,"next_before_sequence":40,"has_more":true,"results":[
          {"sequenceId":52,"snippet":"…validation now runs on paste and on blur…","matchedField":"payload.message",
           "event":{"id":"e52","event":"session_message","sequenceId":52,"ts":"2026-10-28T18:00:00Z",
                    "agentId":"review-agent","payload":{"message":"validation now runs on paste and on blur"}}},
          {"sequenceId":47,"snippet":"Paste skips validation","event":{"id":"e47","event":"agent_heartbeat","sequenceId":47}},
          {"sequenceId":52,"snippet":"duplicate"},
          {"sequenceId":0,"snippet":"no place"}
        ]}
        """#.utf8)
        let page = try JSONDecoder().decode(RoomSearchPage.self, from: data)
        XCTAssertEqual(page.query, "paste")
        XCTAssertEqual(page.results.map(\.sequenceId), [52, 47], "one match per row; a match without a place is dropped")
        XCTAssertEqual(page.results.first?.message?.authorName, "review-agent")
        XCTAssertEqual(page.results.first?.matchedField, "payload.message")
        XCTAssertNil(page.results.last?.message, "a row the room does not show still lists its snippet")
        XCTAssertEqual(page.nextBeforeSequence, 40)
        XCTAssertTrue(page.hasMore)

        let last = try JSONDecoder().decode(RoomSearchPage.self, from: Data(#"{"query":"x","results":[],"next_before_sequence":null,"has_more":false}"#.utf8))
        XCTAssertNil(last.nextBeforeSequence)
        XCTAssertFalse(last.hasMore)
    }
}
