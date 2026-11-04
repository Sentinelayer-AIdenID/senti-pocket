import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts
import XCTest
@testable import PocketSyncClient

/// Room folders against the pinned contract (2026-11-04): the routes, the folder object, your order, and 404/403 read as
/// "off" on the list and "gone" on one folder. Names are made up.
final class RoomFoldersClientTests: XCTestCase {
    private func client(_ handler: @escaping (PersonalRoutesURLProtocol.Seen) -> (Int, String)) -> HTTPRoomFoldersClient {
        PersonalRoutesURLProtocol.reset(handler: handler)
        return HTTPRoomFoldersClient(apiBaseURL: URL(string: "https://api.example.test"),
                                     urlSession: PersonalRoutesURLProtocol.session(), tokenProvider: { "person-token" })
    }

    func test_the_list_is_in_your_order_and_skips_what_it_cannot_read() async throws {
        let folders = client { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.path, "/api/v1/me/room-folders")
            XCTAssertEqual(request.authorization, "Bearer person-token")
            return (200, """
            {"folders": [
              {"id": "f-b", "name": "Clients", "position": 1, "roomCount": 2, "createdAt": "2026-11-04T03:20:00Z"},
              {"id": "f-a", "name": "Launch", "position": 0, "roomCount": 1, "createdAt": "2026-11-04T03:19:00Z"},
              {"id": "f-c", "name": "Archive", "position": 1, "roomCount": 0},
              {"id": "f-a", "name": "Launch again", "position": 5},
              {"name": "no id", "position": 2},
              {"id": "f-d", "name": "   ", "position": 3},
              {"id": "f-e", "name": "No place"}
            ]}
            """)
        }
        let list = try await folders.folders()
        XCTAssertEqual(list.map(\.id), ["f-a", "f-c", "f-b", "f-e"],
                       "by position, a tie by name, a folder listed twice once, one without a position last")
        XCTAssertEqual(list[0].roomCount, 1)
        XCTAssertEqual(list[3].roomCount, 0)
    }

    func test_off_is_a_404_or_a_403_on_the_list() async {
        for status in [404, 403] {
            let folders = client { _ in (status, #"{"detail":"Not Found"}"#) }
            do {
                _ = try await folders.folders()
                XCTFail("\(status) listed folders")
            } catch {
                XCTAssertEqual(error as? RoomFolderError, .unavailable)
            }
        }
    }

    func test_a_new_folder_sends_its_trimmed_name_and_a_taken_name_says_so() async throws {
        var folders = client { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/api/v1/me/room-folders")
            XCTAssertEqual(request.body?["name"]?.stringValue, "Launch")
            return (201, #"{"folder": {"id": "f-a", "name": "Launch", "position": 0, "roomCount": 0}}"#)
        }
        let made = try await folders.createFolder(named: "  Launch \n")
        XCTAssertEqual(made, RoomFolder(id: "f-a", name: "Launch", position: 0, roomCount: 0))

        folders = client { _ in (409, #"{"detail":"duplicate"}"#) }
        do {
            _ = try await folders.createFolder(named: "Launch")
            XCTFail("a taken name was made")
        } catch {
            XCTAssertEqual(error as? RoomFolderError, .duplicateName)
        }
    }

    func test_a_name_the_api_would_refuse_is_never_sent() async {
        let folders = client { _ in (201, "{}") }
        for name in ["", "   ", String(repeating: "a", count: 61), "tab\there"] {
            do {
                _ = try await folders.createFolder(named: name)
                XCTFail("sent \(name)")
            } catch {
                XCTAssertEqual(error as? RoomFolderError, .rejected)
            }
        }
        XCTAssertTrue(PersonalRoutesURLProtocol.requests.isEmpty)
    }

    func test_rename_move_and_delete_name_the_folder_and_a_missing_one_is_gone() async throws {
        var folders = client { _ in (200, #"{"folder": {"id": "f-a", "name": "Renamed", "position": 2, "roomCount": 1}}"#) }
        _ = try await folders.renameFolder("f-a", to: "Renamed")
        _ = try await folders.moveFolder("f-a", to: 2)
        let rename = PersonalRoutesURLProtocol.requests[0]
        let move = PersonalRoutesURLProtocol.requests[1]
        XCTAssertEqual([rename.method, rename.path], ["PATCH", "/api/v1/me/room-folders/f-a"])
        XCTAssertEqual(rename.body, .object(["name": .string("Renamed")]), "a rename sends only the name")
        XCTAssertEqual([move.method, move.path], ["PATCH", "/api/v1/me/room-folders/f-a"])
        XCTAssertEqual(move.body, .object(["position": .int(2)]), "a move sends only the position")

        folders = client { _ in (204, "") }
        try await folders.deleteFolder("f-a")
        XCTAssertEqual(PersonalRoutesURLProtocol.requests.map(\.method), ["DELETE"])

        for status in [404, 403] {
            folders = client { _ in (status, "") }
            do {
                try await folders.deleteFolder("f-gone")
                XCTFail("deleted a folder that is not there")
            } catch {
                XCTAssertEqual(error as? RoomFolderError, .gone)
            }
        }
    }

    func test_filing_puts_and_unfiling_deletes_the_room_under_its_folder() async throws {
        let folders = client { _ in (204, "") }
        try await folders.file(room: "room-0001", in: "f-a")
        try await folders.unfile(room: "room-0001", from: "f-a")
        let seen = PersonalRoutesURLProtocol.requests
        XCTAssertEqual(seen.map(\.method), ["PUT", "DELETE"])
        XCTAssertEqual(seen.map(\.path), ["/api/v1/me/room-folders/f-a/rooms/room-0001",
                                          "/api/v1/me/room-folders/f-a/rooms/room-0001"])
        XCTAssertNil(seen[0].body, "filing carries no body")
    }
}
