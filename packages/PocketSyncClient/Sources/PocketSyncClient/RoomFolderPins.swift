import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Pin membership and order are private to the signed-in person, independent of the folder tree.
public protocol RoomFolderPinsServing: Sendable {
    func pinFolder(_ folderId: String, accountId: String) async throws -> RoomFolder
    func unpinFolder(_ folderId: String, accountId: String) async throws
    func reorderFolderPins(_ folderIds: [String], accountId: String) async throws
    /// The authoritative reload belongs to the same account as the write, including on a 409.
    func folders(accountId: String) async throws -> [RoomFolder]
}

/// An account verified using this exact bearer. Refreshing the bearer does not change the account.
public struct RoomFolderPinsCredential: Sendable {
    public let accountId: String
    public let token: String

    public init(accountId: String, token: String) {
        self.accountId = accountId
        self.token = token
    }
}

/// Pin operations and their reloads are bound to an account. The existing folder transport still handles the
/// request and response; its fixed bearer is the one verified for that account before this request starts.
public final class HTTPRoomFolderPinsClient: RoomFolderPinsServing, @unchecked Sendable {
    private let apiBaseURL: URL?
    private let urlSession: URLSession
    private let credentialProvider: @Sendable () async throws -> RoomFolderPinsCredential

    public init(apiBaseURL: URL?, urlSession: URLSession,
                credentialProvider: @escaping @Sendable () async throws -> RoomFolderPinsCredential) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.credentialProvider = credentialProvider
    }

    public func pinFolder(_ folderId: String, accountId: String) async throws -> RoomFolder {
        guard PersonalRequest.isIdentifier(folderId) else { throw RoomFolderError.rejected }
        return try await withAccount(accountId) { try await $0.pinFolder(folderId) }
    }

    public func unpinFolder(_ folderId: String, accountId: String) async throws {
        guard PersonalRequest.isIdentifier(folderId) else { throw RoomFolderError.rejected }
        try await withAccount(accountId) { try await $0.unpinFolder(folderId) }
    }

    /// The full pin set, at most ten. The server accepts a same-set last write; a changed set is a 409.
    public func reorderFolderPins(_ folderIds: [String], accountId: String) async throws {
        guard folderIds.count <= 10, folderIds.allSatisfy(PersonalRequest.isIdentifier) else {
            throw RoomFolderError.rejected
        }
        guard Set(folderIds).count == folderIds.count else { throw RoomFolderError.pinsChanged }
        try await withAccount(accountId) { try await $0.reorderFolderPins(folderIds) }
    }

    public func folders(accountId: String) async throws -> [RoomFolder] {
        try await withAccount(accountId) { try await $0.folders() }
    }

    private func withAccount<Value: Sendable>(_ accountId: String,
        operation: @Sendable (HTTPRoomFoldersClient) async throws -> Value) async throws -> Value {
        guard !accountId.isEmpty else { throw RoomFolderError.reauthenticationRequired }
        let credential = try await credentialProvider()
        guard credential.accountId == accountId else { throw RoomFolderError.accountChanged }
        let bound = HTTPRoomFoldersClient(apiBaseURL: apiBaseURL, urlSession: urlSession,
                                          tokenProvider: { credential.token })
        let result: Result<Value, Error>
        do { result = .success(try await operation(bound)) }
        catch { result = .failure(error) }
        // Check the person, not equality with a bearer that can rotate while the write is in flight. Check failed
        // writes too: a conflict from the old account must not trigger a reload with the next account's credential.
        guard try await credentialProvider().accountId == accountId else { throw RoomFolderError.accountChanged }
        return try result.get()
    }
}

extension HTTPRoomFoldersClient {
    fileprivate func pinFolder(_ folderId: String) async throws -> RoomFolder {
        try folder(in: await send("PUT", Self.base + [folderId, "pin"], notFound: .gone))
    }

    fileprivate func unpinFolder(_ folderId: String) async throws {
        _ = try await send("DELETE", Self.base + [folderId, "pin"], notFound: .gone)
    }

    fileprivate func reorderFolderPins(_ folderIds: [String]) async throws {
        _ = try await send("PUT", Self.base + ["pins"], body: ["folderIds": folderIds], notFound: .unavailable)
    }
}
