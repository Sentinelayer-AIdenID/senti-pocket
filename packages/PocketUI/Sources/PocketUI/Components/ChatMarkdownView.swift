#if canImport(SwiftUI)
import SwiftUI

/// Renders a chat or ticket body as the web does: block layout from `ChatMarkdown`, inline styling from
/// `ChatInlineMarkdown`. Parsed blocks are cached by text, so scrolling a long room does not re-parse rows.
public struct ChatMarkdownView: View {
    let text: String
    var ownHandles: Set<String> = []

    public init(text: String, ownHandles: Set<String> = []) {
        self.text = text
        self.ownHandles = ownHandles
    }

    public var body: some View {
        ChatMarkdownBlocksView(blocks: ChatMarkdownCache.blocks(for: text), ownHandles: ownHandles)
    }
}

/// One ticket link as its own row, like the web's ticket chip: one line, cut with "…", and it opens the ticket.
private struct TicketLinkRow: View {
    let ticket: ChatReferences.TicketLink

    var body: some View {
        Link(destination: ticket.url) {
            HStack(spacing: 8) {
                Image(systemName: "ticket")
                    .foregroundStyle(PocketPalette.accentStrong)
                    .accessibilityHidden(true)
                Text(ticket.title)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .lineLimit(1)
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

private struct ChatMarkdownBlocksView: View {
    let blocks: [ChatMarkdownBlock]
    let ownHandles: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            let split = ChatReferences.ticketLinks(in: text)
            if split.tickets.isEmpty {
                inline(text)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if !split.prose.isEmpty { inline(split.prose) }
                    ForEach(split.tickets, id: \.ticketId) { ticket in
                        TicketLinkRow(ticket: ticket)
                    }
                }
            }
        case .heading(let level, let text):
            inline(text)
                .font(level <= 1 ? .title3.bold() : (level == 2 ? .headline : .subheadline.weight(.semibold)))
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // A task item ("- [ ] ..." / "- [x] ...") shows its box, as GitHub does.
                        if let task = ChatMarkdownListItem.task(item.text) {
                            Image(systemName: task.done ? "checkmark.square.fill" : "square")
                                .foregroundStyle(task.done ? PocketPalette.verified : PocketPalette.textSecondary)
                                .accessibilityLabel(task.done ? "Done" : "Not done")
                            inline(task.text)
                        } else {
                            Text(ordered ? "\(start + offset)." : (item.depth == 0 ? "•" : "◦"))
                                .monospacedDigit()
                                .foregroundStyle(PocketPalette.textSecondary)
                            inline(item.text)
                        }
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
        case .quote(let inner):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(PocketPalette.separator)
                    .frame(width: 3)
                ChatMarkdownBlocksView(blocks: inner, ownHandles: ownHandles)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5)
            )
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let table):
            tableView(table)
        }
    }

    /// A table as a grid with a shaded header row and lines between rows (Carter, #55366). Each column is as wide as
    /// its longest cell up to a cap, so long cells wrap, and a table wider than the screen scrolls inside itself.
    private func tableView(_ table: ChatMarkdownTable) -> some View {
        let widths = table.columnWidths()
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, text in
                        tableCell(text, width: widths[column], alignment: table.alignments[column])
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .background(PocketPalette.inset)
                ForEach(Array(table.rows.prefix(Self.maximumTableRows).enumerated()), id: \.offset) { _, row in
                    Divider()
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, text in
                            tableCell(text, width: widths[column], alignment: table.alignments[column])
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
        }
        .accessibilityElement(children: .contain)
    }

    /// More rows than this are left out on the phone; the whole message is in its long view and on the web.
    private static let maximumTableRows = 200

    private func tableCell(_ text: String, width: Double, alignment: ChatMarkdownTable.Alignment) -> some View {
        let frameAlignment: Alignment
        let textAlignment: TextAlignment
        switch alignment {
        case .leading: (frameAlignment, textAlignment) = (.leading, .leading)
        case .center: (frameAlignment, textAlignment) = (.center, .center)
        case .trailing: (frameAlignment, textAlignment) = (.trailing, .trailing)
        }
        return inline(text)
            .multilineTextAlignment(textAlignment)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: width, alignment: frameAlignment)
    }

    private func inline(_ text: String) -> some View {
        Text(ChatInlineMarkdown.attributed(text, ownHandles: ownHandles))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Inline Markdown with the web's rules applied:
/// - links: only http(s) to a real host stay tappable (`RoomLinkPolicy`); bare URLs are linked like GFM autolinks;
/// - GitHub pull-request links read as `owner/repo#n` chips (custom link text becomes "text · owner/repo#n");
/// - `@handle` mentions are highlighted, and mentions of you stand out more;
/// - code spans are left alone.
enum ChatInlineMarkdown {
    static func attributed(_ text: String, ownHandles: Set<String> = []) -> AttributedString {
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
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>()\[\]]+"#) else { return }
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
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|(?<=\s))@([A-Za-z0-9_-]+)"#) else { return }
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
