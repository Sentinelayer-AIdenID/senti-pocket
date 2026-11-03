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
        XCTAssertTrue(page.pinned.isEmpty)
        XCTAssertEqual(page.pinLimit, 10)
    }

    func test_the_rooms_pinned_messages_come_newest_first_once_each() throws {
        let page = try decode(#"""
        {"projection":{"byTarget":[],"pinLimit":10,"pinnedMessages":[
          {"id":"p2","actionType":"pin","targetSequenceId":7,"actorId":"human-mrrcarter","createdAt":"2026-10-29T01:00:00Z"},
          {"id":"p1","actionType":"pin","targetSequenceId":3,"actorId":"cobalt-warden","createdAt":"2026-10-28T23:00:00Z"},
          {"id":"p0","actionType":"pin","targetSequenceId":7,"actorId":"human-griff"},
          {"id":"","actionType":"pin","targetSequenceId":9},
          {"id":"p9","actionType":"pin","targetSequenceId":0}
        ]}}
        """#)
        XCTAssertEqual(page.pinned.map(\.targetSequenceId), [7, 3], "one pin per message; rows without an id or target are dropped")
        XCTAssertEqual(page.pinned.first?.pinnedBy, "human-mrrcarter")
        XCTAssertEqual(page.pinLimit, 10)
    }

    func test_emoji_reactions_come_in_first_use_order_with_your_own_marked() throws {
        let page = try decode(#"""
        {"projection":{"byTarget":[
          {"targetSequenceId":5,"reactions":{"like":{"count":1,"byViewer":false}},
           "emojiReactions":[
             {"emoji":"🎉","count":3,"viewerReacted":true,"actors":["human-alex","review-agent",""]},
             {"emoji":"👀","count":1,"actors":["build-agent",7]}
           ]},
          {"targetSequenceId":6,"counts":{"ack":1}}
        ]}}
        """#)
        XCTAssertEqual(page.byTarget[5]?.emojiReactions, [
            RoomEmojiReaction(emoji: "🎉", count: 3, viewerReacted: true, actors: ["human-alex", "review-agent"]),
            RoomEmojiReaction(emoji: "👀", count: 1, viewerReacted: false, actors: ["build-agent"])
        ], "an actor that is empty or not text is dropped; not saying you reacted means you did not")
        XCTAssertEqual(page.byTarget[5]?.counts, ["like": 1], "the like count is unchanged")
        XCTAssertEqual(page.byTarget[6]?.emojiReactions, [], "a summary without emoji reactions has none")
    }

    func test_an_emoji_reaction_that_is_not_one_emoji_or_has_no_count_is_dropped() throws {
        let page = try decode(#"""
        {"projection":{"byTarget":[{"targetSequenceId":5,"emojiReactions":[
          {"emoji":"@all","count":2},
          {"emoji":"abc","count":2},
          {"emoji":"👍👍","count":2},
          {"count":2},
          {"emoji":"🔥","count":0},
          {"emoji":"🔥"},
          {"emoji":"✅","count":2},
          {"emoji":"✅","count":9,"viewerReacted":true}
        ]}]}}
        """#)
        XCTAssertEqual(page.byTarget[5]?.emojiReactions.map(\.emoji), ["✅"])
        XCTAssertEqual(page.byTarget[5]?.emojiReactions.first?.count, 2, "an emoji listed twice keeps its first entry")
    }

    func test_emoji_reactions_are_capped_at_twenty_per_message_and_ten_reactors_each() throws {
        let emoji = (0..<25).map { String(UnicodeScalar(0x1F600 + $0)!) }
        let actors = (0..<12).map { "\"agent-\($0)\"" }.joined(separator: ",")
        let entries = emoji.map { #"{"emoji":"\#($0)","count":1,"actors":[\#(actors)]}"# }.joined(separator: ",")
        let page = try decode(#"{"projection":{"byTarget":[{"targetSequenceId":5,"emojiReactions":[\#(entries)]}]}}"#)
        let reactions = try XCTUnwrap(page.byTarget[5]?.emojiReactions)
        XCTAssertEqual(reactions.map(\.emoji), Array(emoji.prefix(20)), "the first twenty, in order")
        XCTAssertEqual(reactions.first?.actors, (0..<10).map { "agent-\($0)" })
    }
}
