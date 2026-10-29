import Foundation
import PocketContracts

// A room's tickets, source-bound to sentinelayer-api `GET /tickets/snapshot` and `GET /tickets/events`, read with the
// web's protocol (sentinelayer-web `ticketFeed.ts` at d479a03):
// 1. page the snapshot to the end, keeping the FIRST page's cursor (ids strictly ascending, and each continuation
//    exactly the last id returned);
// 2. follow the event feed from that cursor; every event carries the ticket at its version;
// 3. upsert by (id, highest version), so an old event never regresses a newer row.
// A catch-up is atomic: it applies to a copy and publishes board and cursor together only when every page succeeded.

/// Who holds a ticket's lease, as every read shows it (sentinelayer-api `_ticket_state` / `_ticket_lease_view`): the
/// holder only, never the lease id, which is the holder's credential and is returned once, by the claim.
public struct RoomTicketLease: Equatable, Sendable {
    public let holder: String
    public let holderKind: String?
    public let fence: Int64
    public let expiresAt: String?
    /// The API's reading when it answered a read; absent on a ticket carried by a stored event.
    public let liveWhenRead: Bool?

    public init?(json: JSONValue?) {
        guard let json, let holder = json["holder"]?.stringValue, !holder.isEmpty else { return nil }
        self.init(
            holder: holder,
            holderKind: json["holderKind"]?.stringValue,
            fence: json["fence"]?.intValue ?? 0,
            expiresAt: json["expiresAt"]?.stringValue,
            liveWhenRead: json["live"]?.boolValue
        )
    }

    public init(holder: String, holderKind: String? = nil, fence: Int64 = 1, expiresAt: String? = nil, liveWhenRead: Bool? = nil) {
        self.holder = holder
        self.holderKind = holderKind
        self.fence = fence
        self.expiresAt = expiresAt
        self.liveWhenRead = liveWhenRead
    }

    /// Live at `now`: by the expiry when it parses, else by the API's reading. For choosing what to offer only; the API
    /// decides, and an expired lease still protects the ticket until a takeover, release or override.
    public func isLive(at now: Date) -> Bool {
        if let expiry = expiresAt.flatMap({ ParsedSessionTimestamp($0).date }) { return expiry > now }
        return liveWhenRead ?? false
    }
}

public struct RoomTicket: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let status: String
    public let createdBy: String
    public let assignee: String?
    public let createdAt: String
    public let updatedAt: String
    public let version: Int64
    /// P0...P4 from the body's `## Priority` section, as the keeper writes it; nil when absent.
    public let priority: Int?
    /// The chat message the ticket was filed from, when known.
    public let sourceSequenceId: Int64?
    public let isVerifiedDone: Bool
    public let unaccepted: Bool
    public let staleClaim: Bool
    /// Present while a lease exists, live or expired.
    public let lease: RoomTicketLease?

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty,
              let version = json["version"]?.intValue, version >= 1 else { return nil }
        self.id = id
        self.title = json["title"]?.stringValue ?? "Untitled ticket"
        self.body = json["body"]?.stringValue ?? ""
        self.status = json["status"]?.stringValue ?? "open"
        self.createdBy = json["createdBy"]?.stringValue ?? json["creator"]?["id"]?.stringValue ?? ""
        let assignee = json["assignee"]?.stringValue ?? json["assignee"]?["id"]?.stringValue
        self.assignee = assignee.flatMap { $0.isEmpty ? nil : $0 }
        self.createdAt = json["createdAt"]?.stringValue ?? ""
        self.updatedAt = json["updatedAt"]?.stringValue ?? json["createdAt"]?.stringValue ?? ""
        self.version = version
        self.priority = RoomTicket.priority(inBody: json["body"]?.stringValue ?? "")
        self.sourceSequenceId = json["sourceMessage"]?["sequenceId"]?.intValue
        self.isVerifiedDone = json["completion"]?["verified"]?.boolValue ?? false
        self.unaccepted = json["unaccepted"]?.boolValue ?? false
        self.staleClaim = json["staleClaim"]?.boolValue ?? false
        self.lease = RoomTicketLease(json: json["lease"])
    }

    public init(
        id: String,
        title: String,
        body: String = "",
        status: String = "open",
        createdBy: String = "",
        assignee: String? = nil,
        createdAt: String = "",
        updatedAt: String = "",
        version: Int64 = 1,
        sourceSequenceId: Int64? = nil,
        isVerifiedDone: Bool = false,
        lease: RoomTicketLease? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.status = status
        self.createdBy = createdBy
        self.assignee = assignee
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.priority = RoomTicket.priority(inBody: body)
        self.sourceSequenceId = sourceSequenceId
        self.isVerifiedDone = isVerifiedDone
        self.unaccepted = false
        self.staleClaim = false
        self.lease = lease
    }

    /// Archived: `done`, or `killed`, the API's other final status (nothing transitions out of it). The web archives
    /// only `done`, so a killed ticket there still reads as active.
    public var isArchived: Bool { status == "done" || status == "killed" }

    /// Reads `## Priority` followed by `P0`-`P4` (the keeper's format), ignoring fenced code.
    public static func priority(inBody body: String) -> Int? {
        var inFence = false
        var afterHeading = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            if line.lowercased().hasPrefix("## priority") { afterHeading = true; continue }
            guard afterHeading, !line.isEmpty else { continue }
            if line.hasPrefix("#") { return nil }
            guard line.count >= 2, line.first == "P" || line.first == "p",
                  let digit = line.dropFirst().first?.wholeNumberValue, (0...4).contains(digit) else { return nil }
            return digit
        }
        return nil
    }
}

public struct RoomTicketSnapshotPage: Decodable, Equatable, Sendable {
    public let items: [RoomTicket]
    /// Rows on the wire, including any without a valid id or version.
    public let rawIds: [String?]
    public let hasMore: Bool
    public let nextAfterId: String?
    public let cursor: Int64?

    enum CodingKeys: String, CodingKey { case items, hasMore, nextAfterId, cursor }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decode([JSONValue].self, forKey: .items)
        self.items = rows.compactMap(RoomTicket.init(json:))
        self.rawIds = rows.map { $0["id"]?.stringValue }
        self.hasMore = try container.decode(Bool.self, forKey: .hasMore)
        self.nextAfterId = try container.decodeIfPresent(String.self, forKey: .nextAfterId)
        self.cursor = try container.decodeIfPresent(Int64.self, forKey: .cursor)
    }

    public init(items: [RoomTicket], hasMore: Bool = false, nextAfterId: String? = nil, cursor: Int64? = nil) {
        self.items = items
        self.rawIds = items.map(\.id)
        self.hasMore = hasMore
        self.nextAfterId = nextAfterId
        self.cursor = cursor
    }
}

public struct RoomTicketEventsPage: Decodable, Equatable, Sendable {
    /// The ticket each event carries (events without one, or with an invalid one, contribute nothing).
    public let tickets: [RoomTicket]
    public let eventCount: Int
    public let cursor: Int64

    enum CodingKeys: String, CodingKey { case events, cursor }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let events = try container.decode([JSONValue].self, forKey: .events)
        self.tickets = events.compactMap { $0["ticket"].flatMap(RoomTicket.init(json:)) }
        self.eventCount = events.count
        self.cursor = try container.decode(Int64.self, forKey: .cursor)
    }

    public init(tickets: [RoomTicket], eventCount: Int? = nil, cursor: Int64) {
        self.tickets = tickets
        self.eventCount = eventCount ?? tickets.count
        self.cursor = cursor
    }
}

/// Every ticket in the room at a committed feed cursor.
public struct RoomTicketBoard: Equatable, Sendable {
    public private(set) var tickets: [String: RoomTicket] = [:]
    public private(set) var cursor: Int64 = 0

    public init() {}

    /// Keeps the higher version. Returns whether the board changed.
    @discardableResult
    public mutating func upsert(_ ticket: RoomTicket) -> Bool {
        if let current = tickets[ticket.id], current.version >= ticket.version { return false }
        tickets[ticket.id] = ticket
        return true
    }

    public static let maxSnapshotPages = 50
    public static let maxCatchUpPages = 20

    /// Pages the snapshot to the end, validating keyset order and continuation like the web.
    public static func loadBaseline(
        fetchPage: (String?) async throws -> RoomTicketSnapshotPage
    ) async throws -> RoomTicketBoard {
        var board = RoomTicketBoard()
        var afterId: String?
        for page in 0..<maxSnapshotPages {
            let body = try await fetchPage(afterId)
            if page == 0 {
                guard let cursor = body.cursor, cursor >= 0 else { throw SessionTransportError.invalidData }
                board.cursor = cursor
            }
            var previous = afterId
            for id in body.rawIds {
                guard let id, !id.isEmpty else { throw SessionTransportError.invalidData }
                if let previous, !(id > previous) { throw SessionTransportError.invalidData }
                previous = id
            }
            guard body.items.count == body.rawIds.count else { throw SessionTransportError.invalidData }
            for ticket in body.items { board.upsert(ticket) }
            if !body.hasMore { return board }
            guard !body.items.isEmpty, let next = body.nextAfterId, !next.isEmpty, next == previous else {
                throw SessionTransportError.invalidData
            }
            afterId = next
        }
        throw SessionTransportError.invalidData
    }

    /// Follows the feed until drained. Atomic: returns a new board, or throws and leaves `self` untouched.
    public func caughtUp(
        fetchEvents: (Int64) async throws -> RoomTicketEventsPage
    ) async throws -> (board: RoomTicketBoard, changed: Bool) {
        var next = self
        var changed = false
        for _ in 0..<Self.maxCatchUpPages {
            let page = try await fetchEvents(next.cursor)
            guard page.cursor >= next.cursor else { throw SessionTransportError.invalidData }
            for ticket in page.tickets where next.upsert(ticket) { changed = true }
            let advanced = page.cursor > next.cursor
            next.cursor = page.cursor
            if page.eventCount == 0 || !advanced { return (next, changed) }
        }
        return (next, changed)
    }
}

extension HTTPSessionTransport {
    public func roomTicketSnapshot(sessionId: String, afterId: String?, limit: Int = 200) async throws -> RoomTicketSnapshotPage {
        try Self.requireIdentifier(sessionId)
        try Self.requireLimit(limit, allowed: 1...200)
        if let afterId, afterId.isEmpty || afterId.utf8.count > 36 { throw SessionTransportError.invalidRequest }
        return try await getDecodable(
            RoomTicketSnapshotPage.self,
            path: ["api", "v1", "sessions", sessionId, "tickets", "snapshot"],
            query: [
                URLQueryItem(name: "limit", value: String(limit)),
                afterId.map { URLQueryItem(name: "afterId", value: $0) }
            ].compactMap { $0 }
        )
    }

    public func roomTicketEvents(sessionId: String, after: Int64, limit: Int = 500) async throws -> RoomTicketEventsPage {
        try Self.requireIdentifier(sessionId)
        try Self.requireLimit(limit, allowed: 1...500)
        guard after >= 0 else { throw SessionTransportError.invalidRequest }
        return try await getDecodable(
            RoomTicketEventsPage.self,
            path: ["api", "v1", "sessions", sessionId, "tickets", "events"],
            query: [
                URLQueryItem(name: "after", value: String(after)),
                URLQueryItem(name: "limit", value: String(limit))
            ]
        )
    }
}
