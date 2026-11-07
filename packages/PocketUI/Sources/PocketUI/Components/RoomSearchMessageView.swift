#if canImport(SwiftUI)
import SwiftUI

/// The selected result uses the normal Markdown renderer in full, with its existing links, code and mentions.
struct RoomSearchMessageView: View {
    let text: String
    let focus: RoomSearchFocus
    let ownHandles: Set<String>
    let onReveal: () -> Void

    var body: some View {
        ChatMarkdownView(text: text, ownHandles: ownHandles, searchFocus: focus)
        .accessibilityIdentifier("pocket.search.expanded.\(focus.sequenceId)")
        .task(id: focus.id) {
            // The outer list first materializes the row. Then its inner match can be reached.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            onReveal()
        }
    }
}

/// Highlight the rendered characters, leaving Markdown's links, fonts and mention attributes intact.
enum RoomSearchMarkdown {
    struct Highlighted {
        let value: AttributedString
        let prefix: AttributedString?
        let firstMatch: String?
    }

    static func highlight(_ original: AttributedString, query: String) -> Highlighted {
        var value = original
        var cursor = value.startIndex
        var prefix: AttributedString?
        var firstMatch: String?
        for fragment in RoomSearchText.fragments(String(original.characters), query: query) {
            let end = value.characters.index(cursor, offsetBy: fragment.text.count)
            if fragment.isMatch {
                if prefix == nil {
                    prefix = AttributedString(original[original.startIndex..<cursor])
                    firstMatch = fragment.text
                }
                value[cursor..<end].swiftUI.backgroundColor = Color.yellow.opacity(0.45)
            }
            cursor = end
        }
        return Highlighted(value: value, prefix: prefix, firstMatch: firstMatch)
    }

    static func contains(_ value: AttributedString, query: String) -> Bool {
        RoomSearchText.fragments(String(value.characters), query: query).contains(where: \.isMatch)
    }

    static func containsInline(_ text: String, query: String, ownHandles: Set<String>) -> Bool {
        contains(ChatInlineMarkdown.attributed(text, ownHandles: ownHandles), query: query)
    }

    static func contains(_ block: ChatMarkdownBlock, query: String, ownHandles: Set<String>) -> Bool {
        switch block {
        case .paragraph(let text):
            let split = ChatReferences.ticketLinks(in: text)
            return containsInline(split.prose, query: query, ownHandles: ownHandles)
                || split.tickets.contains { contains(AttributedString($0.title), query: query) }
        case .heading(_, let text):
            return containsInline(text, query: query, ownHandles: ownHandles)
        case .list(_, _, let items):
            return items.contains { containsInline(ChatMarkdownListItem.task($0.text)?.text ?? $0.text,
                                                   query: query, ownHandles: ownHandles) }
        case .quote(let blocks), .deeperQuote(_, let blocks):
            return blocks.contains { contains($0, query: query, ownHandles: ownHandles) }
        case .code(_, let text):
            return contains(AttributedString(text), query: query)
        case .table(let table):
            return firstMatch(in: table, query: query, ownHandles: ownHandles) != nil
        case .rule:
            return false
        }
    }

    static func firstMatch(in table: ChatMarkdownTable, query: String, ownHandles: Set<String>) -> (row: Int, column: Int)? {
        for (column, text) in table.header.enumerated() where containsInline(text, query: query, ownHandles: ownHandles) {
            return (-1, column)
        }
        for (row, cells) in table.rows.enumerated() {
            for (column, text) in cells.enumerated() where containsInline(text, query: query, ownHandles: ownHandles) {
                return (row, column)
            }
        }
        return nil
    }
}

/// A selected text leaf keeps its original layout. An invisible copy of its attributed prefix locates the match
/// even in one very long paragraph; it has the same width and inherited font and adds no layout height or state.
/// The anchor is within one text line of the match, so centering it brings the actual words into view.
struct RoomSearchAttributedText: View {
    let value: AttributedString
    let focus: RoomSearchFocus?
    var anchorsMatch = false

    var body: some View {
        if let focus {
            let marked = RoomSearchMarkdown.highlight(value, query: focus.query)
            Text(marked.value)
            .overlay(alignment: .topLeading) {
                if anchorsMatch, let prefix = marked.prefix, let match = marked.firstMatch {
                    Group {
                        if prefix.characters.isEmpty {
                            matchAnchor(focus, text: match)
                        } else {
                            Text(prefix)
                                .fixedSize(horizontal: false, vertical: true)
                                .hidden()
                                .accessibilityHidden(true)
                                .overlay(alignment: .bottomTrailing) { matchAnchor(focus, text: match) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
                }
            }
        } else {
            Text(value)
        }
    }

    private func matchAnchor(_ focus: RoomSearchFocus, text: String) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .id(focus.anchor)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Search match: \(text)")
            .accessibilityIdentifier("pocket.search.match.\(focus.sequenceId)")
    }
}
#endif
