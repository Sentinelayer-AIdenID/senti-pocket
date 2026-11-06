import Foundation
import XCTest
@testable import PocketUI

/// Block quotes nest at most four deep (`ChatMarkdown.maximumQuoteDepth`): each level is a stack inside a stack on
/// screen, and a message of 50 ">" could stop any phone that showed it. Deeper lines go in the fourth quote, each led by
/// one "↳" and, past one level deeper, how much deeper ("↳ (8 levels deeper)"); VoiceOver says "quoted 8 levels
/// deeper"; every word still shows.
final class ChatMarkdownQuoteDepthTests: XCTestCase {
    /// `levels` block quotes, each inside the one before, each with its own line: "level-1-end" … "level-N-end". The
    /// marks are written ">>>" (as Markdown allows) so 200 levels stay inside what the parser reads
    /// (`ChatMarkdown.maximumParsedCharacters`); past that, the rest of a message is one plain paragraph.
    static func nested(_ levels: Int) -> String {
        (1...levels).map { String(repeating: ">", count: $0) + " level-\($0)-end" }.joined(separator: "\n")
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
            XCTAssertLessThan(Self.nested(levels).count, ChatMarkdown.maximumParsedCharacters,
                              "\(levels) levels fit in what the parser reads")
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

/// The work of laying a quote out, counted, not timed (a hosted runner's speed varies): the parsed blocks drawn in the
/// app's own quote frame (`ChatQuoteFrame`, as `ChatMarkdownView` draws a quote), with a counter on each quote level and
/// on each line, which counts each time it is sized, placed or asked for an alignment. The real view's times are
/// printed too.
final class ChatMarkdownQuoteDepthLayoutTests: XCTestCase {
    /// Counts each time a level is sized, placed or asked for an alignment, and passes it all to its one view.
    private struct CountingLayout: Layout {
        nonisolated(unsafe) static var calls = 0

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            Self.calls += 1
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            Self.calls += 1
            subviews.first?.place(at: bounds.origin, proposal: proposal)
        }

        func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                               subviews: Subviews, cache: inout ()) -> CGFloat? {
            Self.calls += 1
            return subviews.first?.dimensions(in: proposal)[explicit: guide].map { $0 + bounds.minX }
        }

        func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                               subviews: Subviews, cache: inout ()) -> CGFloat? {
            Self.calls += 1
            return subviews.first?.dimensions(in: proposal)[explicit: guide].map { $0 + bounds.minY }
        }
    }

    /// Parsed blocks drawn the way `ChatMarkdownView` draws them (a quote in the app's own `ChatQuoteFrame`), a counter on
    /// each quote's blocks and on each paragraph.
    private struct CountedBlocks: View {
        let blocks: [ChatMarkdownBlock]

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .quote(let inner):
                        ChatQuoteFrame { CountingLayout { CountedBlocks(blocks: inner) } }
                    case .deeperQuote(let levels, let text):
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(ChatMarkdown.deeperQuoteMark(levels: levels)).font(.caption)
                            Text(text)
                        }
                    case .list(_, _, let items):
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•")
                                    Text(item.text)
                                }
                                .padding(.leading, CGFloat(item.depth) * 16)
                            }
                        }
                    case .paragraph(let text):
                        CountingLayout { Text(text) }
                    default:
                        Text("…")
                    }
                }
            }
        }
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

    /// The counted layout calls of `text` laid out fresh at 390 pt, then again at 360 (as a size change makes it).
    private func work(_ text: String) -> (fresh: Int, again: Int) {
        let view = CountedBlocks(blocks: ChatMarkdown.parse(text)).frame(maxWidth: .infinity, alignment: .topLeading)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 390, height: 4_000)
        CountingLayout.calls = 0
        host.layoutSubtreeIfNeeded()
        let fresh = CountingLayout.calls
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 4_000)
        CountingLayout.calls = 0
        host.layoutSubtreeIfNeeded()
        return (fresh, CountingLayout.calls)
    }

    /// The real view's fresh layout, in ms, for the record only.
    private func realMilliseconds(_ text: String) -> Int {
        let host = NSHostingView(rootView: ChatMarkdownView(text: text).frame(width: 390, alignment: .topLeading))
        host.frame = NSRect(x: 0, y: 0, width: 390, height: 4_000)
        let start = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        return Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    /// Capped at four, a quote seven deep makes at most twice the layout work of one four deep, fresh and again.
    func test_a_seven_deep_quote_makes_about_the_work_of_four_deep() {
        var counted: [Int: (fresh: Int, again: Int)] = [:]
        for depth in [1, 2, 3, 4, 7] {
            counted[depth] = work(Self.quotedReplies(depth))
            print("QUOTEDEPTH counted depth \(depth): fresh \(counted[depth]?.fresh ?? 0) calls, again "
                + "\(counted[depth]?.again ?? 0) calls; real view \(realMilliseconds(Self.quotedReplies(depth))) ms")
        }
        let four = counted[4] ?? (0, 0)
        let seven = counted[7] ?? (0, 0)
        XCTAssertGreaterThan(four.fresh, 0, "the counter sees the quote levels")
        XCTAssertLessThanOrEqual(seven.fresh, four.fresh * 2, "7 deep, laid out fresh, makes at most twice 4 deep's work")
        XCTAssertLessThanOrEqual(seven.again, max(four.again, 1) * 2,
                                 "7 deep, laid out again, makes at most twice 4 deep's work")
    }

    /// `lines` paragraphs inside quotes `levels` deep.
    private static func lines(_ lines: Int, levels: Int) -> String {
        var text = (1..<max(levels, 1)).map { String(repeating: ">", count: $0) + " level \($0)" }
        let marks = String(repeating: ">", count: levels)
        for line in 1...lines {
            text.append(marks + " Line \(line), long enough to wrap onto a second line in a row of the room.")
            text.append(marks)
        }
        return text.joined(separator: "\n")
    }

    /// Lines inside a quote four deep make at most twice the layout work of the same lines one deep: each level adds a
    /// little, it does not multiply what is inside it. And twice the lines make about twice the work.
    func test_lines_four_quotes_deep_cost_about_what_they_cost_one_deep() {
        let oneDeep = work(Self.lines(50, levels: 1))
        let fourDeep = work(Self.lines(50, levels: 4))
        let fourDeepMore = work(Self.lines(200, levels: 4))
        print("QUOTEDEPTH counted 50 lines 1 deep: fresh \(oneDeep.fresh), again \(oneDeep.again); 4 deep: fresh "
            + "\(fourDeep.fresh), again \(fourDeep.again); 200 lines 4 deep: fresh \(fourDeepMore.fresh), again "
            + "\(fourDeepMore.again)")
        XCTAssertGreaterThan(oneDeep.fresh, 50, "the counter sees every line")
        XCTAssertLessThanOrEqual(fourDeep.fresh, oneDeep.fresh * 2, "4 deep makes at most twice 1 deep's work, fresh")
        XCTAssertLessThanOrEqual(fourDeep.again, max(oneDeep.again, 1) * 2, "and laid out again")
        XCTAssertLessThanOrEqual(fourDeepMore.fresh, fourDeep.fresh * 4 + fourDeep.fresh / 2,
                                 "four times the lines make about four times the work")
    }

    /// 50 and 200 levels make at most twice the layout work of four levels: every line past the fourth sits in the
    /// fourth quote, and no level is added for it.
    func test_fifty_and_two_hundred_levels_make_about_the_work_of_four() {
        let four = work(ChatMarkdownQuoteDepthTests.nested(4))
        XCTAssertGreaterThan(four.fresh, 0, "the counter sees the quote levels")
        for levels in [50, 200] {
            let counted = work(ChatMarkdownQuoteDepthTests.nested(levels))
            print("QUOTEDEPTH counted \(levels) levels: fresh \(counted.fresh) calls, again \(counted.again) calls "
                + "(4 levels: \(four.fresh), \(four.again)); real view "
                + "\(realMilliseconds(ChatMarkdownQuoteDepthTests.nested(levels))) ms")
            XCTAssertLessThanOrEqual(counted.fresh, four.fresh * 2, "\(levels) levels make at most twice 4 levels' work")
            XCTAssertLessThanOrEqual(counted.again, max(four.again, 1) * 2,
                                     "\(levels) levels, laid out again, make at most twice 4 levels' work")
        }
    }
}
#endif
