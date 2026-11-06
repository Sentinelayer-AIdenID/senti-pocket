import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// Ticket 52065281: at the largest text sizes a room row's action icons drew over each other (each sat in a fixed
/// 28-pt button while the icon grew with the text) and the author's name was cut to "revie…" beside the time. Hosted,
/// in an iPhone-wide room, at the default text size and at the largest: no two action buttons overlap, each lies in the
/// window and is at least as large as its icon's font, and the name is shown whole.
@MainActor
final class ActionRowTextSizeTests: XCTestCase {
    /// What VoiceOver calls the row's action buttons (`RoomRowOption` titles) and its More menu.
    private static let actionLabels: Set<String> = ["Copy text", "Listen", "Like", "Dislike", "Add reaction", "Reply",
                                                    "Open thread", "Acknowledge", "More actions"]

    private static let photo: Data = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).pngData { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    }

    /// One agent message, plain or with one photo, in a room where reactions are on (so its row has every button).
    private func room(photo: Bool) -> RoomChatPresentationState {
        let chips = photo ? [RoomAttachmentChip(attachmentId: "att-1", filename: "site-1.jpg", kind: .image)] : []
        let message = RoomChatMessageInput(id: "evt-1", sequenceId: 1, kind: .message, authorId: "review-agent",
                                           authorName: "review-agent", isHuman: false,
                                           text: photo ? "A photo from the site." : "The site is ready for review.",
                                           timestamp: "2026-11-05T12:00:00.000000+00:00",
                                           date: Date(timeIntervalSince1970: 1_793_000_000), attachments: chips)
        return RoomChatPresentationState(sessionId: "room-actions", title: "Site", messages: [message],
                                         connection: .live, canReact: true,
                                         attachmentPreviews: photo ? ["att-1": Self.photo] : [:])
    }

    /// The room in a 390-pt-wide window (an iPhone's), at the default text size or the largest.
    private func host(photo: Bool, largest: Bool) throws -> UIWindow {
        let state = room(photo: photo)
        let window = try HostedSummary.host(NavigationStack { RoomChatView(state: state) { _ in } })
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        if #available(iOS 17.0, *), largest {
            window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        }
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.room.message.1", in: window), "the message shows")
        HostedSummary.pump(0.8)
        return window
    }

    /// The row's action buttons and More menu on the screen, left to right.
    private func actionButtons(in window: UIWindow) -> [(label: String, frame: CGRect)] {
        HostedSummary.elements(in: window)
            .filter { $0.isAccessibilityElement && Self.actionLabels.contains($0.accessibilityLabel ?? "") }
            .map { (label: $0.accessibilityLabel ?? "", frame: window.convert($0.accessibilityFrame, from: nil)) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    private func font(_ style: UIFont.TextStyle, largest: Bool) -> UIFont {
        UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(
            preferredContentSizeCategory: largest ? .accessibilityExtraExtraExtraLarge : .large))
    }

    func test_action_buttons_never_overlap_and_are_as_large_as_their_icons_at_any_text_size() throws {
        for photo in [false, true] {
            for largest in [false, true] {
                let what = "\(photo ? "a photo" : "words"), \(largest ? "largest" : "default") text"
                let window = try host(photo: photo, largest: largest)
                let buttons = actionButtons(in: window)
                print("ACTIONROW \(what): " + buttons.map {
                    "\($0.label)=\(Int($0.frame.minX))-\(Int($0.frame.maxX))x\(Int($0.frame.height))"
                }.joined(separator: " "))
                XCTAssertTrue(buttons.contains { $0.label == "More actions" }, "\(what): the More menu is there")
                // An icon is drawn at its font's size: its button must be at least that large, or it spills over.
                let icon = font(.footnote, largest: largest).pointSize
                for button in buttons {
                    XCTAssertTrue(window.bounds.contains(button.frame),
                                  "\(what): \(button.label) lies in the window: \(button.frame)")
                    XCTAssertGreaterThanOrEqual(button.frame.height, icon - 0.5,
                                                "\(what): \(button.label) is at least as large as its icon (\(icon) pt)")
                    XCTAssertGreaterThanOrEqual(button.frame.width, icon - 0.5,
                                                "\(what): \(button.label) is at least as wide as its icon (\(icon) pt)")
                }
                for (index, left) in buttons.enumerated() {
                    for right in buttons.dropFirst(index + 1) {
                        XCTAssertFalse(left.frame.intersects(right.frame),
                                       "\(what): \(left.label) and \(right.label) do not overlap")
                    }
                }
                HostedSummary.close(window)
            }
        }
    }

    /// At the default text size the row is as it was: every button, 28 pt, 18 pt apart.
    func test_at_the_default_text_size_the_action_row_is_unchanged() throws {
        let window = try host(photo: false, largest: false)
        defer { HostedSummary.close(window) }
        let buttons = actionButtons(in: window)
        XCTAssertGreaterThanOrEqual(buttons.count, 4, "the buttons show, not only More: \(buttons.map(\.label))")
        XCTAssertEqual(buttons.first?.label, "Copy text")
        XCTAssertEqual(buttons.last?.label, "More actions")
        for button in buttons {
            XCTAssertEqual(button.frame.width, 28, accuracy: 0.5, "\(button.label) is 28 pt")
            XCTAssertEqual(button.frame.height, 28, accuracy: 0.5)
        }
        for (left, right) in zip(buttons, buttons.dropFirst()) {
            XCTAssertEqual(right.frame.minX - left.frame.maxX, 18, accuracy: 0.5, "18 pt between buttons")
        }
    }

    /// At the largest text size the row folds into its More menu, which VoiceOver reads as "More actions", a button.
    func test_at_the_largest_text_size_the_more_menu_reads_more_actions_to_voiceover() throws {
        let window = try host(photo: false, largest: true)
        defer { HostedSummary.close(window) }
        let more = try XCTUnwrap(HostedSummary.elements(in: window)
            .first { $0.isAccessibilityElement && $0.accessibilityLabel == "More actions" }, "the More menu is there")
        XCTAssertTrue(more.accessibilityTraits.contains(.button), "VoiceOver reads it as a button")
        XCTAssertEqual(actionButtons(in: window).map(\.label), ["More actions"],
                       "too wide for the row, the buttons fold into the More menu")
    }

    /// The author's name is shown whole: beside the time when both fit, on a line of its own when they do not (at the
    /// largest text size it was cut to "revie…").
    func test_the_authors_name_is_shown_whole_at_any_text_size() throws {
        for largest in [false, true] {
            let window = try host(photo: false, largest: largest)
            let name = try XCTUnwrap(HostedSummary.elements(in: window)
                .filter { $0.isAccessibilityElement && $0.accessibilityLabel == "review-agent" }
                .max { $0.accessibilityFrame.width < $1.accessibilityFrame.width }, "the name is there")
            let base = font(.subheadline, largest: largest)
            let needed = ("review-agent" as NSString).size(withAttributes: [
                .font: UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
            ]).width
            let shown = window.convert(name.accessibilityFrame, from: nil)
            print("ACTIONROW name, \(largest ? "largest" : "default") text: \(Int(shown.width)) pt shown, \(Int(needed)) needed")
            // A cut name ("revie…") is about half as wide; a little room for how SwiftUI sets the font.
            XCTAssertGreaterThanOrEqual(shown.width, needed * 0.95,
                                        "the name is not cut (\(largest ? "largest" : "default") text)")
            HostedSummary.close(window)
        }
    }
}
