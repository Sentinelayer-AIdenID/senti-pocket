import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts

// Room folders, built against the pinned API contract of 2026-11-04 (flag ROOM_FOLDERS_ENABLED, off by default):
// `/api/v1/me/room-folders`, per person and private, one folder per room. With the flag off the routes answer 404.
// Which folder a room is in is the room list's `folderId`; this client never keeps a copy of it.

/// One of your folders.
public struct RoomFolder: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// Where it sits in your order.
    public let position: Int
    public let roomCount: Int
    public let createdAt: String?

    public init(id: String, name: String, position: Int, roomCount: Int = 0, createdAt: String? = nil) {
        self.id = id
        self.name = name
        self.position = position
        self.roomCount = max(0, roomCount)
        self.createdAt = createdAt
    }

    /// A folder needs an id and a name; a missing position sorts last, a missing count reads as 0.
    init?(json: JSONValue?) {
        guard let json, let id = json["id"]?.stringValue, PersonalRequest.isIdentifier(id),
              let name = json["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        self.init(
            id: id,
            name: name,
            position: json["position"]?.intValue.map { Int(clamping: $0) } ?? Int.max,
            roomCount: json["roomCount"]?.intValue.map { Int(clamping: $0) } ?? 0,
            createdAt: json["createdAt"]?.stringValue
        )
    }

    /// Your order: by position, then by name, then by id, so two folders the server gave one position never swap.
    public static func ordered(_ folders: [RoomFolder]) -> [RoomFolder] {
        folders.sorted { ($0.position, $0.name.lowercased(), $0.id) < ($1.position, $1.name.lowercased(), $1.id) }
    }
}

public enum RoomFolderError: Error, Equatable, Sendable {
    /// The list answered 404 or 403: folders are off (or the token is not a person's).
    case unavailable
    /// The folder (or the room) answered 404 or 403: it is gone. Read the list again.
    case gone
    /// 409: you already have a folder with that name.
    case duplicateName
    /// 409 `ROOM_FOLDER_LIMIT`: you have as many folders as one person can.
    case limitReached
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
    func folders() async throws -> [RoomFolder]
    func createFolder(named name: String) async throws -> RoomFolder
    func renameFolder(_ folderId: String, to name: String) async throws -> RoomFolder
    func moveFolder(_ folderId: String, to position: Int) async throws -> RoomFolder
    /// Its rooms become unfiled.
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
        return RoomFolder.ordered(rows.compactMap(RoomFolder.init(json:)).filter { seen.insert($0.id).inserted })
    }

    public func createFolder(named name: String) async throws -> RoomFolder {
        guard let name = RoomFolderName.cleaned(name) else { throw RoomFolderError.rejected }
        return try folder(in: await send("POST", Self.base, body: ["name": name], notFound: .unavailable))
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
            ?? json?["detail"]?["code"]?.stringValue
            ?? json?["code"]?.stringValue
    }

    private func folder(in answer: JSONValue?) throws -> RoomFolder {
        guard let folder = RoomFolder(json: answer?["folder"]) else { throw RoomFolderError.invalidData }
        return folder
    }

    private func send(_ method: String, _ path: [String], body: [String: Any]? = nil,
                      notFound: RoomFolderError) async throws -> JSONValue? {
        let answer: PersonalRequest.Answer
        do {
            answer = try await request.send(method, path, body: body)
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
        case 403, 404: throw notFound
        case 409:
            // A 409 is a taken name unless the server says it is the cap.
            throw Self.errorCode(answer.json) == "ROOM_FOLDER_LIMIT" ? RoomFolderError.limitReached : RoomFolderError.duplicateName
        case 408, 425, 429, 500..<600: throw RoomFolderError.retryable
        default: throw RoomFolderError.rejected
        }
    }
}
