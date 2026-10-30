import Foundation
import PocketContracts

// Everything waiting on the signed-in user's decision across their rooms (ticket 931e1d2e), source-bound to
// sentinelayer-api `GET /api/v1/me/waiting?limit=&cursor=` -> `{total, items: [...], nextCursor}`, oldest first, and
// to the web's answer line (sentinelayer-web `decisionChatLine` in `Session.helpers.ts`).

public struct SentiWaitingItem: Equatable, Identifiable, Sendable {
    /// The ticket the decision is asked in; one row per ticket.
    public var id: String { ticketId }
    /// "decision" today.
    public let kind: String
    public let roomId: String
    public let roomTitle: String
    public let ticketId: String
    public let title: String
    public let question: String
    /// The answers offered, without "Custom"; empty for an open question.
    public let options: [String]
    /// A free answer is allowed besides the options.
    public let custom: Bool
    public let askedAt: String
    /// Who asked (the ticket's creator): an agent id, or a person's user id.
    public let askedBy: String?
    /// Who the answer is for (the ticket's assignee), as the web mentions it; nil when unassigned or not sent.
    public let assignee: String?

    public init(kind: String = "decision", roomId: String, roomTitle: String, ticketId: String, title: String,
                question: String, options: [String] = [], custom: Bool = false, askedAt: String = "",
                askedBy: String? = nil, assignee: String? = nil) {
        self.kind = kind
        self.roomId = roomId
        self.roomTitle = roomTitle
        self.ticketId = ticketId
        self.title = title
        self.question = question
        self.options = options
        self.custom = custom
        self.askedAt = askedAt
        self.askedBy = askedBy
        self.assignee = assignee
    }

    init?(json: JSONValue) {
        let identifier = #"^[A-Za-z0-9._:-]{1,128}$"#
        guard let ticketId = json["ticketId"]?.stringValue,
              ticketId.range(of: identifier, options: .regularExpression) != nil,
              let roomId = json["roomId"]?.stringValue, SessionIdentifier.isValid(roomId) else { return nil }
        let options = (json["options"]?.arrayValue ?? []).compactMap { $0.stringValue }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let askedBy = json["askedBy"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let assignee = json["assignee"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            kind: json["kind"]?.stringValue ?? "decision",
            roomId: roomId,
            roomTitle: json["roomTitle"]?.stringValue ?? "",
            ticketId: ticketId,
            title: json["title"]?.stringValue ?? "",
            question: json["question"]?.stringValue ?? "",
            options: Array(options.prefix(12)),
            custom: json["custom"]?.boolValue ?? false,
            askedAt: json["askedAt"]?.stringValue ?? "",
            askedBy: askedBy?.isEmpty == false ? askedBy : nil,
            assignee: assignee?.isEmpty == false ? assignee : nil
        )
    }

    /// The one chat line that answers it, exactly as the web writes it (`decisionChatLine`): "Decision on
    /// [Ticket: <title>](/dashboard/sessions/<room>?ticket=<id>): <answer>[ — <detail>]", then "@<agent>" when an
    /// agent is assigned, or "(for <name>)" for an assigned person whose name is known. The server clears the ask by
    /// the ticket in the link; the mention only tells the one doing the work.
    public func answerLine(_ answer: String, detail: String = "", personName: String? = nil) -> String {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = detail.isEmpty ? answer : "\(answer) — \(detail)"
        var to = ""
        if let assignee {
            if UUID(uuidString: assignee) != nil {
                if let personName, !personName.isEmpty { to = " (for \(personName))" }
            } else {
                to = " @\(assignee)"
            }
        }
        return "Decision on \(card): \(what)\(to)"
    }

    /// The ticket's card, as the web's `ticketChatCard`.
    var card: String {
        let oneLine = Self.oneLine(title)
        let title = (oneLine.isEmpty ? "(untitled)" : oneLine)
            .replacingOccurrences(of: "[", with: " ").replacingOccurrences(of: "]", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "[Ticket: \(title)](\(Self.deepLink(roomId: roomId, ticketId: ticketId)))"
    }

    /// `/dashboard/sessions/<room>?ticket=<id>`, encoded as JavaScript's `encodeURIComponent` does.
    static func deepLink(roomId: String, ticketId: String) -> String {
        "/dashboard/sessions/\(encodeComponent(roomId))?ticket=\(encodeComponent(ticketId))"
    }

    private static func encodeComponent(_ text: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// Control characters become spaces and runs of spaces one, as the web's `oneLineText`.
    private static func oneLine(_ text: String) -> String {
        let plain = String(String.UnicodeScalarView(text.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : $0 }))
        return plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public struct SentiWaitingPage: Decodable, Equatable, Sendable {
    /// Everything waiting, beyond this page too.
    public let total: Int
    public let items: [SentiWaitingItem]
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey { case total, items, nextCursor }

    public init(total: Int, items: [SentiWaitingItem], nextCursor: String? = nil) {
        self.total = total
        self.items = items
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = (try? container.decode([JSONValue].self, forKey: .items)) ?? []
        self.items = rows.compactMap(SentiWaitingItem.init(json:))
        self.total = max((try? container.decode(Int.self, forKey: .total)) ?? items.count, items.count)
        self.nextCursor = try? container.decode(String.self, forKey: .nextCursor)
    }
}

extension HTTPSessionTransport {
    /// What waits on the signed-in user's decision, oldest first.
    public func waiting(limit: Int = 50) async throws -> SentiWaitingPage {
        try await getDecodable(
            SentiWaitingPage.self,
            path: ["api", "v1", "me", "waiting"],
            query: [URLQueryItem(name: "limit", value: String(max(1, min(200, limit))))]
        )
    }
}

/// Reading what waits on you. A protocol so the coordinator is testable.
public protocol WaitingTransport: Sendable {
    func waiting(limit: Int) async throws -> SentiWaitingPage
}

extension HTTPSessionTransport: WaitingTransport {}
