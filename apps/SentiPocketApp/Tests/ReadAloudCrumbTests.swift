import Foundation
import PocketUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// The Read-aloud crumb in the freeze recorder's trail: where it was started, the thread open, the text size, the
/// images on what is read and how often the reader had just changed; never what is read nor who wrote it.
@MainActor
final class ReadAloudCrumbTests: XCTestCase {
    private static let secret = "Words nobody may see in a crash report"

    private static func png(width: Int, height: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                               format: { let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format }())
        return renderer.pngData { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private static func state(thread: Bool) -> RoomChatPresentationState {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let image = RoomAttachmentChip(attachmentId: "a1", filename: "list.png", kind: .image)
        let message = RoomChatMessageInput(id: "m1", sequenceId: 1, kind: .message, authorId: "human-alex",
                                           authorName: "Alex", isHuman: true, text: secret, timestamp: "", date: date,
                                           attachments: [image])
        let replies = [
            RoomChatReplyRow(id: "r1", authorName: "agent", isHuman: false, isOwn: false, text: secret, date: date,
                             isEdited: false),
            RoomChatReplyRow(id: "r2", authorName: "Alex", isHuman: true, isOwn: true, text: secret, date: date,
                             isEdited: false, parentReplyId: "r1")
        ]
        return RoomChatPresentationState(sessionId: "room", title: "Room", messages: [message],
                                         thread: thread ? RoomChatThreadInput(sequenceId: 1, replies: replies) : nil,
                                         attachmentPreviews: ["a1": png(width: 132, height: 286)])
    }

    func test_a_message_with_an_image_read_aloud_with_no_thread_open() {
        let crumb = ReadAloudCrumb.make(id: RoomReadAloud.message(1), state: Self.state(thread: false),
                                        textSize: .large, readerChanges: 0)
        XCTAssertEqual(crumb.step, "readAloud (1 rows, message, no thread open, text size L, 1 image 132×286, "
            + "reader changed 0 times in 10 s)")
    }

    func test_a_reply_read_aloud_in_an_open_thread_at_the_largest_text_size() {
        let crumb = ReadAloudCrumb.make(id: RoomReadAloud.reply("r2"), state: Self.state(thread: true),
                                        textSize: .accessibilityExtraExtraExtraLarge, readerChanges: 3)
        XCTAssertEqual(crumb.step, "readAloud (1 rows, reply, thread open with 2 replies 1 deep, "
            + "text size AccessibilityXXXL, reader changed 3 times in 10 s)")
    }

    func test_the_crumb_never_says_what_is_read_nor_who_wrote_it() {
        for thread in [false, true] {
            for id in [RoomReadAloud.message(1), RoomReadAloud.reply("r2")] {
                let step = ReadAloudCrumb.make(id: id, state: Self.state(thread: thread), textSize: .large,
                                               readerChanges: 1).step
                XCTAssertFalse(step.contains("Words"), step)
                XCTAssertFalse(step.contains("Alex"), step)
                XCTAssertFalse(step.contains("list.png"), step)
            }
        }
    }

    func test_the_reader_log_counts_only_the_last_ten_seconds() {
        let log = ReaderChangeLog()
        let now = Date()
        log.record(now.addingTimeInterval(-30))
        log.record(now.addingTimeInterval(-9))
        log.record(now.addingTimeInterval(-1))
        XCTAssertEqual(log.count(within: 10, of: now), 2)
    }
}
