import Foundation

// Lossless Senti Sessions WIRE DTOs — source-bound to sentinelayer-api
// (deployed 3ca7640 == origin/main 91a2c3fa; serializers session_relay_service.py + routes/sessions.py
// + session_checkpoint_grading.py, verified against tests/test_sessions.py). Relay owns the wire layer;
// ATLAS projects typed domain values atop these reviewed DTOs.
//
// Rules matched EXACTLY to the wire:
//  - ITEM objects use camelCase keys (default Codable). PAGE ENVELOPES mix snake_case -> CodingKeys.
//  - REQUIRED (non-optional) == the route/serializer GUARANTEES the key: malformed/partial wire must FAIL
//    decode, never silently mint ambiguous domain state. Only truly-nullable fields are Optional.
//  - Timestamps kept as RAW ISO String (lossless; projection parses tolerant ISO8601).
//  - Open/unknown blobs (payload, metadata, projection, tokenRange, summarySections, agent) stay JSONValue
//    so future keys are preserved losslessly. event/actionType stay raw String (projection maps open enums).
//  - A generic session checkpoint is ordinary membership-authorized content, NOT verify-gated here; only a
//    separately-signed Pocket briefing artifact crosses VerifiedBundle (in PocketCall), never this DTO.

// MARK: - Sessions list

public struct SessionSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String
    public let status: String
    public let archiveStatus: String
    public let visibility: String
    public let membershipRole: String
    public let title: String?
    public let summaryText: String?
    public let summaryGeneratedAt: String?
    public let summaryModel: String?
    public let agentCount: Int
    public let eventCount: Int
    public let totalCostUsd: Decimal
    public let createdAt: String?
    public let lastActivityAt: String?
    public let expiresAt: String?
    public let killedAt: String?
    public let templateName: String?
    public let codebasePath: String?
    public let s3ArchivePath: String?
    /// What the room is for: general, study, research or conference (absent from older servers).
    public let roomType: String?
    /// Who is in the room now, people and agents (Carter, 10-31: the room list says how many are online). Absent
    /// from older servers; null when the server cannot say.
    public let online: SessionOnlineCounts?
    /// Your unread messages in the room and the first of them (absent from older servers).
    public let unread: SessionUnreadSummary?
    /// How far the server holds you have read the room (absent from older servers, and before you read it).
    public let lastReadSequenceId: Int64?

    enum CodingKeys: String, CodingKey {
        case sessionId, status, archiveStatus, visibility, membershipRole, title, summaryText, summaryGeneratedAt
        case summaryModel, agentCount, eventCount, totalCostUsd, createdAt, lastActivityAt, expiresAt, killedAt
        case templateName, codebasePath, s3ArchivePath, roomType, online, unread, lastReadSequenceId
    }

    /// The room's own fields decode exactly as the wire guarantees them (a missing required key fails the list).
    /// Who is online and what is unread are counts to show and never content or authority, so they decode
    /// tolerantly: missing, null or malformed, they read as unknown and the room list shows nothing for them,
    /// rather than the whole list failing over a count.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        status = try container.decode(String.self, forKey: .status)
        archiveStatus = try container.decode(String.self, forKey: .archiveStatus)
        visibility = try container.decode(String.self, forKey: .visibility)
        membershipRole = try container.decode(String.self, forKey: .membershipRole)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        summaryText = try container.decodeIfPresent(String.self, forKey: .summaryText)
        summaryGeneratedAt = try container.decodeIfPresent(String.self, forKey: .summaryGeneratedAt)
        summaryModel = try container.decodeIfPresent(String.self, forKey: .summaryModel)
        agentCount = try container.decode(Int.self, forKey: .agentCount)
        eventCount = try container.decode(Int.self, forKey: .eventCount)
        totalCostUsd = try container.decode(Decimal.self, forKey: .totalCostUsd)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        lastActivityAt = try container.decodeIfPresent(String.self, forKey: .lastActivityAt)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        killedAt = try container.decodeIfPresent(String.self, forKey: .killedAt)
        templateName = try container.decodeIfPresent(String.self, forKey: .templateName)
        codebasePath = try container.decodeIfPresent(String.self, forKey: .codebasePath)
        s3ArchivePath = try container.decodeIfPresent(String.self, forKey: .s3ArchivePath)
        roomType = try container.decodeIfPresent(String.self, forKey: .roomType)
        online = try? container.decodeIfPresent(SessionOnlineCounts.self, forKey: .online)
        unread = try? container.decodeIfPresent(SessionUnreadSummary.self, forKey: .unread)
        lastReadSequenceId = SessionTolerant.sequence(in: container, .lastReadSequenceId)
    }
}

/// How many people and agents are in a room now, as the room list shows them. A count that is missing, null,
/// negative or not a whole number reads as 0.
public struct SessionOnlineCounts: Codable, Equatable, Sendable {
    public let humans: Int
    public let agents: Int

    enum CodingKeys: String, CodingKey { case humans, agents }

    public init(humans: Int, agents: Int) {
        self.humans = max(humans, 0)
        self.agents = max(agents, 0)
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        self.init(humans: SessionTolerant.count(in: container, .humans),
                  agents: SessionTolerant.count(in: container, .agents))
    }
}

/// Your unread messages in a room: how many, and the first one's sequence (where the room opens). A count that is
/// missing or malformed reads as 0; a first unread that is missing, malformed or not positive reads as unknown.
public struct SessionUnreadSummary: Codable, Equatable, Sendable {
    public let count: Int
    public let firstUnreadSequenceId: Int64?

    enum CodingKeys: String, CodingKey { case count, firstUnreadSequenceId }

    public init(count: Int, firstUnreadSequenceId: Int64?) {
        self.count = max(count, 0)
        self.firstUnreadSequenceId = firstUnreadSequenceId.flatMap { $0 > 0 ? $0 : nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        self.init(count: SessionTolerant.count(in: container, .count),
                  firstUnreadSequenceId: SessionTolerant.sequence(in: container, .firstUnreadSequenceId))
    }
}

/// Reads display counts and sequence positions without ever failing the response they are in.
enum SessionTolerant {
    static func count<Key: CodingKey>(in container: KeyedDecodingContainer<Key>?, _ key: Key) -> Int {
        guard let value = try? container?.decodeIfPresent(Int.self, forKey: key) else { return 0 }
        return max(value, 0)
    }

    static func sequence<Key: CodingKey>(in container: KeyedDecodingContainer<Key>?, _ key: Key) -> Int64? {
        guard let value = try? container?.decodeIfPresent(Int64.self, forKey: key), value > 0 else { return nil }
        return value
    }
}

/// GET /api/v1/sessions -> route wrapper (sessions.py:2512-2517).
public struct SessionListPage: Codable, Equatable, Sendable {
    public let sessions: [SessionSummary]
    public let count: Int
    public let includeArchived: Bool
    public let nextCursor: String?
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case sessions, count
        case includeArchived = "include_archived"
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

// MARK: - Events

/// _event_from_db_row (:3806-3821) always emits id/event/payload/agentId/agentModel/ts/timestamp/cursor/
/// sequenceId/sessionId, plus a nested `agent` presentation object (role/displayName/provider/clientKind).
/// `agent` is JSONValue for losslessness; eventId/idempotencyToken are conditional; `source` key is
/// always emitted but its value is DB-nullable (models/session.py:141).
public struct SessionEventDTO: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let event: String
    public let agent: JSONValue          // always emitted (presentation object); JSONValue = lossless
    public let agentId: String
    public let agentModel: String
    public let payload: JSONValue
    public let ts: String
    public let timestamp: String
    public let cursor: String
    public let sequenceId: Int64
    public let sessionId: String
    public let source: String?           // key always emitted, but SessionEvent.source is DB-nullable (models/session.py:141)
    public let eventId: String?
    public let idempotencyToken: String?
}

/// GET /{session_id}/events (after/from_sequence) -> forward/tail page: { events } ONLY.
public struct SessionEventForwardPage: Codable, Equatable, Sendable {
    public let events: [SessionEventDTO]
}

/// GET /{session_id}/events/before (beforeSequence) -> historical page. `next_before_sequence` is a
/// SEQUENCE ANCHOR (Int64), nullable when the page reaches the start; NOT an opaque cursor.
public struct SessionEventBeforePage: Codable, Equatable, Sendable {
    public let events: [SessionEventDTO]
    public let count: Int
    public let nextBeforeSequence: Int64?
    public let hasMore: Bool
    public let partial: Bool

    enum CodingKeys: String, CodingKey {
        case events, count, partial
        case nextBeforeSequence = "next_before_sequence"
        case hasMore = "has_more"
    }
}

// MARK: - Actions (SEPARATE feed from events; not SSE)

/// _message_action_row (:5977) — targetSequenceId/actorKind/actorId/metadata/idempotencyKey/createdAt are
/// DB+serializer non-null; targetCursor/targetActionId/actorUserId/actorRole/note are nullable.
public struct SessionActionDTO: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sessionId: String
    public let targetSequenceId: Int64
    public let targetCursor: String?
    public let targetActionId: String?
    public let actionType: String
    public let actorKind: String
    public let actorId: String
    public let actorUserId: String?
    public let actorRole: String?
    public let note: String?
    public let metadata: JSONValue
    public let idempotencyKey: String
    public let createdAt: String
}

/// GET /{session_id}/actions -> envelope, NOT bare rows. `projection` preserved losslessly.
public struct SessionActionPage: Codable, Equatable, Sendable {
    public let sessionId: String
    public let actions: [SessionActionDTO]
    public let count: Int
    public let projection: JSONValue
}

// MARK: - Checkpoints (generic session_checkpoint resource; membership-authorized, NOT verify-gated)

/// Full-content checkpoint DTO (renamed from Ref — it carries title/summary/grade family, not just a ref).
/// kind/title/summary are present before the service returns a row; the grade family is
/// serializer-guaranteed non-null (both normalize_checkpoint_grade return paths emit all four —
/// build_checkpoint_grade uses _grade_letter, which always yields a letter).
public struct SessionCheckpointDTO: Codable, Equatable, Sendable, Identifiable {
    public var id: String { checkpointId }
    public let checkpointId: String
    public let sessionId: String
    public let kind: String
    public let title: String
    public let summary: String
    public let startSequence: Int64?
    public let endSequence: Int64?
    public let tokenRange: JSONValue?
    // serializer-guaranteed non-null (createdBy/createdByAgentId normalized to strings; eventSequence/cursor/
    // createdAt derived from the always-present event; summarySections synthesized; grade family from
    // normalize_checkpoint_grade whose both return paths emit non-null values):
    public let createdBy: String
    public let createdByAgentId: String
    public let eventSequence: Int64
    public let cursor: String
    public let createdAt: String
    public let summarySections: JSONValue
    public let grade: String
    public let gradeScore: Int
    public let gradeVersion: String
    public let gradeReasons: JSONValue
}

/// GET /{session_id}/checkpoints -> { checkpoints, count } (list lacks a cursor).
public struct SessionCheckpointListPage: Codable, Equatable, Sendable {
    public let checkpoints: [SessionCheckpointDTO]
    public let count: Int
}
