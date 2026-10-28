import Foundation
import XCTest
import PocketContracts
@testable import PocketSyncClient

final class RoomEventsTests: XCTestCase {
    private func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func message(
        _ seq: Int64,
        id: String? = nil,
        author: String = "cobalt-warden",
        text: String = "hello",
        revision: Int64 = 1,
        clientId: String? = nil
    ) -> RoomMessage {
        RoomMessage(
            id: id ?? "evt-\(seq)",
            sequenceId: seq,
            kind: .message,
            authorId: author,
            authorName: author,
            isHuman: RoomMessage.isHumanAuthor(author),
            text: text,
            timestamp: "2026-10-28T18:00:00Z",
            clientMessageId: clientId,
            revision: revision
        )
    }

    // MARK: - Projection

    func test_message_projection_reads_payload_message_and_names_agents_by_id() {
        let row = json("""
        {"id":"e1","event":"session_message","sequenceId":5678,"ts":"2026-10-28T18:29:49Z",
         "agent":{"id":"pocket-forge","displayName":"Cobalt"},"agentId":"pocket-forge",
         "payload":{"channel":"session","message":"Mobile plan v1","clientMessageId":"hm_1"},
         "messageRevision":2,"editedAt":"2026-10-28T18:30:00Z"}
        """)
        let projected = RoomMessage(json: row)
        XCTAssertEqual(projected?.text, "Mobile plan v1")
        XCTAssertEqual(projected?.authorName, "pocket-forge", "an agent's displayName is a model family, not a name")
        XCTAssertEqual(projected?.isHuman, false)
        XCTAssertEqual(projected?.clientMessageId, "hm_1")
        XCTAssertEqual(projected?.revision, 2)
        XCTAssertEqual(projected?.isEdited, true)
        XCTAssertEqual(projected?.kind, .message)
    }

    func test_human_rows_use_display_name_or_strip_the_prefix() {
        let named = RoomMessage(json: json("""
        {"id":"e2","event":"session_message","sequenceId":5,"agent":{"id":"human-mrrcarter","displayName":"mrrCarter"},
         "payload":{"message":"hi"}}
        """))
        XCTAssertEqual(named?.authorName, "mrrCarter")
        XCTAssertEqual(named?.isHuman, true)

        let unnamed = RoomMessage(json: json("""
        {"id":"e3","event":"session_message","sequenceId":6,"agentId":"human-griff","payload":{"text":"yo"}}
        """))
        XCTAssertEqual(unnamed?.authorName, "griff")
        XCTAssertEqual(unnamed?.text, "yo", "payload.text is the fallback body")
    }

    func test_projection_reads_reply_target_and_rejects_non_room_rows() {
        let reply = RoomMessage(json: json("""
        {"id":"e4","event":"session_message","sequenceId":7,"agentId":"a","payload":{"message":"re","replyToSequenceId":3}}
        """))
        XCTAssertEqual(reply?.replyToSequenceId, 3)

        XCTAssertNil(RoomMessage(json: json("""
        {"id":"e5","event":"agent_heartbeat","sequenceId":8,"payload":{}}
        """)), "control rows are not displayed")
        XCTAssertNil(RoomMessage(json: json("""
        {"id":"e6","event":"session_message","sequenceId":9,"payload":{"message":"   "}}
        """)), "an empty message is not a row")
        XCTAssertNil(RoomMessage(json: json("""
        {"event":"session_message","sequenceId":10,"payload":{"message":"no id"}}
        """)), "identity fields stay required")
        XCTAssertNil(RoomMessage(json: json("""
        {"id":"e7","event":"session_message","sequenceId":0,"payload":{"message":"bad seq"}}
        """)))
    }

    func test_checkpoint_rows_show_their_title() {
        let row = RoomMessage(json: json("""
        {"id":"c1","event":"session_checkpoint","sequenceId":4567,"agentId":"senti",
         "payload":{"title":"Checkpoint 12","summary":"long"}}
        """))
        XCTAssertEqual(row?.kind, .checkpoint)
        XCTAssertEqual(row?.text, "Checkpoint 12")
    }

    // MARK: - Pages

    func test_page_decodes_row_by_row_and_counts_what_it_could_not_read() throws {
        let data = Data("""
        {"events":[
          {"id":"a","event":"session_message","sequenceId":12,"agentId":"x","payload":{"message":"one"}},
          {"id":"b","event":"listener_heartbeat","sequenceId":13,"payload":{}},
          {"id":"c","event":"session_message","payload":{"message":"no sequence"}},
          {"id":"d","event":"session_message","sequenceId":11,"agentId":"y","payload":{"message":"two"}}
        ],"count":4,"next_before_sequence":11,"has_more":true,"partial":false}
        """.utf8)
        let page = try JSONDecoder().decode(RoomEventPage.self, from: data)
        XCTAssertEqual(page.messages.map(\.sequenceId), [12, 11])
        XCTAssertEqual(page.rawCount, 4)
        XCTAssertEqual(page.undecodableCount, 1)
        XCTAssertEqual(page.maxSequence, 13, "a non-displayable row still advances the resume point")
        XCTAssertEqual(page.minSequence, 11)
        XCTAssertEqual(page.nextBeforeSequence, 11)
        XCTAssertTrue(page.hasMore)
    }

    func test_page_accepts_camel_case_envelope_keys() throws {
        let data = Data("""
        {"events":[],"nextBeforeSequence":40,"hasMore":false}
        """.utf8)
        let page = try JSONDecoder().decode(RoomEventPage.self, from: data)
        XCTAssertEqual(page.nextBeforeSequence, 40)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.maxSequence)
    }

    // MARK: - Timeline

    func test_timeline_orders_by_sequence_and_dedupes_by_sequence_id_or_client_id() {
        var timeline = RoomTimeline()
        timeline.merge([message(30), message(10), message(20)])
        XCTAssertEqual(timeline.messages.map(\.sequenceId), [10, 20, 30])

        let again = timeline.merge([message(20), message(31, id: "evt-30")])
        XCTAssertTrue(again.isEmpty, "same sequence or same event id is the same message")

        timeline.merge([message(40, clientId: "hm_x")])
        let echo = timeline.merge([message(41, id: "other", clientId: "hm_x")])
        XCTAssertTrue(echo.inserted.isEmpty, "a shared client message id is the same message")
        XCTAssertEqual(timeline.messages.count, 4)
        XCTAssertEqual(timeline.newestSequence, 40)
        XCTAssertEqual(timeline.oldestSequence, 10)
    }

    func test_a_client_message_id_only_matches_the_same_author() {
        var timeline = RoomTimeline()
        timeline.merge([message(40, author: "human-alex", clientId: "hm_x")])
        let other = timeline.merge([message(41, id: "other", author: "human-sam", clientId: "hm_x")])
        XCTAssertEqual(other.inserted.map(\.sequenceId), [41], "another author's row with the same client id is a new message")
        XCTAssertEqual(timeline.messages.map(\.authorId), ["human-alex", "human-sam"])
    }

    func test_timeline_replaces_a_body_only_on_a_strictly_higher_revision() {
        var timeline = RoomTimeline()
        timeline.merge([message(5, text: "v2", revision: 2)])
        let stale = timeline.merge([message(5, text: "v1", revision: 1)])
        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(timeline.messages.first?.text, "v2")

        let same = timeline.merge([message(5, text: "v2-again", revision: 2)])
        XCTAssertTrue(same.isEmpty)

        let newer = timeline.merge([message(5, text: "v3", revision: 3)])
        XCTAssertEqual(newer.updatedIds, ["evt-5"])
        XCTAssertEqual(timeline.messages.first?.text, "v3")
    }

    func test_timeline_capacity_drops_the_oldest_rows_and_reopens_history() {
        var timeline = RoomTimeline(capacity: 50, hasMoreOlder: false)
        timeline.merge((1...60).map { message(Int64($0)) })
        XCTAssertEqual(timeline.messages.count, 50)
        XCTAssertEqual(timeline.oldestSequence, 11)
        XCTAssertTrue(timeline.hasMoreOlder)
    }

    func test_index_of_sequence_uses_the_sorted_order() {
        var timeline = RoomTimeline()
        timeline.merge([message(100), message(7), message(55)])
        XCTAssertEqual(timeline.index(ofSequence: 55), 1)
        XCTAssertNil(timeline.index(ofSequence: 56))
    }

    // MARK: - Unread

    func test_unread_counts_other_peoples_messages_only_while_away_from_the_bottom() {
        var unread = RoomUnreadState()
        unread.noteArrivals([message(10)], readerIsAtBottom: true, selfAuthorIds: [])
        XCTAssertEqual(unread.unreadCount, 0)

        unread.noteArrivals(
            [message(12), message(11, author: "human-mrrcarter")],
            readerIsAtBottom: false,
            selfAuthorIds: ["human-mrrcarter"]
        )
        XCTAssertEqual(unread.unreadCount, 1, "your own messages never count as unread")
        XCTAssertEqual(unread.dividerSequence, 12)

        unread.noteArrivals([message(14), message(13)], readerIsAtBottom: false, selfAuthorIds: [])
        XCTAssertEqual(unread.unreadCount, 3)
        XCTAssertEqual(unread.dividerSequence, 12, "the divider stays at the first unseen row")

        unread.readerReachedBottom()
        XCTAssertEqual(unread.unreadCount, 0)
        XCTAssertNil(unread.dividerSequence)
    }
}
