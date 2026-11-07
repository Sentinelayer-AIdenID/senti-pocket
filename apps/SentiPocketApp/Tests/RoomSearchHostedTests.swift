import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

@MainActor
private final class SearchHostedState: ObservableObject {
    @Published var focus: RoomSearchFocus?
    @Published var needsJump = false
    var target = String(repeating: "Earlier words before the match. ", count: 100)
        + "**Néedle** at the far end. [Open notes](https://example.invalid/notes) @reader\n\n"
        + "[Ticket: Planning](/dashboard/sessions/search-chat?ticket=planning)\n\n"
        + "```\nlet answer = 42\n```\n\n| Name | Value |\n| --- | --- |\n| Planning | Ready |"
    let other = String(repeating: "Another message stays folded.\n", count: 80) + "Other hidden ending."

    var presentation: RoomChatPresentationState {
        let messages = [target, other].enumerated().map { index, text in
            RoomChatMessageInput(id: "message-\(index + 1)", sequenceId: Int64(index + 1), kind: .message,
                                 authorId: "human-reader", authorName: "Reader", isHuman: true,
                                 text: text, timestamp: "2026-11-01T12:00:00Z")
        }
        return RoomChatPresentationState(sessionId: "search-chat", title: "Chat", messages: messages,
                                         connection: .live, focusSequenceId: needsJump ? focus?.sequenceId : nil,
                                         searchFocus: focus)
    }
}

@MainActor
private struct SearchHostedChat: View {
    @ObservedObject var model: SearchHostedState
    var onOpenURL: (URL) -> Void = { _ in }
    var body: some View {
        NavigationStack {
            RoomChatView(state: model.presentation) { intent in
                if intent == .focusHandled { model.needsJump = false }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            onOpenURL(url)
            return .handled
        })
    }
}

@MainActor
final class RoomSearchHostedTests: XCTestCase {
    func test_far_code_and_table_matches_are_revealed_inside_their_horizontal_scroll_views() throws {
        let header = "| " + (1...8).map { "Column \($0)" }.joined(separator: " | ") + " |\n"
        let divider = "| " + Array(repeating: "---", count: 8).joined(separator: " | ") + " |\n"
        let cells = Array(repeating: String(repeating: "earlier ", count: 30), count: 7) + ["needle"]
        let table = header + divider + "| " + cells.joined(separator: " | ") + " |"
        for text in ["```\n" + String(repeating: "earlier ", count: 300) + "needle\n```", table] {
            let model = SearchHostedState()
            model.target = text
            let window = try HostedSummary.host(SearchHostedChat(model: model), height: 844)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            defer { HostedSummary.close(window) }
            XCTAssertNotNil(HostedSummary.wait(for: "pocket.room.longMessage", in: window))
            model.focus = RoomSearchFocus(sequenceId: 1, query: "needle")
            model.needsJump = true
            let match = try XCTUnwrap(HostedSummary.wait(for: "pocket.search.match.1", in: window))
            let end = Date().addingTimeInterval(5)
            var revealed = false
            while Date() < end {
                HostedSummary.pump(0.1)
                let horizontal = HostedSummary.elements(in: window).compactMap { $0 as? UIScrollView }
                    .first { $0.bounds.width > 0 && $0.contentSize.width > $0.bounds.width + 1
                        && $0.contentSize.height <= $0.bounds.height + 1 }
                if let horizontal {
                    let viewport = horizontal.convert(horizontal.bounds, to: nil)
                    let frame = match.accessibilityFrame
                    revealed = horizontal.contentOffset.x > 0 && frame.width > 0
                        && frame.minX >= viewport.minX && frame.maxX <= viewport.maxX
                    if revealed { break }
                }
            }
            XCTAssertTrue(revealed, "the match is visible inside the actual code/table scroller, not only in the room's row")
        }
    }

    func test_real_chat_unfolds_only_target_and_scrolls_far_match_into_phone_viewport() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let model = SearchHostedState()
            XCTAssertGreaterThan(model.target.count, 1_000)
            var opened: URL?
            let window = try HostedSummary.host(SearchHostedChat(model: model, onOpenURL: { opened = $0 }), height: 844)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.overrideUserInterfaceStyle = style
            window.layoutIfNeeded()
            defer { HostedSummary.close(window) }
            XCTAssertNotNil(HostedSummary.wait(for: "pocket.room.longMessage", in: window))
            model.focus = RoomSearchFocus(sequenceId: 1, query: "needle")
            model.needsJump = true
            _ = try XCTUnwrap(HostedSummary.wait(for: "pocket.search.expanded.1", in: window),
                             "the real message row must mount the selected Markdown renderer")
            let match = try XCTUnwrap(HostedSummary.wait(for: "pocket.search.match.1", in: window),
                                     "the selected renderer must preserve its match child identifier; found: \(HostedSummary.identifiers(in: window))")
            let end = Date().addingTimeInterval(5)
            var visible = false
            while Date() < end {
                HostedSummary.pump(0.1)
                let scroll = HostedSummary.elements(in: window).compactMap { $0 as? UIScrollView }
                    .filter { $0.contentSize.height > $0.bounds.height + 1 }
                    .max { $0.bounds.height < $1.bounds.height }
                if let scroll {
                    let viewport = scroll.convert(scroll.bounds, to: nil)
                    let frame = match.accessibilityFrame
                    // The prefix anchor is within one line of the real match. Leave room on both sides so the
                    // actual matched word, not only its anchor or the message's top, is inside the viewport.
                    visible = frame.height > 0 && frame.minY >= viewport.minY + 44 && frame.maxY <= viewport.maxY - 44
                    if visible { break }
                }
            }
            XCTAssertTrue(visible, "the match after the cutoff must be in view, not only its message row")
            XCTAssertTrue(match.accessibilityLabel?.contains("Néedle") == true)
            let ticket = try XCTUnwrap(HostedSummary.wait(for: "pocket.ticketLink.planning", in: window),
                                      "the selected message keeps its rendered ticket link")
            XCTAssertTrue(ticket.accessibilityActivate(), "the existing rendered link still opens")
            XCTAssertEqual(opened?.query, "ticket=planning")
            XCTAssertFalse(HostedSummary.elements(in: window).contains {
                $0.accessibilityLabel?.contains("**Néedle**") == true
            }, "opening search must not replace Markdown with raw punctuation")
            XCTAssertNil(HostedSummary.element("pocket.search.expanded.2", in: window))
            XCTAssertNotNil(HostedSummary.wait(for: "pocket.room.longMessage", in: window,
                                               label: "Long message, \(model.other.count) characters"),
                            "the other long message keeps its original folded card")
            XCTAssertFalse(HostedSummary.elements(in: window).contains { $0.accessibilityLabel?.contains("Other hidden ending.") == true })
        }
    }
}
