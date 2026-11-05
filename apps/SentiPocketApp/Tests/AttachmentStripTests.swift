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

    private func room(photos: Int) -> RoomChatPresentationState {
        let chips = (1...photos).map {
            RoomAttachmentChip(attachmentId: "att-\($0)", filename: "photo-\($0).jpg", kind: .image)
        }
        let message = RoomChatMessageInput(id: "evt-1", sequenceId: 1, kind: .message, authorId: "review-agent",
                                           authorName: "review-agent", isHuman: false, text: "Photos from the site.",
                                           timestamp: "2026-11-05T12:00:00.000000+00:00", attachments: chips)
        var previews: [String: Data] = [:]
        for chip in chips { previews[chip.attachmentId] = Self.png }
        return RoomChatPresentationState(sessionId: "room-strip", title: "Site", messages: [message], connection: .live,
                                         attachmentPreviews: previews)
    }

    private func host(photos: Int) throws -> UIWindow {
        let state = room(photos: photos)
        return try HostedSummary.host(NavigationStack { RoomChatView(state: state) { _ in } })
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

    /// Twelve do not fit: the strip scrolls sideways, and its last photo is reached by scrolling.
    func test_twelve_photos_scroll_sideways() throws {
        let window = try host(photos: 12)
        defer { HostedSummary.close(window) }
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.room.attachment.strip.photo", in: window), "the photos show in a strip")
        HostedSummary.pump(0.5)
        let shown = stripPhotos(in: window)
        XCTAssertGreaterThanOrEqual(shown.count, 2)
        assertSideBySide(shown)
        XCTAssertEqual(shown.first?.accessibilityLabel, "photo-1.jpg, 1 of 12")

        let sideways = HostedSummary.elements(in: window).compactMap { $0 as? UIScrollView }
            .first { $0.contentSize.width > $0.bounds.width + 1 && $0.contentSize.height <= $0.bounds.height + 1 }
        let strip = try XCTUnwrap(sideways, "the strip scrolls sideways")
        strip.setContentOffset(CGPoint(x: strip.contentSize.width - strip.bounds.width, y: 0), animated: false)
        HostedSummary.pump(0.8)
        XCTAssertTrue(stripPhotos(in: window).contains { $0.accessibilityLabel == "photo-12.jpg, 12 of 12" },
                      "the twelfth photo is reached by scrolling")
    }
}
