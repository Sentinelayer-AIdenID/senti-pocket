import XCTest
@testable import PocketContracts

/// The room list's new keys for direct messages and folders (pinned contracts of 2026-11-04): `kind`, `counterpart`,
/// `originRoomId` and `folderId`. Where a row sits never fails the list: a malformed placement reads as a room, unfiled.
final class DirectAndFolderWireTests: XCTestCase {
    private func page(_ rows: String) throws -> SessionListPage {
        try JSONDecoder().decode(SessionListPage.self, from: Data("""
        {"sessions":[\(rows)],"count":\(rows.isEmpty ? 0 : rows.components(separatedBy: "\"sessionId\"").count - 1),
         "include_archived":false,"next_cursor":null,"has_more":false}
        """.utf8))
    }

    private func row(_ id: String, _ extra: String = "") -> String {
        """
        {"sessionId":"\(id)","status":"active","archiveStatus":"active","visibility":"private",
         "membershipRole":"owner","title":"Room \(id)","agentCount":1,"eventCount":3,"totalCostUsd":0\(extra)}
        """
    }

    func test_a_row_from_a_server_without_them_is_a_room_in_no_folder() throws {
        let session = try page(row("room-1")).sessions[0]
        XCTAssertNil(session.kind)
        XCTAssertNil(session.counterpart)
        XCTAssertNil(session.originRoomId)
        XCTAssertNil(session.folderId)
        XCTAssertFalse(session.isDirect)
    }

    func test_a_direct_row_names_whom_it_is_with_and_where_it_was_opened() throws {
        let session = try page(row("dm-1", """
        ,"kind":"direct","counterpart":{"senderId":"review-agent","kind":"agent","displayName":"Review Agent"},
         "originRoomId":"room-1","folderId":null
        """)).sessions[0]
        XCTAssertTrue(session.isDirect)
        XCTAssertEqual(session.counterpart, SessionCounterpart(senderId: "review-agent", kind: "agent", displayName: "Review Agent"))
        XCTAssertTrue(session.counterpart?.isAgent == true)
        XCTAssertEqual(session.originRoomId, "room-1")
    }

    func test_an_origin_that_is_gone_is_null() throws {
        let session = try page(row("dm-2", """
        ,"kind":"direct","counterpart":{"senderId":"human-sam","kind":"human","displayName":"Sam"},"originRoomId":null
        """)).sessions[0]
        XCTAssertTrue(session.isDirect)
        XCTAssertNil(session.originRoomId)
    }

    func test_a_malformed_placement_never_fails_the_list() throws {
        let list = try page([
            row("room-1", #","folderId":"f-1""#),
            row("room-2", #","folderId":42,"kind":7"#),
            row("dm-3", #","kind":"direct","counterpart":{"kind":"agent","displayName":"No id"},"originRoomId":"room-1""#),
            row("dm-4", #","kind":"direct","counterpart":"review-agent""#),
            row("room-5", #","kind":"room","counterpart":{"senderId":"x","kind":"agent","displayName":"x"},"folderId":"  ""#)
        ].joined(separator: ","))
        XCTAssertEqual(list.sessions.count, 5)
        XCTAssertEqual(list.sessions[0].folderId, "f-1")
        XCTAssertNil(list.sessions[1].folderId, "a folder id that is not a string reads as none")
        XCTAssertNil(list.sessions[1].kind)
        XCTAssertFalse(list.sessions[2].isDirect, "a counterpart without an id is no counterpart")
        XCTAssertFalse(list.sessions[3].isDirect)
        XCTAssertFalse(list.sessions[4].isDirect, "a room is a room whatever else it carries")
        XCTAssertNil(list.sessions[4].folderId, "a blank folder id is none")
    }

    func test_a_counterpart_reads_any_kind_but_agent_as_a_person_and_falls_back_to_its_id() throws {
        func counterpart(_ json: String) throws -> SessionCounterpart {
            try JSONDecoder().decode(SessionCounterpart.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try counterpart(#"{"senderId":"a1","kind":"AGENT","displayName":"A"}"#).isAgent)
        XCTAssertFalse(try counterpart(#"{"senderId":"h1","kind":"robot","displayName":"H"}"#).isAgent)
        XCTAssertEqual(try counterpart(#"{"senderId":"human-sam","kind":"human"}"#).displayName, "human-sam")
        XCTAssertEqual(try counterpart(#"{"senderId":"human-sam","kind":"human","displayName":"  "}"#).displayName, "human-sam")
        XCTAssertThrowsError(try counterpart(#"{"kind":"human","displayName":"Sam"}"#))
    }

    func test_a_folder_name_is_1_to_60_characters_with_no_control_characters() {
        XCTAssertEqual(RoomFolderName.cleaned("  Launch  "), "Launch")
        XCTAssertEqual(RoomFolderName.validate(""), .failure(.empty))
        XCTAssertEqual(RoomFolderName.validate(" \n "), .failure(.empty))
        XCTAssertEqual(RoomFolderName.validate(String(repeating: "x", count: 60)), .success(String(repeating: "x", count: 60)))
        XCTAssertEqual(RoomFolderName.validate(String(repeating: "x", count: 61)), .failure(.tooLong))
        XCTAssertEqual(RoomFolderName.validate("a\u{0007}b"), .failure(.controlCharacters))
        // Counted as the API counts, in code points: a flag is two.
        XCTAssertEqual(RoomFolderName.validate(String(repeating: "🇫🇷", count: 30)), .success(String(repeating: "🇫🇷", count: 30)))
        XCTAssertEqual(RoomFolderName.validate(String(repeating: "🇫🇷", count: 31)), .failure(.tooLong))
        XCTAssertEqual(RoomFolderName.maximumFolders, 100)
    }

    /// Only true control characters (Cc) are refused: the zero-width joiner that builds an emoji is part of a name.
    func test_a_name_with_a_joined_emoji_is_a_name() {
        XCTAssertEqual(RoomFolderName.cleaned("👩‍💻 Dev"), "👩‍💻 Dev")
        XCTAssertEqual(RoomFolderName.cleaned("a\u{200D}b"), "a\u{200D}b")
        XCTAssertEqual(RoomFolderName.validate("tab\there"), .failure(.controlCharacters))
        XCTAssertEqual(RoomFolderName.validate("del\u{007F}"), .failure(.controlCharacters))
        XCTAssertEqual(RoomFolderName.validate("c1\u{0085}x"), .failure(.controlCharacters))
    }
}
