import Foundation

/// One search match in the list: who wrote it and when, and the text around the match.
public struct RoomSearchRow: Equatable, Identifiable, Sendable {
    public var id: Int64 { sequenceId }
    public let sequenceId: Int64
    public let author: String?
    public let isHuman: Bool
    public let date: Date?
    public let snippet: String

    public init(sequenceId: Int64, author: String?, isHuman: Bool, date: Date?, snippet: String) {
        self.sequenceId = sequenceId
        self.author = author
        self.isHuman = isHuman
        self.date = date
        self.snippet = snippet
    }
}

/// What the search looks through (Carter, #55006: one search across everything, narrowed by tabs): everything,
/// the messages, the people, or one kind of thing the room has shared.
public enum RoomSearchScope: Hashable, Sendable {
    case all
    case messages
    case people
    case artifacts(RoomArtifact.Kind)

    /// The tabs, in order.
    public static let tabs: [RoomSearchScope] = [.all, .messages, .people, .artifacts(.ticket), .artifacts(.pullRequest),
                                                 .artifacts(.file), .artifacts(.checkpoint), .artifacts(.link), .artifacts(.code)]

    public var title: String {
        switch self {
        case .all: return "All"
        case .messages: return "Messages"
        case .people: return "People"
        case .artifacts(let kind): return kind.title
        }
    }

    /// The server's message search runs for these.
    public var searchesMessages: Bool { self == .all || self == .messages }
}

/// Someone in the room, to find what they wrote ("more from").
public struct RoomSearchPerson: Equatable, Identifiable, Sendable {
    /// Their author id: `human-<login>` for a person, the agent's id for an agent.
    public let authorId: String
    public let name: String
    public let isHuman: Bool
    public var id: String { authorId.lowercased() }

    public init(authorId: String, name: String, isHuman: Bool) {
        self.authorId = authorId
        self.name = name
        self.isHuman = isHuman
    }
}

/// The room's search, like the web's: run on submit with at least 2 characters, newest match first, more on demand.
public struct RoomSearchPresentationState: Equatable, Sendable {
    /// The query the results are for.
    public let query: String
    public let rows: [RoomSearchRow]
    public let isSearching: Bool
    public let isLoadingMore: Bool
    public let hasMore: Bool
    /// What to say instead of results: a hint, "no matches", or why the search failed.
    public let message: String?
    public let scope: RoomSearchScope
    /// Only messages from this person.
    public let from: RoomSearchPerson?
    /// The people whose name matches.
    public let people: [RoomSearchPerson]
    /// The tickets, pull requests, files, checkpoints, links and code the room shared that match.
    public let artifacts: [RoomArtifact]
    /// The room's shared things are still being read.
    public let isReadingArtifacts: Bool

    public static let minimumQueryLength = 2

    public init(
        query: String = "",
        rows: [RoomSearchRow] = [],
        isSearching: Bool = false,
        isLoadingMore: Bool = false,
        hasMore: Bool = false,
        message: String? = nil,
        scope: RoomSearchScope = .all,
        from: RoomSearchPerson? = nil,
        people: [RoomSearchPerson] = [],
        artifacts: [RoomArtifact] = [],
        isReadingArtifacts: Bool = false
    ) {
        self.query = query
        self.rows = rows
        self.isSearching = isSearching
        self.isLoadingMore = isLoadingMore
        self.hasMore = hasMore
        self.message = message
        self.scope = scope
        self.from = from
        self.people = people
        self.artifacts = artifacts
        self.isReadingArtifacts = isReadingArtifacts
    }

    /// Every word of the query is in the text, ignoring case and accents. An empty query matches nothing.
    public static func matches(_ query: String, in texts: [String?]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return false }
        let haystack = texts.compactMap { $0 }.joined(separator: " ")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The people and shared things that match the words, for this tab.
    public static func localMatches(query: String, scope: RoomSearchScope, people: [RoomSearchPerson],
                                    artifacts: [RoomArtifact]) -> (people: [RoomSearchPerson], artifacts: [RoomArtifact]) {
        let matchedPeople: [RoomSearchPerson]
        switch scope {
        case .all, .people:
            matchedPeople = people.filter { matches(query, in: [$0.name, $0.authorId]) }
        case .messages, .artifacts:
            matchedPeople = []
        }
        let matchedArtifacts: [RoomArtifact]
        switch scope {
        case .all:
            matchedArtifacts = artifacts.filter { matches(query, in: [$0.title, $0.detail, $0.url?.absoluteString]) }
        case .artifacts(let kind):
            matchedArtifacts = artifacts.filter { $0.kind == kind && matches(query, in: [$0.title, $0.detail, $0.url?.absoluteString]) }
        case .messages, .people:
            matchedArtifacts = []
        }
        return (matchedPeople, matchedArtifacts)
    }

    /// A snippet as it reads, not as it was typed. The server sends one line of about 80 characters around the match,
    /// cut anywhere. Only marks that cannot be anything else go: bold's `**`, a link's brackets and address, a code span's
    /// backticks, a fence's ``` wherever it stands, heading, quote and list marks where a line starts, a table's pipes
    /// and divider. Code is left as written (`2*3*4`, `__init__.py`, `packages/*/Sources`, `>= 3`, pipes inside
    /// backticks). When cleaning would hide a word that was searched for, or leave nothing, the snippet is shown as it
    /// came. A long text (a whole message, when the server sent no snippet) is cut to the part around the match first.
    public static func plainSnippet(_ snippet: String, query: String = "") -> String {
        let raw = collapse(window(snippet, around: query))
        var unfenced = raw
        for fence in [#"```[A-Za-z0-9_+.-]*"#, #"~~~[A-Za-z0-9_+.-]*"#] {
            unfenced = unfenced.replacingOccurrences(of: fence, with: " ", options: .regularExpression)
        }
        // Between backticks is code, kept as written without its backticks; the rest is cleaned.
        var cleaned = ""
        for (index, part) in unfenced.components(separatedBy: "`").enumerated() {
            cleaned += index.isMultiple(of: 2) ? clean(part, atStart: index == 0) : part
        }
        let plain = collapse(cleaned)
        guard !plain.isEmpty else { return raw }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let hidden = words.contains { contains(raw, $0) && !contains(plain, $0) }
        return hidden ? raw : plain
    }

    /// Marks anywhere: a link or image (its words), **bold**, a table's divider row and its pipes.
    private static let inlineMarks: [(String, String)] = [
        (#"!?\[([^\]\n]*)\]\([^)\s]*\)"#, "$1"),
        (#"(?<![\w*])\*\*(?=\S)([^*\n]+?)(?<=\S)\*\*(?![\w*])"#, "$1"),
        (#"\|?(?:[ \t]*:?-+:?[ \t]*\|)+[ \t]*:?-+:?[ \t]*\|?"#, " "),
        (#"(?:^|(?<=[ \t]))\|(?=[ \t]|$)"#, " "),
    ]
    /// Marks only where the snippet starts: a heading's, a quote's, a list's.
    private static let startMarks: [(String, String)] = [
        (#"^[ \t]*#{1,6}[ \t]+"#, ""),
        (#"^[ \t]*(?:>[ \t]+)+"#, ""),
        (#"^[ \t]*(?:[-*+]|\d{1,3}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?"#, ""),
    ]

    private static func clean(_ text: String, atStart: Bool) -> String {
        (atStart ? startMarks + inlineMarks : inlineMarks)
            .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression) }
    }

    private static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static func contains(_ text: String, _ word: String) -> Bool {
        text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// At most about 320 characters of a long text: around the first match, else its start.
    static func window(_ text: String, around query: String, radius: Int = 160) -> String {
        guard text.count > 2 * radius + 80 else { return text }
        let needle = query.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard !needle.isEmpty,
              let match = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(text.prefix(2 * radius))
        }
        let lower = text.index(match.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(match.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[lower..<upper])
    }

    /// The text before the match, the match, and the text after it (case-insensitive, first match), so a list can
    /// mark what was found; nil when the query is not in the snippet.
    public static func highlight(_ snippet: String, query: String) -> (before: String, match: String, after: String)? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty,
              let range = snippet.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        return (String(snippet[..<range.lowerBound]), String(snippet[range]), String(snippet[range.upperBound...]))
    }
}

public enum RoomSearchIntent: Equatable, Sendable {
    case submit(String)
    /// The words changed: search once typing pauses.
    case typed(String)
    case loadMore
    /// Go to the message in the room.
    case open(sequenceId: Int64)
    /// Look through everything, or one kind.
    case scope(RoomSearchScope)
    /// Only what this person wrote ("more from"); nil for everyone.
    case from(RoomSearchPerson?)
    /// Open a shared thing: a ticket over the room, anything else at its message.
    case openArtifact(RoomArtifact)
}
