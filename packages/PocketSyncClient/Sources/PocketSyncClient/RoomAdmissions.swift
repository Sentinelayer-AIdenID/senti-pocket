import Foundation
import PocketContracts

// Agent admission requests for a room, source-bound to sentinelayer-api `GET /api/v1/sessions/{id}/admissions`
// (owners and admins) and to the web's panel (sentinelayer-web `AgentAdmissionPanel.tsx`,
// `agentAdmission.helpers.ts` at d479a03). An agent's goal, deliverables and stop conditions are its OWN words:
// they are shown as untrusted text, never as instructions.

public struct RoomAdmission: Equatable, Identifiable, Sendable {
    public var id: String { admissionId }
    public let admissionId: String
    /// pending, approved, active, denied, expired, revoked, cancelled, ...
    public let status: String
    public let agentId: String
    public let displayName: String?
    public let model: String?
    public let provider: String?
    public let clientKind: String?
    public let goalSummary: String
    public let deliverables: [String]
    public let stopConditions: [String]
    public let requestedActions: [String]
    public let requestedTTLSeconds: Int
    public let grantedActions: [String]
    public let grantedExpiresAt: String?
    public let createdAt: String
    public let pendingExpiresAt: String?

    public var isPending: Bool { status == "pending" }
    public var isLive: Bool { status == "approved" || status == "active" }

    public init(
        admissionId: String,
        status: String,
        agentId: String,
        displayName: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        clientKind: String? = nil,
        goalSummary: String = "",
        deliverables: [String] = [],
        stopConditions: [String] = [],
        requestedActions: [String] = [],
        requestedTTLSeconds: Int = 0,
        grantedActions: [String] = [],
        grantedExpiresAt: String? = nil,
        createdAt: String = "",
        pendingExpiresAt: String? = nil
    ) {
        self.admissionId = admissionId
        self.status = status
        self.agentId = agentId
        self.displayName = displayName
        self.model = model
        self.provider = provider
        self.clientKind = clientKind
        self.goalSummary = goalSummary
        self.deliverables = deliverables
        self.stopConditions = stopConditions
        self.requestedActions = requestedActions
        self.requestedTTLSeconds = requestedTTLSeconds
        self.grantedActions = grantedActions
        self.grantedExpiresAt = grantedExpiresAt
        self.createdAt = createdAt
        self.pendingExpiresAt = pendingExpiresAt
    }

    init?(json: JSONValue) {
        guard let id = json["admissionId"]?.stringValue, UUID(uuidString: id) != nil,
              let status = json["status"]?.stringValue,
              let agentId = json["agentId"]?.stringValue, !agentId.isEmpty else { return nil }
        let strings: (JSONValue?) -> [String] = { value in (value?.arrayValue ?? []).compactMap(\.stringValue) }
        self.init(
            admissionId: id.lowercased(),
            status: status,
            agentId: agentId,
            displayName: json["displayName"]?.stringValue,
            model: json["model"]?.stringValue,
            provider: json["provider"]?.stringValue,
            clientKind: json["clientKind"]?.stringValue,
            goalSummary: json["goal"]?["summary"]?.stringValue ?? "",
            deliverables: strings(json["goal"]?["deliverables"]),
            stopConditions: strings(json["goal"]?["stopConditions"]),
            requestedActions: strings(json["requestedScope"]?["actions"]),
            requestedTTLSeconds: Int(clamping: json["requestedScope"]?["ttlSeconds"]?.intValue ?? 0),
            grantedActions: strings(json["grantedScope"]?["actions"]),
            grantedExpiresAt: json["grantedScope"]?["expiresAt"]?.stringValue,
            createdAt: json["createdAt"]?.stringValue ?? "",
            pendingExpiresAt: json["pendingExpiresAt"]?.stringValue
        )
    }
}

public struct RoomAdmissionsPage: Decodable, Equatable, Sendable {
    /// `legacy` or `required`.
    public let mode: String
    public let admissions: [RoomAdmission]

    enum CodingKeys: String, CodingKey { case agentAdmissionMode, admissions }

    public init(mode: String = "legacy", admissions: [RoomAdmission]) {
        self.mode = mode
        self.admissions = admissions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = (try? container.decode(String.self, forKey: .agentAdmissionMode)) ?? "legacy"
        let rows = (try? container.decode([JSONValue].self, forKey: .admissions)) ?? []
        self.admissions = rows.compactMap(RoomAdmission.init(json:))
    }
}

/// Reading a room's admission requests. A protocol so the coordinator is testable.
public protocol RoomAdmissionsTransport: Sendable {
    func roomAdmissions(sessionId: String) async throws -> RoomAdmissionsPage
}

extension HTTPSessionTransport: RoomAdmissionsTransport {
    public func roomAdmissions(sessionId: String) async throws -> RoomAdmissionsPage {
        try Self.requireIdentifier(sessionId)
        return try await getDecodable(
            RoomAdmissionsPage.self,
            path: ["api", "v1", "sessions", sessionId, "admissions"],
            query: []
        )
    }
}
