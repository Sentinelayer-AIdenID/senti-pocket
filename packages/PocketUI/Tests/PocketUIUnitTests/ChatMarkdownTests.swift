import Foundation
import XCTest
@testable import PocketUI

final class ChatMarkdownTests: XCTestCase {
    func test_paragraphs_join_soft_breaks_and_split_on_blank_lines() {
        XCTAssertEqual(ChatMarkdown.parse("one\ntwo\n\nthree"), [.paragraph("one two"), .paragraph("three")])
    }

    func test_headings_rules_and_quotes() {
        let blocks = ChatMarkdown.parse("## Status ##\n---\n> quoted **text**\n> more\n\nafter")
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Status"),
            .rule,
            .quote([.paragraph("quoted **text** more")]),
            .paragraph("after")
        ])
        XCTAssertEqual(ChatMarkdown.parse("#nospace"), [.paragraph("#nospace")], "a heading needs a space")
    }

    func test_ordered_and_unordered_lists_keep_their_numbering_and_depth() {
        XCTAssertEqual(ChatMarkdown.parse("3. third\n4) fourth"), [
            .list(ordered: true, start: 3, items: [
                ChatMarkdownListItem(depth: 0, text: "third"),
                ChatMarkdownListItem(depth: 0, text: "fourth")
            ])
        ])
        XCTAssertEqual(ChatMarkdown.parse("- a\n  - nested\n* b"), [
            .list(ordered: false, start: 1, items: [
                ChatMarkdownListItem(depth: 0, text: "a"),
                ChatMarkdownListItem(depth: 1, text: "nested"),
                ChatMarkdownListItem(depth: 0, text: "b")
            ])
        ])
    }

    func test_fenced_code_is_verbatim_and_an_unclosed_fence_runs_to_the_end() {
        XCTAssertEqual(ChatMarkdown.parse("```swift\nlet a = 1\n# not a heading\n```\ntail"), [
            .code(language: "swift", text: "let a = 1\n# not a heading"),
            .paragraph("tail")
        ])
        XCTAssertEqual(ChatMarkdown.parse("~~~\nopen"), [.code(language: nil, text: "open")])
    }

    func test_very_long_bodies_stop_parsing_at_the_limit() {
        let body = String(repeating: "a", count: ChatMarkdown.maximumParsedCharacters + 10)
        let blocks = ChatMarkdown.parse(body)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.last, .paragraph(String(repeating: "a", count: 10)))
    }

    func test_pull_request_links_match_the_web_rules_exactly() {
        XCTAssertEqual(
            ChatReferences.pullRequest(URL(string: "https://github.com/Sentinelayer-AIdenID/senti-pocket/pull/179")!)?.label,
            "Sentinelayer-AIdenID/senti-pocket#179"
        )
        XCTAssertNil(ChatReferences.pullRequest(URL(string: "http://github.com/a/b/pull/1")!), "https only")
        XCTAssertNil(ChatReferences.pullRequest(URL(string: "https://github.com:8443/a/b/pull/1")!), "no port")
        XCTAssertNil(ChatReferences.pullRequest(URL(string: "https://github.com/a/b/pull/1/files")!), "exact path")
        XCTAssertNil(ChatReferences.pullRequest(URL(string: "https://github.com/a/b/issues/1")!))
        XCTAssertNil(ChatReferences.pullRequest(URL(string: "https://gitlab.com/a/b/pull/1")!))
        XCTAssertNil(ChatReferences.pullRequest(URL(string: "https://github.com/a/b/pull/0")!))
    }

    func test_ticket_links_and_mentions() {
        let ticket = ChatReferences.ticket("/dashboard/sessions/0b1c2d3e-4f50/?ticket=c0ffee08")
        XCTAssertNil(ticket, "a trailing slash before the query is not the web's ticket shape")
        let exact = ChatReferences.ticket("/dashboard/sessions/0b1c2d3e?ticket=c0ffee08-1234")
        XCTAssertEqual(exact?.sessionId, "0b1c2d3e")
        XCTAssertEqual(exact?.ticketId, "c0ffee08-1234")
        XCTAssertNil(ChatReferences.ticket("/dashboard/sessions/x?ticket=a&evil=1"))
    }

    /// Carter and warden: the keeper's ticket links sat side by side; each is its own row now.
    func test_ticket_links_come_out_of_the_text_one_per_row() {
        let keeper = "🎫 Tickets for this message: [Ticket: Fix Phone notifications that stop updating]"
            + "(/dashboard/sessions/e9e8dc5e-8d57-4603-975f-09156e3b4473?ticket=c2e3430f-894d-47b6-be6d-5a4d98939a52) · "
            + "[Ticket: Keep Phone and web notifications synchronized]"
            + "(/dashboard/sessions/e9e8dc5e-8d57-4603-975f-09156e3b4473?ticket=b562dbe7-865b-48bf-be36-e476d275f6a3)"
        let split = ChatReferences.ticketLinks(in: keeper)
        XCTAssertEqual(split.prose, "🎫 Tickets for this message:")
        XCTAssertEqual(split.tickets.map(\.title), ["Fix Phone notifications that stop updating",
                                                    "Keep Phone and web notifications synchronized"])
        XCTAssertEqual(split.tickets.first?.ticketId, "c2e3430f-894d-47b6-be6d-5a4d98939a52")
        XCTAssertEqual(split.tickets.first?.url.absoluteString,
                       "https://sentinelayer.com/dashboard/sessions/e9e8dc5e-8d57-4603-975f-09156e3b4473?ticket=c2e3430f-894d-47b6-be6d-5a4d98939a52")

        let inline = ChatReferences.ticketLinks(in: "🎫 1 new from #54924: P2 [Ticket: Lower the text box](https://sentinelayer.com/dashboard/sessions/e9e8dc5e?ticket=ba811458)")
        XCTAssertEqual(inline.prose, "🎫 1 new from #54924: P2")
        XCTAssertEqual(inline.tickets.map(\.ticketId), ["ba811458"])

        let other = "See [the docs](https://example.com/dashboard/sessions/x?ticket=y) and nothing else"
        XCTAssertTrue(ChatReferences.ticketLinks(in: other).tickets.isEmpty, "only Senti's own ticket links")
        XCTAssertEqual(ChatReferences.ticketLinks(in: "plain text").prose, "plain text")

        XCTAssertEqual(
            ChatReferences.mentionHandles(in: "@cobalt-warden ping @all and email a@b.com @Cobalt-Warden"),
            ["cobalt-warden", "all"],
            "an @ inside an email is not a mention; handles are case-insensitive and unique"
        )
    }

    #if canImport(SwiftUI)
    func test_inline_markdown_chips_pull_requests_autolinks_and_disarms() {
        let text = ChatInlineMarkdown.attributed(
            "see https://github.com/a/b/pull/7 and [notes](https://example.com/n). Call [us](tel:555)."
        )
        let rendered = String(text.characters)
        XCTAssertTrue(rendered.contains("a/b#7"), "a bare pull-request URL reads as a chip: \(rendered)")
        XCTAssertFalse(rendered.contains("https://github.com/a/b/pull/7"))
        let links = Set(text.runs.compactMap { $0.link?.absoluteString })
        XCTAssertEqual(links, ["https://github.com/a/b/pull/7", "https://example.com/n"])
        XCTAssertTrue(rendered.contains("us"), "a disarmed link keeps its text")
    }

    func test_inline_markdown_keeps_custom_link_text_beside_the_chip_and_skips_code() {
        let text = ChatInlineMarkdown.attributed("[the fix](https://github.com/a/b/pull/9) `@notamention https://x.dev`")
        let rendered = String(text.characters)
        XCTAssertTrue(rendered.contains("the fix · a/b#9"), rendered)
        XCTAssertEqual(Set(text.runs.compactMap { $0.link }).count, 1, "nothing inside a code span is linked")
    }
    #endif
}
