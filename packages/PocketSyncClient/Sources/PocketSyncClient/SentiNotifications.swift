import Foundation
import PocketContracts

// The signed-in user's notifications, source-bound to sentinelayer-api `GET /api/v1/sessions/notifications` (the newest
// 50) and to the web's bell (sentinelayer-web `useRoomNotifications.ts`, `useToastNotifications.ts` at d479a03).

public struct SentiNotification: Equatable, Identifiable, Sendable {
    public let id: String
    /// `mention`, `invite_accepted`, `join_link_accepted`, `member_returned`, ...
    public let kind: String
    /// The room the notification is about.
    public let sessionId: String
    public let title: String
    public let body: String
    public let link: SentiLink?
    public let isRead: Bool
    public let createdAt: String
    public let actorName: String?

    public init(
        id: String,
        kind: String,
        sessionId: String,
        title: String,
        body: String = "",
        link: SentiLink? = nil,
        isRead: Bool = false,
        createdAt: String = "",
        actorName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sessionId = sessionId
        self.title = title
        self.body = body
        self.link = link
        self.isRead = isRead
        self.createdAt = createdAt
        self.actorName = actorName
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty, id.utf8.count <= 128 else { return nil }
        let actor = json["actorName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        // The web replaces a leading "None"/"Someone" with the actor's name.
        var title = json["title"]?.stringValue ?? ""
        if let actor {
            for placeholder in ["None ", "Someone "] where title.hasPrefix(placeholder) {
                title = actor + " " + title.dropFirst(placeholder.count)
            }
        }
        self.init(
            id: id,
            kind: json["kind"]?.stringValue ?? "",
            sessionId: json["subjectId"]?.stringValue ?? "",
            title: title.isEmpty ? "Notification" : title,
            body: json["body"]?.stringValue ?? "",
            link: (json["actionUrl"]?.stringValue).flatMap(SentiLink.init(string:)),
            isRead: json["isRead"]?.boolValue ?? false,
            createdAt: json["createdAt"]?.stringValue ?? "",
            actorName: actor
        )
    }
}

public struct SentiNotificationsPage: Decodable, Equatable, Sendable {
    public let notifications: [SentiNotification]

    enum CodingKeys: String, CodingKey { case notifications }

    public init(notifications: [SentiNotification]) {
        self.notifications = notifications
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = (try? container.decode([JSONValue].self, forKey: .notifications)) ?? []
        self.notifications = rows.compactMap(SentiNotification.init(json:))
    }
}

/// An in-app destination parsed from a Senti web link. Only Senti's own dashboard paths are recognised; anything
/// else opens in the browser (or not at all), never as an in-app navigation.
public struct SentiLink: Equatable, Hashable, Sendable {
    public let sessionId: String
    public let messageSequence: Int64?
    public let replyId: String?
    public let ticketId: String?

    public static let webHosts: Set<String> = ["sentinelayer.com", "www.sentinelayer.com"]

    public init(sessionId: String, messageSequence: Int64? = nil, replyId: String? = nil, ticketId: String? = nil) {
        self.sessionId = sessionId
        self.messageSequence = messageSequence
        self.replyId = replyId
        self.ticketId = ticketId
    }

    /// Accepts `https://sentinelayer.com/dashboard/sessions/<id>[?message=<seq>[&reply=<uuid>]][&ticket=<id>]`, the
    /// `/app/sessions/<id>` alias, and the same paths without a host (in-app relative links).
    public init?(string: String) {
        guard let components = URLComponents(string: string) else { return nil }
        if let scheme = components.scheme?.lowercased() {
            guard scheme == "https", let host = components.host?.lowercased(), Self.webHosts.contains(host),
                  components.port == nil, components.user == nil, components.password == nil else { return nil }
        } else if components.host != nil {
            return nil
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "dashboard" || parts[0] == "app", parts[1] == "sessions",
              SessionIdentifier.isValid(parts[2]) else { return nil }
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let message = value("message").flatMap { text -> Int64? in
            guard text.range(of: #"^[1-9][0-9]{0,15}$"#, options: .regularExpression) != nil else { return nil }
            return Int64(text)
        }
        let reply = value("reply").flatMap { UUID(uuidString: $0) != nil ? $0.lowercased() : nil }
        let ticket = value("ticket").flatMap {
            $0.range(of: #"^[A-Za-z0-9._:-]{1,128}$"#, options: .regularExpression) != nil ? $0 : nil
        }
        self.init(sessionId: parts[2], messageSequence: message, replyId: reply, ticketId: ticket)
    }
}

extension HTTPSessionTransport {
    /// The newest notifications for the signed-in user.
    public func notifications() async throws -> SentiNotificationsPage {
        try await getDecodable(
            SentiNotificationsPage.self,
            path: ["api", "v1", "sessions", "notifications"],
            query: []
        )
    }
}

/// Reading notifications, for the bell. A protocol so the coordinator is testable.
public protocol NotificationsTransport: Sendable {
    func notifications() async throws -> SentiNotificationsPage
}

extension HTTPSessionTransport: NotificationsTransport {}
