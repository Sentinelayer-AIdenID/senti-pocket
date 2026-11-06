import Foundation
import XCTest
@testable import PocketUI

/// Block quotes nest at most four deep (`ChatMarkdown.maximumQuoteDepth`): each level is a stack inside a stack on
/// screen, and a message of 50 ">" could stop any phone that showed it. Deeper lines go in the fourth quote, each led by
/// one "↳" and, past one level deeper, how much deeper ("↳ (8 levels deeper)"); VoiceOver says "quoted 8 levels
/// deeper"; every word still shows.
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

    /// Every line's text in `blocks`, quotes included, in order, with how many levels deeper than four it was.
    static func lines(_ blocks: [ChatMarkdownBlock]) -> [(text: String, deeper: Int)] {
        blocks.flatMap { block -> [(text: String, deeper: Int)] in
            switch block {
            case .paragraph(let text): return [(text, 0)]
            case .deeperQuote(let levels, let text): return [(text, levels)]
            case .quote(let inner): return lines(inner)
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

    func test_a_quote_deeper_than_four_goes_in_the_fourth_with_how_many_levels_deeper() {
        XCTAssertEqual(ChatMarkdown.parse(Self.nested(6)), [
            .quote([.paragraph("level-1-end"), .quote([.paragraph("level-2-end"), .quote([.paragraph("level-3-end"),
                .quote([.paragraph("level-4-end"), .deeperQuote(levels: 1, text: "level-5-end"),
                        .deeperQuote(levels: 2, text: "level-6-end")])])])])
        ])
    }

    func test_a_deeper_line_shows_one_arrow_and_how_much_deeper_and_says_it_in_words() {
        XCTAssertEqual(ChatMarkdown.deeperQuoteMark(levels: 1), "↳")
        XCTAssertEqual(ChatMarkdown.deeperQuoteMark(levels: 8), "↳ (8 levels deeper)")
        XCTAssertEqual(ChatMarkdown.deeperQuoteMark(levels: 196), "↳ (196 levels deeper)")
        XCTAssertEqual(ChatMarkdown.deeperQuoteLabel(levels: 1), "quoted 1 level deeper")
        XCTAssertEqual(ChatMarkdown.deeperQuoteLabel(levels: 8), "quoted 8 levels deeper")
    }

    func test_fifty_and_two_hundred_levels_nest_four_deep_and_keep_every_word() {
        for levels in [50, 200] {
            let blocks = ChatMarkdown.parse(Self.nested(levels))
            XCTAssertEqual(Self.depth(blocks), ChatMarkdown.maximumQuoteDepth, "\(levels) levels nest four deep")
            let text = Self.lines(blocks)
            XCTAssertEqual(text.count, levels, "\(levels) levels: one line each")
            for (index, line) in text.enumerated() {
                let level = index + 1
                XCTAssertEqual(line.text, "level-\(level)-end", "level \(level)'s words are kept")
                XCTAssertEqual(line.deeper, max(0, level - ChatMarkdown.maximumQuoteDepth),
                               "level \(level): how many levels deeper than four")
                guard line.deeper > 0 else { continue }
                let mark = ChatMarkdown.deeperQuoteMark(levels: line.deeper)
                XCTAssertEqual(mark.filter { $0 == "↳" }.count, 1, "level \(level): one arrow")
                if line.deeper > 1 {
                    XCTAssertTrue(mark.contains("(\(line.deeper) levels deeper)"), "level \(level): how much deeper")
                }
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

    /// Quotes `depth` deep, each level with a paragraph and a two-level list under it, as replies quoting replies are.
    private static func quotedReplies(_ depth: Int) -> String {
        (0..<depth).flatMap { level -> [String] in
            let prefix = String(repeating: "> ", count: level)
            return [prefix + "Level \(level + 1): what the reply before said, long enough to wrap onto a second line.",
                    prefix, prefix + "- a point it made, also long enough to wrap onto a second line",
                    prefix + "  - and a point under that one", prefix]
        }.joined(separator: "\n") + "\nAnd the answer to all of it."
    }

    /// The fastest of three: the message laid out fresh, then again at a new width (as a size change makes it).
    private func freshAndAgain(_ text: String) -> (fresh: Double, again: Double) {
        var fresh = Double.infinity
        var again = Double.infinity
        for _ in 0..<3 {
            let view = ChatMarkdownView(text: text).frame(maxWidth: .infinity, alignment: .topLeading)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 390, height: 4_000)
            var start = CFAbsoluteTimeGetCurrent()
            host.layoutSubtreeIfNeeded()
            fresh = min(fresh, CFAbsoluteTimeGetCurrent() - start)
            host.frame = NSRect(x: 0, y: 0, width: 360, height: 4_000)
            start = CFAbsoluteTimeGetCurrent()
            host.layoutSubtreeIfNeeded()
            again = min(again, CFAbsoluteTimeGetCurrent() - start)
        }
        return (fresh, again)
    }

    /// Laying a deep quote out costs more at every level it nests (about five times per level, measured on the hosted
    /// runner before the cap). Capped at four, 1 to 4 deep stay cheap, and 7 deep costs about what 4 deep does.
    func test_a_seven_deep_quote_lays_out_for_about_what_four_deep_costs() {
        var costs: [Int: (fresh: Double, again: Double)] = [:]
        for depth in [1, 2, 3, 4, 7] {
            costs[depth] = freshAndAgain(Self.quotedReplies(depth))
            print("QUOTEDEPTH real depth \(depth): fresh \(Int((costs[depth]?.fresh ?? 0) * 1000)) ms, "
                + "again \(Int((costs[depth]?.again ?? 0) * 1000)) ms")
        }
        for depth in [1, 2, 3, 4] {
            XCTAssertLessThan(costs[depth]?.fresh ?? 0, 0.5, "\(depth) deep lays out fresh in under half a second")
            XCTAssertLessThan(costs[depth]?.again ?? 0, 0.5, "\(depth) deep lays out again in under half a second")
        }
        let four = costs[4] ?? (0, 0)
        let seven = costs[7] ?? (0, 0)
        XCTAssertLessThanOrEqual(seven.fresh, four.fresh * 2 + 0.03, "7 deep lays out fresh for about what 4 costs")
        XCTAssertLessThanOrEqual(seven.again, four.again * 2 + 0.03, "7 deep lays out again for about what 4 costs")
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
