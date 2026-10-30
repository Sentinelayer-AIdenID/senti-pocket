import Foundation

/// Block-level Markdown for chat and ticket bodies, matching what the web renders (sentinelayer-web
/// `assistant-markdown.tsx` at d479a03: react-markdown + remark-gfm, no raw HTML): paragraphs, headings, lists,
/// block quotes, fenced code and rules. Inline styling (bold, italics, code, strikethrough, links) is applied per
/// block by `ChatInlineMarkdown`. Pure and line-based, so it is unit-tested without SwiftUI.
public enum ChatMarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(ordered: Bool, start: Int, items: [ChatMarkdownListItem])
    case quote([ChatMarkdownBlock])
    case code(language: String?, text: String)
    case rule
    case table(ChatMarkdownTable)
}

/// A GitHub-style table: a header row, a delimiter row that sets each column's alignment, then body rows. Every row
/// has the header's number of cells (short rows are filled, extra cells dropped), as GitHub renders them.
public struct ChatMarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }

    public let header: [String]
    public let alignments: [Alignment]
    public let rows: [[String]]

    /// A column's width on screen: as wide as its longest cell reads, up to `maximum`, so long cells wrap.
    public func columnWidths(perCharacter: Double = 7.6, padding: Double = 20, minimum: Double = 56, maximum: Double = 240) -> [Double] {
        header.indices.map { column in
            let longest = ([header] + rows).map { $0[column].count }.max() ?? 0
            return min(max(Double(longest) * perCharacter + padding, minimum), maximum)
        }
    }
}

public struct ChatMarkdownListItem: Equatable, Sendable {
    public let depth: Int
    public let text: String

    /// A GitHub task item's state and text: "[ ] open" or "[x] done".
    public static func task(_ text: String) -> (done: Bool, text: String)? {
        guard text.count >= 4, text.hasPrefix("["), text.dropFirst(2).first == "]", text.dropFirst(3).first == " " else {
            return nil
        }
        switch text.dropFirst().first {
        case " ": return (false, String(text.dropFirst(4)))
        case "x", "X": return (true, String(text.dropFirst(4)))
        default: return nil
        }
    }
}

public enum ChatMarkdown {
    /// Bodies longer than this are parsed only up to the limit; the rest renders as one plain paragraph so a huge
    /// paste cannot stall the main thread.
    public static let maximumParsedCharacters = 32_000

    public static func parse(_ source: String) -> [ChatMarkdownBlock] {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var overflow: String?
        if text.count > maximumParsedCharacters {
            let cut = text.index(text.startIndex, offsetBy: maximumParsedCharacters)
            overflow = String(text[cut...])
            text = String(text[..<cut])
        }
        var blocks = parseLines(text.components(separatedBy: "\n"))
        if let overflow, !overflow.isEmpty { blocks.append(.paragraph(overflow)) }
        return blocks
    }

    private static func parseLines(_ lines: [String]) -> [ChatMarkdownBlock] {
        var blocks: [ChatMarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let joined = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let fence = codeFence(trimmed) {
                flushParagraph()
                var body: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence.marker) && candidate.allSatisfy({ $0 == fence.marker.first }) {
                        index += 1
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var inner = String(candidate.dropFirst())
                    if inner.hasPrefix(" ") { inner.removeFirst() }
                    quoted.append(inner)
                    index += 1
                }
                blocks.append(.quote(parseLines(quoted)))
                continue
            }

            if let table = table(lines, at: index) {
                flushParagraph()
                blocks.append(.table(table.table))
                index = table.next
                continue
            }

            if let first = listItem(line) {
                flushParagraph()
                var items: [ChatMarkdownListItem] = [ChatMarkdownListItem(depth: first.depth, text: first.text)]
                index += 1
                while index < lines.count, let next = listItem(lines[index]), next.ordered == first.ordered {
                    items.append(ChatMarkdownListItem(depth: next.depth, text: next.text))
                    index += 1
                }
                blocks.append(.list(ordered: first.ordered, start: first.number ?? 1, items: items))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func codeFence(_ line: String) -> (marker: String, language: String?)? {
        for marker in ["```", "~~~"] where line.hasPrefix(marker) {
            let info = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            let language = info.split(separator: " ").first.map(String.init)
            return (marker, language?.isEmpty == false ? language : nil)
        }
        return nil
    }

    private static func heading(_ line: String) -> ChatMarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
        return .heading(level: hashes.count, text: text)
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// A table starts where a line with a pipe is followed by a delimiter row of as many cells (`| --- | :-: |`), and
    /// runs until a blank line or a line without a pipe.
    private static func table(_ lines: [String], at index: Int) -> (table: ChatMarkdownTable, next: Int)? {
        guard index + 1 < lines.count, lines[index].contains("|") else { return nil }
        let header = tableCells(lines[index])
        guard !header.isEmpty, let alignments = tableAlignments(lines[index + 1]), alignments.count == header.count else {
            return nil
        }
        var rows: [[String]] = []
        var next = index + 2
        while next < lines.count {
            let line = lines[next]
            guard line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            let cells = tableCells(line)
            rows.append(Array((cells + Array(repeating: "", count: max(0, header.count - cells.count))).prefix(header.count)))
            next += 1
        }
        return (ChatMarkdownTable(header: header, alignments: alignments, rows: rows), next)
    }

    /// A row's cells: split on pipes not escaped with a backslash, the outer pipes optional, each cell trimmed.
    private static func tableCells(_ line: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped {
                // An escaped pipe is a pipe in the cell; any other escape stays for the inline Markdown.
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|"), !cells.isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The delimiter row's alignments (`---`, `:--`, `:-:`, `--:`), or nil when the line is not one.
    private static func tableAlignments(_ line: String) -> [ChatMarkdownTable.Alignment]? {
        guard line.contains("-") else { return nil }
        let cells = tableCells(line)
        guard !cells.isEmpty, line.contains("|") else { return nil }
        var alignments: [ChatMarkdownTable.Alignment] = []
        for cell in cells {
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            let dashes = cell.dropFirst(left ? 1 : 0).dropLast(right && cell.count > 1 ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? .center : (right ? .trailing : .leading))
        }
        return alignments
    }

    private static func listItem(_ line: String) -> (ordered: Bool, number: Int?, depth: Int, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.dropFirst(indent.count)
        if let marker = body.first, "-*+".contains(marker), body.dropFirst().first == " " {
            let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : (false, nil, min(width / 2, 4), text)
        }
        let digits = body.prefix { $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let afterDigits = body.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (true, Int(digits), min(width / 2, 4), text)
    }
}

/// Recognisers shared by the chat renderer: GitHub pull-request links (rendered as `owner/repo#n` chips), Senti
/// ticket links, and @-mentions. All match the web's exact rules.
public enum ChatReferences {
    public struct PullRequest: Equatable, Sendable {
        public let owner: String
        public let repo: String
        public let number: Int
        public var label: String { "\(owner)/\(repo)#\(number)" }
    }

    /// `https://github.com/<owner>/<repo>/pull/<n>` exactly: no port, userinfo, or extra path (web
    /// `githubPullRequest.ts`).
    public static func pullRequest(_ url: URL) -> PullRequest? {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.port == nil, url.user == nil, url.password == nil else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard parts.count == 4, parts[parts.startIndex + 2] == "pull" else { return nil }
        let owner = String(parts[parts.startIndex])
        let repo = String(parts[parts.startIndex + 1])
        let numberText = String(parts[parts.startIndex + 3])
        guard owner.range(of: #"^[A-Za-z0-9-]{1,39}$"#, options: .regularExpression) != nil,
              repo.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              repo != ".", repo != "..",
              numberText.range(of: #"^[1-9][0-9]{0,9}$"#, options: .regularExpression) != nil,
              let number = Int(numberText) else { return nil }
        return PullRequest(owner: owner, repo: repo, number: number)
    }

    /// A ticket link in a message, shown as its own row (the web's ticket chip).
    public struct TicketLink: Equatable, Sendable {
        /// The link's text without a leading "Ticket: ".
        public let title: String
        public let ticketId: String
        /// Absolute, so the room's link handling opens the ticket in the app.
        public let url: URL
    }

    /// Pulls a paragraph's ticket links (`[Ticket: title](/dashboard/sessions/<room>?ticket=<id>)`, also with
    /// `https://sentinelayer.com` in front) out of the text, with the "·" between them: the ticket keeper writes
    /// several on one line, and they read better one per row. Returns the text that is left and the links, in order.
    public static func ticketLinks(in paragraph: String) -> (prose: String, tickets: [TicketLink]) {
        guard paragraph.contains("?ticket=") else { return (paragraph, []) }
        let pattern = #"\[([^\]\n]{1,300})\]\(((?:https://(?:www\.)?sentinelayer\.com)?/dashboard/sessions/[^)\s]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (paragraph, []) }
        let whole = NSRange(paragraph.startIndex..., in: paragraph)
        var tickets: [TicketLink] = []
        var removed: [Range<String.Index>] = []
        for match in regex.matches(in: paragraph, range: whole) {
            guard let all = Range(match.range, in: paragraph),
                  let labelRange = Range(match.range(at: 1), in: paragraph),
                  let hrefRange = Range(match.range(at: 2), in: paragraph) else { continue }
            var href = String(paragraph[hrefRange])
            for prefix in ["https://sentinelayer.com", "https://www.sentinelayer.com"] where href.hasPrefix(prefix) {
                href = String(href.dropFirst(prefix.count))
            }
            guard let found = ticket(href), let url = URL(string: "https://sentinelayer.com" + href) else { continue }
            var title = String(paragraph[labelRange]).trimmingCharacters(in: .whitespaces)
            if title.lowercased().hasPrefix("ticket:") {
                title = String(title.dropFirst("ticket:".count)).trimmingCharacters(in: .whitespaces)
            }
            tickets.append(TicketLink(title: title.isEmpty ? "Ticket" : title, ticketId: found.ticketId, url: url))
            removed.append(all)
        }
        guard !tickets.isEmpty else { return (paragraph, []) }
        var prose = ""
        var cursor = paragraph.startIndex
        for range in removed {
            prose += paragraph[cursor..<range.lowerBound]
            cursor = range.upperBound
        }
        prose += paragraph[cursor...]
        // The separators that stood between the links go with them.
        let cleaned = prose
            .replacingOccurrences(of: #"(\s*·\s*)+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(\s*·\s*){2,}"#, with: " · ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, tickets)
    }

    /// The Senti ticket a link opens, for in-app links of the form `/dashboard/sessions/<room>?ticket=<id>`.
    public static func ticket(_ href: String) -> (sessionId: String, ticketId: String)? {
        guard href.range(of: #"^/dashboard/sessions/[^/?#]+\?ticket=[^&#]+$"#, options: .regularExpression) != nil,
              let components = URLComponents(string: href),
              let sessionId = components.path.split(separator: "/").last.map(String.init),
              let ticketId = components.queryItems?.first(where: { $0.name == "ticket" })?.value,
              ticketId.range(of: #"^[A-Za-z0-9._:-]{1,128}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return (sessionId, ticketId)
    }

    private static let mentionExpression = try? NSRegularExpression(pattern: #"(?:^|\s)@([A-Za-z0-9_-]+)"#)

    /// Ranges of `@handle` mentions: an `@` at the start or after whitespace, then letters, digits, `_` or `-`
    /// (web `extractMentions.ts`). Returned as UTF-16 offsets for AttributedString styling.
    public static func mentionHandles(in text: String) -> [String] {
        // Most messages mention no one: skip the expression entirely (this runs for every agent message per update).
        guard text.contains("@"), let regex = mentionExpression else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var handles: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let handleRange = Range(match.range(at: 1), in: text) else { continue }
            let handle = text[handleRange].lowercased()
            if seen.insert(handle).inserted { handles.append(handle) }
        }
        return handles
    }
}
