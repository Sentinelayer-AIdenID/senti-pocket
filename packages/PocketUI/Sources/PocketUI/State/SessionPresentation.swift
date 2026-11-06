import Foundation
import PocketContracts

/// Provenance is supplied by the repository coordinator; PocketUI never infers live data from non-empty rows.
public enum SessionPresentationProvenance: Equatable, Sendable {
    case network(lastUpdated: Date)
    case cache(cachedAt: Date, authenticationExpired: Bool)
    case fixture
    case unavailable
}

public enum SessionLoadFailure: Equatable, Sendable {
    case reauthenticationRequired
    case accessDenied
    case offlineNoCache
    case network
    case invalidData
    case service

    public var title: String {
        switch self {
        case .reauthenticationRequired: return "Sign in again"
        case .accessDenied: return "Access denied"
        case .offlineNoCache: return "Nothing available offline"
        case .network: return "Connection unavailable"
        case .invalidData: return "Session data unavailable"
        case .service: return "Sessions unavailable"
        }
    }

    public var detail: String {
        switch self {
        case .reauthenticationRequired:
            return "Your Senti authorization is no longer valid. Sign in again before loading protected sessions."
        case .accessDenied:
            return "This account is not authorized to open that session. No protected cached content is shown."
        case .offlineNoCache:
            return "Connect to Senti once to make authorized session data available on this device."
        case .network:
            return "Check your connection and try again."
        case .invalidData:
            return "Senti returned session data that this app could not safely present."
        case .service:
            return "Senti could not load sessions right now."
        }
    }

    var suppressesProtectedContent: Bool {
        switch self {
        case .reauthenticationRequired, .accessDenied, .offlineNoCache, .invalidData:
            return true
        case .network, .service:
            return false
        }
    }
}

public struct SessionListPresentationState: Equatable, Sendable {
    public let rows: [SessionRowPresentation]
    public let resultCount: Int
    public let includesArchived: Bool
    public let hasMore: Bool
    public let provenance: SessionPresentationProvenance
    public let isRefreshing: Bool
    public let failure: SessionLoadFailure?

    public init(
        page: SessionListPage,
        provenance: SessionPresentationProvenance,
        isRefreshing: Bool = false,
        failure: SessionLoadFailure? = nil
    ) {
        self.init(
            sessions: page.sessions,
            resultCount: page.count,
            includesArchived: page.includeArchived,
            hasMore: page.hasMore,
            provenance: provenance,
            isRefreshing: isRefreshing,
            failure: failure
        )
    }

    /// Projects an already validated repository snapshot without manufacturing a wire response.
    /// - Parameters:
    ///   - readThrough: how far this phone has read each room since, as the server confirmed it (by session id). A
    ///     count the server made before that read is stale and shows no badge (`SessionRowPresentation`).
    ///   - caughtUp: rooms this phone caught up on, thread replies included, since these rows were counted.
    public init(
        sessions: [SessionSummary],
        resultCount: Int? = nil,
        includesArchived: Bool,
        hasMore: Bool,
        provenance: SessionPresentationProvenance,
        isRefreshing: Bool = false,
        failure: SessionLoadFailure? = nil,
        readThrough: [String: Int64] = [:],
        caughtUp: Set<String> = []
    ) {
        let reportedCount = resultCount ?? sessions.count
        let ids = sessions.map(\.sessionId)
        let identitiesAreValid = ids.allSatisfy { $0.pocketNonblank != nil }
            && Set(ids.map(OpaqueUTF8Identity.init)).count == ids.count
        let countIsValid = reportedCount >= 0 && reportedCount == sessions.count
        let sourceAllowsContent: Bool
        if case .unavailable = provenance {
            sourceAllowsContent = false
        } else {
            sourceAllowsContent = true
        }
        let failureAllowsContent = failure?.suppressesProtectedContent != true
        let canPresentRows = identitiesAreValid && countIsValid && sourceAllowsContent && failureAllowsContent

        self.rows = canPresentRows
            ? sessions.map {
                SessionRowPresentation($0, readThrough: readThrough[$0.sessionId],
                                       caughtUp: caughtUp.contains($0.sessionId))
            }
            : []
        self.resultCount = canPresentRows ? reportedCount : 0
        self.includesArchived = includesArchived
        self.hasMore = canPresentRows && hasMore
        self.provenance = provenance
        self.isRefreshing = isRefreshing
        self.failure = identitiesAreValid && countIsValid ? failure : .invalidData
    }
}

public struct SessionRowPresentation: Equatable, Identifiable, Sendable {
    public let id: OpaqueUTF8Identity
    public let sessionId: String
    public let title: String
    public let summary: String?
    public let status: String
    public let archiveStatus: String
    public let membershipRole: String
    public let agentCount: Int
    public let eventCount: Int
    public let lastActivity: ParsedSessionTimestamp?
    /// The room's kind when it isn't a general room: "Study together", "Research" or "Meetings".
    public let roomTypeLabel: String?
    /// Who is in the room now and your unread messages, for the row's counts and badge.
    public let activity: RoomListActivity
    /// The first message you have not read, where the room opens; nil with nothing unread.
    public let firstUnreadSequenceId: Int64?
    /// How far you have read the room: the server's mark, or further where this phone has read since.
    public let lastReadSequenceId: Int64?
    /// A direct message's other side, as you see it; nil for a room.
    public let counterpart: SessionCounterpart?
    /// The room a direct message was opened from, where the side panel nests it; nil when that room is gone or no
    /// longer visible to you.
    public let originRoomId: String?
    /// Your folder for the room, as the room list says (the only copy the app keeps).
    public let folderId: String?

    /// A direct message with one person or agent.
    public var isDirect: Bool { counterpart != nil }

    /// - Parameters:
    ///   - readThrough: how far this phone has read the room since the list was counted, as the server confirmed it.
    ///     The server's unread messages all come at or after its first unread, so a first unread at or behind that
    ///     point means the count was made before the read: no badge until the server counts again. One after it is
    ///     news the read did not cover, and shows.
    ///   - caughtUp: this phone caught up on the room since it was counted. A count with no first unread message is
    ///     thread replies alone (the count includes them), which that read covered.
    fileprivate init(_ session: SessionSummary, readThrough: Int64?, caughtUp: Bool = false) {
        self.id = OpaqueUTF8Identity(session.sessionId)
        self.sessionId = session.sessionId
        // A direct message is named for whom it is with.
        self.counterpart = session.isDirect ? session.counterpart : nil
        self.originRoomId = session.isDirect ? session.originRoomId : nil
        self.folderId = session.isDirect ? nil : session.folderId
        self.title = self.counterpart?.displayName ?? session.title.pocketNonblank ?? "Untitled chat"
        // The room's saved summary: the server's prose as written, or an older server's five labelled parts read
        // into sentences.
        self.summary = session.summaryText.pocketNonblank.map(SummaryProse.saved).pocketNonblank
        self.status = session.status
        self.archiveStatus = session.archiveStatus
        self.membershipRole = session.membershipRole
        self.agentCount = session.agentCount
        self.eventCount = session.eventCount
        self.lastActivity = ParsedSessionTimestamp(session.lastActivityAt)
        self.roomTypeLabel = Self.roomTypeLabel(session.roomType)
        let readHere = readThrough ?? 0
        let first = session.unread?.firstUnreadSequenceId
        let staleCount = first.map { $0 <= readHere } ?? caughtUp
        let unread = staleCount ? 0 : (session.unread?.count ?? 0)
        self.activity = RoomListActivity(
            humansOnline: session.online?.humans,
            agentsOnline: session.online?.agents,
            unread: unread
        )
        self.firstUnreadSequenceId = unread > 0 ? first : nil
        let lastRead = max(session.lastReadSequenceId ?? 0, readHere)
        self.lastReadSequenceId = lastRead > 0 ? lastRead : nil
    }

    /// The label a room kind shows, the phone's New room names; nil for general rooms and kinds this build doesn't know.
    public static func roomTypeLabel(_ type: String?) -> String? {
        switch type?.lowercased() {
        case "study": return "Study together"
        case "research": return "Research"
        case "conference": return "Meetings"
        default: return nil
        }
    }

    public var statusLabel: String { status.pocketTokenLabel }
    public var archiveStatusLabel: String { archiveStatus.pocketTokenLabel }
    public var membershipRoleLabel: String { membershipRole.pocketTokenLabel }
}

public struct SessionActivityPresentationState: Equatable, Sendable {
    public let sessionId: String
    public let events: [SessionEventRowPresentation]
    public let actions: [SessionActionRowPresentation]
    public let provenance: SessionPresentationProvenance
    public let isRefreshing: Bool
    public let failure: SessionLoadFailure?

    public init(
        sessionId: String,
        eventPage: SessionEventForwardPage,
        actionPage: SessionActionPage,
        provenance: SessionPresentationProvenance,
        isRefreshing: Bool = false,
        failure: SessionLoadFailure? = nil,
        naming: ActivityNaming = ActivityNaming()
    ) {
        let eventSessionsMatch = eventPage.events.allSatisfy {
            OpaqueUTF8Identity.matches($0.sessionId, sessionId)
        }
        let actionSessionsMatch = OpaqueUTF8Identity.matches(actionPage.sessionId, sessionId)
            && actionPage.actions.allSatisfy {
                OpaqueUTF8Identity.matches($0.sessionId, sessionId)
            }
        let eventIDs = eventPage.events.map(\.id)
        let eventSequences = eventPage.events.map(\.sequenceId)
        let actionIDs = actionPage.actions.map(\.id)
        let identitiesAreValid = sessionId.pocketNonblank != nil
            && eventIDs.allSatisfy { $0.pocketNonblank != nil }
            && actionIDs.allSatisfy { $0.pocketNonblank != nil }
            && Set(eventIDs.map(OpaqueUTF8Identity.init)).count == eventIDs.count
            && Set(eventSequences).count == eventSequences.count
            && Set(actionIDs.map(OpaqueUTF8Identity.init)).count == actionIDs.count
        let sourceAllowsContent: Bool
        if case .unavailable = provenance {
            sourceAllowsContent = false
        } else {
            sourceAllowsContent = true
        }
        let failureAllowsContent = failure?.suppressesProtectedContent != true

        self.sessionId = sessionId
        self.provenance = provenance
        self.isRefreshing = isRefreshing

        guard eventSessionsMatch, actionSessionsMatch, identitiesAreValid,
              sourceAllowsContent, failureAllowsContent else {
            self.events = []
            self.actions = []
            self.failure = identitiesAreValid && eventSessionsMatch && actionSessionsMatch
                ? failure
                : .invalidData
            return
        }

        // A person's own messages carry the name the server keeps for them: their actions here go by it too.
        var spoken: [String: String] = [:]
        for event in eventPage.events where event.agentId.lowercased().hasPrefix("human-") {
            if let name = event.agent["displayName"]?.stringValue { spoken[event.agentId] = name }
        }
        let named = naming.adding(names: spoken)
        self.events = eventPage.events.map { SessionEventRowPresentation($0, naming: named) }
        self.actions = actionPage.actions.map { SessionActionRowPresentation($0, naming: named) }
        self.failure = failure
    }
}

public struct SessionEventRowPresentation: Equatable, Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        public let sessionId: String
        public let eventId: String

        public static func == (lhs: Self, rhs: Self) -> Bool {
            OpaqueUTF8Identity.matches(lhs.sessionId, rhs.sessionId)
                && OpaqueUTF8Identity.matches(lhs.eventId, rhs.eventId)
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(OpaqueUTF8Identity(sessionId))
            hasher.combine(OpaqueUTF8Identity(eventId))
        }
    }

    public let id: ID
    public let sessionId: String
    public let sequenceId: Int64
    public let eventType: String
    public let author: String
    public let text: String?
    public let timestamp: ParsedSessionTimestamp

    fileprivate init(_ event: SessionEventDTO, naming: ActivityNaming) {
        self.id = ID(sessionId: event.sessionId, eventId: event.id)
        self.sessionId = event.sessionId
        self.sequenceId = event.sequenceId
        self.eventType = event.event
        // As the chat names its authors: an agent by its id, a person by name (ActivityNaming).
        self.author = naming.name(of: event.agentId, displayName: event.agent["displayName"]?.stringValue)
        self.text = event.payload["text"]?.stringValue.pocketNonblank
        self.timestamp = ParsedSessionTimestamp(event.ts)
    }

    /// What happened, in plain words (never the server's token): "Message", "Chat renamed", or "Update".
    public var eventTypeLabel: String { ActivityWords.event(eventType) }
}

public struct SessionActionRowPresentation: Equatable, Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        public let sessionId: String
        public let actionId: String

        public static func == (lhs: Self, rhs: Self) -> Bool {
            OpaqueUTF8Identity.matches(lhs.sessionId, rhs.sessionId)
                && OpaqueUTF8Identity.matches(lhs.actionId, rhs.actionId)
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(OpaqueUTF8Identity(sessionId))
            hasher.combine(OpaqueUTF8Identity(actionId))
        }
    }

    public let id: ID
    public let sessionId: String
    public let targetSequenceId: Int64
    public let actionType: String
    public let actor: String
    public let note: String?
    public let createdAt: ParsedSessionTimestamp

    fileprivate init(_ action: SessionActionDTO, naming: ActivityNaming) {
        self.id = ID(sessionId: action.sessionId, actionId: action.id)
        self.sessionId = action.sessionId
        self.targetSequenceId = action.targetSequenceId
        self.actionType = action.actionType
        self.actor = naming.name(of: action.actorId, isHuman: action.actorKind.lowercased() == "human")
        self.note = action.note.pocketNonblank
        self.createdAt = ParsedSessionTimestamp(action.createdAt)
    }

    /// What someone did, in plain words (never the server's token): "Liked", "Seen", or "Update".
    public var actionTypeLabel: String { ActivityWords.action(actionType) }
    /// What it was on, without the server's numbers.
    public var targetLabel: String {
        targetSequenceId == 0 ? "On the chat" : "On a message"
    }
}

/// Who did something in Activity, named as the chat names people (ticket 693f0cc5): "You"; a person by the name the
/// room gives them, else their GitHub login, else "A person"; an agent by its id, never the name it gives itself (usually
/// a model's, and an agent can set it to anything). Never an account's hex or "human-".
public struct ActivityNaming: Equatable, Sendable {
    public static let you = "You"
    public static let somePerson = "A person"
    public static let someAgent = "An agent"

    /// Your ids, as the room writes them ("human-<login>", "human-g.<account>", the login, the account id).
    private let yourKeys: Set<String>
    /// The room's names for people, by id.
    private let names: [String: String]

    public init(you: Set<String> = [], names: [String: String] = [:]) {
        self.yourKeys = Set(you.compactMap(Self.key))
        var byKey: [String: String] = [:]
        for (id, name) in names {
            guard let key = Self.key(id), let name = Self.plainName(name), byKey[key] == nil else { continue }
            byKey[key] = name
        }
        self.names = byKey
    }

    /// The same naming, with names for people this one has none for (the room's names win).
    func adding(names more: [String: String]) -> ActivityNaming {
        var merged = names
        for (id, name) in more {
            guard let key = Self.key(id), let name = Self.plainName(name), merged[key] == nil else { continue }
            merged[key] = name
        }
        return ActivityNaming(keys: yourKeys, names: merged)
    }

    private init(keys: Set<String>, names: [String: String]) {
        self.yourKeys = keys
        self.names = names
    }

    /// The name for whoever wrote or did something. A `human-` id is a person whatever else is said (agents can never
    /// claim the prefix); `displayName` counts only for a person.
    public func name(of id: String, isHuman: Bool = false, displayName: String? = nil) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard isHuman || lowered.hasPrefix("human-") || lowered == "human" else {
            return trimmed.isEmpty || Self.looksLikeAnId(trimmed) ? Self.someAgent : trimmed
        }
        let key = Self.key(trimmed)
        if let key, yourKeys.contains(key) { return Self.you }
        if let key, let name = names[key] { return name }
        if let name = Self.plainName(displayName) { return name }
        if let login = Self.login(trimmed) { return login }
        return Self.somePerson
    }

    /// One person under all the ids the room writes them with: "human-ada" and "ada" are the same key.
    static func key(_ id: String) -> String? {
        let lowered = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bare = lowered.hasPrefix("human-") ? String(lowered.dropFirst("human-".count)) : lowered
        return bare.isEmpty || bare == "human" ? nil : bare
    }

    /// A GitHub login reads as itself; a Google account (`g.<hex>`) or any id-like text is no name.
    private static func login(_ id: String) -> String? {
        let bare = id.lowercased().hasPrefix("human-") ? String(id.dropFirst("human-".count)) : id
        guard !bare.isEmpty, bare.lowercased() != "human", !bare.lowercased().hasPrefix("g."),
              !bare.contains(where: \.isWhitespace), !looksLikeAnId(bare) else { return nil }
        return bare
    }

    /// A name a person can be called by: not blank, not "human", not an id.
    static func plainName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name.lowercased() != "human", !name.lowercased().hasPrefix("human-"), !looksLikeAnId(name) else { return nil }
        return name
    }

    /// Text holding an id's hex: a run of six or more hex characters with digits and letters both (a UUID's parts,
    /// an account's hex). Words ("added", "faced") and numbers ("2026") are not ids.
    static func looksLikeAnId(_ text: String) -> Bool {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).contains { part in
            part.count >= 6 && part.allSatisfy(\.isHexDigit)
                && part.contains(where: \.isNumber) && part.contains(where: { $0.isLetter })
        }
    }
}

/// Activity in plain words (Carter, 2026-11-06: every activity line reviewed for people who are not technical). The
/// server's event and action types (sentinelayer-api: session events, and the message actions its route accepts) are
/// said as what happened; anything else is an "Update", never the server's token.
enum ActivityWords {
    static let update = "Update"

    private static let events: [String: String] = [
        "session_message": "Message",
        "session_say": "Message",
        "human_relay": "Message",
        "agent_response": "Answer",
        "session_titled": "Chat renamed",
        "session_member_joined": "Someone joined",
        "agent_admission_joined": "An agent joined",
        "agent_join": "An agent joined",
        "agent_joined": "An agent joined",
        "agent_admission_state_changed": "An agent's access changed",
        "agent_leave": "An agent left",
        "agent_complete": "An agent finished",
        "agent_error": "An agent hit a problem",
        "session_branched_from": "Side chat",
        "session_branched_to": "Side chat",
        "room_event_reminder": "Reminder",
        "room_event_cancelled": "Event cancelled",
        "room_event_postponed": "Event moved",
        "recap": "Summary",
        "session_recap": "Summary",
        "context_briefing": "Summary"
    ]

    private static let actions: [String: String] = [
        "ack": "Acknowledged",
        "working_on": "Working on it",
        "reply": "Replied",
        "comment": "Replied",
        "like": "Liked",
        "unlike": "Took back a like",
        "dislike": "Disliked",
        "undislike": "Took back a dislike",
        "disregard": "Disregarded",
        "view": "Seen",
        "pin": "Pinned",
        "unpin": "Unpinned",
        "react": "Reacted",
        "unreact": "Took back a reaction"
    ]

    static func event(_ type: String) -> String {
        events[type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? update
    }

    static func action(_ type: String) -> String {
        actions[type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? update
    }
}

private extension Optional where Wrapped == String {
    var pocketNonblank: String? {
        guard let value = self else { return nil }
        return value.pocketNonblank
    }
}

private extension String {
    var pocketNonblank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var pocketTokenLabel: String {
        replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}
