import Foundation
import PocketContracts

// Room chat read model, source-bound to sentinelayer-api `routes/sessions.py` (`GET /events/before`,
// `GET /events`, `GET /stream`) and to the web client's merge rules (sentinelayer-web
// `useSessionLiveController.ts`, `sessionEventIdentity.ts`, `sessionMessageRevisions.ts` at d479a03).
//
// Unlike the strict Activity DTOs, room pages decode EVENT BY EVENT: one row the app cannot read is skipped and
// counted, so a single malformed or newer-shaped event never blanks a live room. Identity fields
// (`id`, `sequenceId`, `event`) stay required per row; everything presentational is optional.

/// What a room row is, for layout. Unknown event kinds are not displayed.
public enum RoomMessageKind: String, Equatable, Sendable {
    case message
    case checkpoint
    case memberJoined
    /// A breakout started from this room (`session_breakout_opened`); see `breakout`.
    case breakoutOpened
    /// A breakout's published outcome (`session_breakout_outcome`); see `breakout`.
    case breakoutOutcome
}

public struct RoomMessage: Equatable, Identifiable, Sendable {
    /// The event UUID (`id`), stable across edits.
    public let id: String
    public let sequenceId: Int64
    public let kind: RoomMessageKind
    public let authorId: String
    public let authorName: String
    public let isHuman: Bool
    public let text: String
    public let timestamp: String
    public let replyToSequenceId: Int64?
    public let clientMessageId: String?
    public let revision: Int64
    public let isEdited: Bool
    /// The breakout a `.breakoutOpened` or `.breakoutOutcome` row refers to.
    public let breakout: RoomBreakoutEvent?
    /// Files attached to this message, in order.
    public let attachments: [RoomAttachment]
    /// The wire event type. Only `session_message` rows take view receipts (the API refuses the others).
    public let eventType: String

    public init(
        id: String,
        sequenceId: Int64,
        kind: RoomMessageKind,
        authorId: String,
        authorName: String,
        isHuman: Bool,
        text: String,
        timestamp: String,
        replyToSequenceId: Int64? = nil,
        clientMessageId: String? = nil,
        revision: Int64 = 1,
        isEdited: Bool = false,
        breakout: RoomBreakoutEvent? = nil,
        attachments: [RoomAttachment] = [],
        eventType: String = "session_message"
    ) {
        self.id = id
        self.sequenceId = sequenceId
        self.kind = kind
        self.authorId = authorId
        self.authorName = authorName
        self.isHuman = isHuman
        self.text = text
        self.timestamp = timestamp
        self.replyToSequenceId = replyToSequenceId
        self.clientMessageId = clientMessageId
        self.revision = revision
        self.isEdited = isEdited
        self.breakout = breakout
        self.attachments = attachments
        self.eventType = eventType
    }

    /// Projects one wire event. Returns nil for events a room does not display (control, presence, edit
    /// envelopes, unknown kinds) and for rows missing an identity field.
    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty, id.utf8.count <= 256,
              let sequenceId = json["sequenceId"]?.intValue ?? json["sequence_id"]?.intValue,
              sequenceId > 0,
              let event = json["event"]?.stringValue else {
            return nil
        }
        let kind: RoomMessageKind
        switch event {
        case "session_message", "human_relay", "session_attachment": kind = .message
        case "session_checkpoint": kind = .checkpoint
        case "session_member_joined": kind = .memberJoined
        case "session_breakout_opened": kind = .breakoutOpened
        case "session_breakout_outcome": kind = .breakoutOutcome
        default: return nil
        }
        let payload = json["payload"] ?? .null
        let agent = json["agent"] ?? .null
        let authorId = (agent["id"]?.stringValue ?? json["agentId"]?.stringValue ?? "").trimmed
        let isHuman = RoomMessage.isHumanAuthor(authorId)

        let text: String
        switch kind {
        case .message:
            text = (payload["message"]?.stringValue ?? payload["text"]?.stringValue ?? "")
        case .checkpoint:
            text = (payload["title"]?.stringValue ?? payload["summary"]?.stringValue ?? "Checkpoint")
        case .memberJoined, .breakoutOpened:
            text = ""
        case .breakoutOutcome:
            text = payload["text"]?.stringValue ?? ""
        }
        if kind == .message && text.trimmed.isEmpty { return nil }
        let breakout: RoomBreakoutEvent?
        switch kind {
        case .breakoutOpened, .breakoutOutcome:
            // A breakout row without a valid child room (or an outcome without text) is not shown.
            guard let parsed = RoomBreakoutEvent(payload: payload, isOutcome: kind == .breakoutOutcome) else { return nil }
            breakout = parsed
        default:
            breakout = nil
        }

        self.id = id
        self.sequenceId = sequenceId
        self.kind = kind
        self.authorId = authorId
        self.authorName = RoomMessage.displayName(
            authorId: authorId,
            displayName: agent["displayName"]?.stringValue,
            payload: payload,
            isHuman: isHuman
        )
        self.isHuman = isHuman
        self.text = text
        self.timestamp = json["ts"]?.stringValue ?? json["timestamp"]?.stringValue ?? ""
        self.replyToSequenceId = payload["replyToSequenceId"]?.intValue.flatMap { $0 > 0 ? $0 : nil }
        self.clientMessageId = (payload["clientMessageId"]?.stringValue ?? payload["messageId"]?.stringValue)
            .flatMap { $0.isEmpty ? nil : $0 }
        self.revision = json["messageRevision"]?.intValue ?? 1
        self.isEdited = json["editedAt"]?.stringValue.map { !$0.isEmpty } ?? false
        self.breakout = breakout
        self.attachments = kind == .message ? RoomAttachment.list(from: payload) : []
        self.eventType = event
    }

    /// Human identities are server-authored as `human-<user>`; agents can never claim that prefix.
    public static func isHumanAuthor(_ authorId: String) -> Bool {
        authorId.lowercased().hasPrefix("human-") || authorId.lowercased() == "human"
    }

    /// Agents are named by their agent id (their `displayName` is usually a model family name,
    /// which says nothing about who spoke). Humans are named by display name, falling back to the id without
    /// its `human-` prefix.
    static func displayName(authorId: String, displayName: String?, payload: JSONValue, isHuman: Bool) -> String {
        if isHuman {
            if let name = displayName?.trimmed, !name.isEmpty, name.lowercased() != "human" { return name }
            if let name = payload["displayName"]?.stringValue?.trimmed, !name.isEmpty { return name }
            let stripped = authorId.hasPrefix("human-") ? String(authorId.dropFirst("human-".count)) : authorId
            return stripped.isEmpty ? "Someone" : stripped
        }
        return authorId.isEmpty ? "Unknown participant" : authorId
    }
}

/// One page of room events from `GET /events/before` or `GET /events`, decoded row by row.
public struct RoomEventPage: Decodable, Equatable, Sendable {
    public let messages: [RoomMessage]
    /// Rows present on the wire (displayable or not). Lets the caller tell "nothing displayable" from "empty".
    public let rawCount: Int
    /// Rows that carried an identity the app could not read. Never silently zero when rows were dropped.
    public let undecodableCount: Int
    /// The highest sequence seen on the wire, displayable or not, so a forward poll can advance past
    /// control-only pages instead of re-reading them forever.
    public let maxSequence: Int64?
    /// The lowest sequence seen on the wire, so back-pagination can continue past non-displayable rows.
    public let minSequence: Int64?
    public let nextBeforeSequence: Int64?
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case events
        case nextBeforeSequenceSnake = "next_before_sequence"
        case nextBeforeSequence
        case hasMoreSnake = "has_more"
        case hasMore
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decode([JSONValue].self, forKey: .events)
        var messages: [RoomMessage] = []
        var undecodable = 0
        var maxSequence: Int64?
        var minSequence: Int64?
        for row in rows {
            if let sequence = row["sequenceId"]?.intValue ?? row["sequence_id"]?.intValue, sequence > 0 {
                maxSequence = max(maxSequence ?? sequence, sequence)
                minSequence = min(minSequence ?? sequence, sequence)
            } else {
                undecodable += 1
                continue
            }
            if let message = RoomMessage(json: row) { messages.append(message) }
        }
        self.messages = messages
        self.rawCount = rows.count
        self.undecodableCount = undecodable
        self.maxSequence = maxSequence
        self.minSequence = minSequence
        self.nextBeforeSequence = try container.decodeIfPresent(Int64.self, forKey: .nextBeforeSequenceSnake)
            ?? container.decodeIfPresent(Int64.self, forKey: .nextBeforeSequence)
        self.hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMoreSnake)
            ?? container.decodeIfPresent(Bool.self, forKey: .hasMore)
            ?? false
    }

    public init(
        messages: [RoomMessage],
        rawCount: Int? = nil,
        undecodableCount: Int = 0,
        maxSequence: Int64? = nil,
        minSequence: Int64? = nil,
        nextBeforeSequence: Int64? = nil,
        hasMore: Bool = false
    ) {
        self.messages = messages
        self.rawCount = rawCount ?? messages.count
        self.undecodableCount = undecodableCount
        self.maxSequence = maxSequence ?? messages.map(\.sequenceId).max()
        self.minSequence = minSequence ?? messages.map(\.sequenceId).min()
        self.nextBeforeSequence = nextBeforeSequence
        self.hasMore = hasMore
    }
}

/// The ordered, de-duplicated rows of one room. Pure value type so every merge rule is unit-testable.
///
/// Merge rules (web parity):
/// - Rows are ordered by `sequenceId`. Sequence ids come from a global counter, so gaps are normal.
/// - A row is the same message as an existing one if it shares the sequence id, the event id, or a non-empty
///   client message id.
/// - An existing body is replaced only by a strictly higher `revision`.
/// - The room keeps at most `capacity` rows; when over, the OLDEST rows are dropped and `hasMoreOlder` turns on.
public struct RoomTimeline: Equatable, Sendable {
    public private(set) var messages: [RoomMessage] = []
    public var hasMoreOlder: Bool
    public let capacity: Int

    public init(capacity: Int = 3_000, hasMoreOlder: Bool = true) {
        self.capacity = max(capacity, 50)
        self.hasMoreOlder = hasMoreOlder
    }

    public var newestSequence: Int64? { messages.last?.sequenceId }
    public var oldestSequence: Int64? { messages.first?.sequenceId }

    public struct MergeResult: Equatable, Sendable {
        public var inserted: [RoomMessage] = []
        public var updatedIds: [String] = []
        public var isEmpty: Bool { inserted.isEmpty && updatedIds.isEmpty }
    }

    @discardableResult
    public mutating func merge(_ incoming: [RoomMessage]) -> MergeResult {
        var result = MergeResult()
        for message in incoming {
            if let index = indexOfSameMessage(as: message) {
                let existing = messages[index]
                if message.revision > existing.revision {
                    messages[index] = message
                    result.updatedIds.append(message.id)
                }
                continue
            }
            let insertAt = insertionIndex(for: message.sequenceId)
            messages.insert(message, at: insertAt)
            result.inserted.append(message)
        }
        if messages.count > capacity {
            messages.removeFirst(messages.count - capacity)
            hasMoreOlder = true
        }
        return result
    }

    public func index(ofSequence sequenceId: Int64) -> Int? {
        let at = insertionIndex(for: sequenceId)
        return at < messages.count && messages[at].sequenceId == sequenceId ? at : nil
    }

    private func indexOfSameMessage(as message: RoomMessage) -> Int? {
        if let bySequence = index(ofSequence: message.sequenceId) { return bySequence }
        if let byId = messages.firstIndex(where: { $0.id == message.id }) { return byId }
        // A client id is only unique per author: another author's message with the same id is a different row.
        if let clientId = message.clientMessageId,
           let byClient = messages.firstIndex(where: {
               $0.clientMessageId == clientId && $0.authorId.lowercased() == message.authorId.lowercased()
           }) {
            return byClient
        }
        return nil
    }

    /// First index whose sequence is >= `sequenceId` (binary search; rows stay sorted).
    private func insertionIndex(for sequenceId: Int64) -> Int {
        var low = 0
        var high = messages.count
        while low < high {
            let mid = (low + high) / 2
            if messages[mid].sequenceId < sequenceId {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

/// Unread tracking for one open room, mirroring the web's client-only divider: while the reader is away from the
/// bottom, arriving rows from OTHER people count as unread and the divider sits at the first of them. Reaching
/// the bottom clears both.
public struct RoomUnreadState: Equatable, Sendable {
    public private(set) var unreadCount = 0
    public private(set) var dividerSequence: Int64?

    public init() {}

    public mutating func noteArrivals(_ inserted: [RoomMessage], readerIsAtBottom: Bool, selfAuthorIds: Set<String>) {
        guard !readerIsAtBottom else { return }
        let fromOthers = inserted.filter { $0.kind == .message && !selfAuthorIds.contains($0.authorId.lowercased()) }
        guard !fromOthers.isEmpty else { return }
        unreadCount += fromOthers.count
        let first = fromOthers.map(\.sequenceId).min()!
        dividerSequence = min(dividerSequence ?? first, first)
    }

    public mutating func readerReachedBottom() {
        unreadCount = 0
        dividerSequence = nil
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
