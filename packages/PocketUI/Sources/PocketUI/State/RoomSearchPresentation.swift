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

    public static let minimumQueryLength = 2

    public init(
        query: String = "",
        rows: [RoomSearchRow] = [],
        isSearching: Bool = false,
        isLoadingMore: Bool = false,
        hasMore: Bool = false,
        message: String? = nil
    ) {
        self.query = query
        self.rows = rows
        self.isSearching = isSearching
        self.isLoadingMore = isLoadingMore
        self.hasMore = hasMore
        self.message = message
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
}
