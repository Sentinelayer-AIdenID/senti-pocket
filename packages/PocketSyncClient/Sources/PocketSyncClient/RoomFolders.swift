import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts

// Room folders, built against the API's contract (sentinelayer-api #1125, flag ROOM_FOLDERS_ENABLED, off by default):
// `/api/v1/me/room-folders`, per person and private, one folder per room, folders inside folders up to 3 levels. With
// the flag off the routes answer 404. Which folder a room is in is the room list's `folderId`; this client never keeps a
// copy of it.

/// One of your folders.
public struct RoomFolder: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// The folder it is in; nil at the top level.
    public let parentFolderId: String?
    /// Where it sits among the folders beside it.
    public let position: Int
    /// The rooms in it.
    public let roomCount: Int
    /// The rooms in it and in every folder inside it.
    public let totalRoomCount: Int
    public let createdAt: String?

    public init(id: String, name: String, parentFolderId: String? = nil, position: Int, roomCount: Int = 0,
                totalRoomCount: Int? = nil, createdAt: String? = nil) {
        self.id = id
        self.name = name
        self.parentFolderId = parentFolderId
        self.position = position
        self.roomCount = max(0, roomCount)
        self.totalRoomCount = max(self.roomCount, totalRoomCount ?? 0)
        self.createdAt = createdAt
    }

    /// A folder needs an id and a name; a missing position sorts last, a missing count reads as 0, and a parent that is
    /// not an id reads as the top level.
    init?(json: JSONValue?) {
        guard let json, let id = json["id"]?.stringValue, PersonalRequest.isIdentifier(id),
              let name = json["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        self.init(
            id: id,
            name: name,
            parentFolderId: json["parentFolderId"]?.stringValue.flatMap { PersonalRequest.isIdentifier($0) ? $0 : nil },
            position: json["position"]?.intValue.map { Int(clamping: $0) } ?? Int.max,
            roomCount: json["roomCount"]?.intValue.map { Int(clamping: $0) } ?? 0,
            totalRoomCount: json["totalRoomCount"]?.intValue.map { Int(clamping: $0) },
            createdAt: json["createdAt"]?.stringValue
        )
    }
}

public enum RoomFolderError: Error, Equatable, Sendable {
    /// The list answered 404 or 403: folders are off (or the token is not a person's).
    case unavailable
    /// The folder (or the room) answered 404 or 403: it is gone. Read the list again.
    case gone
    /// 409 `ROOM_FOLDER_NAME_TAKEN`: a folder beside it already has that name (on a delete: a folder inside it that
    /// would move up has the name of one already there).
    case duplicateName
    /// 409 `ROOM_FOLDER_LIMIT`: you have as many folders as one person can.
    case limitReached
    /// 409 `ROOM_FOLDER_DEPTH`: the folder would sit more than 3 levels deep.
    case tooDeep
    /// 409 `ROOM_FOLDER_CYCLE`: a folder cannot go inside itself or a folder inside it.
    case cycle
    /// The name is not one the API takes (see `RoomFolderName`), or the API refused the request.
    case rejected
    case reauthenticationRequired
    case notConfigured
    case retryable
    case invalidData
    case accountChanged
}

/// Your room folders as the signed-in person. A protocol so the app's model is testable without a network.
public protocol RoomFoldersServing: Sendable {
    /// Every folder, in no particular order: `RoomFolderTree` places them.
    func folders() async throws -> [RoomFolder]
    /// A new folder at the top level, or inside `parentFolderId`. One `idempotencyKey` for every try of one create, so a
    /// retry after a lost answer gets the folder made, not "that name is taken".
    func createFolder(named name: String, in parentFolderId: String?, idempotencyKey: String?) async throws -> RoomFolder
    func renameFolder(_ folderId: String, to name: String) async throws -> RoomFolder
    /// A new place among the folders beside it, counted from 0.
    func moveFolder(_ folderId: String, to position: Int) async throws -> RoomFolder
    /// Into another folder (nil: the top level), after the folders already there.
    func moveFolder(_ folderId: String, into parentFolderId: String?) async throws -> RoomFolder
    /// Its folders take its place and its rooms move to the folder it was in (at the top level they are unfiled).
    func deleteFolder(_ folderId: String) async throws
    /// Moves the room into the folder, out of any other.
    func file(room sessionId: String, in folderId: String) async throws
    func unfile(room sessionId: String, from folderId: String) async throws
}

public final class HTTPRoomFoldersClient: RoomFoldersServing, @unchecked Sendable {
    private let request: PersonalRequest
    private static let base = ["api", "v1", "me", "room-folders"]

    public init(apiBaseURL: URL?, urlSession: URLSession, tokenProvider: @escaping @Sendable () -> String?) {
        request = PersonalRequest(apiBaseURL: apiBaseURL, urlSession: urlSession, tokenProvider: tokenProvider)
    }

    public func folders() async throws -> [RoomFolder] {
        let answer = try await send("GET", Self.base, notFound: .unavailable)
        guard let rows = answer?["folders"]?.arrayValue else { throw RoomFolderError.invalidData }
        var seen = Set<String>()
        return rows.compactMap(RoomFolder.init(json:)).filter { seen.insert($0.id).inserted }
    }

    public func createFolder(named name: String, in parentFolderId: String?,
                             idempotencyKey: String?) async throws -> RoomFolder {
        guard let name = RoomFolderName.cleaned(name), parentFolderId.map(PersonalRequest.isIdentifier) ?? true else {
            throw RoomFolderError.rejected
        }
        var body: [String: Any] = ["name": name]
        if let parentFolderId { body["parentFolderId"] = parentFolderId }
        let key = idempotencyKey.flatMap { Self.isIdempotencyKey($0) ? $0 : nil }
        // Made inside a folder, a 404 is that folder gone (deleted elsewhere a moment ago), not folders turned off.
        return try folder(in: await send("POST", Self.base, body: body,
                                         headers: key.map { ["Idempotency-Key": $0] } ?? [:],
                                         notFound: parentFolderId == nil ? .unavailable : .gone))
    }

    public func renameFolder(_ folderId: String, to name: String) async throws -> RoomFolder {
        guard PersonalRequest.isIdentifier(folderId), let name = RoomFolderName.cleaned(name) else {
            throw RoomFolderError.rejected
        }
        return try folder(in: await send("PATCH", Self.base + [folderId], body: ["name": name], notFound: .gone))
    }

    public func moveFolder(_ folderId: String, to position: Int) async throws -> RoomFolder {
        guard PersonalRequest.isIdentifier(folderId), position >= 0 else { throw RoomFolderError.rejected }
        return try folder(in: await send("PATCH", Self.base + [folderId], body: ["position": position], notFound: .gone))
    }

    public func moveFolder(_ folderId: String, into parentFolderId: String?) async throws -> RoomFolder {
        guard PersonalRequest.isIdentifier(folderId), parentFolderId.map(PersonalRequest.isIdentifier) ?? true,
              parentFolderId != folderId else { throw RoomFolderError.rejected }
        // JSON null moves it to the top level; the position is left out, so it goes after the folders already there.
        let parent: Any = parentFolderId ?? NSNull()
        return try folder(in: await send("PATCH", Self.base + [folderId], body: ["parentFolderId": parent], notFound: .gone))
    }

    public func deleteFolder(_ folderId: String) async throws {
        guard PersonalRequest.isIdentifier(folderId) else { throw RoomFolderError.rejected }
        _ = try await send("DELETE", Self.base + [folderId], notFound: .gone)
    }

    public func file(room sessionId: String, in folderId: String) async throws {
        guard PersonalRequest.isIdentifier(folderId), PersonalRequest.isIdentifier(sessionId) else {
            throw RoomFolderError.rejected
        }
        _ = try await send("PUT", Self.base + [folderId, "rooms", sessionId], notFound: .gone)
    }

    public func unfile(room sessionId: String, from folderId: String) async throws {
        guard PersonalRequest.isIdentifier(folderId), PersonalRequest.isIdentifier(sessionId) else {
            throw RoomFolderError.rejected
        }
        _ = try await send("DELETE", Self.base + [folderId, "rooms", sessionId], notFound: .gone)
    }

    /// The error's code, as the API writes it (`{"error": {"code": ...}}`), or under FastAPI's `detail`.
    static func errorCode(_ json: JSONValue?) -> String? {
        json?["error"]?["code"]?.stringValue
            ?? json?["detail"]?["error"]?["code"]?.stringValue
            ?? json?["detail"]?["code"]?.stringValue
            ?? json?["code"]?.stringValue
    }

    /// What a 409 means. A 409 with no code at all is a taken name, as the first servers sent it; a code this build does
    /// not know (a reused Idempotency-Key, say) is a refusal, never a guess at the name.
    static func conflict(_ json: JSONValue?) -> RoomFolderError {
        switch errorCode(json) {
        case "ROOM_FOLDER_NAME_TAKEN", nil: return .duplicateName
        case "ROOM_FOLDER_LIMIT": return .limitReached
        case "ROOM_FOLDER_DEPTH": return .tooDeep
        case "ROOM_FOLDER_CYCLE": return .cycle
        default: return .rejected
        }
    }

    /// The API takes keys of up to 200 characters; this one is sent only if it is printable ASCII.
    static func isIdempotencyKey(_ key: String) -> Bool {
        (1...200).contains(key.utf8.count) && key.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    private func folder(in answer: JSONValue?) throws -> RoomFolder {
        guard let folder = RoomFolder(json: answer?["folder"]) else { throw RoomFolderError.invalidData }
        return folder
    }

    private func send(_ method: String, _ path: [String], body: [String: Any]? = nil, headers: [String: String] = [:],
                      notFound: RoomFolderError) async throws -> JSONValue? {
        let answer: PersonalRequest.Answer
        do {
            answer = try await request.send(method, path, body: body, headers: headers)
        } catch PersonalRequest.Failure.notConfigured {
            throw RoomFolderError.notConfigured
        } catch PersonalRequest.Failure.notLoggedIn {
            throw RoomFolderError.reauthenticationRequired
        } catch PersonalRequest.Failure.accountChanged {
            throw RoomFolderError.accountChanged
        } catch PersonalRequest.Failure.invalidRequest {
            throw RoomFolderError.rejected
        } catch {
            throw RoomFolderError.retryable
        }
        switch answer.status {
        case 200..<300: return answer.json
        case 401: throw RoomFolderError.reauthenticationRequired
        // The account itself refused (blocked, banned, inactive, being deleted): what signing in again says, not a
        // folder that is gone.
        case 403 where Self.errorCode(answer.json)?.hasPrefix("ACCOUNT_") == true:
            throw RoomFolderError.reauthenticationRequired
        case 403, 404: throw notFound
        case 409: throw Self.conflict(answer.json)
        case 408, 425, 429, 500..<600: throw RoomFolderError.retryable
        default: throw RoomFolderError.rejected
        }
    }
}
