import Foundation
import XCTest
@testable import PocketUI

final class RoomAttachmentPresentationTests: XCTestCase {
    func test_labels_say_what_the_file_is_and_only_mention_problems() {
        let ready = RoomAttachmentChip(attachmentId: "a", filename: "screen.png", kind: .image, sizeBytes: 482_000, processingStatus: "ready")
        XCTAssertEqual(ready.kindLabel, "Image")
        XCTAssertNotNil(ready.sizeLabel)
        XCTAssertNil(ready.statusLabel, "a ready file says nothing about processing")
        XCTAssertEqual(RoomAttachmentChip(attachmentId: "b", filename: "s.pdf", kind: .pdf, processingStatus: "retry").statusLabel,
                       "Processing…")
        XCTAssertEqual(RoomAttachmentChip(attachmentId: "c", filename: "x.md", kind: .markdown, processingStatus: "dead_letter").statusLabel,
                       "Couldn't process")
        XCTAssertNil(RoomAttachmentChip(attachmentId: "d", filename: "x", kind: .other, processingStatus: "failed").statusLabel,
                     "the API never sends failed; an unknown state says nothing")
        XCTAssertNil(RoomAttachmentChip(attachmentId: "e", filename: "x", kind: .other).sizeLabel)
    }
}
