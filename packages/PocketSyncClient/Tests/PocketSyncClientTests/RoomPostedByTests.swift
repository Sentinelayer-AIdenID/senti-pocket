import Foundation
import XCTest
import PocketContracts
@testable import PocketSyncClient

/// Who posted a message, as the server stamps it on the message's own event (`payload.postedBy`): the room's owner or
/// an admin, or anyone else. Older events carry no stamp; an edit notice never carries one, and a message replaced by
/// its edit keeps the stamp its own event had.
final class RoomPostedByTests: XCTestCase {
    private func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func event(_ seq: Int64, postedBy: String?, text: String = "🏆 Board", revision: Int64 = 1) -> String {
        let stamp = postedBy.map { #","postedBy":\#($0)"# } ?? ""
        return #"{"id":"evt-\#(seq)","event":"session_message","sequenceId":\#(seq),"ts":"2026-11-01T01:00:00Z","#
            + #""agent":{"id":"host-agent"},"payload":{"message":"\#(text)"\#(stamp)},"messageRevision":\#(revision)}"#
    }

    func test_the_stamp_is_read_from_the_messages_own_event() throws {
        let owner = try XCTUnwrap(RoomMessage(json: json(event(1, postedBy: #"{"isRoomOwner":true,"external":false}"#))))
        XCTAssertEqual(owner.postedBy, RoomPostedBy(isRoomOwner: true, external: false))
        let admin = try XCTUnwrap(RoomMessage(json: json(event(2, postedBy: #"{"isRoomOwner":false,"external":false}"#))))
        XCTAssertEqual(admin.postedBy, RoomPostedBy(isRoomOwner: false, external: false))
        let member = try XCTUnwrap(RoomMessage(json: json(event(3, postedBy: #"{"isRoomOwner":false,"external":true}"#))))
        XCTAssertEqual(member.postedBy?.external, true)
        XCTAssertNil(try XCTUnwrap(RoomMessage(json: json(event(4, postedBy: nil)))).postedBy, "an older event")
        XCTAssertNil(try XCTUnwrap(RoomMessage(json: json(event(5, postedBy: #"{"external":"false"}"#)))).postedBy,
                     "only a JSON boolean counts")
    }

    /// An edit notice's inner event says nothing about who posted the message, even when it claims to.
    func test_an_edit_never_carries_a_stamp() throws {
        let inner = event(9, postedBy: #"{"isRoomOwner":true,"external":false}"#, revision: 2)
        let notice = json(#"{"id":"edit-1","event":"session_message_edited","sequenceId":10,"#
            + #""payload":{"targetSequenceId":9,"targetMessageId":"evt-9","event":\#(inner)}}"#)
        let edited = try XCTUnwrap(RoomMessage.edited(from: notice))
        XCTAssertEqual(edited.revision, 2)
        XCTAssertNil(edited.postedBy)
    }

    /// The timeline keeps a message's stamp when its edit, or a newer copy without one, replaces it.
    func test_a_replaced_message_keeps_its_stamp() throws {
        let stamp = RoomPostedBy(isRoomOwner: true, external: false)
        let original = try XCTUnwrap(RoomMessage(json: json(event(9, postedBy: #"{"isRoomOwner":true,"external":false}"#))))
        var timeline = RoomTimeline()
        _ = timeline.merge([original])
        let edit = original.withPostedBy(nil)
        _ = timeline.applyEdits([RoomMessage(json: json(event(9, postedBy: nil, text: "🏆 Board 2", revision: 2)))!])
        XCTAssertEqual(timeline.messages.first?.text, "🏆 Board 2")
        XCTAssertEqual(timeline.messages.first?.postedBy, stamp, "kept across the edit")
        _ = timeline.merge([RoomMessage(json: json(event(9, postedBy: nil, text: "🏆 Board 3", revision: 3)))!])
        XCTAssertEqual(timeline.messages.first?.text, "🏆 Board 3")
        XCTAssertEqual(timeline.messages.first?.postedBy, stamp, "and across a newer copy without one")
        XCTAssertNil(edit.postedBy)
    }
}
