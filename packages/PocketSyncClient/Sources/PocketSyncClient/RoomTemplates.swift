import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts

// Ways to start a chat (the API's room templates): `GET /api/v1/rooms/templates`. Until the server offers them the
// route answers 404 and the phone keeps its own kinds. A chat started from one sends its `templateId` and no
// `roomType`: the server gives the room the template's type, its starter agents and what Senti does there, and refuses
// a `roomType` sent with a `templateId`.

/// One way to start a chat, as the server lists it.
public struct RoomTemplate: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// The SF Symbol it shows; nil when the server named none.
    public let symbol: String?
    /// What it is for, in one line; empty when the server sent none.
    public let summary: String
    /// The kind of room it makes (`general`, `study`, ...), as the server derives it. Never sent by the phone.
    public let roomType: String
    /// The catalog ids of the agents the server adds when the chat is made.
    public let starterAgents: [String]
    /// What Senti says it can do there, in a line or two; nil when the server sent none.
    public let firstMessage: String?

    public init(id: String, name: String, symbol: String? = nil, summary: String = "", roomType: String = "general",
                starterAgents: [String] = [], firstMessage: String? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.summary = summary
        self.roomType = roomType
        self.starterAgents = starterAgents
        self.firstMessage = firstMessage
    }

    /// A template needs an id the API could hold and a name; anything else missing reads as empty, and a missing type
    /// as a general room.
    init?(json: JSONValue?) {
        guard let json, let id = json["id"]?.stringValue, PersonalRequest.isIdentifier(id),
              let name = Self.text(json["name"]) else { return nil }
        self.init(
            id: id,
            name: name,
            symbol: Self.text(json["symbol"]),
            summary: Self.text(json["summary"]) ?? "",
            roomType: Self.text(json["roomType"]) ?? "general",
            starterAgents: (json["starterAgents"]?.arrayValue ?? []).compactMap(\.stringValue),
            firstMessage: Self.text(json["firstMessage"])
        )
    }

    /// The string trimmed, or nil when it is not a string or nothing is left.
    private static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}

public enum RoomTemplatesError: Error, Equatable, Sendable {
    /// 404 or 403: the server offers no ways to start yet. Nothing to show the person: the phone keeps its own kinds.
    case unavailable
    case reauthenticationRequired
    case notConfigured
    case retryable
    case invalidData
    case accountChanged
    case rejected
}

/// The ways to start a chat. A protocol so the app's model is testable without a network.
public protocol RoomTemplatesServing: Sendable {
    /// In the server's order, each once.
    func templates() async throws -> [RoomTemplate]
}

public final class HTTPRoomTemplatesClient: RoomTemplatesServing, @unchecked Sendable {
    private let request: PersonalRequest

    public init(apiBaseURL: URL?, urlSession: URLSession, tokenProvider: @escaping @Sendable () -> String?) {
        request = PersonalRequest(apiBaseURL: apiBaseURL, urlSession: urlSession, tokenProvider: tokenProvider)
    }

    public func templates() async throws -> [RoomTemplate] {
        let answer: PersonalRequest.Answer
        do {
            answer = try await request.send("GET", ["api", "v1", "rooms", "templates"])
        } catch PersonalRequest.Failure.notConfigured {
            throw RoomTemplatesError.notConfigured
        } catch PersonalRequest.Failure.notLoggedIn {
            throw RoomTemplatesError.reauthenticationRequired
        } catch PersonalRequest.Failure.accountChanged {
            throw RoomTemplatesError.accountChanged
        } catch PersonalRequest.Failure.invalidRequest {
            throw RoomTemplatesError.rejected
        } catch {
            throw RoomTemplatesError.retryable
        }
        switch answer.status {
        case 200..<300:
            guard let rows = answer.json?["templates"]?.arrayValue else { throw RoomTemplatesError.invalidData }
            var seen = Set<String>()
            return rows.compactMap(RoomTemplate.init(json:)).filter { seen.insert($0.id).inserted }
        case 401:
            throw RoomTemplatesError.reauthenticationRequired
        // The account itself refused (blocked, inactive, being deleted): signing in again says why, not "none offered".
        case 403 where HTTPRoomFoldersClient.errorCode(answer.json)?.hasPrefix("ACCOUNT_") == true:
            throw RoomTemplatesError.reauthenticationRequired
        case 403, 404:
            throw RoomTemplatesError.unavailable
        case 408, 425, 429, 500..<600:
            throw RoomTemplatesError.retryable
        default:
            throw RoomTemplatesError.rejected
        }
    }
}
