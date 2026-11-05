import XCTest
@testable import PocketUI

/// Ticket 3b458212: two or more photos under a message show as one strip of thumbnails, side by side; one photo,
/// videos, removed files and other files one by one, as before.
final class RoomAttachmentStripTests: XCTestCase {
    private func photo(_ name: String, removed: Bool = false) -> RoomAttachmentChip {
        RoomAttachmentChip(attachmentId: "att-\(name)", filename: name, kind: .image, isRemoved: removed)
    }

    private func file(_ name: String, kind: RoomAttachmentChip.Kind = .pdf) -> RoomAttachmentChip {
        RoomAttachmentChip(attachmentId: "att-\(name)", filename: name, kind: kind)
    }

    func test_one_photo_stays_alone_and_two_or_more_go_in_one_strip() {
        let one = [photo("a.jpg")]
        XCTAssertEqual(RoomAttachmentLayoutItem.items(one), [.single(one[0])])
        let three = [photo("a.jpg"), photo("b.jpg"), photo("c.jpg")]
        XCTAssertEqual(RoomAttachmentLayoutItem.items(three), [.strip(three)])
        let twelve = (1...12).map { photo("p\($0).jpg") }
        XCTAssertEqual(RoomAttachmentLayoutItem.items(twelve), [.strip(twelve)])
    }

    func test_the_strip_sits_where_the_first_photo_was_and_other_files_keep_their_place() {
        let notes = file("notes.pdf")
        let clip = file("clip.mov", kind: .video)
        let gone = photo("gone.jpg", removed: true)
        let a = photo("a.jpg"), b = photo("b.jpg")
        let chips = [notes, a, clip, gone, b]
        XCTAssertEqual(RoomAttachmentLayoutItem.items(chips),
                       [.single(notes), .strip([a, b]), .single(clip), .single(gone)],
                       "videos, removed photos and other files are not in the strip")
        XCTAssertEqual(RoomAttachmentLayoutItem.items([a, gone]), [.single(a), .single(gone)],
                       "one photo left is not a strip")
    }

    func test_each_photo_in_a_strip_says_its_name_and_its_place() {
        let chips = [photo("beach.jpg"), photo("dock.jpg"), photo("sunset.jpg")]
        XCTAssertEqual(RoomAttachmentLayoutItem.stripLabel(chips[1], index: 1, count: 3), "dock.jpg, 2 of 3")
        let failed = RoomAttachmentChip(attachmentId: "att-x", filename: "x.jpg", kind: .image,
                                        processingStatus: "dead_letter")
        XCTAssertTrue(RoomAttachmentLayoutItem.stripLabel(failed, index: 0, count: 2).hasPrefix("x.jpg, 1 of 2"))
    }
}
