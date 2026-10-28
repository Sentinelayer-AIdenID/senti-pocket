import Foundation
import PocketContracts

// The room's people (sentinelayer-api `GET /sessions/{id}/members`, `list_session_members`). The API serves this
// list to owners and admins only. Each row names the person by GitHub login, the handle @-mentions notify.

/// A person who belongs to the room.
public struct RoomMember: Equatable, Identifiable, Sendable {
    public var id: String { login }
    /// The GitHub login, lowercased: what an @-mention must carry to notify this person.
    public let login: String
    public let displayName: String
    public let role: String
    public let isOnline: Bool
    public let lastActiveAt: String?

    public init(login: String, displayName: String, role: String, isOnline: Bool = false, lastActiveAt: String? = nil) {
        self.login = login
        self.displayName = displayName
        self.role = role
        self.isOnline = isOnline
        self.lastActiveAt = lastActiveAt
    }

    init?(json: JSONValue) {
        guard let login = json["githubLogin"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              login.range(of: #"^[a-z0-9][a-z0-9-]{0,38}$"#, options: .regularExpression) != nil else { return nil }
        let name = json["displayName"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            login: login,
            displayName: (name?.isEmpty == false ? name : nil) ?? login,
            role: json["role"]?.stringValue ?? "viewer",
            isOnline: json["online"]?.boolValue ?? false,
            lastActiveAt: json["lastActiveAt"]?.stringValue
        )
    }
}

public struct RoomMembersPage: Decodable, Equatable, Sendable {
    public let members: [RoomMember]

    enum CodingKeys: String, CodingKey { case members }

    public init(members: [RoomMember] = []) {
        self.members = members
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = (try? container.decode([JSONValue].self, forKey: .members)) ?? []
        var seen = Set<String>()
        self.members = rows.compactMap(RoomMember.init(json:)).filter { seen.insert($0.login).inserted }
    }
}

extension HTTPSessionTransport {
    public func roomMembers(sessionId: String) async throws -> RoomMembersPage {
        guard SessionIdentifier.isValid(sessionId) else { throw SessionTransportError.invalidRequest }
        return try await getDecodable(
            RoomMembersPage.self,
            path: ["api", "v1", "sessions", sessionId, "members"],
            query: []
        )
    }
}
