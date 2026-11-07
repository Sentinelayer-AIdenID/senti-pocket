#if canImport(SwiftUI)
import SwiftUI

/// Renders a chat or ticket body as the web does: block layout from `ChatMarkdown`, inline styling from
/// `ChatInlineMarkdown`. Parsed blocks are cached by text, so scrolling a long room does not re-parse rows.
public struct ChatMarkdownView: View {
    let text: String
    var ownHandles: Set<String> = []
    var searchFocus: RoomSearchFocus?

    public init(text: String, ownHandles: Set<String> = [], searchFocus: RoomSearchFocus? = nil) {
        self.text = text
        self.ownHandles = ownHandles
        self.searchFocus = searchFocus
    }

    public var body: some View {
        ChatMarkdownBlocksView(blocks: ChatMarkdownCache.blocks(for: text), ownHandles: ownHandles,
                               searchFocus: searchFocus)
    }
}

/// One ticket link as its own row, like the web's ticket chip: one line, cut with "…", and it opens the ticket.
private struct TicketLinkRow: View {
    let ticket: ChatReferences.TicketLink
    var searchFocus: RoomSearchFocus?
    var anchorsMatch = false

    var body: some View {
        Link(destination: ticket.url) {
            HStack(spacing: 8) {
                Image(systemName: "ticket")
                    .foregroundStyle(PocketPalette.accentStrong)
                    .accessibilityHidden(true)
                RoomSearchAttributedText(value: AttributedString(ticket.title), focus: searchFocus, anchorsMatch: anchorsMatch)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .lineLimit(anchorsMatch ? nil : 1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketPalette.textSecondary)
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ticket: \(ticket.title)")
        .accessibilityHint("Opens the ticket")
        .accessibilityIdentifier("pocket.ticketLink.\(ticket.ticketId)")
    }
}

/// A block quote's frame: its blocks, set in from a bar drawn behind them. Behind them, not beside them in a stack: a
/// stack holding the bar beside the blocks measured the blocks again and again, at every level of quote, so a quote's
/// layout cost about five times more at each level it nested, for every line inside it. Padded, with the bar behind,
/// each level measures its blocks once for each size it is asked about.
struct ChatQuoteFrame<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.leading, 11)
            .background(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(PocketPalette.separator)
                    .frame(width: 3)
            }
    }
}

private struct ChatMarkdownBlocksView: View {
    let blocks: [ChatMarkdownBlock]
    let ownHandles: Set<String>
    var searchFocus: RoomSearchFocus?
    var anchorsFirstMatch = true

    /// One line of this stack: a block, or the header over a run from a deeper quote.
    private enum Row {
        case block(ChatMarkdownBlock)
        case deeperQuoteHeader(levels: Int)
    }

    /// `blocks` as this stack shows them: a run from a deeper quote is its header and then its blocks, straight in this
    /// stack, not in a stack of its own, so a run adds no level of layout.
    private static func rows(_ blocks: [ChatMarkdownBlock]) -> [Row] {
        blocks.flatMap { block -> [Row] in
            guard case .deeperQuote(let levels, let inner) = block else { return [.block(block)] }
            return [.deeperQuoteHeader(levels: levels)] + rows(inner)
        }
    }

    var body: some View {
        let rows = Self.rows(blocks)
        let firstMatch = searchFocus.flatMap { focus in
            rows.firstIndex { row in
                guard case .block(let block) = row else { return false }
                return RoomSearchMarkdown.contains(block, query: focus.query, ownHandles: ownHandles)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                switch row {
                case .block(let block):
                    blockView(block, anchorsMatch: anchorsFirstMatch && index == firstMatch)
                case .deeperQuoteHeader(let levels):
                    // Lines from a quote deeper than the deepest shown: one small header on a line of its own saying
                    // how much deeper, then their blocks as any quote's, the full width of the quote.
                    Text(ChatMarkdown.deeperQuoteHeader(levels: levels))
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .accessibilityLabel(ChatMarkdown.deeperQuoteLabel(levels: levels))
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdownBlock, anchorsMatch: Bool) -> some View {
        switch block {
        case .paragraph(let text):
            let split = ChatReferences.ticketLinks(in: text)
            if split.tickets.isEmpty {
                inline(text, anchorsMatch: anchorsMatch)
            } else {
                let proseMatches = searchFocus.map {
                    RoomSearchMarkdown.containsInline(split.prose, query: $0.query, ownHandles: ownHandles)
                } ?? false
                let firstTicket = searchFocus.flatMap { focus in
                    split.tickets.first { RoomSearchMarkdown.contains(AttributedString($0.title), query: focus.query) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    if !split.prose.isEmpty { inline(split.prose, anchorsMatch: anchorsMatch && proseMatches) }
                    ForEach(split.tickets, id: \.ticketId) { ticket in
                        TicketLinkRow(ticket: ticket, searchFocus: searchFocus,
                                      anchorsMatch: anchorsMatch && !proseMatches && ticket.ticketId == firstTicket?.ticketId)
                    }
                }
            }
        case .heading(let level, let text):
            inline(text, anchorsMatch: anchorsMatch)
                .font(level <= 1 ? .title3.bold() : (level == 2 ? .headline : .subheadline.weight(.semibold)))
        case .list(let ordered, let start, let items):
            let firstItem = searchFocus.flatMap { focus in
                items.firstIndex { RoomSearchMarkdown.containsInline(ChatMarkdownListItem.task($0.text)?.text ?? $0.text,
                                                                      query: focus.query, ownHandles: ownHandles) }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // A task item ("- [ ] ..." / "- [x] ...") shows its box, as GitHub does.
                        if let task = ChatMarkdownListItem.task(item.text) {
                            Image(systemName: task.done ? "checkmark.square.fill" : "square")
                                .foregroundStyle(task.done ? PocketPalette.verified : PocketPalette.textSecondary)
                                .accessibilityLabel(task.done ? "Done" : "Not done")
                            inline(task.text, anchorsMatch: anchorsMatch && offset == firstItem)
                        } else {
                            Text(ordered ? "\(start + offset)." : (item.depth == 0 ? "•" : "◦"))
                                .monospacedDigit()
                                .foregroundStyle(PocketPalette.textSecondary)
                            inline(item.text, anchorsMatch: anchorsMatch && offset == firstItem)
                        }
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .quote(let inner):
            ChatQuoteFrame {
                ChatMarkdownBlocksView(blocks: inner, ownHandles: ownHandles, searchFocus: searchFocus,
                                       anchorsFirstMatch: anchorsMatch)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
        case .code(_, let text):
            ScrollViewReader { codeScroll in
                ScrollView(.horizontal, showsIndicators: false) {
                    RoomSearchAttributedText(value: AttributedString(text), focus: searchFocus, anchorsMatch: anchorsMatch)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
                .task(id: searchFocus?.id) {
                    guard anchorsMatch, let focus = searchFocus else { return }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    codeScroll.scrollTo(focus.anchor, anchor: .center)
                }
            }
            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5)
            )
        case .deeperQuote:
            // Never reached: `rows(_:)` shows a run as its header and its blocks.
            EmptyView()
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let table):
            tableView(table, anchorsMatch: anchorsMatch)
        }
    }

    private func tableView(_ table: ChatMarkdownTable, anchorsMatch: Bool) -> some View {
        ChatMarkdownTableView(table: table, ownHandles: ownHandles, searchFocus: searchFocus,
                              anchorsFirstMatch: anchorsMatch)
    }

    private func inline(_ text: String, anchorsMatch: Bool = false) -> some View {
        RoomSearchAttributedText(value: ChatInlineMarkdown.attributed(text, ownHandles: ownHandles),
                                 focus: searchFocus, anchorsMatch: anchorsMatch)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A table as a grid with a shaded header row and lines between rows (Carter, #55366). A narrow table fits the width
/// it is given, its cells wrapping; a wide one keeps its columns readable and scrolls sideways, with its scroll bar
/// showing (Carter, #55517).
private struct ChatMarkdownTableView: View {
    let table: ChatMarkdownTable
    let ownHandles: Set<String>
    var searchFocus: RoomSearchFocus?
    var anchorsFirstMatch = true
    /// The width the message gives the table, once measured; a phone's until then.
    @State private var available: Double = 330

    /// More rows than this are left out on the phone; the whole message is in its long view and on the web.
    private static let maximumTableRows = 200

    var body: some View {
        let fit = table.fittedWidths(available: available)
        Group {
            if fit.scrolls {
                ScrollViewReader { tableScroll in
                    ScrollView(.horizontal, showsIndicators: true) { grid(fit.widths) }
                        .task(id: searchFocus?.id) {
                            guard anchorsFirstMatch, let focus = searchFocus else { return }
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            guard !Task.isCancelled else { return }
                            tableScroll.scrollTo(focus.anchor, anchor: .center)
                        }
                }
            } else {
                grid(fit.widths)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { available = proxy.size.width }
                .onChange(of: proxy.size.width) { available = $0 }
        })
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func grid(_ widths: [Double]) -> some View {
        let firstMatch = searchFocus.flatMap { RoomSearchMarkdown.firstMatch(in: table, query: $0.query, ownHandles: ownHandles) }
        let rendered = Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { column, text in
                    cell(text, width: widths[column], alignment: table.alignments[column],
                         anchorsMatch: anchorsFirstMatch && firstMatch?.row == -1 && firstMatch?.column == column)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .background(PocketPalette.inset)
            ForEach(Array(table.rows.prefix(Self.maximumTableRows).enumerated()), id: \.offset) { rowIndex, row in
                Divider()
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, text in
                        cell(text, width: widths[column], alignment: table.alignments[column],
                             anchorsMatch: anchorsFirstMatch && firstMatch?.row == rowIndex && firstMatch?.column == column)
                            .font(.subheadline)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(PocketPalette.separator, lineWidth: 0.5)
        )
        .padding(.vertical, 2)
        if let searchFocus, table.rows.count > Self.maximumTableRows {
            // Keep the table's existing layout budget. Only an opened search result also shows its remaining
            // cells as text, so a match after the bounded grid stays reachable without laying out thousands of rows.
            VStack(alignment: .leading, spacing: 6) {
                rendered
                RoomSearchAttributedText(value: AttributedString(table.rows.dropFirst(Self.maximumTableRows)
                    .map { $0.joined(separator: "\t") }.joined(separator: "\n")), focus: searchFocus,
                    anchorsMatch: anchorsFirstMatch && (firstMatch?.row ?? -1) >= Self.maximumTableRows)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            rendered
        }
    }

    private func cell(_ text: String, width: Double, alignment: ChatMarkdownTable.Alignment, anchorsMatch: Bool) -> some View {
        let frameAlignment: Alignment
        let textAlignment: TextAlignment
        switch alignment {
        case .leading: (frameAlignment, textAlignment) = (.leading, .leading)
        case .center: (frameAlignment, textAlignment) = (.center, .center)
        case .trailing: (frameAlignment, textAlignment) = (.trailing, .trailing)
        }
        return RoomSearchAttributedText(value: ChatInlineMarkdown.attributed(text, ownHandles: ownHandles),
                                        focus: searchFocus, anchorsMatch: anchorsMatch)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(textAlignment)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: width, alignment: frameAlignment)
    }
}

/// Inline Markdown with the web's rules applied:
/// - links: only http(s) to a real host stay tappable (`RoomLinkPolicy`); bare URLs are linked like GFM autolinks;
/// - GitHub pull-request links read as `owner/repo#n` chips (custom link text becomes "text · owner/repo#n");
/// - `@handle` mentions are highlighted, and mentions of you stand out more;
/// - code spans are left alone.
enum ChatInlineMarkdown {
    /// Every paragraph of every row on screen asks for this on every redraw, and building it parses Markdown and
    /// scans for links and mentions, so each answer is kept per text and handles (with the expressions compiled once,
    /// as for the room's other per-redraw helpers).
    static func attributed(_ text: String, ownHandles: Set<String> = []) -> AttributedString {
        let key = (ownHandles.sorted().joined(separator: ",") + "\u{1}" + text) as NSString
        if let known = memo.object(forKey: key) { return known.value }
        let value = build(text, ownHandles: ownHandles)
        memo.setObject(Built(value), forKey: key)
        return value
    }

    private final class Built {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let memo: NSCache<NSString, Built> = {
        let cache = NSCache<NSString, Built>()
        cache.countLimit = 4_000
        return cache
    }()

    private static let linkExpression = try? NSRegularExpression(pattern: #"https?://[^\s<>()\[\]]+"#)
    private static let mentionExpression = try? NSRegularExpression(pattern: #"(?:^|(?<=\s))@([A-Za-z0-9_-]+)"#)

    private static func build(_ text: String, ownHandles: Set<String>) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)

        // 1. Autolink bare http(s) URLs outside code spans and existing links (GFM autolinks, as the web does).
        autolink(&attributed)

        // 2. Disarm links the policy refuses; collect pull-request links to relabel.
        var pullRequests: [(Range<AttributedString.Index>, URL, ChatReferences.PullRequest, String)] = []
        var disarmed: [Range<AttributedString.Index>] = []
        for run in attributed.runs {
            guard let url = run.link else { continue }
            if !RoomLinkPolicy.isAllowed(url) {
                disarmed.append(run.range)
            } else if let pr = ChatReferences.pullRequest(url) {
                pullRequests.append((run.range, url, pr, String(attributed[run.range].characters)))
            }
        }
        for range in disarmed { attributed[range].link = nil }

        // 3. Relabel pull-request links as chips, last first so earlier ranges stay valid.
        for (range, url, pr, label) in pullRequests.reversed() {
            let isBareURL = label.hasPrefix("http://") || label.hasPrefix("https://")
            var chip = AttributedString(pr.label)
            chip.swiftUI.font = .system(.callout, design: .monospaced).weight(.semibold)
            chip.swiftUI.backgroundColor = PocketPalette.accent.opacity(0.12)
            var replacement = isBareURL ? AttributedString() : AttributedString("\(label) · ")
            replacement.append(chip)
            replacement.link = url
            attributed.replaceSubrange(range, with: replacement)
        }

        // 4. Highlight @mentions outside code and links.
        highlightMentions(&attributed, ownHandles: ownHandles)
        return attributed
    }

    private static func isCode(_ run: AttributedString.Runs.Run) -> Bool {
        run.inlinePresentationIntent?.contains(.code) == true
    }

    private static func autolink(_ attributed: inout AttributedString) {
        guard let regex = linkExpression else { return }
        var additions: [(Range<AttributedString.Index>, URL)] = []
        for run in attributed.runs where run.link == nil && !isCode(run) {
            let segment = String(attributed[run.range].characters)
            let nsRange = NSRange(segment.startIndex..., in: segment)
            for match in regex.matches(in: segment, range: nsRange) {
                guard let swiftRange = Range(match.range, in: segment) else { continue }
                var candidate = String(segment[swiftRange])
                while let last = candidate.last, ".,;:!?'\"".contains(last) { candidate.removeLast() }
                guard let url = URL(string: candidate), RoomLinkPolicy.isAllowed(url) else { continue }
                let startOffset = segment.distance(from: segment.startIndex, to: swiftRange.lowerBound)
                let start = attributed.characters.index(run.range.lowerBound, offsetBy: startOffset)
                let end = attributed.characters.index(start, offsetBy: candidate.count)
                additions.append((start..<end, url))
            }
        }
        for (range, url) in additions { attributed[range].link = url }
    }

    private static func highlightMentions(_ attributed: inout AttributedString, ownHandles: Set<String>) {
        guard let regex = mentionExpression else { return }
        var marks: [(Range<AttributedString.Index>, Bool)] = []
        for run in attributed.runs where run.link == nil && !isCode(run) {
            let segment = String(attributed[run.range].characters)
            let nsRange = NSRange(segment.startIndex..., in: segment)
            for match in regex.matches(in: segment, range: nsRange) {
                guard let whole = Range(match.range, in: segment),
                      let handle = Range(match.range(at: 1), in: segment) else { continue }
                let startOffset = segment.distance(from: segment.startIndex, to: whole.lowerBound)
                let length = segment.distance(from: whole.lowerBound, to: whole.upperBound)
                let start = attributed.characters.index(run.range.lowerBound, offsetBy: startOffset)
                let end = attributed.characters.index(start, offsetBy: length)
                marks.append((start..<end, ownHandles.contains(segment[handle].lowercased())))
            }
        }
        for (range, isOwn) in marks {
            attributed[range].swiftUI.foregroundColor = PocketPalette.accent
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
            if isOwn { attributed[range].swiftUI.backgroundColor = PocketPalette.warning.opacity(0.22) }
        }
    }
}

/// Parsed-block cache keyed by body text. NSCache is thread-safe and evicts under memory pressure.
enum ChatMarkdownCache {
    private final class Box {
        let blocks: [ChatMarkdownBlock]
        init(_ blocks: [ChatMarkdownBlock]) { self.blocks = blocks }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 1_000
        return cache
    }()

    static func blocks(for text: String) -> [ChatMarkdownBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = ChatMarkdown.parse(text)
        cache.setObject(Box(blocks), forKey: key)
        return blocks
    }
}
#endif
