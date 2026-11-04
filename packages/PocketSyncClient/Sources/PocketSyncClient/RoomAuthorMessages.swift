import Foundation
import PocketContracts

// One person's or agent's messages in a room, source-bound to sentinelayer-api
// `GET /api/v1/sessions/{id}/events/by-author` (#1136): newest first, paged by `before_sequence` (exclusive), each row
// exactly an `/events/before` row, and once per answer how the author's latest post came in.

/// How someone's latest post reached the room, as the API reads it (`connection`). A display hint, never authority: the
/// API stores no marker for a person's own posts, so for people it is usually unknown.
public enum RoomAuthorConnection: String, Equatable, Sendable {
    case mcp
    case box
    case app
    case web
    case cli
}

/// A page of one author's messages, newest first.
public struct RoomAuthorPage: Decodable, Equatable, Sendable {
    /// The author's messages on this page, newest first, decoded as `/events/before` rows.
    public let messages: [RoomMessage]
    /// Where the next (older) page starts; nil once the page reaches the start of the room: there is no more.
    public let nextBeforeSequence: Int64?
    /// Nil when the API does not know (or says something this app does not): shown as nothing, never as a guess.
    public let connection: RoomAuthorConnection?

    public init(messages: [RoomMessage], nextBeforeSequence: Int64? = nil, connection: RoomAuthorConnection? = nil) {
        self.messages = messages
        self.nextBeforeSequence = nextBeforeSequence
        self.connection = connection
    }

    enum CodingKeys: String, CodingKey { case connection }

    public init(from decoder: Decoder) throws {
        // The rows and the cursor are `/events/before`'s (its decoder reads `nextBeforeSequence` too).
        let page = try RoomEventPage(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? container.decodeIfPresent(String.self, forKey: .connection)) ?? nil
        self.init(
            messages: page.messages,
            nextBeforeSequence: page.nextBeforeSequence,
            connection: raw.flatMap { RoomAuthorConnection(rawValue: $0.lowercased()) }
        )
    }
}

public enum RoomAuthor {
    /// How a public room shows a person to a reader outside it (`human-public.<digest>`). The API answers an empty page
    /// for that id, by design: people's messages are private there.
    public static func isPublicAlias(_ authorId: String) -> Bool {
        authorId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("human-public.")
    }

    /// An id the API matches an author by: the row-carried form (`human-<login>`, `human-g.<hex>`, an agent id).
    static func isValidId(_ authorId: String) -> Bool {
        authorId.range(of: #"^[A-Za-z0-9._:@-]{1,128}$"#, options: .regularExpression) != nil
    }
}

/// Reading one author's messages. A protocol so the member view is testable without a network.
public protocol RoomAuthorMessagesReading: Sendable {
    func roomMessages(by authorId: String, sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomAuthorPage
}

extension HTTPSessionTransport: RoomAuthorMessagesReading {
    /// `GET /events/by-author?author=&before_sequence=&limit=` (1...50). The cursor's name is the API's own snake case
    /// here, unlike `/events/before`'s `beforeSequence`.
    public func roomMessages(by authorId: String, sessionId: String, beforeSequence: Int64? = nil,
                             limit: Int = 20) async throws -> RoomAuthorPage {
        try Self.requireIdentifier(sessionId)
        try Self.requireLimit(limit, allowed: 1...50)
        guard RoomAuthor.isValidId(authorId) else { throw SessionTransportError.invalidRequest }
        if let beforeSequence, beforeSequence < 1 { throw SessionTransportError.invalidRequest }
        return try await getDecodable(
            RoomAuthorPage.self,
            path: ["api", "v1", "sessions", sessionId, "events", "by-author"],
            query: [
                URLQueryItem(name: "author", value: authorId),
                beforeSequence.map { URLQueryItem(name: "before_sequence", value: String($0)) },
                URLQueryItem(name: "limit", value: String(limit))
            ].compactMap { $0 }
        )
    }
}
