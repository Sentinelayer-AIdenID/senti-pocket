import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts

// Direct messages, phase 1, built against the pinned API contract of 2026-11-04 (flag DIRECT_MESSAGES_ENABLED, off by
// default): `POST /api/v1/dms`, `GET /api/v1/dms/{id}`, `PATCH /api/v1/dms/{id}/memory-share` and
// `GET|PATCH /api/v1/me/dm-settings`. With the flag off every one of them answers 404, and so does every refusal of a
// direct message (blocked, direct messages off for that person, no room shared, unknown): one answer for all of them,
// so the app can never tell which.

/// A room a direct message names: the one it was opened from, or one you share with the other side.
public struct DirectRoomReference: Equatable, Hashable, Sendable {
    public let sessionId: String
    public let title: String

    public init(sessionId: String, title: String) {
        self.sessionId = sessionId
        self.title = title
    }

    init?(json: JSONValue?) {
        guard let json, let id = json["sessionId"]?.stringValue, PersonalRequest.isIdentifier(id) else { return nil }
        let title = json["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(sessionId: id, title: title.isEmpty ? "Untitled room" : title)
    }
}

/// Whether an agent you message directly may use the chat when it works in one room. The server holds it; it is off
/// for every direct message until you turn it on.
public struct DirectMemoryShare: Equatable, Sendable {
    public let roomId: String
    public let enabled: Bool

    public init(roomId: String, enabled: Bool) {
        self.roomId = roomId
        self.enabled = enabled
    }

    init?(json: JSONValue) {
        guard let roomId = json["roomId"]?.stringValue, !roomId.isEmpty,
              let enabled = json["enabled"]?.boolValue else { return nil }
        self.init(roomId: roomId, enabled: enabled)
    }

    static func list(_ json: JSONValue?) -> [DirectMemoryShare]? {
        guard let rows = json?.arrayValue else { return nil }
        return rows.compactMap(DirectMemoryShare.init(json:))
    }
}

/// A direct message as the server describes it to one of its two sides.
public struct DirectMessage: Equatable, Sendable {
    public let sessionId: String
    public let counterpart: SessionCounterpart
    /// The room it was opened from, or nil when that room is gone or no longer visible to you.
    public let originRoom: DirectRoomReference?
    /// The rooms you share with the other side now, as the server sees them for you.
    public let mutualRooms: [DirectRoomReference]
    public let memoryShare: [DirectMemoryShare]
    /// The server made it for this request (201); false when it already existed (200).
    public let created: Bool

    public init(sessionId: String, counterpart: SessionCounterpart, originRoom: DirectRoomReference?,
                mutualRooms: [DirectRoomReference], memoryShare: [DirectMemoryShare], created: Bool) {
        self.sessionId = sessionId
        self.counterpart = counterpart
        self.originRoom = originRoom
        self.mutualRooms = mutualRooms
        self.memoryShare = memoryShare
        self.created = created
    }

    /// The `dm` object, under `"dm"` or on its own. It needs a session id and a counterpart; `kind`, when present, must
    /// be "direct".
    public init?(json: JSONValue?) {
        guard let json else { return nil }
        let dm = json["dm"]?.objectValue != nil ? json["dm"]! : json
        guard let sessionId = dm["sessionId"]?.stringValue, PersonalRequest.isIdentifier(sessionId),
              dm["kind"].map({ $0.stringValue == "direct" }) ?? true,
              let counterpartJSON = dm["counterpart"],
              let data = try? JSONEncoder().encode(counterpartJSON),
              let counterpart = try? JSONDecoder().decode(SessionCounterpart.self, from: data) else { return nil }
        var seen = Set<String>()
        self.init(
            sessionId: sessionId,
            counterpart: counterpart,
            originRoom: DirectRoomReference(json: dm["originRoom"]),
            mutualRooms: (dm["mutualRooms"]?.arrayValue ?? []).compactMap(DirectRoomReference.init(json:))
                .filter { seen.insert($0.sessionId).inserted },
            memoryShare: DirectMemoryShare.list(dm["memoryShare"]) ?? [],
            created: dm["created"]?.boolValue ?? false
        )
    }

    /// Whether the server says the agent may use this chat in `roomId`. No entry for the room is the server's default,
    /// off: the app never assumes on.
    public func sharesMemory(in roomId: String) -> Bool {
        memoryShare.first { $0.roomId == roomId }?.enabled ?? false
    }

    /// The same direct message with the server's newest memory switches.
    public func with(memoryShare: [DirectMemoryShare]) -> DirectMessage {
        DirectMessage(sessionId: sessionId, counterpart: counterpart, originRoom: originRoom, mutualRooms: mutualRooms,
                      memoryShare: memoryShare, created: created)
    }
}

/// Who can message you directly.
public enum DirectMessagesAllowance: String, CaseIterable, Equatable, Sendable {
    /// People and agents in a room you share with them (the server's default).
    case sharedRooms = "shared_rooms"
    case nobody
}

public enum DirectMessageError: Error, Equatable, Sendable {
    /// 404 (or 403): direct messages are off, or this person or agent cannot be messaged. The two are one answer.
    case unavailable
    case reauthenticationRequired
    case notConfigured
    /// No answer, 408, 425, 429 or 5xx: nothing is known to have changed; try again.
    case retryable
    /// Any other refusal: the request itself was not taken.
    case rejected
    /// A 2xx this build cannot read.
    case invalidData
    /// Another account signed in while the call was out.
    case accountChanged
}

/// Direct messages as the signed-in person. A protocol so the app's models are testable without a network.
public protocol DirectMessaging: Sendable {
    /// Opens (or finds) the direct message with `targetSenderId`, from the room you are in.
    func openDirectMessage(with targetSenderId: String, from contextRoomId: String) async throws -> DirectMessage
    func directMessage(_ sessionId: String) async throws -> DirectMessage
    /// Turns the agent's use of this chat in `roomId` on or off; answers the server's switches after it.
    func setMemoryShare(_ sessionId: String, roomId: String, enabled: Bool) async throws -> [DirectMemoryShare]
    /// Who can message you. Nil is a value this build does not know; a 404 throws `.unavailable` (the feature is off).
    func directMessageSettings() async throws -> DirectMessagesAllowance?
    func setDirectMessageSettings(_ allowance: DirectMessagesAllowance) async throws -> DirectMessagesAllowance?
}

public final class HTTPDirectMessagesClient: DirectMessaging, @unchecked Sendable {
    private let request: PersonalRequest

    public init(apiBaseURL: URL?, urlSession: URLSession, tokenProvider: @escaping @Sendable () -> String?) {
        request = PersonalRequest(apiBaseURL: apiBaseURL, urlSession: urlSession, tokenProvider: tokenProvider)
    }

    public func openDirectMessage(with targetSenderId: String, from contextRoomId: String) async throws -> DirectMessage {
        let target = targetSenderId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target.utf8.count <= 256, PersonalRequest.isIdentifier(contextRoomId) else {
            throw DirectMessageError.rejected
        }
        let answer = try await send("POST", ["api", "v1", "dms"],
                                    body: ["targetSenderId": target, "contextRoomId": contextRoomId])
        guard let dm = DirectMessage(json: answer) else { throw DirectMessageError.invalidData }
        return dm
    }

    public func directMessage(_ sessionId: String) async throws -> DirectMessage {
        guard PersonalRequest.isIdentifier(sessionId) else { throw DirectMessageError.rejected }
        guard let dm = DirectMessage(json: try await send("GET", ["api", "v1", "dms", sessionId])) else {
            throw DirectMessageError.invalidData
        }
        return dm
    }

    public func setMemoryShare(_ sessionId: String, roomId: String, enabled: Bool) async throws -> [DirectMemoryShare] {
        guard PersonalRequest.isIdentifier(sessionId), PersonalRequest.isIdentifier(roomId) else {
            throw DirectMessageError.rejected
        }
        let answer = try await send("PATCH", ["api", "v1", "dms", sessionId, "memory-share"],
                                    body: ["roomId": roomId, "enabled": enabled])
        guard let shares = DirectMemoryShare.list(answer?["memoryShare"]) else { throw DirectMessageError.invalidData }
        return shares
    }

    public func directMessageSettings() async throws -> DirectMessagesAllowance? {
        let answer = try await send("GET", ["api", "v1", "me", "dm-settings"])
        return answer?["allowDms"]?.stringValue.flatMap(DirectMessagesAllowance.init(rawValue:))
    }

    public func setDirectMessageSettings(_ allowance: DirectMessagesAllowance) async throws -> DirectMessagesAllowance? {
        let answer = try await send("PATCH", ["api", "v1", "me", "dm-settings"], body: ["allowDms": allowance.rawValue])
        return answer?["allowDms"]?.stringValue.flatMap(DirectMessagesAllowance.init(rawValue:))
    }

    private func send(_ method: String, _ path: [String], body: [String: Any]? = nil) async throws -> JSONValue? {
        let answer: PersonalRequest.Answer
        do {
            answer = try await request.send(method, path, body: body)
        } catch PersonalRequest.Failure.notConfigured {
            throw DirectMessageError.notConfigured
        } catch PersonalRequest.Failure.notLoggedIn {
            throw DirectMessageError.reauthenticationRequired
        } catch PersonalRequest.Failure.accountChanged {
            throw DirectMessageError.accountChanged
        } catch PersonalRequest.Failure.invalidRequest {
            throw DirectMessageError.rejected
        } catch {
            throw DirectMessageError.retryable
        }
        switch answer.status {
        case 200..<300: return answer.json
        case 401: throw DirectMessageError.reauthenticationRequired
        case 403, 404: throw DirectMessageError.unavailable
        case 408, 425, 429, 500..<600: throw DirectMessageError.retryable
        default: throw DirectMessageError.rejected
        }
    }
}
