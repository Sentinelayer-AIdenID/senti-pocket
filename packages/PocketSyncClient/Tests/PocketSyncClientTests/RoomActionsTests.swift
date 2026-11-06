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

    // MARK: - Photos and files on replies (sentinelayer-api #1135)

    /// The API's own reply row, as `_message_action_row` writes it: the message's pointer shape under `attachments`.
    private static let photoReply = """
    {"id":"9b2f7a40-0000-4000-8000-000000000001","actionType":"reply","targetSequenceId":42,"actorId":"human-pat",
     "note":"look at this","createdAt":"2026-11-04T10:00:00+00:00","messageRevision":1,
     "attachments":[{"attachmentId":"pm_aaaaaaaaaaaaaaaaaaaaaaaa","filename":"IMG_0001.jpg","kind":"image",
       "contentType":"image/jpeg","sizeBytes":342490,"sha256":"\(String(repeating: "a", count: 64))",
       "status":"uploaded","previewAttachmentId":"pm_aaaaaaaaaaaaaaaaaaaaaaaa.pv","uploadedBy":"human-pat",
       "uploadedAt":"2026-11-04T09:59:00+00:00","disposition":"inline","pointer":"attachment://x"},
      {"attachmentId":"pm_bbbbbbbbbbbbbbbbbbbbbbbb","filename":"notes.pdf","kind":"file",
       "contentType":"application/pdf","sizeBytes":1200,"status":"uploaded","removed":true}]}
    """

    func test_a_reply_carries_its_photos_and_files_in_the_messages_shape() throws {
        let page = try decode(#"{"actions":["# + Self.photoReply + #"],"projection":{}}"#)
        let reply = try XCTUnwrap(page.replies.first)
        XCTAssertEqual(reply.text, "look at this")
        XCTAssertEqual(reply.attachments.map(\.attachmentId), ["pm_aaaaaaaaaaaaaaaaaaaaaaaa", "pm_bbbbbbbbbbbbbbbbbbbbbbbb"])
        XCTAssertEqual(reply.attachments.first?.kind, .image)
        XCTAssertEqual(reply.attachments.first?.sizeBytes, 342_490)
        XCTAssertEqual(reply.attachments.last?.kind, .pdf)
        XCTAssertEqual(reply.attachments.last?.isRemoved, true, "a file taken back after it was sent shows as removed")
        XCTAssertEqual(page.replyAttachments, .supported)
    }

    func test_a_reply_of_files_alone_shows_and_a_reply_of_nothing_does_not() throws {
        let page = try decode("""
        {"actions":[
          {"id":"p","actionType":"reply","targetSequenceId":42,"actorId":"human-pat","note":null,
           "createdAt":"2026-11-04T10:00:00+00:00","attachments":[{"attachmentId":"pm_cccccccccccccccccccccccc",
           "filename":"IMG_2.jpg","kind":"image","contentType":"image/jpeg"}]},
          {"id":"q","actionType":"reply","targetSequenceId":42,"actorId":"human-pat","note":"  ",
           "createdAt":"2026-11-04T10:01:00+00:00","attachments":[]}
        ],"projection":{}}
        """)
        XCTAssertEqual(page.replies.map(\.id), ["p"], "a photo with no words is a reply; nothing at all is not")
        XCTAssertEqual(page.replies.first?.text, "")
        XCTAssertEqual(page.replies.first?.attachments.first?.kind, .image)
    }

    func test_absent_attachments_decode_as_none_and_say_the_api_takes_none_on_a_reply() throws {
        // An API from before reply attachments (or an older row): no `attachments` key at all.
        let older = try decode("""
        {"actions":[{"id":"r","actionType":"reply","targetSequenceId":42,"actorId":"agent-a1","note":"done",
          "createdAt":"2026-11-04T10:00:00+00:00"},
          {"id":"k","actionType":"ack","targetSequenceId":42,"actorId":"agent-a1","createdAt":"2026-11-04T10:00:01+00:00"}],
         "projection":{}}
        """)
        XCTAssertEqual(older.replies.first?.attachments, [])
        XCTAssertEqual(older.replies.first?.text, "done")
        XCTAssertEqual(older.replyAttachments, .unsupported)

        // The API that takes them writes the list on every row it returns, empty when there are none.
        let newer = try decode("""
        {"actions":[{"id":"k","actionType":"ack","targetSequenceId":42,"actorId":"agent-a1","attachments":[],
          "createdAt":"2026-11-04T10:00:01+00:00"}],"projection":{}}
        """)
        XCTAssertEqual(newer.replyAttachments, .supported)
        XCTAssertEqual(try decode(#"{"actions":[],"projection":{}}"#).replyAttachments, .unknown, "no rows say nothing")
    }
}
