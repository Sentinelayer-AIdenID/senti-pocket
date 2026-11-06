#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import PocketUI

/// A message's menu shows a preview of its own, never the row lifted out of the room's list (at the largest text size
/// that lift set the room laying itself out without end). The preview stays small whatever the message holds: 8 lines of
/// its text, one line for what it carries, and no second build of the row.
final class RoomMessageMenuPreviewTests: XCTestCase {
    private func row(text: String, attachments: [RoomAttachmentChip] = [], files: [RoomChatFileCard] = [])
        -> RoomChatMessageRow {
        let input = RoomChatMessageInput(id: "m1", sequenceId: 1, kind: .message, authorId: "review-agent",
                                         authorName: "review-agent", isHuman: false, text: text, timestamp: "",
                                         date: Date(timeIntervalSince1970: 1_800_000_000), attachments: attachments)
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: [input],
                                              files: files.isEmpty ? [:] : [1: files])
        let messages = state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
        return messages[0]
    }

    private func height(_ row: RoomChatMessageRow) -> CGFloat {
        NSHostingView(rootView: RoomMessageMenuPreview(row: row, ownHandles: [])).fittingSize.height
    }

    private func card(_ index: Int) -> RoomChatFileCard {
        RoomChatFileCard(thread: 1, name: "pack-\(index).zip", author: "review-agent", sha256: nil, verified: nil,
                         status: "parts missing", partsTotal: 3, partPosts: 3, previewable: false)
    }

    func test_a_large_message_makes_a_preview_no_taller_than_eight_lines_and_one_line_of_what_it_carries() {
        let eightLines = height(row(text: (1...8).map { "Line \($0)" }.joined(separator: "\n"),
                                    attachments: [RoomAttachmentChip(attachmentId: "a0", filename: "a.png", kind: .image)]))
        let images = (1...12).map { RoomAttachmentChip(attachmentId: "a\($0)", filename: "photo-\($0).png", kind: .image) }
        let drawsBefore = RenderTrace.snapshot().draws
        let huge = height(row(text: (1...2_000).map { "Line \($0) of a very long review packet." }.joined(separator: "\n"),
                              attachments: images, files: (1...6).map(card)))
        print("MENUPREVIEW eight lines and a photo: \(eightLines) pt; 2,000 lines, 12 photos, 6 files: \(huge) pt")
        XCTAssertGreaterThan(huge, 60, "the preview was laid out")
        XCTAssertEqual(huge, eightLines, accuracy: 1, "2,000 lines, 12 photos and 6 file cards show as 8 lines and one line")
        XCTAssertEqual(RenderTrace.snapshot().draws, drawsBefore, "no message row is built for the preview")
    }

    func test_what_a_message_carries_is_one_line() {
        XCTAssertNil(RoomMessageMenuPreview.carried(row(text: "Only words.")))
        let photo = RoomAttachmentChip(attachmentId: "a1", filename: "a.png", kind: .image)
        let video = RoomAttachmentChip(attachmentId: "a2", filename: "b.mov", kind: .video)
        let gone = RoomAttachmentChip(attachmentId: "a3", filename: "c.png", kind: .image, isRemoved: true)
        XCTAssertEqual(RoomMessageMenuPreview.carried(row(text: "A photo.", attachments: [photo]))?.label, "Photo")
        XCTAssertEqual(RoomMessageMenuPreview.carried(row(text: "Two.", attachments: [video, photo]))?.label, "Video and 1 more")
        XCTAssertNil(RoomMessageMenuPreview.carried(row(text: "Gone.", attachments: [gone])), "a removed attachment is not shown")
        XCTAssertEqual(RoomMessageMenuPreview.carried(row(text: "x", files: [card(1), card(2)]))?.label,
                       "pack-1.zip and 1 more")
    }
}
#endif
