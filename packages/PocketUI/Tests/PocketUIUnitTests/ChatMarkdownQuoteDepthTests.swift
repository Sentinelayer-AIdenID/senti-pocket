import Foundation
import XCTest
@testable import PocketUI

/// Block quotes nest at most four deep (`ChatMarkdown.maximumQuoteDepth`): each level is a stack inside a stack on
/// screen, and a message of 50 ">" could stop any phone that showed it. Deeper lines go in the fourth quote, led by one
/// "↳" for every level they were deeper, and every word still shows.
final class ChatMarkdownQuoteDepthTests: XCTestCase {
    /// `levels` block quotes, each inside the one before, each with its own line: "level-1-end" … "level-N-end".
    static func nested(_ levels: Int) -> String {
        (1...levels).map { String(repeating: "> ", count: $0) + "level-\($0)-end" }.joined(separator: "\n")
    }

    /// How deep the quotes in `blocks` nest.
    static func depth(_ blocks: [ChatMarkdownBlock]) -> Int {
        blocks.map { block -> Int in
            if case .quote(let inner) = block { return 1 + depth(inner) }
            return 0
        }.max() ?? 0
    }

    /// Every paragraph's text in `blocks`, quotes included, in order.
    static func paragraphs(_ blocks: [ChatMarkdownBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case .paragraph(let text): return [text]
            case .quote(let inner): return paragraphs(inner)
            default: return []
            }
        }
    }

    func test_quotes_up_to_four_deep_nest_as_written() {
        XCTAssertEqual(ChatMarkdown.parse(Self.nested(4)), [
            .quote([.paragraph("level-1-end"), .quote([.paragraph("level-2-end"), .quote([.paragraph("level-3-end"),
                .quote([.paragraph("level-4-end")])])])])
        ])
        XCTAssertEqual(ChatMarkdown.parse("> one\n> > two\n\nafter"),
                       [.quote([.paragraph("one"), .quote([.paragraph("two")])]), .paragraph("after")])
    }

    func test_a_quote_deeper_than_four_goes_in_the_fourth_with_a_mark_for_each_level_deeper() {
        XCTAssertEqual(ChatMarkdown.parse(Self.nested(6)), [
            .quote([.paragraph("level-1-end"), .quote([.paragraph("level-2-end"), .quote([.paragraph("level-3-end"),
                .quote([.paragraph("level-4-end"), .paragraph("↳ level-5-end"), .paragraph("↳↳ level-6-end")])])])])
        ])
    }

    func test_fifty_and_two_hundred_levels_nest_four_deep_and_keep_every_word() {
        for levels in [50, 200] {
            let blocks = ChatMarkdown.parse(Self.nested(levels))
            XCTAssertEqual(Self.depth(blocks), ChatMarkdown.maximumQuoteDepth, "\(levels) levels nest four deep")
            let text = Self.paragraphs(blocks)
            XCTAssertEqual(text.count, levels, "\(levels) levels: one line each")
            for level in 1...levels {
                let line = text[level - 1]
                XCTAssertTrue(line.hasSuffix("level-\(level)-end"), "level \(level)'s words are kept")
                let marks = line.prefix { $0 == "↳" }.count
                XCTAssertEqual(marks, max(0, level - ChatMarkdown.maximumQuoteDepth),
                               "level \(level): one mark for each level deeper than four")
            }
        }
    }
}

#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI

/// The same messages on screen: 50 and 200 levels lay out about as fast as 4 (each at most four stacks deep), well
/// inside a frame budget's worth of seconds; without the cap they would be 50 and 200 stacks deep.
final class ChatMarkdownQuoteDepthLayoutTests: XCTestCase {
    private func layoutSeconds(_ text: String) -> Double {
        let host = NSHostingView(rootView: ChatMarkdownView(text: text).frame(width: 390, alignment: .topLeading))
        host.frame = NSRect(x: 0, y: 0, width: 390, height: 4_000)
        let start = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        return CFAbsoluteTimeGetCurrent() - start
    }

    func test_fifty_and_two_hundred_levels_lay_out_about_as_fast_as_four() {
        let four = layoutSeconds(ChatMarkdownQuoteDepthTests.nested(4))
        for levels in [50, 200] {
            let seconds = layoutSeconds(ChatMarkdownQuoteDepthTests.nested(levels))
            print("QUOTEDEPTH \(levels) levels: \(Int(seconds * 1000)) ms (4 levels: \(Int(four * 1000)) ms)")
            XCTAssertLessThan(seconds, 1, "\(levels) levels lay out in under a second")
        }
    }
}
#endif
