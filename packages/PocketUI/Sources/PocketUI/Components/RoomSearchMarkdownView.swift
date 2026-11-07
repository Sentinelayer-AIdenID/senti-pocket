#if canImport(SwiftUI)
import SwiftUI

/// Full Markdown for the selected search result. Normal messages keep their existing renderer and view tree.
/// Parsing, inline attributes and quote layout are shared with `ChatMarkdownView`.
struct RoomSearchMarkdownView: View {
    let text: String
    let ownHandles: Set<String>
    let focus: RoomSearchFocus

    var body: some View {
        RoomSearchMarkdownBlocksView(blocks: ChatMarkdownCache.blocks(for: text), ownHandles: ownHandles,
                                     searchFocus: focus)
    }
}

/// One ticket link as its own row, like the web's ticket chip: one line, cut with "…", and it opens the ticket.
private struct RoomSearchTicketLinkRow: View {
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

private struct RoomSearchMarkdownBlocksView: View {
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
                        RoomSearchTicketLinkRow(ticket: ticket, searchFocus: searchFocus,
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
                RoomSearchMarkdownBlocksView(blocks: inner, ownHandles: ownHandles, searchFocus: searchFocus,
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
        RoomSearchMarkdownTableView(table: table, ownHandles: ownHandles, searchFocus: searchFocus,
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
private struct RoomSearchMarkdownTableView: View {
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

#endif
