import Foundation
import XCTest
@testable import PocketUI

/// Photos and files on replies (sentinelayer-api #1135): what the thread shows, when its Send can go, and the bell's
/// reply kind.
@MainActor
final class ReplyAttachmentsPresentationTests: XCTestCase {
    private let parent = RoomChatMessageInput(
        id: "e1", sequenceId: 7, kind: .message, authorId: "agent-a1", authorName: "agent-a1",
        isHuman: false, text: "parent", timestamp: "2026-11-04T10:00:00Z"
    )

    /// The API refuses an empty reply (422): with no words and no files, Send stays off in the thread and the room.
    func test_send_is_disabled_when_there_are_no_words_and_no_files() {
        XCTAssertFalse(RoomMediaSendButton.isEnabled(canSendText: false, hasProblem: false, attached: 0),
                       "nothing typed and nothing attached: an empty reply is never sent")
        XCTAssertTrue(RoomMediaSendButton.isEnabled(canSendText: false, hasProblem: false, attached: 1),
                      "a photo alone is a reply")
        XCTAssertTrue(RoomMediaSendButton.isEnabled(canSendText: true, hasProblem: false, attached: 0))
        XCTAssertFalse(RoomMediaSendButton.isEnabled(canSendText: true, hasProblem: true, attached: 2),
                       "words over the limit hold the send, files or not")
    }

    func test_a_reply_shows_its_photos_and_files_and_the_thread_its_focused_reply() {
        let photo = RoomAttachmentChip(attachmentId: "pm_photo_000001", filename: "IMG_0001.jpg", kind: .image)
        let reply = RoomChatReplyRow(id: "r1", authorName: "pat", isHuman: true, isOwn: false, text: "", date: nil,
                                     isEdited: false, attachments: [photo])
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: [parent],
            thread: RoomChatThreadInput(sequenceId: 7, replies: [reply], canReply: true, focusReplyId: "r1")
        )
        XCTAssertEqual(state.thread?.replies.first?.attachments, [photo])
        XCTAssertEqual(state.thread?.replies.first?.text, "", "a reply of a photo alone")
        XCTAssertEqual(state.thread?.focusReplyId, "r1", "opened at the reply its notification named")
    }

    func test_a_reply_bell_has_its_own_mark() {
        let row = NotificationRow(id: "n1", kind: "reply", title: "pat replied", body: "Photo", roomTitle: "Room",
                                  createdAt: "2026-11-04T10:00:00Z", isRead: false, canOpen: true)
        XCTAssertEqual(row.symbol, "arrowshape.turn.up.left")
        let mention = NotificationRow(id: "n2", kind: "mention", title: "", body: "", roomTitle: nil,
                                      createdAt: "", isRead: false, canOpen: true)
        XCTAssertNotEqual(mention.symbol, row.symbol)
    }

    func test_a_reply_on_its_way_says_whom_it_answers_and_offers_the_room_when_the_api_takes_no_files() {
        let progress = RoomMediaProgress()
        let target = RoomMediaReplyTarget(sequenceId: 7, replyId: nil, name: "agent-a1")
        let row = RoomMediaOutgoingRow(id: "hm_1", text: nil, items: [], status: .failed(
            reason: RoomMediaOutgoingRow.replyFilesRefused, canRetry: false), progress: progress,
            replyTo: target, offersSendAsMessage: true)
        XCTAssertEqual(row.statusText, "Photos can't go in a reply yet")
        XCTAssertFalse(row.canRetry, "the same reply would be refused again")
        XCTAssertNotEqual(row, RoomMediaOutgoingRow(id: "hm_1", text: nil, items: [], status: row.status,
                                                    progress: progress, replyTo: target),
                          "offering the room is part of what the card shows")
    }
}
