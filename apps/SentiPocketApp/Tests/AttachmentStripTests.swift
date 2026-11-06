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
