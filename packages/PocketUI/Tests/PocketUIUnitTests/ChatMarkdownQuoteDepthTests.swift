import Foundation
import XCTest
@testable import PocketUI

/// Block quotes nest at most four deep (`ChatMarkdown.maximumQuoteDepth`): each level is a stack inside a stack on
/// screen, and a message of 50 ">" could stop any phone that showed it. Deeper lines go in the fourth quote, in a run for
/// each stretch of lines equally deep, under one header ("↳ 2 levels deeper"; VoiceOver says "quoted 2 levels deeper"),
/// each run parsed as blocks, so lists stay lists, code stays code, and every word still shows.
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

    /// Every paragraph's text in `blocks`, quotes included, in order, with how many levels deeper than four it was.
    static func lines(_ blocks: [ChatMarkdownBlock], deeper: Int = 0) -> [(text: String, deeper: Int)] {
        blocks.flatMap { block -> [(text: String, deeper: Int)] in
            switch block {
            case .paragraph(let text): return [(text, deeper)]
            case .deeperQuote(let levels, let inner): return lines(inner, deeper: levels)
            case .quote(let inner): return lines(inner)
            default: return []
            }
        }
    }

    /// The runs from deeper quotes in `blocks`, quotes included, in order: how much deeper each is, and its blocks.
    static func runs(_ blocks: [ChatMarkdownBlock]) -> [(levels: Int, blocks: [ChatMarkdownBlock])] {
        blocks.flatMap { block -> [(levels: Int, blocks: [ChatMarkdownBlock])] in
            switch block {
            case .deeperQuote(let levels, let inner): return [(levels, inner)] + runs(inner)
            case .quote(let inner): return runs(inner)
            default: return []
            }
        }
    }

    /// Whether any block in `blocks` is a quote or a run (a run's blocks never hold either).
    static func holdsQuote(_ blocks: [ChatMarkdownBlock]) -> Bool {
        blocks.contains { block in
            switch block {
            case .quote, .deeperQuote: return true
            default: return false
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
                .quote([.paragraph("level-4-end"), .deeperQuote(levels: 1, blocks: [.paragraph("level-5-end")]),
                        .deeperQuote(levels: 2, blocks: [.paragraph("level-6-end")])])])])])
        ])
    }

    /// Past four, marks are counted as the quote parser reads them a level at a time: any spaces before a ">", at most
    /// one after it.
    func test_a_deeper_line_counts_its_marks_however_they_are_spaced() {
        XCTAssertEqual(ChatMarkdown.parse("> > > > Four deep.\n> > > > >   >  x\n> > > > >>>y"), [
            .quote([.quote([.quote([.quote([.paragraph("Four deep."), .deeperQuote(levels: 2, blocks: [.paragraph("x")]),
                                            .deeperQuote(levels: 3, blocks: [.paragraph("y")])])])])])
        ])
    }

    /// A point and a point under it, as a reply quoting a reply lists them.
    private static let points = ChatMarkdownBlock.list(ordered: false, start: 1, items: [
        ChatMarkdownListItem(depth: 0, text: "a point it made"),
        ChatMarkdownListItem(depth: 1, text: "and a point under that one")
    ])

    func test_lists_past_the_cap_keep_their_bullets_and_nesting() {
        let text = [
            "> > > > Four deep.",
            "> > > > > Five deep.", "> > > > >",
            "> > > > > - a point it made", "> > > > >   - and a point under that one",
            "> > > > > > Six deep.", "> > > > > > - a point it made", "> > > > > >   - and a point under that one"
        ].joined(separator: "\n")
        XCTAssertEqual(ChatMarkdown.parse(text), [.quote([.quote([.quote([.quote([
            .paragraph("Four deep."),
            .deeperQuote(levels: 1, blocks: [.paragraph("Five deep."), Self.points]),
            .deeperQuote(levels: 2, blocks: [.paragraph("Six deep."), Self.points])
        ])])])])])
    }

    /// One header for each stretch of lines equally deep, however many lines and blocks it holds; a stretch at another
    /// depth starts a run of its own, and so does a return to an earlier depth.
    func test_each_run_of_equally_deep_lines_has_exactly_one_header() {
        let text = [
            "> > > > Four deep.",
            "> > > > > One deeper, a paragraph", "> > > > > on two lines.", "> > > > >", "> > > > > - a point",
            "> > > > >   - under it", "> > > > >", "> > > > > Another paragraph.",
            "> > > > > > Two deeper.",
            "> > > > > Back to one deeper.",
            "> > > > > > > Three deeper,", "> > > > > > > on two lines."
        ].joined(separator: "\n")
        let runs = Self.runs(ChatMarkdown.parse(text))
        XCTAssertEqual(runs.map(\.levels), [1, 2, 1, 3], "one header for each run")
        XCTAssertEqual(runs.first?.blocks, [
            .paragraph("One deeper, a paragraph on two lines."),
            .list(ordered: false, start: 1, items: [ChatMarkdownListItem(depth: 0, text: "a point"),
                                                    ChatMarkdownListItem(depth: 1, text: "under it")]),
            .paragraph("Another paragraph.")
        ])
        XCTAssertEqual(runs.last?.blocks, [.paragraph("Three deeper, on two lines.")])
        XCTAssertFalse(runs.contains { Self.holdsQuote($0.blocks) }, "a run's blocks never hold a quote")
    }

    func test_a_run_has_a_header_saying_how_much_deeper_and_says_it_in_words() {
        XCTAssertEqual(ChatMarkdown.deeperQuoteHeader(levels: 1), "↳ 1 level deeper")
        XCTAssertEqual(ChatMarkdown.deeperQuoteHeader(levels: 2), "↳ 2 levels deeper")
        XCTAssertEqual(ChatMarkdown.deeperQuoteHeader(levels: 196), "↳ 196 levels deeper")
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
            }
            let runs = Self.runs(blocks)
            XCTAssertEqual(runs.map(\.levels), Array(1...(levels - ChatMarkdown.maximumQuoteDepth)),
                           "\(levels) levels: each level past four, a run of one line under its own header")
            XCTAssertFalse(runs.contains { Self.holdsQuote($0.blocks) }, "a run's blocks never hold a quote")
        }
    }

    // MARK: - Code is never touched

    /// A merge conflict, as code: lines that start with "<" and ">" that are not quote marks.
    private static let conflict = ["<<<<<<< HEAD", "ours", "=======", "theirs", ">>>>>>> feature"]

    private static func fenced(_ lines: [String], prefix: String = "") -> [String] {
        (["```diff"] + lines + ["```"]).map { prefix + $0 }
    }

    /// The text of every code block in `blocks`, quotes included, in order.
    private static func code(_ blocks: [ChatMarkdownBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case .code(_, let text): return [text]
            case .quote(let inner), .deeperQuote(_, let inner): return code(inner)
            default: return []
            }
        }
    }

    func test_code_at_the_top_level_comes_out_exactly_as_written() {
        let blocks = ChatMarkdown.parse(Self.fenced(Self.conflict).joined(separator: "\n"))
        XCTAssertEqual(Self.code(blocks), [Self.conflict.joined(separator: "\n")])
    }

    func test_code_in_a_quote_two_deep_comes_out_exactly_as_written() {
        let blocks = ChatMarkdown.parse(Self.fenced(Self.conflict, prefix: "> > ").joined(separator: "\n"))
        XCTAssertEqual(Self.depth(blocks), 2)
        XCTAssertEqual(Self.code(blocks), [Self.conflict.joined(separator: "\n")])
    }

    func test_code_in_a_list_item_keeps_every_line_as_written() {
        let text = (["- the merge:"] + Self.fenced(Self.conflict, prefix: "  ")).joined(separator: "\n")
        XCTAssertEqual(Self.code(ChatMarkdown.parse(text)), [Self.conflict.map { "  " + $0 }.joined(separator: "\n")],
                       "each line of the code exactly as written, its indent included")
    }

    /// Six deep, past the cap: the code is still one code block, in the fourth quote, in a run two levels deeper, its
    /// lines exactly as written after their quote's marks (the ">>>>>>> feature" line keeps its own ">").
    func test_code_in_a_quote_six_deep_stays_a_code_block_exactly_as_written() {
        let text = (["> > > > Four deep."] + Self.fenced(Self.conflict, prefix: String(repeating: "> ", count: 6)))
            .joined(separator: "\n")
        let blocks = ChatMarkdown.parse(text)
        XCTAssertEqual(Self.depth(blocks), ChatMarkdown.maximumQuoteDepth)
        XCTAssertEqual(Self.code(blocks), [Self.conflict.joined(separator: "\n")])
        XCTAssertEqual(blocks, [.quote([.quote([.quote([.quote([
            .paragraph("Four deep."),
            .deeperQuote(levels: 2, blocks: [.code(language: "diff", text: Self.conflict.joined(separator: "\n"))])
        ])])])])])
    }

    /// Past the cap, a fence in a run with other lines: the lines before and after it stay in the run, and the code is
    /// one block, exactly as written, though its last line has more ">" than the run has marks.
    func test_code_in_a_run_with_other_lines_stays_one_code_block_exactly_as_written() {
        let prefix = String(repeating: "> ", count: 5)
        let text = (["> > > > Four deep.", prefix + "The merge went wrong:"] + Self.fenced(Self.conflict, prefix: prefix)
            + [prefix + "Which side do we keep?"]).joined(separator: "\n")
        XCTAssertEqual(ChatMarkdown.parse(text), [.quote([.quote([.quote([.quote([
            .paragraph("Four deep."),
            .deeperQuote(levels: 1, blocks: [
                .paragraph("The merge went wrong:"),
                .code(language: "diff", text: Self.conflict.joined(separator: "\n")),
                .paragraph("Which side do we keep?")
            ])
        ])])])])])
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

    /// The same count for the header over each run from a deeper quote, kept apart so what the headers cost shows.
    private struct HeaderCountingLayout: Layout {
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

    /// Parsed blocks drawn the way `ChatMarkdownView` draws them (a quote in the app's own `ChatQuoteFrame`, a run from a
    /// deeper quote as its header and then its blocks), a counter on each quote's blocks, on each paragraph (in a run
    /// too), and, apart, on each run's header.
    private struct CountedBlocks: View {
        let blocks: [ChatMarkdownBlock]

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .quote(let inner):
                        ChatQuoteFrame { CountingLayout { CountedBlocks(blocks: inner) } }
                    case .deeperQuote(let levels, let inner):
                        HeaderCountingLayout { Text(ChatMarkdown.deeperQuoteHeader(levels: levels)).font(.caption) }
                        CountedBlocks(blocks: inner)
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

    /// Counted layout calls: laid out fresh, and again at a new width; apart, the calls to the headers of runs from
    /// deeper quotes in each.
    private struct Counted {
        var fresh = 0
        var again = 0
        var headersFresh = 0
        var headersAgain = 0

        var headers: Int { headersFresh + headersAgain }
        /// Each pass, its headers included.
        var allFresh: Int { fresh + headersFresh }
        var allAgain: Int { again + headersAgain }
    }

    /// The counted layout calls of `text` laid out fresh at 390 pt, then again at 360 (as a size change makes it).
    private func work(_ text: String) -> Counted {
        let view = CountedBlocks(blocks: ChatMarkdown.parse(text)).frame(maxWidth: .infinity, alignment: .topLeading)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 390, height: 4_000)
        var counted = Counted()
        CountingLayout.calls = 0
        HeaderCountingLayout.calls = 0
        host.layoutSubtreeIfNeeded()
        counted.fresh = CountingLayout.calls
        counted.headersFresh = HeaderCountingLayout.calls
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 4_000)
        CountingLayout.calls = 0
        HeaderCountingLayout.calls = 0
        host.layoutSubtreeIfNeeded()
        counted.again = CountingLayout.calls
        counted.headersAgain = HeaderCountingLayout.calls
        return counted
    }

    /// `a` as a multiple of `b`, to two places.
    private static func ratio(_ a: Int, _ b: Int) -> String {
        String(format: "%.2f", Double(a) / Double(max(b, 1)))
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
        var counted: [Int: Counted] = [:]
        for depth in [1, 2, 3, 4, 7] {
            counted[depth] = work(Self.quotedReplies(depth))
            print("QUOTEDEPTH counted depth \(depth): fresh \(counted[depth]?.fresh ?? 0) calls, again "
                + "\(counted[depth]?.again ?? 0) calls, headers \(counted[depth]?.headers ?? 0) calls; real view "
                + "\(realMilliseconds(Self.quotedReplies(depth))) ms")
        }
        let four = counted[4] ?? Counted()
        let seven = counted[7] ?? Counted()
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

    /// For the record (printed, not bounded: time varies by runner): the real view laid out fresh at 200 levels, and
    /// at the most text the parser reads, all of it four quotes deep, once as short paragraphs and once as lines from a
    /// quote four levels deeper (one run in the fourth quote).
    func test_print_the_real_view_at_two_hundred_levels_and_at_the_most_the_parser_reads() {
        func filled(_ line: String) -> String {
            let count = (ChatMarkdown.maximumParsedCharacters - 1) / (line.count + 1)
            return Array(repeating: line, count: count).joined(separator: "\n")
        }
        let paragraphs = filled(">>>> x\n>>>>")
        let deeper = filled(">>>>>>>> x")
        XCTAssertLessThanOrEqual(paragraphs.count, ChatMarkdown.maximumParsedCharacters)
        XCTAssertLessThanOrEqual(deeper.count, ChatMarkdown.maximumParsedCharacters)
        print("QUOTEDEPTH real view 200 levels: \(realMilliseconds(ChatMarkdownQuoteDepthTests.nested(200))) ms; "
            + "\(paragraphs.count) chars of short paragraphs four deep: \(realMilliseconds(paragraphs)) ms; "
            + "\(deeper.count) chars of deeper lines: \(realMilliseconds(deeper)) ms")
    }

    /// The lines `nested(levels)` writes, "level-1-end" … "level-N-end", each as deep as it is there but no deeper than
    /// `deepest`, and each a paragraph of its own: the same content, only less deep.
    private static func sameLines(_ levels: Int, deepest: Int) -> String {
        (1...levels).flatMap { level -> [String] in
            let marks = String(repeating: ">", count: min(level, deepest))
            let line = marks + " level-\(level)-end"
            return level > deepest ? [marks, line] : [line]
        }.joined(separator: "\n")
    }

    /// Depth does not multiply the work of the same content. The same 50 and 200 lines four quotes deep make at most
    /// twice the work of those lines one deep; and as 50 and 200 levels, each line past the fourth a run of its own
    /// under its own header (the most headers for the fewest lines), at most twice the work of those lines four deep,
    /// headers included. This once compared 50 and 200 levels with 4 levels' work, which held only because the lines
    /// past the fourth were never counted.
    func test_depth_does_not_multiply_the_work_of_the_same_lines() {
        for levels in [50, 200] {
            let oneDeep = work(Self.sameLines(levels, deepest: 1))
            let fourDeep = work(Self.sameLines(levels, deepest: 4))
            print("QUOTEDEPTH counted \(levels) lines one deep: fresh \(oneDeep.fresh), again \(oneDeep.again); four deep: "
                + "fresh \(fourDeep.fresh), again \(fourDeep.again); four deep against one deep: fresh "
                + "\(Self.ratio(fourDeep.allFresh, oneDeep.allFresh)) ×, again "
                + "\(Self.ratio(fourDeep.allAgain, oneDeep.allAgain)) ×")
            XCTAssertGreaterThan(oneDeep.fresh, levels, "the counter sees every line")
            XCTAssertLessThanOrEqual(fourDeep.allFresh, oneDeep.allFresh * 2, "\(levels) lines four deep, fresh: "
                + "\(Self.ratio(fourDeep.allFresh, oneDeep.allFresh)) × their work one deep (at most 2 ×)")
            XCTAssertLessThanOrEqual(fourDeep.allAgain, oneDeep.allAgain * 2, "\(levels) lines four deep, again: "
                + "\(Self.ratio(fourDeep.allAgain, oneDeep.allAgain)) × their work one deep (at most 2 ×)")

            // Uncapped, quotes this deep laid out as stacks inside stacks would not finish: each level multiplies the
            // work of all below it. So they are laid out only once the quotes nest no deeper than the cap.
            let nested = ChatMarkdownQuoteDepthTests.nested(levels)
            let depth = ChatMarkdownQuoteDepthTests.depth(ChatMarkdown.parse(nested))
            guard depth <= ChatMarkdown.maximumQuoteDepth else {
                XCTFail("\(levels) levels nest \(depth) quotes deep, past the cap of \(ChatMarkdown.maximumQuoteDepth): "
                    + "not laid out, as it would not finish")
                continue
            }
            let deeper = work(nested)
            print("QUOTEDEPTH counted \(levels) levels: fresh \(deeper.fresh), again \(deeper.again), headers fresh "
                + "\(deeper.headersFresh), again \(deeper.headersAgain); against the same lines four deep, headers "
                + "included: fresh \(Self.ratio(deeper.allFresh, fourDeep.allFresh)) ×, again "
                + "\(Self.ratio(deeper.allAgain, fourDeep.allAgain)) ×")
            XCTAssertLessThanOrEqual(deeper.allFresh, fourDeep.allFresh * 2, "\(levels) levels, fresh: "
                + "\(Self.ratio(deeper.allFresh, fourDeep.allFresh)) × the same lines four deep (at most 2 ×)")
            XCTAssertLessThanOrEqual(deeper.allAgain, fourDeep.allAgain * 2, "\(levels) levels, again: "
                + "\(Self.ratio(deeper.allAgain, fourDeep.allAgain)) × the same lines four deep (at most 2 ×)")
        }
    }

    /// Past the cap, the work grows with the lines and no faster: 200 levels (196 runs past four, each a line under
    /// its header) make about four times the work of 50 (46 runs), headers included.
    func test_runs_past_the_cap_cost_about_what_their_lines_cost() {
        let fifty = work(ChatMarkdownQuoteDepthTests.nested(50))
        let twoHundred = work(ChatMarkdownQuoteDepthTests.nested(200))
        print("QUOTEDEPTH counted runs: 50 levels fresh \(fifty.fresh), again \(fifty.again), headers \(fifty.headers); "
            + "200 levels fresh \(twoHundred.fresh), again \(twoHundred.again), headers \(twoHundred.headers)")
        XCTAssertGreaterThan(fifty.headers, 0, "the counter sees the headers")
        let all = { (counted: Counted) in counted.allFresh + counted.allAgain }
        XCTAssertLessThanOrEqual(all(twoHundred), all(fifty) * 9 / 2, "four times the levels make about four times the work")
    }
}
#endif
