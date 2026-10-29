import Foundation
import PocketContracts

// Searching a room's messages (sentinelayer-api `GET /sessions/{id}/events/search`), as the web does: a query of 2 to
// 160 characters, newest matches first, pages of up to 50 paged back with `beforeSequence`.

/// One match: where it is in the room, the text around it, and the row itself when it is a chat row.
public struct RoomSearchResult: Equatable, Identifiable, Sendable {
    public var id: Int64 { sequenceId }
    public let sequenceId: Int64
    /// The text around the match, as the API cut it.
    public let snippet: String
    /// Which part matched (the message text, the author, ...), when the API says.
    public let matchedField: String?
    /// The matched row, when it is one the room shows (author and time for the result list).
    public let message: RoomMessage?

    public init(sequenceId: Int64, snippet: String, matchedField: String? = nil, message: RoomMessage? = nil) {
        self.sequenceId = sequenceId
        self.snippet = snippet
        self.matchedField = matchedField
        self.message = message
    }

    init?(json: JSONValue) {
        guard let sequenceId = json["sequenceId"]?.intValue, sequenceId > 0 else { return nil }
        let snippet = (json["snippet"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let message = json["event"].flatMap(RoomMessage.init(json:))
        guard !snippet.isEmpty || message != nil else { return nil }
        self.init(
            sequenceId: sequenceId,
            snippet: snippet.isEmpty ? (message?.text ?? "") : snippet,
            matchedField: json["matchedField"]?.stringValue,
            message: message
        )
    }
}

public struct RoomSearchPage: Decodable, Equatable, Sendable {
    public let query: String
    /// Newest match first.
    public let results: [RoomSearchResult]
    /// Where the next page starts, when there is one.
    public let nextBeforeSequence: Int64?

    public var hasMore: Bool { nextBeforeSequence != nil }

    public init(query: String, results: [RoomSearchResult] = [], nextBeforeSequence: Int64? = nil) {
        self.query = query
        self.results = results
        self.nextBeforeSequence = nextBeforeSequence
    }

    enum CodingKeys: String, CodingKey {
        case query, results
        case nextBeforeSequence = "next_before_sequence"
        case hasMore = "has_more"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = (try? container.decode(String.self, forKey: .query)) ?? ""
        let rows = (try? container.decode([JSONValue].self, forKey: .results)) ?? []
        var seen = Set<Int64>()
        results = rows.compactMap(RoomSearchResult.init(json:)).filter { seen.insert($0.sequenceId).inserted }
        let hasMore = (try? container.decode(Bool.self, forKey: .hasMore)) ?? false
        let next = try? container.decode(Int64.self, forKey: .nextBeforeSequence)
        nextBeforeSequence = hasMore ? next.flatMap { $0 > 0 ? $0 : nil } : nil
    }
}

/// A protocol so the room's search is testable without a network.
public protocol RoomSearching: Sendable {
    func searchRoom(sessionId: String, query: String, beforeSequence: Int64?, limit: Int) async throws -> RoomSearchPage
}

extension HTTPSessionTransport: RoomSearching {
    public static let searchQueryLength = 2...160

    public func searchRoom(sessionId: String, query: String, beforeSequence: Int64?, limit: Int) async throws -> RoomSearchPage {
        try Self.requireIdentifier(sessionId)
        try Self.requireLimit(limit, allowed: 1...50)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Counted in code points, as the API counts (Python len).
        guard Self.searchQueryLength.contains(trimmed.unicodeScalars.count) else { throw SessionTransportError.invalidRequest }
        if let beforeSequence, beforeSequence < 1 { throw SessionTransportError.invalidRequest }
        return try await getDecodable(
            RoomSearchPage.self,
            path: ["api", "v1", "sessions", sessionId, "events", "search"],
            query: [
                URLQueryItem(name: "q", value: trimmed),
                beforeSequence.map { URLQueryItem(name: "beforeSequence", value: String($0)) },
                URLQueryItem(name: "limit", value: String(limit))
            ].compactMap { $0 }
        )
    }
}
