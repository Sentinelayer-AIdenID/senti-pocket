import Foundation
import PocketContracts

/// One agent admission request as the app hands it to PocketUI.
public struct AdmissionRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let status: String
    public let agentId: String
    /// "model · provider · via client", when known.
    public let detail: String?
    /// The agent's own words. Shown as untrusted text.
    public let goalSummary: String
    public let deliverables: [String]
    public let stopConditions: [String]
    public let requestedActions: [String]
    public let requestedTTLSeconds: Int
    public let grantedActions: [String]
    public let grantedExpires: Date?
    public let pendingExpires: Date?

    public init(
        id: String,
        status: String,
        agentId: String,
        detail: String? = nil,
        goalSummary: String = "",
        deliverables: [String] = [],
        stopConditions: [String] = [],
        requestedActions: [String] = [],
        requestedTTLSeconds: Int = 0,
        grantedActions: [String] = [],
        grantedExpiresAt: String? = nil,
        pendingExpiresAt: String? = nil
    ) {
        self.id = id
        self.status = status
        self.agentId = agentId
        self.detail = detail
        self.goalSummary = goalSummary
        self.deliverables = deliverables
        self.stopConditions = stopConditions
        self.requestedActions = requestedActions
        self.requestedTTLSeconds = requestedTTLSeconds
        self.grantedActions = grantedActions
        self.grantedExpires = grantedExpiresAt.flatMap { ParsedSessionTimestamp($0).date }
        self.pendingExpires = pendingExpiresAt.flatMap { ParsedSessionTimestamp($0).date }
    }

    public var isPending: Bool { status == "pending" }
    public var isLive: Bool { status == "approved" || status == "active" }

    /// Plain-language names for the scope actions an owner approves.
    public static func actionLabel(_ action: String) -> String {
        switch action {
        case "session.read": return "Read the room"
        case "session.post": return "Post messages"
        case "session.react": return "React"
        case "tickets.read": return "Read tickets"
        case "tickets.work": return "Work tickets"
        default: return action
        }
    }

    /// Grant durations the owner may choose (web parity): the fixed choices shorter than the request and at least
    /// five minutes, then the requested duration itself. A grant can be shortened, never lengthened.
    public static func ttlOptions(forRequested requested: Int) -> [Int] {
        let choices = [15 * 60, 60 * 60, 2 * 60 * 60, 8 * 60 * 60, 24 * 60 * 60]
        return choices.filter { $0 < requested && $0 >= 300 } + (requested > 0 ? [requested] : [])
    }

    public static func durationLabel(_ seconds: Int) -> String {
        if seconds > 0, seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        if seconds > 0, seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}

public struct AdmissionsPresentationState: Equatable, Sendable {
    public let pending: [AdmissionRow]
    public let live: [AdmissionRow]
    public let mode: String
    /// Admission ids with a decision in flight.
    public let deciding: Set<String>
    public let errorText: String?
    public let isLoading: Bool
    public let failure: SessionLoadFailure?

    public init(
        rows: [AdmissionRow],
        mode: String = "legacy",
        deciding: Set<String> = [],
        errorText: String? = nil,
        isLoading: Bool = false,
        failure: SessionLoadFailure? = nil
    ) {
        let protected = failure?.suppressesProtectedContent == true
        self.pending = protected ? [] : rows.filter(\.isPending)
        self.live = protected ? [] : rows.filter(\.isLive)
        self.mode = mode
        self.deciding = deciding
        self.errorText = errorText
        self.isLoading = isLoading
        self.failure = failure
    }
}

public enum AdmissionsIntent: Equatable, Sendable {
    case approve(id: String, actions: [String], ttlSeconds: Int)
    case deny(id: String)
    case refresh
}
