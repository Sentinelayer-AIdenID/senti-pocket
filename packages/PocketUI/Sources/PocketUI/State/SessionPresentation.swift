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
    /// - Parameter readThrough: how far this phone has read each room since, as the server confirmed it (by session
    ///   id). A count the server made before that read is stale and shows no badge (`SessionRowPresentation`).
    public init(
        sessions: [SessionSummary],
        resultCount: Int? = nil,
        includesArchived: Bool,
        hasMore: Bool,
        provenance: SessionPresentationProvenance,
        isRefreshing: Bool = false,
        failure: SessionLoadFailure? = nil,
        readThrough: [String: Int64] = [:]
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
            ? sessions.map { SessionRowPresentation($0, readThrough: readThrough[$0.sessionId]) }
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
    /// Who is in the room now and your unread messages, for the row's counts and badge (Carter, 10-31).
    public let activity: RoomListActivity
    /// The first message you have not read, where the room opens; nil with nothing unread.
    public let firstUnreadSequenceId: Int64?
    /// How far you have read the room: the server's mark, or further where this phone has read since.
    public let lastReadSequenceId: Int64?

    /// - Parameter readThrough: how far this phone has read the room since the list was counted, as the server
    ///   confirmed it. The server's unread messages all come at or after its first unread, so a first unread at or
    ///   behind that point means the count was made before the read: no badge until the server counts again. One
    ///   after it is news the read did not cover, and shows.
    fileprivate init(_ session: SessionSummary, readThrough: Int64?) {
        self.id = OpaqueUTF8Identity(session.sessionId)
        self.sessionId = session.sessionId
        self.title = session.title.pocketNonblank ?? "Untitled session"
        self.summary = session.summaryText.pocketNonblank
        self.status = session.status
        self.archiveStatus = session.archiveStatus
        self.membershipRole = session.membershipRole
        self.agentCount = session.agentCount
        self.eventCount = session.eventCount
        self.lastActivity = ParsedSessionTimestamp(session.lastActivityAt)
        self.roomTypeLabel = Self.roomTypeLabel(session.roomType)
        let readHere = readThrough ?? 0
        let first = session.unread?.firstUnreadSequenceId
        let staleCount = first.map { $0 <= readHere } ?? false
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
        failure: SessionLoadFailure? = nil
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

        self.events = eventPage.events.map(SessionEventRowPresentation.init)
        self.actions = actionPage.actions.map(SessionActionRowPresentation.init)
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

    fileprivate init(_ event: SessionEventDTO) {
        self.id = ID(sessionId: event.sessionId, eventId: event.id)
        self.sessionId = event.sessionId
        self.sequenceId = event.sequenceId
        self.eventType = event.event
        self.author = event.agent["displayName"]?.stringValue.pocketNonblank
            ?? event.agentId.pocketNonblank
            ?? "Unknown participant"
        self.text = event.payload["text"]?.stringValue.pocketNonblank
        self.timestamp = ParsedSessionTimestamp(event.ts)
    }

    public var eventTypeLabel: String { eventType.pocketTokenLabel }
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

    fileprivate init(_ action: SessionActionDTO) {
        self.id = ID(sessionId: action.sessionId, actionId: action.id)
        self.sessionId = action.sessionId
        self.targetSequenceId = action.targetSequenceId
        self.actionType = action.actionType
        self.actor = action.actorId.pocketNonblank ?? "Unknown participant"
        self.note = action.note.pocketNonblank
        self.createdAt = ParsedSessionTimestamp(action.createdAt)
    }

    public var actionTypeLabel: String { actionType.pocketTokenLabel }
    public var targetLabel: String {
        targetSequenceId == 0 ? "Session-level" : "Target #\(targetSequenceId)"
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
