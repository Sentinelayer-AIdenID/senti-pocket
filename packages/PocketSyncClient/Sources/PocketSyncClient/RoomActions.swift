import Foundation
import PocketContracts

// Replies and reactions for a room, source-bound to sentinelayer-api `GET /api/v1/sessions/{id}/actions` and its
// `projection.byTarget` (session_relay_service.py), and to the web's use of them (sentinelayer-web
// `SessionMessage.tsx`, `sessionActivity.helpers.ts` at d479a03). Decoded tolerantly, row by row, like room events.

/// One threaded reply (an action of type `reply` on a message).
public struct RoomReply: Equatable, Identifiable, Sendable {
    public let id: String
    public let targetSequenceId: Int64
    /// Set when this replies to another reply rather than to the message itself.
    public let targetActionId: String?
    public let authorId: String
    public let isHuman: Bool
    public let text: String
    public let createdAt: String
    public let revision: Int64
    public let isEdited: Bool

    public init(
        id: String,
        targetSequenceId: Int64,
        targetActionId: String? = nil,
        authorId: String,
        text: String,
        createdAt: String,
        revision: Int64 = 1,
        isEdited: Bool = false
    ) {
        self.id = id
        self.targetSequenceId = targetSequenceId
        self.targetActionId = targetActionId
        self.authorId = authorId
        self.isHuman = RoomMessage.isHumanAuthor(authorId)
        self.text = text
        self.createdAt = createdAt
        self.revision = revision
        self.isEdited = isEdited
    }

    public init?(json: JSONValue) {
        guard json["actionType"]?.stringValue == "reply",
              let id = json["id"]?.stringValue, !id.isEmpty,
              let target = json["targetSequenceId"]?.intValue, target > 0,
              let note = json["note"]?.stringValue,
              !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let author = json["actorId"]?.stringValue ?? ""
        self.init(
            id: id,
            targetSequenceId: target,
            targetActionId: json["targetActionId"]?.stringValue,
            authorId: author,
            text: note,
            createdAt: json["createdAt"]?.stringValue ?? "",
            revision: json["messageRevision"]?.intValue ?? 1,
            isEdited: json["editedAt"]?.stringValue.map { !$0.isEmpty } ?? false
        )
    }
}

/// What the room shows under one message: reaction counts, who reacted, who is working on it, and its replies.
public struct RoomReactionSummary: Equatable, Sendable {
    public let targetSequenceId: Int64
    /// Count per action type (`ack`, `like`, `dislike`, `disregard`, `working_on`, `reply`, `pin`, ...).
    public let counts: [String: Int]
    /// Actor ids per action type, sorted, from `actors` (actor id -> types).
    public let actorsByType: [String: [String]]
    /// Agents currently working on the message.
    public let activeOwners: [String]
    public let likedByViewer: Bool
    public let dislikedByViewer: Bool
    public let replyTotal: Int
    public let latestReplies: [RoomReply]
    public let hasMoreReplies: Bool
    public let isPinned: Bool

    public init(
        targetSequenceId: Int64,
        counts: [String: Int] = [:],
        actorsByType: [String: [String]] = [:],
        activeOwners: [String] = [],
        likedByViewer: Bool = false,
        dislikedByViewer: Bool = false,
        replyTotal: Int = 0,
        latestReplies: [RoomReply] = [],
        hasMoreReplies: Bool = false,
        isPinned: Bool = false
    ) {
        self.targetSequenceId = targetSequenceId
        self.counts = counts
        self.actorsByType = actorsByType
        self.activeOwners = activeOwners
        self.likedByViewer = likedByViewer
        self.dislikedByViewer = dislikedByViewer
        self.replyTotal = replyTotal
        self.latestReplies = latestReplies
        self.hasMoreReplies = hasMoreReplies
        self.isPinned = isPinned
    }

    init?(json: JSONValue) {
        guard let target = json["targetSequenceId"]?.intValue, target > 0 else { return nil }
        var counts: [String: Int] = [:]
        for (type, value) in json["counts"]?.objectValue ?? [:] {
            if let count = value.intValue, count > 0 { counts[type] = Int(clamping: count) }
        }
        var actorsByType: [String: Set<String>] = [:]
        for (actor, types) in json["actors"]?.objectValue ?? [:] {
            for type in types.arrayValue ?? [] {
                if let type = type.stringValue { actorsByType[type, default: []].insert(actor) }
            }
        }
        let owners = (json["activeOwners"]?.arrayValue ?? []).compactMap { owner -> String? in
            owner.stringValue ?? owner["actorId"]?.stringValue ?? owner["agentId"]?.stringValue ?? owner["id"]?.stringValue
        }
        let reactions = json["reactions"] ?? .null
        let likes = reactions["like"]?["count"]?.intValue
        let dislikes = reactions["dislike"]?["count"]?.intValue
        if let likes, likes > 0 { counts["like"] = Int(clamping: likes) }
        if let dislikes, dislikes > 0 { counts["dislike"] = Int(clamping: dislikes) }
        let replies = (json["latestReplies"]?.arrayValue ?? []).compactMap(RoomReply.init(json:))
        self.init(
            targetSequenceId: target,
            counts: counts,
            actorsByType: actorsByType.mapValues { $0.sorted() },
            activeOwners: owners,
            likedByViewer: reactions["like"]?["byViewer"]?.boolValue ?? false,
            dislikedByViewer: reactions["dislike"]?["byViewer"]?.boolValue ?? false,
            replyTotal: max(Int(clamping: json["replyTotal"]?.intValue ?? 0), counts["reply"] ?? 0, replies.count),
            latestReplies: replies,
            hasMoreReplies: json["hasMoreReplies"]?.boolValue ?? false,
            isPinned: json["isPinned"]?.boolValue ?? false
        )
    }
}

/// An agent saying what it is doing about a message (an action of type `working_on`), e.g. "drafting the fix" or
/// "done: filed 1 ticket".
public struct RoomWorkingOn: Equatable, Identifiable, Sendable {
    public let id: String
    public let targetSequenceId: Int64
    public let actorId: String
    public let note: String
    public let createdAt: String

    public init(id: String, targetSequenceId: Int64, actorId: String, note: String, createdAt: String) {
        self.id = id
        self.targetSequenceId = targetSequenceId
        self.actorId = actorId
        self.note = note
        self.createdAt = createdAt
    }

    init?(json: JSONValue) {
        guard json["actionType"]?.stringValue == "working_on",
              let id = json["id"]?.stringValue, !id.isEmpty,
              let target = json["targetSequenceId"]?.intValue, target > 0,
              let actor = json["actorId"]?.stringValue, !actor.isEmpty else { return nil }
        let note = (json["note"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(id: id, targetSequenceId: target, actorId: actor, note: note.isEmpty ? "working on it" : note,
                  createdAt: json["createdAt"]?.stringValue ?? "")
    }

    /// Finished: the agent's note says so.
    public var isDone: Bool { note.lowercased().hasPrefix("done") }
}

/// A message pinned for the room (`projection.pinnedMessages`): newest pin first, at most the room's pin limit.
public struct RoomPinnedMessage: Equatable, Identifiable, Sendable {
    /// The pin action's id.
    public let id: String
    public let targetSequenceId: Int64
    /// Who pinned it: `human-<login>` or an agent id.
    public let pinnedBy: String
    public let createdAt: String

    public init(id: String, targetSequenceId: Int64, pinnedBy: String, createdAt: String = "") {
        self.id = id
        self.targetSequenceId = targetSequenceId
        self.pinnedBy = pinnedBy
        self.createdAt = createdAt
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty,
              let target = json["targetSequenceId"]?.intValue, target > 0 else { return nil }
        self.init(
            id: id,
            targetSequenceId: target,
            pinnedBy: json["actorId"]?.stringValue ?? "",
            createdAt: json["createdAt"]?.stringValue ?? ""
        )
    }
}

/// `GET /actions` decoded for a room: per-message summaries, the room's pinned messages, plus the reply rows in the
/// page (a thread fetch, `?targetSequenceId=`, returns that thread's replies here).
public struct RoomActionsPage: Decodable, Equatable, Sendable {
    public let byTarget: [Int64: RoomReactionSummary]
    public let replies: [RoomReply]
    /// "Working on" updates in the page, oldest first.
    public let workingOn: [RoomWorkingOn]
    /// How long a "working on" stays current without a newer one (the API's `workingOnStaleAfterSeconds`).
    public let workingOnStaleAfter: TimeInterval
    /// The room's pinned messages, newest pin first.
    public let pinned: [RoomPinnedMessage]
    /// How many messages the room can pin at once (the API's limit).
    public let pinLimit: Int

    public init(
        byTarget: [Int64: RoomReactionSummary] = [:],
        replies: [RoomReply] = [],
        workingOn: [RoomWorkingOn] = [],
        workingOnStaleAfter: TimeInterval = 900,
        pinned: [RoomPinnedMessage] = [],
        pinLimit: Int = 10
    ) {
        self.byTarget = byTarget
        self.replies = replies
        self.workingOn = workingOn
        self.workingOnStaleAfter = workingOnStaleAfter
        self.pinned = pinned
        self.pinLimit = pinLimit
    }

    enum CodingKeys: String, CodingKey { case actions, projection }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let actions = (try? container.decode([JSONValue].self, forKey: .actions)) ?? []
        let projection = (try? container.decode(JSONValue.self, forKey: .projection)) ?? .null
        var byTarget: [Int64: RoomReactionSummary] = [:]
        for row in projection["byTarget"]?.arrayValue ?? [] {
            if let summary = RoomReactionSummary(json: row) { byTarget[summary.targetSequenceId] = summary }
        }
        self.byTarget = byTarget
        var pinnedTargets = Set<Int64>()
        self.pinned = (projection["pinnedMessages"]?.arrayValue ?? [])
            .compactMap(RoomPinnedMessage.init(json:))
            .filter { pinnedTargets.insert($0.targetSequenceId).inserted }
        self.pinLimit = Int(clamping: max(1, projection["pinLimit"]?.intValue ?? 10))
        // Newest revision wins per reply id; ordered oldest first, like the web's thread.
        var latest: [String: RoomReply] = [:]
        for reply in actions.compactMap(RoomReply.init(json:)) {
            if let existing = latest[reply.id], existing.revision >= reply.revision { continue }
            latest[reply.id] = reply
        }
        self.workingOn = actions.compactMap(RoomWorkingOn.init(json:)).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        self.workingOnStaleAfter = TimeInterval(max(60, min(86_400, projection["workingOnStaleAfterSeconds"]?.intValue ?? 900)))
        self.replies = latest.values.sorted {
            ($0.createdAt, $0.id) < ($1.createdAt, $1.id)
        }
    }
}

extension HTTPSessionTransport {
    /// `GET /actions` for the room (`targetSequenceId == nil`, newest 500 actions plus the projection) or one
    /// thread (`targetSequenceId` set).
    public func roomActions(
        sessionId: String,
        targetSequenceId: Int64? = nil,
        limit: Int = 500
    ) async throws -> RoomActionsPage {
        try Self.requireIdentifier(sessionId)
        try Self.requireLimit(limit, allowed: 1...500)
        if let targetSequenceId, targetSequenceId < 1 { throw SessionTransportError.invalidRequest }
        return try await getDecodable(
            RoomActionsPage.self,
            path: ["api", "v1", "sessions", sessionId, "actions"],
            query: [
                targetSequenceId.map { URLQueryItem(name: "targetSequenceId", value: String($0)) },
                URLQueryItem(name: "limit", value: String(limit))
            ].compactMap { $0 }
        )
    }
}
