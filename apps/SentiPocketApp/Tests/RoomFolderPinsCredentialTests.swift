import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class PinIdentityStore: @unchecked Sendable {
    private let lock = NSLock()
    private var token = "fixture-first"
    private var secondAccount = "account-a"
    private var revoked = false

    func get() -> String { lock.withLock { token } }
    func rotate(to accountId: String) {
        lock.withLock { token = "fixture-second"; secondAccount = accountId }
    }
    func revoke() { lock.withLock { revoked = true } }
    var isRevoked: Bool { lock.withLock { revoked } }
    func account(for request: URLRequest) -> String {
        lock.withLock {
            request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-first" ? "account-a" : secondAccount
        }
    }
}

private final class PinIdentityURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, String))?
    private static var seen: [URLRequest] = []

    static func install(_ handler: @escaping (URLRequest) -> (Int, String)) -> URLSession {
        lock.withLock { self.handler = handler; seen = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }
    static var requests: [URLRequest] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.lock.withLock {
            Self.seen.append(request)
            return Self.handler
        }
        let (status, body) = handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Exercises the production credential resolver, transport and center together. The account has no GitHub login;
/// neither a login nor the bearer itself may stand in for the actual account id.
@MainActor
final class RoomFolderPinsCredentialTests: XCTestCase {
    private let base = URL(string: "https://api.example.test")!

    private func client(session: URLSession, store: PinIdentityStore) -> HTTPRoomFolderPinsClient {
        let credentials = RoomFolderPinsAccountCredentials(apiBaseURL: base, urlSession: session,
                                                            tokenProvider: { store.get() })
        return HTTPRoomFolderPinsClient(apiBaseURL: base, urlSession: session,
                                         credentialProvider: { try await credentials.current() })
    }

    private func center(session: URLSession, store: PinIdentityStore) -> RoomFoldersCenter {
        let folders = RoomFoldersCenter(client: HTTPRoomFoldersClient(apiBaseURL: base, urlSession: session,
            tokenProvider: { store.get() }), onRoomsChanged: {}, pinClient: client(session: session, store: store))
        folders.setPinAccountId("account-a")
        return folders
    }

    func test_same_actual_account_with_a_rotated_bearer_succeeds_and_reloads_the_server_pin() async {
        let store = PinIdentityStore()
        let session = PinIdentityURLProtocol.install { request in
            if request.url?.path == "/api/v1/auth/me" {
                return (200, "{\"id\":\"\(store.account(for: request))\",\"github_username\":\"\"}")
            }
            if request.httpMethod == "PUT" {
                XCTAssertEqual(request.url?.path, "/api/v1/me/room-folders/work/pin")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-first")
                store.rotate(to: "account-a")
                return (200, #"{"folder":{"id":"work","name":"Work","pinnedPosition":0}}"#)
            }
            XCTAssertEqual(request.url?.path, "/api/v1/me/room-folders")
            let position = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-first" ? "null" : "0"
            return (200, "{\"folders\":[{\"id\":\"work\",\"name\":\"Work\",\"pinnedPosition\":\(position)}]}")
        }
        defer { session.invalidateAndCancel() }
        let folders = center(session: session, store: store)
        await folders.refresh()
        XCTAssertTrue(folders.items?.first?.supportsPinning == true)
        XCTAssertNil(folders.items?.first?.pinnedPosition)

        await folders.setPinned("work", pinned: true)

        XCTAssertEqual(folders.items?.first?.pinnedPosition, 0, "the acknowledged pin is followed by the server's list")
        XCTAssertNil(folders.notice)
        XCTAssertFalse(folders.isPinSaving)
        let requests = PinIdentityURLProtocol.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "PUT" }.count, 1)
        let reads = requests.filter { $0.url?.path == "/api/v1/me/room-folders" }
        XCTAssertEqual(reads.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer fixture-first", "Bearer fixture-second"])
    }

    func test_a_different_account_after_success_or_conflict_never_starts_its_folder_get() async {
        for status in [200, 409] {
            let store = PinIdentityStore()
            let session = PinIdentityURLProtocol.install { request in
                if request.url?.path == "/api/v1/auth/me" {
                    return (200, "{\"id\":\"\(store.account(for: request))\",\"github_username\":\"\"}")
                }
                if request.httpMethod == "PUT" {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-first")
                    store.rotate(to: "account-b")
                    return status == 200
                        ? (200, #"{"folder":{"id":"c","name":"Notes","pinnedPosition":2}}"#)
                        : (409, #"{"error":{"code":"ROOM_FOLDER_PINS_CHANGED"}}"#)
                }
                XCTAssertEqual(request.url?.path, "/api/v1/me/room-folders")
                return (200, #"{"folders":[{"id":"a","name":"Work","pinnedPosition":0},{"id":"b","name":"Ideas","pinnedPosition":1},{"id":"c","name":"Notes","pinnedPosition":null}]}"#)
            }
            defer { session.invalidateAndCancel() }
            let folders = center(session: session, store: store)
            await folders.refresh()
            if status == 200 { await folders.setPinned("c", pinned: true) }
            else { await folders.reorderPins(["b", "a"]) }

            let requests = PinIdentityURLProtocol.requests
            XCTAssertEqual(requests.filter { $0.httpMethod == "PUT" }.count, 1)
            let reads = requests.filter { $0.url?.path == "/api/v1/me/room-folders" }
            XCTAssertEqual(reads.count, 1, "neither a successful old-account write nor its 409 may start a new-account GET")
            XCTAssertEqual(reads.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-first")
            XCTAssertEqual(RoomFolderPinsPresentation.ordered(folders.items ?? []).map(\.id), ["a", "b"])
            XCTAssertNil(folders.notice, "an old account's result must not appear for the new sign-in")
            XCTAssertFalse(folders.isPinSaving)
        }
    }

    func test_rotation_during_identity_resolution_sends_only_the_verified_rotated_bearer() async throws {
        let store = PinIdentityStore()
        let session = PinIdentityURLProtocol.install { request in
            if request.url?.path == "/api/v1/auth/me" {
                if request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-first" {
                    store.rotate(to: "account-a")
                }
                return (200, #"{"id":"account-a","github_username":""}"#)
            }
            XCTAssertEqual(request.url?.path, "/api/v1/me/room-folders/work/pin")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-second")
            return (200, #"{"folder":{"id":"work","name":"Work","pinnedPosition":0}}"#)
        }
        defer { session.invalidateAndCancel() }
        _ = try await client(session: session, store: store).pinFolder("work", accountId: "account-a")
        XCTAssertEqual(PinIdentityURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count, 1)
    }

    func test_an_account_switch_during_identity_resolution_never_sends_the_old_accounts_pin() async {
        let store = PinIdentityStore()
        let session = PinIdentityURLProtocol.install { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/me", "no pin write may start")
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-first" {
                store.rotate(to: "account-b")
                return (200, #"{"id":"account-a","github_username":""}"#)
            }
            return (200, #"{"id":"account-b","github_username":""}"#)
        }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client(session: session, store: store).pinFolder("work", accountId: "account-a")
            XCTFail("sent the old account's pin with the new person's bearer")
        } catch { XCTAssertEqual(error as? RoomFolderError, .accountChanged) }
        XCTAssertTrue(PinIdentityURLProtocol.requests.allSatisfy { $0.url?.path == "/api/v1/auth/me" })
    }

    func test_identity_401_before_or_after_the_write_requires_sign_in_without_a_folder_reload() async {
        for revokeAfterWrite in [false, true] {
            let store = PinIdentityStore()
            let session = PinIdentityURLProtocol.install { request in
                if request.url?.path == "/api/v1/auth/me" {
                    if !revokeAfterWrite || store.isRevoked { return (401, #"{"error":{"code":"UNAUTHORIZED"}}"#) }
                    return (200, #"{"id":"account-a","github_username":""}"#)
                }
                if request.httpMethod == "PUT" {
                    store.revoke()
                    return (401, #"{"error":{"code":"UNAUTHORIZED"}}"#)
                }
                XCTAssertEqual(request.url?.path, "/api/v1/me/room-folders")
                return (200, #"{"folders":[{"id":"work","name":"Work","pinnedPosition":null}]}"#)
            }
            defer { session.invalidateAndCancel() }
            var signIns = 0
            let folders = RoomFoldersCenter(client: HTTPRoomFoldersClient(apiBaseURL: base, urlSession: session,
                tokenProvider: { store.get() }), onRoomsChanged: {}, onReauthenticationRequired: { signIns += 1 },
                pinClient: client(session: session, store: store))
            folders.setPinAccountId("account-a")
            await folders.refresh()
            await folders.setPinned("work", pinned: true)

            XCTAssertEqual(signIns, 1, "an identity 401 must retain the actionable authentication failure")
            XCTAssertFalse(folders.isPinSaving)
            XCTAssertNil(folders.notice)
            let requests = PinIdentityURLProtocol.requests
            XCTAssertEqual(requests.filter { $0.httpMethod == "PUT" }.count, revokeAfterWrite ? 1 : 0)
            XCTAssertEqual(requests.filter { $0.url?.path == "/api/v1/me/room-folders" }.count, 1)
        }
    }
}
