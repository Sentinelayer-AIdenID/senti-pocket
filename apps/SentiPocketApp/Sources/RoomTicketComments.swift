import Foundation
import PocketContracts

/// One comment on a ticket (sentinelayer-api `SessionTicketLeaseService.comments`). Comments are immutable; a person's
/// `actorId` is their user id, an agent's its agent id.
struct RoomTicketComment: Equatable, Identifiable, Sendable {
    let id: String
    let body: String
    let kind: String
    let actorKind: String
    let actorId: String
    let createdAt: String
    /// The ticket-event cursor: comments page by it, oldest first.
    let cursor: Int64

    init?(json: JSONValue, cursor fallback: Int64? = nil) {
        guard let id = json["id"]?.stringValue, !id.isEmpty, let body = json["body"]?.stringValue,
              let cursor = json["cursor"]?.intValue ?? fallback else { return nil }
        self.id = id
        self.body = body
        self.kind = json["kind"]?.stringValue ?? "comment"
        self.actorKind = json["actorKind"]?.stringValue ?? "human"
        self.actorId = json["actorId"]?.stringValue ?? ""
        self.createdAt = json["createdAt"]?.stringValue ?? ""
        self.cursor = cursor
    }

    init(id: String, body: String, actorId: String, actorKind: String = "human", createdAt: String = "", cursor: Int64) {
        self.id = id
        self.body = body
        self.kind = "comment"
        self.actorKind = actorKind
        self.actorId = actorId
        self.createdAt = createdAt
        self.cursor = cursor
    }
}

struct RoomTicketCommentsPage: Equatable, Sendable {
    let comments: [RoomTicketComment]
    let cursor: Int64
    let hasMore: Bool

    init(comments: [RoomTicketComment], cursor: Int64, hasMore: Bool = false) {
        self.comments = comments
        self.cursor = cursor
        self.hasMore = hasMore
    }

    init?(json: JSONValue) {
        guard let rows = json["comments"]?.arrayValue, let cursor = json["cursor"]?.intValue else { return nil }
        self.comments = rows.compactMap { RoomTicketComment(json: $0) }
        self.cursor = cursor
        self.hasMore = json["hasMore"]?.boolValue ?? false
    }
}

/// A person in the room (sentinelayer-api `GET /member-directory`, the member-visible directory): the user id a ticket
/// is assigned to, and how to name them.
struct RoomDirectoryMember: Equatable, Sendable {
    let userId: String
    let displayName: String?
    let githubLogin: String?

    var label: String {
        if let name = displayName, !name.isEmpty {
            return githubLogin.map { "\(name) (@\($0))" } ?? name
        }
        return githubLogin.map { "@\($0)" } ?? "A member"
    }

    /// How the room names them in ticket lines.
    var name: String { displayName.flatMap { $0.isEmpty ? nil : $0 } ?? githubLogin ?? "a person" }
}

struct RoomDirectoryPage: Equatable, Sendable {
    let members: [RoomDirectoryMember]
    let nextCursor: String?
    let hasMore: Bool

    init(members: [RoomDirectoryMember], nextCursor: String? = nil, hasMore: Bool = false) {
        self.members = members
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }

    init?(json: JSONValue) {
        guard let rows = json["members"]?.arrayValue else { return nil }
        self.members = rows.compactMap { row in
            guard let id = row["userId"]?.stringValue, UUID(uuidString: id) != nil else { return nil }
            return RoomDirectoryMember(
                userId: id.lowercased(),
                displayName: row["displayName"]?.stringValue,
                githubLogin: row["githubLogin"]?.stringValue
            )
        }
        self.nextCursor = json["nextCursor"]?.stringValue
        self.hasMore = json["hasMore"]?.boolValue ?? false
    }
}

enum RoomTicketExtrasError: Error, Equatable {
    case reauthenticationRequired
    /// 409 `DIRECTORY_CHANGED`: membership changed mid-read; start the directory again.
    case directoryChanged
    case unavailable
}

/// The ticket screen's reads beyond the board: one ticket's comments, and the room's member directory for Assign.
protocol RoomTicketExtrasReading: Sendable {
    func comments(sessionId: String, ticketId: String, after: Int64) async throws -> RoomTicketCommentsPage
    func memberDirectory(sessionId: String, cursor: String?) async throws -> RoomDirectoryPage
}

final class HTTPRoomTicketExtras: RoomTicketExtrasReading, @unchecked Sendable {
    private let apiBaseURL: URL?
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?

    init(
        apiBaseURL: URL?,
        urlSession: URLSession = SentiHTTPTransportPolicy.liveSession,
        tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }
    ) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
    }

    func comments(sessionId: String, ticketId: String, after: Int64) async throws -> RoomTicketCommentsPage {
        let json = try await get(["api", "v1", "sessions", sessionId, "tickets", ticketId, "comments"],
                                 query: [URLQueryItem(name: "after", value: String(max(0, after))),
                                         URLQueryItem(name: "limit", value: "100")])
        guard let page = RoomTicketCommentsPage(json: json) else { throw RoomTicketExtrasError.unavailable }
        return page
    }

    func memberDirectory(sessionId: String, cursor: String?) async throws -> RoomDirectoryPage {
        var query = [URLQueryItem(name: "limit", value: "100")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let json = try await get(["api", "v1", "sessions", sessionId, "member-directory"], query: query)
        guard let page = RoomDirectoryPage(json: json) else { throw RoomTicketExtrasError.unavailable }
        return page
    }

    private func get(_ path: [String], query: [URLQueryItem]) async throws -> JSONValue {
        guard let apiBaseURL, var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw RoomTicketExtrasError.unavailable
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw RoomTicketExtrasError.reauthenticationRequired }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var encoded: [String] = []
        for part in path {
            guard !part.isEmpty, part.utf8.count <= 256, let piece = part.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw RoomTicketExtrasError.unavailable
            }
            encoded.append(piece)
        }
        components.percentEncodedPath = "/" + encoded.joined(separator: "/")
        components.queryItems = query
        guard let url = components.url else { throw RoomTicketExtrasError.unavailable }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw RoomTicketExtrasError.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw RoomTicketExtrasError.unavailable }
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        switch http.statusCode {
        case 200:
            guard let json else { throw RoomTicketExtrasError.unavailable }
            return json
        case 401:
            throw RoomTicketExtrasError.reauthenticationRequired
        case 409 where HTTPRoomTicketWriter.errorCode(json) == "DIRECTORY_CHANGED":
            throw RoomTicketExtrasError.directoryChanged
        default:
            throw RoomTicketExtrasError.unavailable
        }
    }
}
