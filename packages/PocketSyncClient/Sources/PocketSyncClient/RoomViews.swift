import Foundation
import PocketContracts

// Read receipts and presence, as the web shows them (sentinelayer-api `POST/GET /sessions/{id}/view-receipts` and
// `GET /sessions/{id}/presence`): "Viewed by" and ticks under messages, and who is in the room now.

/// A message or reply to record a view of: its UUID (a message's event id, a reply's action id) at the revision
/// shown.
public struct RoomViewTarget: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case message
        case reply
    }

    public let kind: Kind
    public let id: String
    public let revision: Int64

    /// nil when `id` is not a UUID: the API refuses those, and a row still being sent has none yet.
    public init?(kind: Kind, id: String, revision: Int64) {
        guard let uuid = UUID(uuidString: id.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.kind = kind
        self.id = uuid.uuidString.lowercased()
        self.revision = max(1, revision)
    }
}

/// Someone who viewed a message or reply: a person by account id, an agent by its id.
public struct RoomViewer: Equatable, Sendable {
    public let isHuman: Bool
    public let actorId: String
    public let viewedAt: String

    public init(isHuman: Bool, actorId: String, viewedAt: String) {
        self.isHuman = isHuman
        self.actorId = actorId
        self.viewedAt = viewedAt
    }

    init?(json: JSONValue) {
        let kind = json["actorKind"]?.stringValue
        guard kind == "human" || kind == "agent",
              let actorId = json["actorId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !actorId.isEmpty else { return nil }
        self.init(isHuman: kind == "human", actorId: actorId, viewedAt: json["viewedAt"]?.stringValue ?? "")
    }
}

/// Who has viewed one message or reply, at its current revision (an edit starts the list again).
public struct RoomViewSummary: Equatable, Sendable {
    public let kind: RoomViewTarget.Kind
    public let id: String
    public let revision: Int64
    public let viewedCount: Int
    /// You have viewed this revision.
    public let selfViewed: Bool
    /// Oldest view first, at most 500 (`isTruncated` when there were more).
    public let viewers: [RoomViewer]
    public let isTruncated: Bool

    public init(
        kind: RoomViewTarget.Kind,
        id: String,
        revision: Int64,
        viewedCount: Int,
        selfViewed: Bool = false,
        viewers: [RoomViewer] = [],
        isTruncated: Bool = false
    ) {
        self.kind = kind
        self.id = id.lowercased()
        self.revision = revision
        self.viewedCount = viewedCount
        self.selfViewed = selfViewed
        self.viewers = viewers
        self.isTruncated = isTruncated
    }

    init?(json: JSONValue) {
        guard let kind = json["kind"]?.stringValue.flatMap(RoomViewTarget.Kind.init(rawValue:)),
              let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        self.init(
            kind: kind,
            id: id,
            revision: json["messageRevision"]?.intValue ?? 1,
            viewedCount: Int(clamping: max(0, json["viewedCount"]?.intValue ?? 0)),
            selfViewed: json["selfViewed"]?.boolValue ?? false,
            viewers: (json["viewers"]?.arrayValue ?? []).compactMap(RoomViewer.init(json:)),
            isTruncated: json["viewersTruncated"]?.boolValue ?? false
        )
    }
}

/// `GET /view-receipts`: `{"targets":[...]}`, one summary per message or reply asked about.
public struct RoomViewsPage: Decodable, Equatable, Sendable {
    public let summaries: [RoomViewSummary]

    enum CodingKeys: String, CodingKey { case targets }

    public init(summaries: [RoomViewSummary] = []) {
        self.summaries = summaries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decode([JSONValue].self, forKey: .targets)
        self.summaries = rows.compactMap(RoomViewSummary.init(json:))
    }
}

/// Someone in the room now.
public struct RoomPresentParticipant: Equatable, Sendable {
    /// `human-<account id>` for a person, the agent id for an agent.
    public let id: String
    public let isHuman: Bool
    public let displayName: String?
    public let isIdle: Bool
    public let lastSeen: String?
    /// An agent's lab as the server reports it from the model it sent (`anthropic`, `openai`, … or `other`).
    public let lab: String?
    /// Whether the server sees the agent working now, and until when that holds without news (ms since 1970).
    public let isWorking: Bool
    public let workingUntilMs: Int64?
    /// The agent runs in a box.
    public let isBox: Bool
    /// A person's posting handle: their posts are `human-<login>`.
    public let login: String?

    public init(id: String, isHuman: Bool, displayName: String? = nil, isIdle: Bool = false, lastSeen: String? = nil,
                lab: String? = nil, isWorking: Bool = false, workingUntilMs: Int64? = nil, isBox: Bool = false,
                login: String? = nil) {
        self.id = id
        self.isHuman = isHuman
        self.displayName = displayName
        self.isIdle = isIdle
        self.lastSeen = lastSeen
        self.lab = lab
        self.isWorking = isWorking
        self.workingUntilMs = workingUntilMs
        self.isBox = isBox
        self.login = login
    }

    init?(json: JSONValue) {
        guard let id = json["agentId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty
        else { return nil }
        let name = json["displayName"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            id: id,
            isHuman: json["kind"]?.stringValue == "human" || id.lowercased().hasPrefix("human-"),
            displayName: name?.isEmpty == false ? name : nil,
            isIdle: json["state"]?.stringValue == "idle",
            lastSeen: json["lastSeen"]?.stringValue,
            lab: json["lab"]?.stringValue,
            isWorking: json["working"]?.boolValue ?? false,
            workingUntilMs: json["workingUntilMs"]?.intValue,
            isBox: json["box"]?.boolValue ?? false,
            login: json["login"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// `GET /presence`: who is in the room now, most recent first. Not available (the server cannot tell) is not the
/// same as nobody: the counts are nil then.
public struct RoomPresence: Decodable, Equatable, Sendable {
    public let isAvailable: Bool
    public let participants: [RoomPresentParticipant]
    public let humansOnline: Int?
    public let agentsOnline: Int?
    /// How long a heartbeat keeps you present, in seconds.
    public let ttlSeconds: Int?

    enum CodingKeys: String, CodingKey { case status, present, humansOnline, agentsOnline, ttlSeconds }

    public init(
        isAvailable: Bool = true,
        participants: [RoomPresentParticipant] = [],
        humansOnline: Int? = nil,
        agentsOnline: Int? = nil,
        ttlSeconds: Int? = nil
    ) {
        self.isAvailable = isAvailable
        self.participants = participants
        self.humansOnline = humansOnline
        self.agentsOnline = agentsOnline
        self.ttlSeconds = ttlSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decodeIfPresent(String.self, forKey: .status)
        let humans = try? container.decodeIfPresent(Int.self, forKey: .humansOnline)
        let agents = try? container.decodeIfPresent(Int.self, forKey: .agentsOnline)
        let rows = (try? container.decode([JSONValue].self, forKey: .present)) ?? []
        self.isAvailable = status == "ok" && humans != nil
        self.participants = isAvailable ? rows.compactMap(RoomPresentParticipant.init(json:)) : []
        self.humansOnline = isAvailable ? humans : nil
        self.agentsOnline = isAvailable ? agents : nil
        self.ttlSeconds = try? container.decodeIfPresent(Int.self, forKey: .ttlSeconds)
    }
}
