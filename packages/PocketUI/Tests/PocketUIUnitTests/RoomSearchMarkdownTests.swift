#if canImport(SwiftUI)
import SwiftUI
import XCTest
@testable import PocketUI

final class RoomSearchMarkdownTests: XCTestCase {
    /// Mutant: replace the parsed attributed text with raw highlighted strings. Links, emphasis and mention
    /// attributes would disappear, and Markdown punctuation would become visible.
    func test_search_highlights_keep_rendered_link_code_emphasis_and_mention_attributes() throws {
        let rendered = ChatInlineMarkdown.attributed("**Strong** [notes](https://example.invalid/notes) `code` @reader",
                                                      ownHandles: ["reader"])
        let highlighted = RoomSearchMarkdown.highlight(rendered, query: "strong notes code reader")
        XCTAssertEqual(String(highlighted.value.characters), String(rendered.characters))
        XCTAssertFalse(String(highlighted.value.characters).contains("**"))
        XCTAssertEqual(Set(highlighted.value.runs.compactMap { $0.link?.absoluteString }),
                       ["https://example.invalid/notes"])
        XCTAssertTrue(highlighted.value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertTrue(highlighted.value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(highlighted.value.runs.contains { $0.swiftUI.foregroundColor != nil },
                      "the existing mention treatment survives the search highlight")
        XCTAssertTrue(highlighted.value.runs.contains { $0.swiftUI.backgroundColor != nil })
        XCTAssertEqual(highlighted.firstMatch, "Strong")
        XCTAssertEqual(String(try XCTUnwrap(highlighted.prefix).characters), "")
    }

    func test_a_far_match_uses_the_rendered_prefix_and_never_a_hidden_link_destination() throws {
        let before = String(repeating: "Earlier words stay in the same paragraph. ", count: 100)
        let rendered = ChatInlineMarkdown.attributed(before + "**Néedle** [Open notes](https://example.invalid/needle)")
        let highlighted = RoomSearchMarkdown.highlight(rendered, query: "needle")
        XCTAssertEqual(String(try XCTUnwrap(highlighted.prefix).characters), before)
        XCTAssertEqual(highlighted.firstMatch, "Néedle")
        XCTAssertGreaterThan(try XCTUnwrap(highlighted.prefix).characters.count, 1_000)
        XCTAssertFalse(RoomSearchMarkdown.containsInline("[Open notes](https://example.invalid/needle)",
                                                          query: "needle", ownHandles: []),
                       "a link's destination is not a visible match")
    }

    func test_the_first_match_is_found_in_existing_code_list_quote_and_table_blocks() throws {
        let samples = ["```\nneedle = true\n```", "- **needle**", "> needle",
                       "| Name |\n| --- |\n| **needle** |"]
        for source in samples {
            let blocks = ChatMarkdown.parse(source)
            XCTAssertTrue(blocks.contains { RoomSearchMarkdown.contains($0, query: "needle", ownHandles: []) })
        }
        let ticket = "[Ticket: Planning](/dashboard/sessions/chat?ticket=plan)"
        XCTAssertTrue(ChatMarkdown.parse(ticket).contains {
            RoomSearchMarkdown.contains($0, query: "planning", ownHandles: [])
        })
    }
}
#endif
