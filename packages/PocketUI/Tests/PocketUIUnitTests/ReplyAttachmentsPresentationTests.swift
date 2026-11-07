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

    /// A long thread shows a page of its replies: its title counts them all, it says older ones are there, and that
    /// the reply it was opened at is further back.
    func test_a_long_threads_page_counts_the_whole_thread_and_says_what_is_further_back() {
        let replies = (1...3).map {
            RoomChatReplyRow(id: "r\($0)", authorName: "pat", isHuman: true, isOwn: false, text: "reply \($0)", date: nil,
                             isEdited: false)
        }
        let page = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: [parent],
            thread: RoomChatThreadInput(sequenceId: 7, replies: replies, canReply: true, focusReplyId: "r0",
                                        hasOlder: true, isLoadingOlder: true, totalReplies: 120_000, focusMissing: true)
        ).thread
        XCTAssertEqual(page?.title, "120000 replies", "the whole thread, not the page loaded")
        XCTAssertEqual(page?.hasOlder, true)
        XCTAssertEqual(page?.isLoadingOlder, true)
        XCTAssertEqual(page?.focusMissing, true)
        let unknown = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: [parent],
            thread: RoomChatThreadInput(sequenceId: 7, replies: Array(replies.prefix(1)))
        ).thread
        XCTAssertEqual(unknown?.title, "1 reply", "the replies loaded, when the room has no count")
        XCTAssertEqual(unknown?.hasOlder, false)
        XCTAssertEqual(unknown?.focusMissing, false)
        XCTAssertEqual(unknown?.hasLater, false)
    }

    /// A thread opened at a reply short of its newest (one read around it) says later replies are there, and when a
    /// page of them is on its way.
    func test_a_thread_opened_short_of_its_newest_says_later_replies_are_there() {
        let reply = RoomChatReplyRow(id: "r1", authorName: "pat", isHuman: true, isOwn: false, text: "reply", date: nil,
                                     isEdited: false)
        let window = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: [parent],
            thread: RoomChatThreadInput(sequenceId: 7, replies: [reply], focusReplyId: "r1", hasOlder: true,
                                        hasLater: true, isLoadingLater: true)
        ).thread
        XCTAssertEqual(window?.hasLater, true)
        XCTAssertEqual(window?.isLoadingLater, true)
        XCTAssertEqual(window?.hasNewer, false)
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
