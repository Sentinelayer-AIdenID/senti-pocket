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
