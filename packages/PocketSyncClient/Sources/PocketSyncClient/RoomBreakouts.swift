import Foundation
import PocketContracts

// Breakout rooms, v1-a (sentinelayer-api PR #1031, docs/contracts/breakout-room-v1.json): a breakout is a child
// session linked to the parent message that started it. The parent timeline carries only two events, and both
// are bounded on purpose:
// - `session_breakout_opened` {childSessionId, relationVersion}: the card; title, people and counts come from the
//   principal-filtered descriptor (`GET /sessions/{child}/breakout` or the parent's list), never from the event.
// - `session_breakout_outcome`: the published outcome text and each required participant's acknowledgement.
// Child messages never appear in parent reads; the phone opens the child as its own room.

/// A breakout's reference in its parent room's timeline.
public struct RoomBreakoutEvent: Equatable, Sendable {
    public let childSessionId: String
    /// Set for `session_breakout_outcome`.
    public let outcome: RoomBreakoutOutcome?

    public init(childSessionId: String, outcome: RoomBreakoutOutcome? = nil) {
        self.childSessionId = childSessionId
        self.outcome = outcome
    }

    init?(payload: JSONValue, isOutcome: Bool) {
        guard let child = payload["childSessionId"]?.stringValue, RoomBreakout.isValidId(child) else { return nil }
        if isOutcome {
            guard let outcome = RoomBreakoutOutcome(payload: payload) else { return nil }
            self.init(childSessionId: child, outcome: outcome)
        } else {
            self.init(childSessionId: child)
        }
    }
}

/// A breakout's published outcome, as its parent room shows it.
public struct RoomBreakoutOutcome: Equatable, Sendable {
    public let outcomeId: String
    public let revision: Int64
    public let text: String
    public let authorId: String
    public let publishedAt: String
    public let acknowledgements: [RoomBreakoutAcknowledgement]

    public init(
        outcomeId: String,
        revision: Int64,
        text: String,
        authorId: String,
        publishedAt: String = "",
        acknowledgements: [RoomBreakoutAcknowledgement]
    ) {
        self.outcomeId = outcomeId
        self.revision = revision
        self.text = text
        self.authorId = authorId
        self.publishedAt = publishedAt
        self.acknowledgements = acknowledgements
    }

    init?(payload: JSONValue) {
        guard let outcomeId = payload["outcomeId"]?.stringValue, !outcomeId.isEmpty, outcomeId.utf8.count <= 128,
              let text = payload["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        var seen = Set<String>()
        let acknowledgements = (payload["acknowledgements"]?.arrayValue ?? []).compactMap { row -> RoomBreakoutAcknowledgement? in
            guard let ack = RoomBreakoutAcknowledgement(json: row), seen.insert(ack.principalId).inserted else { return nil }
            return ack
        }
        self.init(
            outcomeId: outcomeId,
            revision: payload["revision"]?.intValue ?? 1,
            text: String(text.prefix(RoomBreakout.maximumOutcomeCharacters)),
            authorId: payload["authorId"]?.stringValue ?? "",
            publishedAt: payload["publishedAt"]?.stringValue ?? "",
            acknowledgements: acknowledgements
        )
    }
}

/// One required participant's answer to an outcome. "missing" means not acknowledged yet; an unknown state is
/// shown as missing, never as agreement.
public struct RoomBreakoutAcknowledgement: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case ack
        case disagree
        case missing
    }

    public let principalId: String
    public let isHuman: Bool
    public let state: State

    public init(principalId: String, isHuman: Bool, state: State) {
        self.principalId = principalId
        self.isHuman = isHuman
        self.state = state
    }

    init?(json: JSONValue) {
        guard let principal = json["principalId"]?.stringValue, !principal.isEmpty, principal.utf8.count <= 128 else {
            return nil
        }
        let kind = json["principalKind"]?.stringValue
        self.init(
            principalId: principal,
            isHuman: kind.map { $0 == "human" } ?? RoomMessage.isHumanAuthor(principal),
            state: (json["state"]?.stringValue).flatMap(State.init(rawValue:)) ?? .missing
        )
    }
}

/// A breakout as the signed-in viewer may see it. Fields the server withholds from this viewer are nil.
public struct RoomBreakout: Equatable, Identifiable, Sendable {
    public struct Participant: Equatable, Sendable {
        public let id: String
        public let name: String?
        public let isHuman: Bool

        public init(id: String, name: String? = nil, isHuman: Bool) {
            self.id = id
            self.name = name
            self.isHuman = isHuman
        }
    }

    public var id: String { childSessionId }
    public let childSessionId: String
    public let parentSessionId: String
    public let title: String
    public let isOpen: Bool
    /// `approval_required`: agents need a human-approved grant to read it.
    public let isLocked: Bool
    public let createdAt: String
    public let parentAnchorSequence: Int64?
    public let sourceMessageSequence: Int64?
    public let participants: [Participant]?
    public let messageCount: Int?
    public let unreadCount: Int?
    public let canRead: Bool
    public let canPost: Bool
    public let hasPublishedOutcome: Bool

    public static let maximumTitleCharacters = 120
    public static let maximumOutcomeCharacters = 2000

    public init(
        childSessionId: String,
        parentSessionId: String,
        title: String,
        isOpen: Bool = true,
        isLocked: Bool = false,
        createdAt: String = "",
        parentAnchorSequence: Int64? = nil,
        sourceMessageSequence: Int64? = nil,
        participants: [Participant]? = nil,
        messageCount: Int? = nil,
        unreadCount: Int? = nil,
        canRead: Bool = true,
        canPost: Bool = false,
        hasPublishedOutcome: Bool = false
    ) {
        self.childSessionId = childSessionId
        self.parentSessionId = parentSessionId
        self.title = title
        self.isOpen = isOpen
        self.isLocked = isLocked
        self.createdAt = createdAt
        self.parentAnchorSequence = parentAnchorSequence
        self.sourceMessageSequence = sourceMessageSequence
        self.participants = participants
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.canRead = canRead
        self.canPost = canPost
        self.hasPublishedOutcome = hasPublishedOutcome
    }

    init?(json: JSONValue) {
        guard let child = json["childSessionId"]?.stringValue, Self.isValidId(child) else { return nil }
        let viewer = json["viewer"] ?? .null
        let participants: [Participant]? = json["participants"]?.arrayValue.map { rows in
            rows.compactMap { row in
                guard let id = row["id"]?.stringValue, !id.isEmpty, id.utf8.count <= 128 else { return nil }
                let kind = row["kind"]?.stringValue
                return Participant(
                    id: id,
                    name: row["name"]?.stringValue ?? row["displayName"]?.stringValue,
                    isHuman: kind.map { $0 == "human" } ?? RoomMessage.isHumanAuthor(id)
                )
            }
        }
        let title = (json["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            childSessionId: child,
            parentSessionId: json["parentSessionId"]?.stringValue ?? "",
            title: String((title.isEmpty ? "Breakout" : title).prefix(Self.maximumTitleCharacters)),
            isOpen: (json["status"]?.stringValue ?? "open") != "closed",
            isLocked: json["agentAccess"]?.stringValue == "approval_required",
            createdAt: json["createdAt"]?.stringValue ?? "",
            parentAnchorSequence: json["parentAnchorSequence"]?.intValue,
            sourceMessageSequence: json["sourceMessageSequence"]?.intValue,
            participants: participants,
            messageCount: (json["messageCount"]?.intValue).map { Int(clamping: max(0, $0)) },
            unreadCount: (json["unreadCount"]?.intValue).map { Int(clamping: max(0, $0)) },
            canRead: viewer["canRead"]?.boolValue ?? false,
            canPost: viewer["canPost"]?.boolValue ?? false,
            hasPublishedOutcome: json["publishedOutcome"].map { $0 != .null } ?? false
        )
    }

    /// Breakout ids are server-issued session ids.
    static func isValidId(_ id: String) -> Bool {
        SessionIdentifier.isValid(id)
    }
}

/// `GET /sessions/{parent}/breakouts`: the breakouts this viewer may see, metadata only.
public struct RoomBreakoutsPage: Decodable, Equatable, Sendable {
    public let items: [RoomBreakout]
    public let nextCursor: String?
    public let complete: Bool

    enum CodingKeys: String, CodingKey { case items, nextCursor, complete }

    public init(items: [RoomBreakout] = [], nextCursor: String? = nil, complete: Bool = true) {
        self.items = items
        self.nextCursor = nextCursor
        self.complete = complete
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = (try? container.decode([JSONValue].self, forKey: .items)) ?? []
        var seen = Set<String>()
        self.items = rows.compactMap(RoomBreakout.init(json:)).filter { seen.insert($0.childSessionId).inserted }
        self.nextCursor = (try? container.decodeIfPresent(String.self, forKey: .nextCursor)) ?? nil
        self.complete = (try? container.decodeIfPresent(Bool.self, forKey: .complete)) ?? true
    }
}

extension HTTPSessionTransport {
    public func roomBreakouts(parentSessionId: String, cursor: String?, limit: Int = 50) async throws -> RoomBreakoutsPage {
        guard SessionIdentifier.isValid(parentSessionId) else { throw SessionTransportError.invalidRequest }
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))]
        if let cursor, !cursor.isEmpty, cursor.utf8.count <= 512 { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await getDecodable(
            RoomBreakoutsPage.self,
            path: ["api", "v1", "sessions", parentSessionId, "breakouts"],
            query: query
        )
    }
}
