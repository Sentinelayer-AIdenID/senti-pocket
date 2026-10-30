import Foundation
import PocketContracts

// The signed-in person's calls across their rooms, newest first, source-bound to sentinelayer-api
// `GET /api/v1/me/calls?limit=&cursor=` -> `{calls: [...], nextCursor}` (PR #1060): voice rooms they started from the
// phone, and rings to or from them.

public struct SentiCall: Equatable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// A voice room the person started.
        case voiceRoom = "voice_room"
        /// A ring to or from the person's phone.
        case ring
    }

    /// An agent's summary of the call, posted in reply to its end.
    public struct Summary: Equatable, Sendable {
        public let author: String
        public let text: String
        public let createdAt: String

        public init(author: String, text: String, createdAt: String = "") {
            self.author = author
            self.text = text
            self.createdAt = createdAt
        }
    }

    public let kind: Kind
    public let id: String
    public let sessionId: String
    public let roomTitle: String
    /// "ended", "ongoing" or "unfinished" for a voice room; "ringing", "answered", "declined", "missed" or "ended"
    /// for a ring.
    public let status: String
    /// When it began: a voice room's start, a ring's creation.
    public let startedAt: String
    public let endedAt: String?

    // A voice room.
    /// The agents it rang.
    public let with: [String]
    public let isMeeting: Bool
    public let durationText: String?
    public let turns: Int?
    public let timingsText: String?
    public let transcriptAttachmentId: String?
    public let summaries: [Summary]
    public let startSequenceId: Int64?
    public let endSequenceId: Int64?

    // A ring.
    /// "incoming" or "outgoing".
    public let direction: String?
    public let callerName: String?
    public let calleeName: String?
    public let reason: String?

    public init(kind: Kind, id: String, sessionId: String, roomTitle: String = "", status: String, startedAt: String,
                endedAt: String? = nil, with: [String] = [], isMeeting: Bool = false, durationText: String? = nil,
                turns: Int? = nil, timingsText: String? = nil, transcriptAttachmentId: String? = nil,
                summaries: [Summary] = [], startSequenceId: Int64? = nil, endSequenceId: Int64? = nil,
                direction: String? = nil, callerName: String? = nil, calleeName: String? = nil, reason: String? = nil) {
        self.kind = kind
        self.id = id
        self.sessionId = sessionId
        self.roomTitle = roomTitle
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.with = with
        self.isMeeting = isMeeting
        self.durationText = durationText
        self.turns = turns
        self.timingsText = timingsText
        self.transcriptAttachmentId = transcriptAttachmentId
        self.summaries = summaries
        self.startSequenceId = startSequenceId
        self.endSequenceId = endSequenceId
        self.direction = direction
        self.callerName = callerName
        self.calleeName = calleeName
        self.reason = reason
    }

    init?(json: JSONValue) {
        guard let kind = json["kind"]?.stringValue.flatMap(Kind.init(rawValue:)),
              let id = json["id"]?.stringValue, !id.isEmpty, id.utf8.count <= 128,
              let sessionId = json["sessionId"]?.stringValue, SessionIdentifier.isValid(sessionId) else { return nil }
        func text(_ key: String) -> String? {
            json[key]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        func sequence(_ key: String) -> Int64? {
            guard let value = json[key]?.intValue, value >= 1, value <= 9_007_199_254_740_991 else { return nil }
            return value
        }
        let summaries = (json["summaries"]?.arrayValue ?? []).compactMap { item -> Summary? in
            guard let author = item["author"]?.stringValue, let body = item["text"]?.stringValue,
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Summary(author: author, text: body, createdAt: item["createdAt"]?.stringValue ?? "")
        }
        let turns = json["turns"]?.intValue.flatMap { $0 >= 0 && $0 < 100_000 ? Int($0) : nil }
        self.init(
            kind: kind,
            id: id,
            sessionId: sessionId,
            roomTitle: json["roomTitle"]?.stringValue ?? "",
            status: json["status"]?.stringValue ?? "",
            startedAt: (kind == .ring ? json["createdAt"] : json["startedAt"])?.stringValue ?? "",
            endedAt: text("endedAt"),
            with: (json["with"]?.arrayValue ?? []).compactMap { $0.stringValue }.filter { !$0.isEmpty },
            isMeeting: json["meeting"]?.boolValue ?? false,
            durationText: text("durationText"),
            turns: turns,
            timingsText: text("timingsText"),
            transcriptAttachmentId: text("transcriptAttachmentId"),
            summaries: Array(summaries.prefix(5)),
            startSequenceId: sequence("startSequenceId"),
            endSequenceId: sequence("endSequenceId"),
            direction: text("direction"),
            callerName: text("callerName"),
            calleeName: text("calleeName"),
            reason: text("reason")
        )
    }
}

public struct SentiCallLogPage: Decodable, Equatable, Sendable {
    public let calls: [SentiCall]
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey { case calls, nextCursor }

    public init(calls: [SentiCall], nextCursor: String? = nil) {
        self.calls = calls
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A reply without its list is an error, not "no calls yet" (warden, #272).
        let rows = try container.decode([JSONValue].self, forKey: .calls)
        self.calls = rows.compactMap(SentiCall.init(json:))
        self.nextCursor = try? container.decode(String.self, forKey: .nextCursor)
    }
}

extension HTTPSessionTransport {
    /// The signed-in person's calls, newest first.
    public func calls(limit: Int = 50, cursor: String? = nil) async throws -> SentiCallLogPage {
        var query = [URLQueryItem(name: "limit", value: String(max(1, min(200, limit))))]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await getDecodable(SentiCallLogPage.self, path: ["api", "v1", "me", "calls"], query: query)
    }
}

/// Reading the call log. A protocol so the coordinator is testable.
public protocol CallLogTransport: Sendable {
    func calls(limit: Int, cursor: String?) async throws -> SentiCallLogPage
}

extension HTTPSessionTransport: CallLogTransport {}
