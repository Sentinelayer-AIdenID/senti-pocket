import Foundation
import PocketContracts

// The rooms you share with someone, source-bound to sentinelayer-api `GET /api/v1/me/shared-rooms` (ticket ab3c079b):
// the rooms you are a member of and may read in which they take part (a person by membership; an agent by posting there
// or by an active admission), newest first by their latest activity, a page at a time, with how many in all.

/// One room you share with someone.
public struct SharedRoom: Decodable, Equatable, Sendable {
    public let sessionId: String
    public let title: String
    /// When they were last active in it (ISO-8601), as the API says; nil when it does not.
    public let lastActiveAt: String?

    public init(sessionId: String, title: String, lastActiveAt: String? = nil) {
        self.sessionId = sessionId
        self.title = title
        self.lastActiveAt = lastActiveAt
    }

    enum CodingKeys: String, CodingKey { case sessionId, title, lastActiveAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        lastActiveAt = (try? container.decodeIfPresent(String.self, forKey: .lastActiveAt)) ?? nil
    }
}

/// A page of the rooms you share with someone, newest first.
public struct SharedRoomsPage: Decodable, Equatable, Sendable {
    public let rooms: [SharedRoom]
    /// How many rooms you share in all, not just this page.
    public let total: Int
    /// Where the next page starts; nil on the last page.
    public let nextCursor: String?

    public init(rooms: [SharedRoom], total: Int? = nil, nextCursor: String? = nil) {
        self.rooms = rooms
        self.total = max(total ?? rooms.count, rooms.count)
        self.nextCursor = nextCursor
    }

    enum CodingKeys: String, CodingKey { case rooms, total, nextCursor }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rooms = try container.decode([SharedRoom].self, forKey: .rooms)
        let total = (try? container.decodeIfPresent(Int.self, forKey: .total)) ?? nil
        let next = (try? container.decodeIfPresent(String.self, forKey: .nextCursor)) ?? nil
        self.init(rooms: rooms, total: total, nextCursor: next.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// Reading the rooms you share with someone. A protocol so the card is testable without a network.
public protocol SharedRoomsReading: Sendable {
    func sharedRooms(with principal: String, cursor: String?, limit: Int) async throws -> SharedRoomsPage
}

extension HTTPSessionTransport: SharedRoomsReading {
    /// `GET /api/v1/me/shared-rooms?with=&limit=&cursor=` (1...50). `with` is a room author id, checked by the API's own
    /// rule before anything is sent.
    public func sharedRooms(with principal: String, cursor: String? = nil, limit: Int = 20) async throws -> SharedRoomsPage {
        try Self.requireLimit(limit, allowed: 1...50)
        guard RoomAuthor.isValidId(principal) else { throw SessionTransportError.invalidRequest }
        if let cursor, cursor.isEmpty || cursor.utf8.count > 512 { throw SessionTransportError.invalidRequest }
        return try await getDecodable(
            SharedRoomsPage.self,
            path: ["api", "v1", "me", "shared-rooms"],
            query: [
                URLQueryItem(name: "with", value: principal),
                URLQueryItem(name: "limit", value: String(limit)),
                cursor.map { URLQueryItem(name: "cursor", value: $0) }
            ].compactMap { $0 }
        )
    }
}
