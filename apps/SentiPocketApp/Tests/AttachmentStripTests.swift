import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// Ticket 3b458212, hosted: a message with 1, 2, 3 and 12 photos in the room as it is drawn, read the way VoiceOver
/// reads it. One photo stays as it was; two or more sit side by side as smaller thumbnails, each saying its name and its
/// place, and a strip that does not fit scrolls sideways.
@MainActor
final class AttachmentStripTests: XCTestCase {
    private static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).pngData { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    }

    /// A wide photo, four times as wide as tall: scaled to fill a square, it spills furthest past it.
    private static let panorama: Data = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 100)).pngData { context in
        UIColor.systemOrange.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
    }

    private func room(photos: Int, preview: Data) -> RoomChatPresentationState {
        let chips = (1...photos).map {
            RoomAttachmentChip(attachmentId: "att-\($0)", filename: "photo-\($0).jpg", kind: .image)
        }
        let message = RoomChatMessageInput(id: "evt-1", sequenceId: 1, kind: .message, authorId: "review-agent",
                                           authorName: "review-agent", isHuman: false, text: "Photos from the site.",
                                           timestamp: "2026-11-05T12:00:00.000000+00:00", attachments: chips)
        var previews: [String: Data] = [:]
        for chip in chips { previews[chip.attachmentId] = preview }
        return RoomChatPresentationState(sessionId: "room-strip", title: "Site", messages: [message], connection: .live,
                                         attachmentPreviews: previews)
    }

    /// The room with one message of `photos` photos, each with `preview` (a small teal one when none is given); what
    /// the room sends goes to `send`.
    private func host(photos: Int, preview: Data? = nil,
                      send: @escaping (RoomChatIntent) -> Void = { _ in }) throws -> UIWindow {
        let state = room(photos: photos, preview: preview ?? Self.png)
        return try HostedSummary.host(NavigationStack { RoomChatView(state: state, send: send) })
    }

    /// The pixel at a point of `image` (top-left origin, in points), as 0-255 red, green and blue.
    private func pixel(_ image: UIImage, at point: CGPoint) -> (r: Int, g: Int, b: Int)? {
        guard let cg = image.cgImage else { return nil }
        let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
        guard x >= 0, y >= 0, x < cg.width, y < cg.height else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
            return true
        }
        return drawn ? (Int(bytes[0]), Int(bytes[1]), Int(bytes[2])) : nil
    }

    /// The panorama's orange, as the simulator draws it.
    private static func isOrange(_ p: (r: Int, g: Int, b: Int)) -> Bool {
        p.r > 200 && (110...190).contains(p.g) && p.b < 80
    }

    /// The room with one message of `photos` photos in a 390-pt-wide window (an iPhone's), each a teal preview.
    private func hostPhone(photos: Int, send: @escaping (RoomChatIntent) -> Void = { _ in }) throws -> UIWindow {
        let window = try host(photos: photos, send: send)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        HostedSummary.pump(0.3)
        return window
    }

    /// The strip's sideways scroll, if it has one: a scroll view wider inside than out, and no taller.
    private func sidewaysScroll(in window: UIWindow) -> UIScrollView? {
        HostedSummary.elements(in: window).compactMap { $0 as? UIScrollView }
            .first { $0.contentSize.width > $0.bounds.width + 1 && $0.contentSize.height <= $0.bounds.height + 1 }
    }

    /// The strip's photos the screen has, left to right.
    private func stripPhotos(in window: UIWindow) -> [NSObject] {
        HostedSummary.elements(in: window)
            .filter { $0.isAccessibilityElement && HostedSummary.identifier(of: $0) == "pocket.room.attachment.strip.photo" }
            .sorted { $0.accessibilityFrame.minX < $1.accessibilityFrame.minX }
    }

    private func assertSideBySide(_ photos: [NSObject], file: StaticString = #filePath, line: UInt = #line) {
        guard let first = photos.first else { return XCTFail("no photo in a strip", file: file, line: line) }
        for (left, right) in zip(photos, photos.dropFirst()) {
            XCTAssertEqual(right.accessibilityFrame.minY, first.accessibilityFrame.minY, accuracy: 1,
                           "the photos sit side by side, on one line", file: file, line: line)
            XCTAssertGreaterThan(right.accessibilityFrame.minX, left.accessibilityFrame.maxX - 1,
                                 "each photo sits to the right of the one before", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(first.accessibilityFrame.height, 130, "a thumbnail, about 120 pt", file: file, line: line)
    }

    func test_one_photo_shows_alone_as_before() throws {
        let window = try host(photos: 1)
        defer { HostedSummary.close(window) }
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.room.attachment", in: window), "the photo shows")
        XCTAssertEqual(stripPhotos(in: window).count, 0, "one photo is not a strip")
    }

    func test_two_and_three_photos_sit_side_by_side_and_say_their_place() throws {
        for count in [2, 3] {
            let window = try host(photos: count)
            XCTAssertNotNil(HostedSummary.wait(for: "pocket.room.attachment.strip.photo", in: window),
                            "\(count) photos show in a strip")
            HostedSummary.pump(0.5)
            let photos = stripPhotos(in: window)
            XCTAssertEqual(photos.count, count, "every photo is there")
            assertSideBySide(photos)
            XCTAssertEqual(photos.map(\.accessibilityLabel), (1...count).map { "photo-\($0).jpg, \($0) of \(count)" })
            HostedSummary.close(window)
        }
    }

    /// Each thumbnail's tap and VoiceOver area is its own square: wide photos do not reach into their neighbours' (they
    /// did, scaled to fill: a tap near a photo's right edge could open the next one).
    func test_neighbouring_thumbnails_tap_areas_do_not_overlap_even_for_wide_photos() throws {
        let window = try host(photos: 3, preview: Self.panorama)
        defer { HostedSummary.close(window) }
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.room.attachment.strip.photo", in: window), "the photos show in a strip")
        HostedSummary.pump(0.5)
        let photos = stripPhotos(in: window)
        XCTAssertEqual(photos.count, 3)
        for photo in photos {
            XCTAssertEqual(photo.accessibilityFrame.width, photo.accessibilityFrame.height, accuracy: 1,
                           "a thumbnail's area is its square, nothing spilling past it")
        }
        for (left, right) in zip(photos, photos.dropFirst()) {
            XCTAssertFalse(left.accessibilityFrame.intersects(right.accessibilityFrame),
                           "neighbouring thumbnails' tap areas do not overlap")
        }
    }

    /// Carter's three photos on an iPhone: they all fit, so they fill the row, each wholly in sight, the same size, and
    /// nothing scrolls (they were 120 pt, and the third was cut off at the screen's edge).
    func test_three_photos_on_a_phone_fit_the_row_all_in_sight_the_same_size_and_nothing_scrolls() throws {
        let window = try hostPhone(photos: 3)
        defer { HostedSummary.close(window) }
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.room.attachment.strip.photo", in: window), "the photos show in a strip")
        HostedSummary.pump(0.5)
        let photos = stripPhotos(in: window).map { window.convert($0.accessibilityFrame, from: nil) }
        XCTAssertEqual(photos.count, 3)
        print("STRIP three on a phone: photos \(photos.map { "\(Int($0.minX))-\(Int($0.maxX))x\(Int($0.height))" })")
        for photo in photos {
            XCTAssertTrue(window.bounds.contains(photo), "each photo is wholly on the screen: \(photo)")
            XCTAssertEqual(photo.width, photos[0].width, accuracy: 0.5, "the photos are the same size")
            XCTAssertEqual(photo.width, photo.height, accuracy: 0.5, "and square")
        }
        XCTAssertGreaterThanOrEqual(photos[0].width, 96)
        XCTAssertLessThanOrEqual(photos[0].width, 120)
        XCTAssertNil(sidewaysScroll(in: window), "nothing scrolls sideways, so nothing is cut off")
    }

    /// Four or twelve photos on an iPhone do not fit at 96 pt: they stay at 120 pt and scroll, and the first photo not
    /// wholly in sight shows at least 30 pt of itself, so it is plain there is more.
    func test_four_or_twelve_photos_on_a_phone_scroll_at_120_pt_showing_30_pt_or_more_of_the_next() throws {
        for count in [4, 12] {
            let window = try hostPhone(photos: count)
            XCTAssertNotNil(HostedSummary.wait(for: "pocket.room.attachment.strip.photo", in: window),
                            "\(count) photos show in a strip")
            HostedSummary.pump(0.5)
            let photos = stripPhotos(in: window).map { window.convert($0.accessibilityFrame, from: nil) }
            let scroll = try XCTUnwrap(sidewaysScroll(in: window), "\(count) photos scroll sideways")
            let strip = scroll.convert(scroll.bounds, to: window)
            print("STRIP \(count) on a phone: in sight \(strip), photos \(photos.map { "\(Int($0.minX))-\(Int($0.maxX))" })")
            XCTAssertEqual(photos.first?.width ?? 0, 120, accuracy: 0.5, "\(count) photos stay 120 pt")
            let next = try XCTUnwrap(photos.first { $0.maxX > strip.maxX + 0.5 }, "a photo runs past the strip's edge")
            XCTAssertGreaterThanOrEqual(strip.maxX - next.minX, 30,
                                        "\(count) photos: the next one shows at least 30 pt: \(next) in \(strip)")
            HostedSummary.close(window)
        }
    }

    /// The text size leaves the photos alone: three photos on an iPhone are the same size at the largest text size as
    /// at the default one, and still fit (the strip used to grow its photos with the text, up to 200 pt).
    func test_the_largest_text_size_leaves_the_photos_the_same_size() throws {
        var widths: [CGFloat] = []
        for ax5 in [false, true] {
            let window = try hostPhone(photos: 3)
            if #available(iOS 17.0, *), ax5 {
                window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            }
            XCTAssertNotNil(HostedSummary.wait(for: "pocket.room.attachment.strip.photo", in: window), "the photos show")
            HostedSummary.pump(0.5)
            let photos = stripPhotos(in: window).map { window.convert($0.accessibilityFrame, from: nil) }
            XCTAssertEqual(photos.count, 3)
            XCTAssertTrue(photos.allSatisfy { window.bounds.contains($0) }, "all three in sight (AX5: \(ax5))")
            widths.append(photos.first?.width ?? 0)
            HostedSummary.close(window)
        }
        print("STRIP three on a phone, default and AX5: \(widths)")
        XCTAssertEqual(widths[0], widths[1], accuracy: 0.5, "the same size at the default and the largest text size")
    }

    /// What is drawn stays inside each square too: between two wide photos the room's background shows, never the photo
    /// (the clip shape; without it, a wide photo filling its square was drawn over the gap and onto its neighbours).
    func test_wide_photos_are_drawn_only_inside_their_squares() throws {
        let window = try host(photos: 3, preview: Self.panorama)
        defer { HostedSummary.close(window) }
        window.overrideUserInterfaceStyle = .light
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.room.attachment.strip.photo", in: window), "the photos show in a strip")
        HostedSummary.pump(0.5)
        let squares = stripPhotos(in: window).map { window.convert($0.accessibilityFrame, from: nil) }
        XCTAssertEqual(squares.count, 3)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        for square in squares {
            let middle = CGPoint(x: square.midX, y: square.midY)
            guard window.bounds.contains(middle), let colour = pixel(image, at: middle) else { continue }
            XCTAssertTrue(Self.isOrange(colour), "the photo is drawn in its square: \(colour) at x=\(Int(middle.x))")
        }
        var gaps = 0
        for (left, right) in zip(squares, squares.dropFirst()) {
            let gap = CGPoint(x: (left.maxX + right.minX) / 2, y: left.midY)
            guard window.bounds.insetBy(dx: 1, dy: 1).contains(gap), let colour = pixel(image, at: gap) else { continue }
            gaps += 1
            XCTAssertFalse(Self.isOrange(colour),
                           "between two photos the background shows, no photo drawn past its square: \(colour) at x=\(Int(gap.x))")
        }
        XCTAssertGreaterThan(gaps, 0, "a gap between two photos was on screen to look at")
    }

    /// Twelve do not fit: the strip scrolls sideways, and its last photo is reached by scrolling. It goes straight to the
    /// scroll and is lazy: until it is scrolled, the twelfth photo is not built (not even to measure it), not on
    /// screen, and its preview is not asked for.
    func test_twelve_photos_scroll_sideways_building_only_the_photos_in_sight() throws {
        var appeared: [String] = []
        RenderTrace.resetStripPhotos()
        let window = try host(photos: 12) { intent in
            if case .attachmentAppeared(let id) = intent { appeared.append(id) }
        }
        defer { HostedSummary.close(window) }
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.room.attachment.strip.photo", in: window), "the photos show in a strip")
        HostedSummary.pump(0.5)
        let shown = stripPhotos(in: window)
        XCTAssertGreaterThanOrEqual(shown.count, 2)
        assertSideBySide(shown)
        XCTAssertEqual(shown.first?.accessibilityLabel, "photo-1.jpg, 1 of 12")
        let furthest = RenderTrace.furthestStripPhoto()
        print("STRIP before scrolling: built up to photo \(furthest + 1) of 12, \(shown.count) on screen, "
              + "\(Set(appeared).count) previews asked for")
        XCTAssertGreaterThanOrEqual(furthest, 1, "the photos in sight are built")
        XCTAssertLessThan(furthest, 11, "the strip builds the photos in sight, not all twelve to show or measure them")
        XCTAssertFalse(shown.contains { $0.accessibilityLabel == "photo-12.jpg, 12 of 12" },
                       "before scrolling, the twelfth photo is not on screen")
        XCTAssertFalse(appeared.contains("att-12"), "before scrolling, the twelfth photo's preview is not asked for")

        let sideways = HostedSummary.elements(in: window).compactMap { $0 as? UIScrollView }
            .first { $0.contentSize.width > $0.bounds.width + 1 && $0.contentSize.height <= $0.bounds.height + 1 }
        let strip = try XCTUnwrap(sideways, "the strip scrolls sideways")
        strip.setContentOffset(CGPoint(x: strip.contentSize.width - strip.bounds.width, y: 0), animated: false)
        HostedSummary.pump(0.8)
        XCTAssertTrue(stripPhotos(in: window).contains { $0.accessibilityLabel == "photo-12.jpg, 12 of 12" },
                      "the twelfth photo is reached by scrolling")
        XCTAssertEqual(RenderTrace.furthestStripPhoto(), 11, "scrolled to its end, the twelfth photo is built")
        XCTAssertTrue(appeared.contains("att-12"), "and its preview is asked for")
    }
}
