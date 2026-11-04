import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts
import XCTest
@testable import PocketSyncClient

/// Room folders against the API's contract (sentinelayer-api #1125): the routes, the folder object with its parent and
/// counts, the 409 codes, and 404/403 read as "off" on the list and "gone" on one folder. Names are made up.
final class RoomFoldersClientTests: XCTestCase {
    private func client(_ handler: @escaping (PersonalRoutesURLProtocol.Seen) -> (Int, String)) -> HTTPRoomFoldersClient {
        PersonalRoutesURLProtocol.reset(handler: handler)
        return HTTPRoomFoldersClient(apiBaseURL: URL(string: "https://api.example.test"),
                                     urlSession: PersonalRoutesURLProtocol.session(), tokenProvider: { "person-token" })
    }

    /// The list is flat, as the server sends it; the tree is the app's to build (`RoomFolderTree`).
    func test_the_list_reads_each_folders_parent_and_counts_and_skips_what_it_cannot_read() async throws {
        let folders = client { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.path, "/api/v1/me/room-folders")
            XCTAssertEqual(request.authorization, "Bearer person-token")
            return (200, """
            {"folders": [
              {"id": "f-b", "name": "Ops", "parentFolderId": null, "position": 1, "roomCount": 2, "totalRoomCount": 5,
               "createdAt": "2026-11-04T03:20:00+00:00"},
              {"id": "f-c", "name": "Night shift", "parentFolderId": "f-b", "position": 0, "roomCount": 3,
               "totalRoomCount": 3},
              {"id": "f-a", "name": "Studio", "position": 0, "roomCount": 1},
              {"id": "f-a", "name": "Studio again", "position": 5},
              {"name": "no id", "position": 2},
              {"id": "f-d", "name": "   ", "position": 3},
              {"id": "f-e", "name": "Odd parent", "parentFolderId": "not an id!", "position": 4},
              {"id": "f-f", "name": "No place"}
            ]}
            """)
        }
        let list = try await folders.folders()
        XCTAssertEqual(list.map(\.id), ["f-b", "f-c", "f-a", "f-e", "f-f"], "as sent, a folder listed twice once")
        XCTAssertEqual(list[0].parentFolderId, nil)
        XCTAssertEqual(list[0].totalRoomCount, 5)
        XCTAssertEqual(list[0].createdAt, "2026-11-04T03:20:00+00:00")
        XCTAssertEqual(list[1].parentFolderId, "f-b")
        XCTAssertEqual(list[2].totalRoomCount, 1, "no total: its own rooms")
        XCTAssertNil(list[3].parentFolderId, "a parent that is not an id: the top level")
        XCTAssertEqual(list[4].position, Int.max, "no position: last")
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

    func test_a_new_folder_sends_its_trimmed_name_its_parent_and_one_key() async throws {
        let folders = client { _ in
            (201, #"{"folder": {"id": "f-a", "name": "Studio", "parentFolderId": null, "position": 0, "roomCount": 0}}"#)
        }
        let made = try await folders.createFolder(named: "  Studio \n", in: nil, idempotencyKey: "key-1")
        XCTAssertEqual(made, RoomFolder(id: "f-a", name: "Studio", position: 0, roomCount: 0))
        _ = try await folders.createFolder(named: "Sketches", in: "f-a", idempotencyKey: "key-2")
        _ = try await folders.createFolder(named: "Notes", in: nil, idempotencyKey: nil)
        let seen = PersonalRoutesURLProtocol.requests
        XCTAssertEqual(seen.map(\.method), ["POST", "POST", "POST"])
        XCTAssertEqual(seen.map(\.path), Array(repeating: "/api/v1/me/room-folders", count: 3))
        XCTAssertEqual(seen[0].body, .object(["name": .string("Studio")]), "at the top level: no parent sent")
        XCTAssertEqual(seen[1].body, .object(["name": .string("Sketches"), "parentFolderId": .string("f-a")]))
        XCTAssertEqual(seen.map(\.idempotencyKey), ["key-1", "key-2", nil])
    }

    func test_a_key_or_a_parent_that_is_not_sendable_is_never_sent() async {
        let folders = client { _ in (201, #"{"folder": {"id": "f-a", "name": "Studio", "position": 0}}"#) }
        do {
            _ = try await folders.createFolder(named: "Studio", in: "not an id!", idempotencyKey: nil)
            XCTFail("sent a parent that is not an id")
        } catch {
            XCTAssertEqual(error as? RoomFolderError, .rejected)
        }
        _ = try? await folders.createFolder(named: "Studio", in: nil, idempotencyKey: "has a space")
        XCTAssertEqual(PersonalRoutesURLProtocol.requests.map(\.idempotencyKey), [nil], "a bad key is left out")
    }

    /// Each 409 code is its own refusal. A 409 with no code at all is a taken name, as the first servers sent it; a
    /// code this build does not know (a reused key) is a refusal, never "that name is taken".
    func test_each_409_code_is_its_own_refusal() async {
        let cases: [(String, RoomFolderError)] = [
            (#"{"error": {"code": "ROOM_FOLDER_LIMIT"}}"#, .limitReached),
            (#"{"error": {"code": "ROOM_FOLDER_DEPTH"}}"#, .tooDeep),
            (#"{"error": {"code": "ROOM_FOLDER_CYCLE"}}"#, .cycle),
            (#"{"error": {"code": "ROOM_FOLDER_NAME_TAKEN"}}"#, .duplicateName),
            (#"{"detail": {"error": {"code": "ROOM_FOLDER_DEPTH"}}}"#, .tooDeep),
            (#"{"detail": {"code": "ROOM_FOLDER_LIMIT"}}"#, .limitReached),
            (#"{"error": {"code": "HTTP_ERROR", "message": "Idempotency-Key reused"}}"#, .rejected),
            (#"{"detail": "duplicate"}"#, .duplicateName),
            ("", .duplicateName)
        ]
        for (body, expected) in cases {
            let folders = client { _ in (409, body) }
            do {
                _ = try await folders.createFolder(named: "One more", in: nil, idempotencyKey: nil)
                XCTFail("made a folder on a 409")
            } catch {
                XCTAssertEqual(error as? RoomFolderError, expected, body)
            }
        }
    }

    func test_a_move_that_the_server_refuses_says_why() async {
        for (body, expected) in [(#"{"error": {"code": "ROOM_FOLDER_DEPTH"}}"#, RoomFolderError.tooDeep),
                                 (#"{"error": {"code": "ROOM_FOLDER_CYCLE"}}"#, .cycle),
                                 (#"{"error": {"code": "ROOM_FOLDER_NAME_TAKEN"}}"#, .duplicateName)] {
            let folders = client { _ in (409, body) }
            do {
                _ = try await folders.moveFolder("f-a", into: "f-b")
                XCTFail("moved on a 409")
            } catch {
                XCTAssertEqual(error as? RoomFolderError, expected, body)
            }
        }
    }

    /// A delete that would put a folder inside it beside one of the same name is refused with NAME_TAKEN.
    func test_a_delete_refused_for_a_name_says_so() async {
        let folders = client { _ in (409, #"{"error": {"code": "ROOM_FOLDER_NAME_TAKEN"}}"#) }
        do {
            try await folders.deleteFolder("f-a")
            XCTFail("deleted on a 409")
        } catch {
            XCTAssertEqual(error as? RoomFolderError, .duplicateName)
        }
    }

    func test_a_name_the_api_would_refuse_is_never_sent() async {
        let folders = client { _ in (201, "{}") }
        for name in ["", "   ", String(repeating: "a", count: 61), "tab\there", "line\u{2028}break"] {
            do {
                _ = try await folders.createFolder(named: name, in: nil, idempotencyKey: nil)
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
        _ = try await folders.moveFolder("f-a", into: "f-b")
        _ = try await folders.moveFolder("f-a", into: nil)
        let seen = PersonalRoutesURLProtocol.requests
        XCTAssertEqual(seen.map(\.method), ["PATCH", "PATCH", "PATCH", "PATCH"])
        XCTAssertEqual(Set(seen.map(\.path)), ["/api/v1/me/room-folders/f-a"])
        XCTAssertEqual(seen[0].body, .object(["name": .string("Renamed")]), "a rename sends only the name")
        XCTAssertEqual(seen[1].body, .object(["position": .int(2)]), "a move up or down sends only the position")
        XCTAssertEqual(seen[2].body, .object(["parentFolderId": .string("f-b")]),
                       "a move into a folder sends only the parent: it goes after the folders there")
        XCTAssertEqual(seen[3].body, .object(["parentFolderId": .null]), "null: the top level")

        do {
            _ = try await folders.moveFolder("f-a", into: "f-a")
            XCTFail("sent a folder into itself")
        } catch {
            XCTAssertEqual(error as? RoomFolderError, .rejected)
        }

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
