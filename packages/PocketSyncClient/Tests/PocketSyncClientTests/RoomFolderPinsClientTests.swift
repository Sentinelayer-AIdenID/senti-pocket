import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts
import XCTest
@testable import PocketSyncClient

private final class PinCredentialState: @unchecked Sendable {
    private let lock = NSLock()
    private var credential = RoomFolderPinsCredential(accountId: "account-a", token: "person-token")
    func current() -> RoomFolderPinsCredential { lock.withLock { credential } }
    func set(accountId: String, token: String) {
        lock.withLock { credential = RoomFolderPinsCredential(accountId: accountId, token: token) }
    }
}

final class RoomFolderPinsClientTests: XCTestCase {
    private func client(
        credentials: @escaping @Sendable () async throws -> RoomFolderPinsCredential = {
            RoomFolderPinsCredential(accountId: "account-a", token: "person-token")
        }, during: (() -> Void)? = nil,
        _ handler: @escaping (PersonalRoutesURLProtocol.Seen) -> (Int, String)
    ) -> HTTPRoomFolderPinsClient {
        PersonalRoutesURLProtocol.reset(during: during, handler: handler)
        return HTTPRoomFolderPinsClient(apiBaseURL: URL(string: "https://api.example.test"),
            urlSession: PersonalRoutesURLProtocol.session(), credentialProvider: credentials)
    }

    func test_missing_pin_position_is_unsupported_but_explicit_null_is_supported() async throws {
        let client = client { _ in (200, #"{"folders":[{"id":"old","name":"Old","position":0},{"id":"new","name":"New","position":1,"pinnedPosition":null},{"id":"pin","name":"Pinned","position":2,"pinnedPosition":0}]}"#) }
        let folders = try await client.folders(accountId: "account-a")
        XCTAssertEqual(folders.map(\.supportsPinning), [false, true, true])
        XCTAssertEqual(folders.map(\.pinnedPosition), [nil, nil, 0])
    }

    func test_malformed_positions_do_not_advertise_pin_support() throws {
        for value in ["true", "\"0\"", "-1", "10", "0.5"] {
            let raw = "{\"id\":\"folder\",\"name\":\"Folder\",\"pinnedPosition\":" + value + "}"
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
            let folder = try XCTUnwrap(RoomFolder(json: json))
            XCTAssertFalse(folder.supportsPinning, value)
            XCTAssertNil(folder.pinnedPosition, value)
        }
    }

    func test_pin_unpin_and_reorder_use_the_exact_routes_and_full_order() async throws {
        let client = client { _ in (200, #"{"folder":{"id":"f-a","name":"Studio","position":0,"pinnedPosition":1}}"#) }
        let pinned = try await client.pinFolder("f-a", accountId: "account-a")
        XCTAssertEqual(pinned.pinnedPosition, 1)
        XCTAssertTrue(pinned.supportsPinning)
        try await client.unpinFolder("f-a", accountId: "account-a")
        try await client.reorderFolderPins(["f-b", "f-a"], accountId: "account-a")
        let requests = PersonalRoutesURLProtocol.requests
        XCTAssertEqual(requests.map(\.method), ["PUT", "DELETE", "PUT"])
        XCTAssertEqual(requests.map(\.authorization), Array(repeating: "Bearer person-token", count: 3))
        XCTAssertEqual(requests.map(\.path), ["/api/v1/me/room-folders/f-a/pin", "/api/v1/me/room-folders/f-a/pin", "/api/v1/me/room-folders/pins"])
        XCTAssertEqual(requests[2].body, .object(["folderIds": .array([.string("f-b"), .string("f-a")])]))
    }

    func test_pin_limit_and_changed_pin_set_keep_their_distinct_409_meanings() async {
        let limit = client { _ in (409, #"{"error":{"code":"ROOM_FOLDER_PIN_LIMIT"}}"#) }
        do { _ = try await limit.pinFolder("eleventh", accountId: "account-a"); XCTFail("an eleventh pin succeeded") }
        catch { XCTAssertEqual(error as? RoomFolderError, .pinLimit) }
        let changed = client { _ in (409, #"{"detail":{"error":{"code":"ROOM_FOLDER_PINS_CHANGED"}}}"#) }
        do { try await changed.reorderFolderPins(["f-b", "f-a"], accountId: "account-a"); XCTFail("a stale set succeeded") }
        catch { XCTAssertEqual(error as? RoomFolderError, .pinsChanged) }
    }

    func test_invalid_reorders_never_send_and_empty_order_is_valid() async throws {
        let client = client { _ in (200, "{}") }
        do { try await client.reorderFolderPins(["f-a", "f-a"], accountId: "account-a"); XCTFail("sent duplicates") }
        catch { XCTAssertEqual(error as? RoomFolderError, .pinsChanged) }
        do { try await client.reorderFolderPins((0...10).map { "f-\($0)" }, accountId: "account-a"); XCTFail("sent more than ten") }
        catch { XCTAssertEqual(error as? RoomFolderError, .rejected) }
        XCTAssertTrue(PersonalRoutesURLProtocol.requests.isEmpty)
        try await client.reorderFolderPins([], accountId: "account-a")
        XCTAssertEqual(PersonalRoutesURLProtocol.requests.first?.body, .object(["folderIds": .array([])]))
    }

    func test_rotation_in_flight_keeps_the_verified_bearer_and_allows_the_same_accounts_reload() async throws {
        let state = PinCredentialState()
        let client = client(credentials: { state.current() },
            during: { state.set(accountId: "account-a", token: "rotated-token") }) { request in
                request.method == "PUT"
                    ? (200, #"{"folder":{"id":"f-a","name":"Studio","pinnedPosition":0}}"#)
                    : (200, #"{"folders":[{"id":"f-a","name":"Studio","pinnedPosition":0}]}"#)
            }
        _ = try await client.pinFolder("f-a", accountId: "account-a")
        let folders = try await client.folders(accountId: "account-a")
        XCTAssertEqual(folders.first?.pinnedPosition, 0)
        XCTAssertEqual(PersonalRoutesURLProtocol.requests.map(\.authorization),
                       ["Bearer person-token", "Bearer rotated-token"])
    }

    func test_an_account_change_while_a_write_finishes_rejects_both_success_and_conflict() async {
        for status in [200, 409] {
            let state = PinCredentialState()
            let client = client(credentials: { state.current() },
                during: { state.set(accountId: "account-b", token: "another-person") }) { _ in
                    (status, status == 200
                        ? #"{"folder":{"id":"f-a","name":"Studio","pinnedPosition":0}}"#
                        : #"{"error":{"code":"ROOM_FOLDER_PINS_CHANGED"}}"#)
                }
            do { _ = try await client.pinFolder("f-a", accountId: "account-a"); XCTFail("accepted an old account's response") }
            catch { XCTAssertEqual(error as? RoomFolderError, .accountChanged) }
            XCTAssertEqual(PersonalRoutesURLProtocol.requests.count, 1)
            XCTAssertEqual(PersonalRoutesURLProtocol.requests.first?.authorization, "Bearer person-token")
        }
    }

    func test_a_changed_account_refuses_the_follow_up_read_before_sending_it() async throws {
        let state = PinCredentialState()
        let client = client(credentials: { state.current() }) { _ in
            (200, #"{"folder":{"id":"f-a","name":"Studio","pinnedPosition":0}}"#)
        }
        _ = try await client.pinFolder("f-a", accountId: "account-a")
        state.set(accountId: "account-b", token: "another-person")
        do { _ = try await client.folders(accountId: "account-a"); XCTFail("read the next person's folders") }
        catch { XCTAssertEqual(error as? RoomFolderError, .accountChanged) }
        XCTAssertEqual(PersonalRoutesURLProtocol.requests.map(\.method), ["PUT"])
    }
}
