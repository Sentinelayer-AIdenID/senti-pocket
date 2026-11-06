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

    /// On a phone's row (about 350 pt after the room's inset), three photos fill it at 111 pt each and nothing scrolls;
    /// two stay at 120 pt; four and twelve do not fit at 96 pt, so they stay at 120 pt and scroll, and the third photo
    /// shows 94 pt of itself. On a wider phone's row (390 pt), 120 pt would show the fourth photo only 6 pt in, so the
    /// strip takes 112 pt and shows 30.
    func test_a_strip_fills_its_row_when_every_photo_fits_at_96_pt_and_otherwise_scrolls_showing_the_next() {
        let three = RoomStripMetrics(count: 3, width: 350)
        XCTAssertEqual(three, RoomStripMetrics(count: 3, width: 350))
        XCTAssertEqual(three.mode, .fit)
        XCTAssertEqual(three.side, 111)
        XCTAssertEqual(three.height, 111, "a strip that fits has no scroll indicator under it")
        XCTAssertEqual(RoomStripMetrics(count: 2, width: 350).side, 120, "never larger than 120 pt")
        XCTAssertEqual(RoomStripMetrics(count: 2, width: 350).mode, .fit)
        for count in [4, 12] {
            let strip = RoomStripMetrics(count: count, width: 350)
            XCTAssertEqual(strip.mode, .scroll, "\(count) photos do not fit a phone's row at 96 pt")
            XCTAssertEqual(strip.side, 120)
            XCTAssertEqual(strip.height, 128, "and the scroll's indicator has its room")
            XCTAssertEqual(RoomStripMetrics.nextPhotoShows(side: strip.side, width: 350), 94)
        }
        let wide = RoomStripMetrics(count: 12, width: 390)
        XCTAssertEqual(wide.mode, .scroll)
        XCTAssertEqual(wide.side, 112)
        XCTAssertEqual(RoomStripMetrics.nextPhotoShows(side: 120, width: 390), 6)
        XCTAssertEqual(RoomStripMetrics.nextPhotoShows(side: wide.side, width: 390), 30)
    }

    /// For every row from 200 to 800 pt wide and every strip of 2 to 12 photos: a strip that fits sits within its row
    /// with photos of 96 to 120 pt; one that scrolls really does not fit, has photos of 96 to 120 pt, and shows at least
    /// 30 pt of the next photo.
    func test_the_strip_rule_holds_for_every_row_width_and_number_of_photos() {
        for count in 2...12 {
            for width in stride(from: CGFloat(200), through: 800, by: 1) {
                let strip = RoomStripMetrics(count: count, width: width)
                let gaps = RoomStripMetrics.spacing * CGFloat(count - 1)
                XCTAssertTrue((96...120).contains(strip.side), "\(count) photos, \(width) pt: side \(strip.side)")
                switch strip.mode {
                case .fit:
                    XCTAssertLessThanOrEqual(CGFloat(count) * strip.side + gaps, width, "\(count) photos, \(width) pt")
                case .scroll:
                    XCTAssertGreaterThan(CGFloat(count) * strip.side + gaps, width, "\(count) photos, \(width) pt")
                    XCTAssertGreaterThanOrEqual(RoomStripMetrics.nextPhotoShows(side: strip.side, width: width), 30,
                                                "\(count) photos, \(width) pt: the next photo shows")
                }
            }
        }
    }
}
