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

/// Who is in a room and who is invited, every row of `GET /sessions/{id}/members` (owners and admins only): what a check
/// that nobody else can read a message needs. Unlike `RoomMembersPage`, a member without a GitHub login is kept, and a
/// member row without a user id is kept as an empty id, so it can never be taken for you.
public struct RoomMembershipSnapshot: Decodable, Equatable, Sendable {
    /// `private` or `public`, lowercased, as the API says; anything else (or nothing) is not private.
    public let visibility: String
    /// Every member's user id, lowercased, the owner included.
    public let memberUserIds: [String]
    /// How many invitations are still open, to anyone.
    public let pendingInvitationCount: Int

    public init(visibility: String, memberUserIds: [String], pendingInvitationCount: Int = 0) {
        self.visibility = visibility.lowercased()
        self.memberUserIds = memberUserIds.map { $0.lowercased() }
        self.pendingInvitationCount = pendingInvitationCount
    }

    enum CodingKeys: String, CodingKey { case visibility, members, invitations, pendingInvitationCount }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A reply without its member list is no membership at all: the read fails rather than looking empty.
        let rows = try container.decode([JSONValue].self, forKey: .members)
        visibility = ((try? container.decode(String.self, forKey: .visibility)) ?? "").lowercased()
        memberUserIds = rows.map { ($0["userId"]?.stringValue ?? "").lowercased() }
        let invitations = (try? container.decode([JSONValue].self, forKey: .invitations)) ?? []
        let listed = invitations.filter { ($0["status"]?.stringValue ?? "pending").lowercased() == "pending" }.count
        let counted = (try? container.decode(Int.self, forKey: .pendingInvitationCount)) ?? 0
        pendingInvitationCount = max(listed, counted)
    }
}

extension HTTPSessionTransport {
    /// The room's whole membership, for owners and admins. A room that is gone, or that this account no longer owns or
    /// administers, reads as `SessionTransportError.accessDenied` (403 and 404 alike).
    public func roomMembership(sessionId: String) async throws -> RoomMembershipSnapshot {
        guard SessionIdentifier.isValid(sessionId) else { throw SessionTransportError.invalidRequest }
        return try await getDecodable(
            RoomMembershipSnapshot.self,
            path: ["api", "v1", "sessions", sessionId, "members"],
            query: []
        )
    }
}
