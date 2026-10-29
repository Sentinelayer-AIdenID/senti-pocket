import Foundation
import XCTest
@testable import PocketSyncClient

final class RoomActionsTests: XCTestCase {
    private func decode(_ json: String) throws -> RoomActionsPage {
        try JSONDecoder().decode(RoomActionsPage.self, from: Data(json.utf8))
    }

    func test_projection_gives_counts_reactors_owners_and_viewer_reactions_per_message() throws {
        let page = try decode("""
        {"sessionId":"s","actions":[],"count":0,"projection":{"byTarget":[
          {"targetSequenceId":1234,
           "counts":{"ack":2,"reply":3,"working_on":1,"disregard":0},
           "actors":{"ticket-keeper":["ack","working_on"],"cobalt-warden":["ack","reply"],"coral-helper":["reply"]},
           "activeOwners":["cobalt-warden",{"actorId":"coral-helper"}],
           "reactions":{"like":{"count":4,"byViewer":true},"dislike":{"count":0,"byViewer":false}},
           "latestReplies":[{"id":"r1","actionType":"reply","targetSequenceId":1234,"actorId":"cobalt-warden",
             "note":"on it","createdAt":"2026-10-28T18:47:59.657359+00:00","messageRevision":1}],
           "replyTotal":111,"hasMoreReplies":true,"isPinned":true},
          {"counts":{"ack":1}}
        ]}}
        """)
        XCTAssertEqual(page.byTarget.count, 1, "a target without a sequence id is skipped")
        let summary = try XCTUnwrap(page.byTarget[1234])
        XCTAssertEqual(summary.counts, ["ack": 2, "reply": 3, "working_on": 1, "like": 4], "zero counts are dropped")
        XCTAssertEqual(summary.actorsByType["ack"], ["cobalt-warden", "ticket-keeper"])
        XCTAssertEqual(summary.actorsByType["reply"], ["cobalt-warden", "coral-helper"])
        XCTAssertEqual(summary.activeOwners, ["cobalt-warden", "coral-helper"])
        XCTAssertTrue(summary.likedByViewer)
        XCTAssertFalse(summary.dislikedByViewer)
        XCTAssertEqual(summary.replyTotal, 111)
        XCTAssertEqual(summary.latestReplies.map(\.id), ["r1"])
        XCTAssertTrue(summary.hasMoreReplies)
        XCTAssertTrue(summary.isPinned)
    }

    func test_thread_replies_keep_only_replies_take_the_newest_revision_and_sort_oldest_first() throws {
        let page = try decode("""
        {"actions":[
          {"id":"b","actionType":"reply","targetSequenceId":7,"actorId":"human-mrrcarter","note":"second",
           "createdAt":"2026-10-28T10:02:00+00:00","messageRevision":1},
          {"id":"a","actionType":"reply","targetSequenceId":7,"actorId":"cobalt-warden","note":"first v1",
           "createdAt":"2026-10-28T10:01:00+00:00","messageRevision":1},
          {"id":"a","actionType":"reply","targetSequenceId":7,"actorId":"cobalt-warden","note":"first v2",
           "createdAt":"2026-10-28T10:01:00+00:00","messageRevision":2,"editedAt":"2026-10-28T10:05:00+00:00"},
          {"id":"c","actionType":"ack","targetSequenceId":7,"actorId":"x","note":null,"createdAt":"2026-10-28T10:03:00+00:00"},
          {"id":"d","actionType":"reply","targetSequenceId":7,"actorId":"x","note":"   ","createdAt":"2026-10-28T10:04:00+00:00"}
        ],"projection":{}}
        """)
        XCTAssertEqual(page.replies.map(\.id), ["a", "b"])
        XCTAssertEqual(page.replies.first?.text, "first v2")
        XCTAssertEqual(page.replies.first?.isEdited, true)
        XCTAssertEqual(page.replies.last?.isHuman, true)
        XCTAssertTrue(page.byTarget.isEmpty)
    }

    func test_a_page_with_missing_or_odd_fields_still_decodes() throws {
        let page = try decode(#"{"projection":{"byTarget":"nope"}}"#)
        XCTAssertTrue(page.byTarget.isEmpty)
        XCTAssertTrue(page.replies.isEmpty)
    }
}
