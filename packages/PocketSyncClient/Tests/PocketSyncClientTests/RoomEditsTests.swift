import Foundation
import XCTest
import PocketContracts
@testable import PocketSyncClient

/// An edit made anywhere (the web, another phone) reaches an open room: the `session_message_edited` envelope the
/// API writes (shape from room e9e8dc5e, sequence 55373, editing 55371) replaces the shown message with its new
/// text and "edited", and never adds a row (Carter, #55371).
final class RoomEditsTests: XCTestCase {
    private func envelope(
        sequence: Int64 = 55373,
        targetSequence: Int64 = 55371,
        targetId: String = "a1f24dcb",
        innerSequence: Int64 = 55371,
        innerId: String = "a1f24dcb",
        text: String = "Edited text",
        reply: String = "null"
    ) -> String {
        """
        {"id":"fc878036","sequenceId":\(sequence),"event":"session_message_edited",
         "ts":"2026-10-30T07:34:31.950409+00:00",
         "agent":{"id":"human-e7287377","model":"human"},
         "payload":{"schema":"session-message-edit:v1","channel":"session",
          "targetSequenceId":\(targetSequence),"targetMessageId":"\(targetId)","targetActionId":null,
          "messageRevision":2,"editedAt":"2026-10-30T07:34:31.950409+00:00","reply":\(reply),
          "event":{"id":"\(innerId)","sequenceId":\(innerSequence),"event":"session_message",
           "ts":"2026-10-30T07:33:24.113208+00:00","agent":{"id":"human-mrrcarter","model":"human"},
           "payload":{"source":"human","channel":"session","message":"\(text)"},
           "editedAt":"2026-10-30T07:34:31.950409+00:00","messageRevision":2}}}
        """
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func original(_ text: String = "Original text", sequence: Int64 = 55371, id: String = "a1f24dcb") -> RoomMessage {
        RoomMessage(id: id, sequenceId: sequence, kind: .message, authorId: "human-mrrcarter", authorName: "mrrCarter",
                    isHuman: true, text: text, timestamp: "2026-10-30T07:33:24.113208+00:00")
    }

    func test_the_envelope_gives_the_message_as_it_reads_now() throws {
        let edited = try XCTUnwrap(RoomMessage.edited(from: json(envelope())))
        XCTAssertEqual(edited.id, "a1f24dcb")
        XCTAssertEqual(edited.sequenceId, 55371, "the edited message keeps its own place, not the edit's")
        XCTAssertEqual(edited.text, "Edited text")
        XCTAssertEqual(edited.revision, 2)
        XCTAssertTrue(edited.isEdited)
        XCTAssertNil(RoomMessage(json: try json(envelope())), "the envelope itself is never a row")
    }

    func test_an_envelope_whose_message_is_not_the_one_it_names_is_ignored() throws {
        XCTAssertNil(RoomMessage.edited(from: try json(envelope(innerSequence: 55000))))
        XCTAssertNil(RoomMessage.edited(from: try json(envelope(innerId: "someone-else"))))
        XCTAssertNil(RoomMessage.edited(from: try json(envelope(reply: #"{"id":"r1"}"#))), "a reply's edit is not a message's")
    }

    func test_a_page_carries_edits_apart_from_its_rows_and_still_advances_past_them() throws {
        let page = try JSONDecoder().decode(RoomEventPage.self, from: Data("""
        {"events":[{"id":"m2","sequenceId":55372,"event":"session_message","agent":{"id":"claude-warden"},
                    "payload":{"message":"Three steps"}},
                   \(envelope())]}
        """.utf8))
        XCTAssertEqual(page.messages.map(\.sequenceId), [55372])
        XCTAssertEqual(page.edits.map(\.sequenceId), [55371])
        XCTAssertEqual(page.maxSequence, 55373, "the next poll starts after the edit")
        XCTAssertEqual(page.undecodableCount, 0)
    }

    func test_an_edit_replaces_a_shown_message_and_never_adds_one() throws {
        var timeline = RoomTimeline(capacity: 50)
        timeline.merge([original(), original("Later", sequence: 55372, id: "m2")])
        let edited = try XCTUnwrap(RoomMessage.edited(from: json(envelope())))

        XCTAssertEqual(timeline.applyEdits([edited]), ["a1f24dcb"])
        XCTAssertEqual(timeline.messages.map(\.text), ["Edited text", "Later"])
        XCTAssertTrue(timeline.messages[0].isEdited)
        XCTAssertEqual(timeline.applyEdits([edited]), [], "the same revision twice changes nothing")

        var elsewhere = RoomTimeline(capacity: 50)
        elsewhere.merge([original("Later", sequence: 55372, id: "m2")])
        XCTAssertEqual(elsewhere.applyEdits([edited]), [])
        XCTAssertEqual(elsewhere.messages.map(\.sequenceId), [55372], "a message not loaded is not brought in")
    }

    func test_the_stream_hands_over_the_edit_with_its_own_sequence() throws {
        let frame = RoomStreamFrame.decode(envelope())
        guard case .edited(let message, let sequenceId)? = frame else {
            return XCTFail("expected an edit frame, got \(String(describing: frame))")
        }
        XCTAssertEqual(message.text, "Edited text")
        XCTAssertEqual(sequenceId, 55373)
        XCTAssertEqual(RoomStreamFrame.decode(envelope(innerId: "someone-else")), .nonDisplayable(sequenceId: 55373))
    }
}

/// The jump down from a long history keeps only the newest rows (Carter's freezes on 10-30).
final class RoomTimelineKeepNewestTests: XCTestCase {
    func test_keeping_the_newest_drops_the_oldest_and_says_more_is_older() {
        var timeline = RoomTimeline(capacity: 3_000, hasMoreOlder: false)
        timeline.merge((1...200).map { RoomMessage(id: "m\($0)", sequenceId: Int64($0), kind: .message, authorId: "a",
                                                   authorName: "a", isHuman: false, text: "t", timestamp: "") })
        XCTAssertTrue(timeline.keepNewest(80))
        XCTAssertEqual(timeline.messages.first?.sequenceId, 121)
        XCTAssertEqual(timeline.messages.count, 80)
        XCTAssertTrue(timeline.hasMoreOlder)
        XCTAssertFalse(timeline.keepNewest(80), "already short enough")
    }
}
