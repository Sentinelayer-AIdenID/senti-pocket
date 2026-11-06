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
    /// A stand-in name (`human-public.<digest>`). When you read a public room you are not a member of, the API shows a
    /// person who signed in with an account id (`human-<uuid>`, `human-g.<hex>`) under a stand-in name made for that
    /// room; people known by their login (`human-<login>`) and agents keep their own ids. Rows are stored under the real
    /// id, so asking for a stand-in name finds nothing.
    public static func isPublicAlias(_ authorId: String) -> Bool {
        authorId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("human-public.")
    }

    /// An id the API accepts for `author`, exactly its own agent-id rule: a letter or digit first, then up to 63 more
    /// of letters, digits, `.`, `_`, `:` and `-` (64 at most, no `@`).
    static func isValidId(_ authorId: String) -> Bool {
        authorId.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$"#, options: .regularExpression) != nil
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
