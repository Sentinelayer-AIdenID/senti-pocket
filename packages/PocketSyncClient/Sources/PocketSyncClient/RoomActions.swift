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
    /// What it says; empty for a reply that is only photos or files.
    public let text: String
    public let createdAt: String
    public let revision: Int64
    public let isEdited: Bool
    /// Its photos and files, in the shape a message's take (sentinelayer-api #1135). An API that stores none, and a
    /// reply from before it, carries none.
    public let attachments: [RoomAttachment]
    /// Who it was addressed to, as the server decided when it was written (`RoomAddressed`), as a message's.
    public let addressed: RoomAddressed?
    /// The box its author runs in, from the author record (`RoomAgentBox`).
    public let authorBox: RoomAgentBox?

    public init(
        id: String,
        targetSequenceId: Int64,
        targetActionId: String? = nil,
        authorId: String,
        text: String,
        createdAt: String,
        revision: Int64 = 1,
        isEdited: Bool = false,
        attachments: [RoomAttachment] = [],
        addressed: RoomAddressed? = nil,
        authorBox: RoomAgentBox? = nil
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
        self.attachments = attachments
        self.addressed = addressed
        self.authorBox = authorBox
    }

    /// A reply action, or nil. It says something, or carries a photo or file; a reply with neither is not shown.
    public init?(json: JSONValue) {
        guard json["actionType"]?.stringValue == "reply",
              let id = json["id"]?.stringValue, !id.isEmpty,
              let target = json["targetSequenceId"]?.intValue, target > 0 else {
            return nil
        }
        let raw = json["note"]?.stringValue ?? ""
        let note = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : raw
        // Absent (an API without reply attachments, or an older row) is none.
        let attachments = RoomAttachment.list(from: json)
        guard !note.isEmpty || !attachments.isEmpty else { return nil }
        let author = json["actorId"]?.stringValue ?? ""
        self.init(
            id: id,
            targetSequenceId: target,
            targetActionId: json["targetActionId"]?.stringValue,
            authorId: author,
            text: note,
            createdAt: json["createdAt"]?.stringValue ?? "",
            revision: json["messageRevision"]?.intValue ?? 1,
            isEdited: json["editedAt"]?.stringValue.map { !$0.isEmpty } ?? false,
            attachments: attachments,
            addressed: RoomAddressed(in: json),
            authorBox: RoomAgentBox.actor(of: json)
        )
    }
}

/// Whether the API takes photos and files on a reply (sentinelayer-api #1135), as its reads show: that API writes an
/// `attachments` list on every action it returns (empty when there are none), and an older one writes none.
public enum RoomReplyAttachmentSupport: Equatable, Sendable {
    /// Nothing read yet says.
    case unknown
    case supported
    case unsupported

    /// What a page of action rows says: any row with an `attachments` list is the API that takes them; rows with none
    /// are an older API; no rows say nothing.
    static func reading(_ rows: [JSONValue]) -> RoomReplyAttachmentSupport {
        let objects = rows.filter { $0.objectValue != nil }
        guard !objects.isEmpty else { return .unknown }
        return objects.contains { $0["attachments"]?.arrayValue != nil } ? .supported : .unsupported
    }
}

/// One emoji reaction on a message: the emoji, how many reacted with it, whether you did, and some of who did.
public struct RoomEmojiReaction: Equatable, Sendable {
    public let emoji: String
    public let count: Int
    public let viewerReacted: Bool
    /// Public ids of who reacted, at most `actorLimit`.
    public let actors: [String]

    /// The most distinct emoji a message holds (the API's limit).
    public static let limit = 20
    /// The most reactors the API lists per emoji.
    public static let actorLimit = 10

    public init(emoji: String, count: Int, viewerReacted: Bool, actors: [String] = []) {
        self.emoji = emoji
        self.count = count
        self.viewerReacted = viewerReacted
        self.actors = actors
    }

    /// One entry of the summary's `emojiReactions`, or nil unless it holds exactly one emoji and a count.
    init?(json: JSONValue) {
        guard let emoji = json["emoji"]?.stringValue, ReactionEmoji.isValid(emoji),
              let count = json["count"]?.intValue, count > 0 else { return nil }
        let actors = (json["actors"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
        self.init(
            emoji: emoji,
            count: Int(clamping: count),
            viewerReacted: json["viewerReacted"]?.boolValue ?? false,
            actors: Array(actors.prefix(Self.actorLimit))
        )
    }

    /// The summary's `emojiReactions` in first-use order: entries that are not one emoji are dropped, an emoji
    /// listed twice counts once, and at most `limit` are kept.
    static func list(_ json: JSONValue?) -> [RoomEmojiReaction] {
        var seen = Set<String>()
        let entries = (json?.arrayValue ?? []).compactMap(RoomEmojiReaction.init(json:))
        return Array(entries.filter { seen.insert($0.emoji).inserted }.prefix(limit))
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
    /// Emoji reactions, in the order they were first used.
    public let emojiReactions: [RoomEmojiReaction]

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
        isPinned: Bool = false,
        emojiReactions: [RoomEmojiReaction] = []
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
        self.emojiReactions = emojiReactions
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
            isPinned: json["isPinned"]?.boolValue ?? false,
            emojiReactions: RoomEmojiReaction.list(json["emojiReactions"])
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
    /// Whether this API takes photos and files on a reply, as its rows show.
    public let replyAttachments: RoomReplyAttachmentSupport
    /// What reads the page older than this one (`auditWindow.nextCursor`, sent back as `beforeCursor`); nil at the
    /// oldest.
    public let nextCursor: String?
    /// Older actions than this page's are there (`auditWindow.hasMore`): the API reads newest first.
    public var hasMore: Bool { nextCursor != nil }
    /// What reads the page newer than this one (`afterCursor`, sent back as `afterCursor`): a read around a reply, and
    /// the pages read on from it, give one; nil when the page reaches the thread's newest action, and on other reads.
    public let afterCursor: String?
    /// The reply a read around a reply (`aroundActionId`, sentinelayer-api #1199) is around: the one asked for, or the
    /// reply a collapsed one resolved to. Nil on any other read, and from an API without that read, which answers it
    /// with the thread's newest page.
    public let anchoredActionId: String?

    public init(
        byTarget: [Int64: RoomReactionSummary] = [:],
        replies: [RoomReply] = [],
        workingOn: [RoomWorkingOn] = [],
        workingOnStaleAfter: TimeInterval = 900,
        pinned: [RoomPinnedMessage] = [],
        pinLimit: Int = 10,
        replyAttachments: RoomReplyAttachmentSupport = .unknown,
        nextCursor: String? = nil,
        afterCursor: String? = nil,
        anchoredActionId: String? = nil
    ) {
        self.byTarget = byTarget
        self.replies = replies
        self.workingOn = workingOn
        self.workingOnStaleAfter = workingOnStaleAfter
        self.pinned = pinned
        self.pinLimit = pinLimit
        self.replyAttachments = replyAttachments
        self.nextCursor = nextCursor
        self.afterCursor = afterCursor
        self.anchoredActionId = anchoredActionId
    }

    enum CodingKeys: String, CodingKey { case actions, projection, auditWindow, afterCursor, anchoredActionId }

    /// A cursor as the API writes one (1 to 512 bytes), or nil: a cursor that could not be one is never sent back.
    static func cursor(_ value: String?) -> String? {
        value.flatMap { (1...512).contains($0.utf8.count) ? $0 : nil }
    }

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
        self.replyAttachments = RoomReplyAttachmentSupport.reading(actions)
        // Older pages, as the API reads them: newest first by (created_at, id), the next older through the cursor. A
        // cursor that could not be one is no cursor: the thread is then as far back as it goes.
        let window = (try? container.decode(JSONValue.self, forKey: .auditWindow)) ?? .null
        let cursor = Self.cursor(window["nextCursor"]?.stringValue)
        self.nextCursor = window["hasMore"]?.boolValue == true ? cursor : nil
        // A read around a reply (and the pages read on from it): the newer side's cursor, and the reply it is around.
        self.afterCursor = Self.cursor(try? container.decodeIfPresent(String.self, forKey: .afterCursor))
        self.anchoredActionId = (try? container.decodeIfPresent(String.self, forKey: .anchoredActionId))
            .flatMap { (1...128).contains($0.utf8.count) ? $0 : nil }
    }
}

/// The API's answer to a read around a reply that is not in the thread: missing, deleted, in another room or thread,
/// or a collapsed reply that resolves nowhere are one answer (404 `ACTION_NOT_FOUND`). The API reads the room's access
/// first, so this is never a room this account cannot read: that 404 keeps the membership boundary (`accessDenied`).
public struct RoomActionNotFound: Error, Equatable, Sendable {
    public init() {}

    /// The API's code for it.
    static let code = "ACTION_NOT_FOUND"
}

extension HTTPSessionTransport {
    /// `GET /actions` for the room (`targetSequenceId == nil`, newest 500 actions plus the projection) or one
    /// thread (`targetSequenceId` set).
    public func roomActions(
        sessionId: String,
        targetSequenceId: Int64? = nil,
        limit: Int = 500
    ) async throws -> RoomActionsPage {
        try await roomActions(sessionId: sessionId, targetSequenceId: targetSequenceId, limit: limit, beforeCursor: nil)
    }

    /// The same, one page older than `beforeCursor` (a page's `nextCursor`): a thread of any length is read a page at
    /// a time, newest first.
    public func roomActions(
        sessionId: String,
        targetSequenceId: Int64?,
        limit: Int,
        beforeCursor: String?
    ) async throws -> RoomActionsPage {
        try Self.requireIdentifier(sessionId)
        try Self.requireLimit(limit, allowed: 1...500)
        if let targetSequenceId, targetSequenceId < 1 { throw SessionTransportError.invalidRequest }
        if let beforeCursor, !(1...512).contains(beforeCursor.utf8.count) { throw SessionTransportError.invalidRequest }
        return try await getDecodable(
            RoomActionsPage.self,
            path: ["api", "v1", "sessions", sessionId, "actions"],
            query: [
                targetSequenceId.map { URLQueryItem(name: "targetSequenceId", value: String($0)) },
                URLQueryItem(name: "limit", value: String(limit)),
                beforeCursor.map { URLQueryItem(name: "beforeCursor", value: $0) }
            ].compactMap { $0 }
        )
    }

    /// One thread opened at one of its replies, in ONE read however far back the reply is (`aroundActionId`,
    /// sentinelayer-api #1199): up to `limit` actions around it, newest first, with the reply it is around
    /// (`anchoredActionId`) and a cursor each way. No cursor goes with it. A reply not in the thread throws
    /// `RoomActionNotFound`. An API without this read answers it with the thread's newest page.
    public func roomActions(
        sessionId: String,
        targetSequenceId: Int64,
        limit: Int,
        aroundActionId: String
    ) async throws -> RoomActionsPage {
        try Self.requireIdentifier(sessionId)
        try Self.requireLimit(limit, allowed: 1...500)
        // A reply's id is a UUID: anything else could not be one, and is never sent.
        guard targetSequenceId >= 1, UUID(uuidString: aroundActionId) != nil else {
            throw SessionTransportError.invalidRequest
        }
        return try await getDecodable(
            RoomActionsPage.self,
            path: ["api", "v1", "sessions", sessionId, "actions"],
            query: [
                URLQueryItem(name: "targetSequenceId", value: String(targetSequenceId)),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "aroundActionId", value: aroundActionId)
            ],
            notFound: (code: RoomActionNotFound.code, error: RoomActionNotFound())
        )
    }

    /// The page newer than `afterCursor` (a read around a reply's, or a page's read on from it), newest first.
    public func roomActions(
        sessionId: String,
        targetSequenceId: Int64,
        limit: Int,
        afterCursor: String
    ) async throws -> RoomActionsPage {
        try Self.requireIdentifier(sessionId)
        try Self.requireLimit(limit, allowed: 1...500)
        guard targetSequenceId >= 1, RoomActionsPage.cursor(afterCursor) != nil else {
            throw SessionTransportError.invalidRequest
        }
        return try await getDecodable(
            RoomActionsPage.self,
            path: ["api", "v1", "sessions", sessionId, "actions"],
            query: [
                URLQueryItem(name: "targetSequenceId", value: String(targetSequenceId)),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "afterCursor", value: afterCursor)
            ]
        )
    }
}
