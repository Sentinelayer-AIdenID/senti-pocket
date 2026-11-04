import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// Your folders as a fake of the pinned contract (2026-11-04): 404 for everything when the flag is off, 404 for a folder
/// that is gone, 409 for a name already used.
private final class FakeRoomFolders: RoomFoldersServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _on = true
    private var _folders: [RoomFolder] = []
    private var _calls: [String] = []
    private var _failNext: RoomFolderError?
    private var next = 1

    var on: Bool { get { lock.withLock { _on } } set { lock.withLock { _on = newValue } } }
    var failNext: RoomFolderError? { get { lock.withLock { _failNext } } set { lock.withLock { _failNext = newValue } } }
    var calls: [String] { lock.withLock { _calls } }

    init(_ folders: [RoomFolder] = []) { _folders = folders }

    private func note(_ call: String) throws {
        try lock.withLock {
            _calls.append(call)
            guard _on else { throw RoomFolderError.unavailable }
            if let failure = _failNext {
                _failNext = nil
                throw failure
            }
        }
    }

    func folders() async throws -> [RoomFolder] {
        try note("list")
        return lock.withLock { _folders }
    }

    func createFolder(named name: String) async throws -> RoomFolder {
        try note("create \(name)")
        return lock.withLock {
            let folder = RoomFolder(id: "f-new\(next)", name: name, position: _folders.count)
            next += 1
            _folders.append(folder)
            return folder
        }
    }

    func renameFolder(_ folderId: String, to name: String) async throws -> RoomFolder {
        try note("rename \(folderId) \(name)")
        return RoomFolder(id: folderId, name: name, position: 0)
    }

    func moveFolder(_ folderId: String, to position: Int) async throws -> RoomFolder {
        try note("move \(folderId) \(position)")
        return RoomFolder(id: folderId, name: "moved", position: position)
    }

    func deleteFolder(_ folderId: String) async throws {
        try note("delete \(folderId)")
    }

    func file(room sessionId: String, in folderId: String) async throws {
        try note("file \(sessionId) \(folderId)")
    }

    func unfile(room sessionId: String, from folderId: String) async throws {
        try note("unfile \(sessionId) \(folderId)")
    }
}

@MainActor
final class RoomFoldersCenterTests: XCTestCase {
    private let three = [RoomFolder(id: "f-a", name: "Launch", position: 0, roomCount: 2),
                         RoomFolder(id: "f-b", name: "Clients", position: 1, roomCount: 1),
                         RoomFolder(id: "f-c", name: "Later", position: 2)]
    private var roomReads = 0

    private func center(_ fake: FakeRoomFolders) -> RoomFoldersCenter {
        RoomFoldersCenter(client: fake, onRoomsChanged: { [weak self] in self?.roomReads += 1 })
    }

    /// Waits for work the center started on its own (a menu's change).
    private func settle(_ fake: FakeRoomFolders, calls: Int) async throws {
        for _ in 0..<100 where fake.calls.count < calls || roomReads == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    func test_folders_stay_hidden_until_listed_and_a_404_hides_them() async {
        let fake = FakeRoomFolders(three)
        let folders = center(fake)
        XCTAssertNil(folders.items, "nothing shows before the server has listed them")
        await folders.refresh()
        XCTAssertEqual(folders.items?.map(\.id), ["f-a", "f-b", "f-c"])
        fake.on = false
        await folders.refresh()
        XCTAssertNil(folders.items, "the flag off: the routes 404 and every folder affordance hides")
    }

    func test_a_new_folder_from_a_rooms_menu_is_made_then_the_room_filed_then_both_lists_read_again() async {
        let fake = FakeRoomFolders(three)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.create(fileRoomId: "room-1"))
        XCTAssertEqual(folders.sheet, .create(fileRoomId: "room-1"))
        await folders.save(name: "  Pilots ")
        XCTAssertEqual(fake.calls, ["list", "create Pilots", "file room-1 f-new1", "list"])
        XCTAssertNil(folders.sheet)
        XCTAssertEqual(roomReads, 1, "where the room is filed is the room list's: it is read again")
        XCTAssertEqual(folders.items?.count, 4)
    }

    func test_a_taken_name_keeps_the_sheet_open_and_says_so() async {
        let fake = FakeRoomFolders(three)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.create(fileRoomId: nil))
        fake.failNext = .duplicateName
        await folders.save(name: "Launch")
        XCTAssertEqual(folders.sheet, .create(fileRoomId: nil))
        XCTAssertEqual(folders.sheetProblem, "You already have a folder named “Launch”.")
        XCTAssertEqual(roomReads, 0)
    }

    /// The server counted 100 folders where the phone counted fewer (another device made some): the sheet says it is
    /// the cap, not a taken name, and the folders are read again so the phone counts what the server has.
    func test_the_servers_cap_says_so_and_reads_the_folders_again() async {
        let fake = FakeRoomFolders(three)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.create(fileRoomId: nil))
        fake.failNext = .limitReached
        await folders.save(name: "One more")
        XCTAssertEqual(folders.sheetProblem, RoomFolderName.limitMessage)
        XCTAssertEqual(fake.calls, ["list", "create One more", "list"], "the folders are read again")
        XCTAssertEqual(folders.sheet, .create(fileRoomId: nil), "the sheet stays, with the reason")
    }

    func test_a_name_the_api_would_refuse_is_never_sent() async {
        let fake = FakeRoomFolders(three)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.create(fileRoomId: nil))
        await folders.save(name: String(repeating: "x", count: 61))
        XCTAssertEqual(fake.calls, ["list"])
        XCTAssertNotNil(folders.sheetProblem)
    }

    func test_a_folder_that_is_gone_says_so_and_everything_is_read_again() async {
        let fake = FakeRoomFolders(three)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.rename(folderId: "f-b"))
        XCTAssertEqual(folders.sheet, .rename(three[1]))
        fake.failNext = .gone
        await folders.save(name: "Customers")
        XCTAssertNil(folders.sheet)
        XCTAssertEqual(folders.notice, RoomFoldersCenter.gone)
        XCTAssertEqual(fake.calls.last, "list")
        XCTAssertEqual(roomReads, 1)
    }

    func test_move_up_and_down_send_the_new_place_and_the_ends_do_not_move() async throws {
        let fake = FakeRoomFolders(three)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.move(folderId: "f-a", up: true))
        folders.send(.move(folderId: "f-c", up: false))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fake.calls, ["list"], "the first cannot go up, the last cannot go down")
        folders.send(.move(folderId: "f-c", up: true))
        try await settle(fake, calls: 3)
        XCTAssertEqual(fake.calls, ["list", "move f-c 1", "list"])
        XCTAssertEqual(roomReads, 1)
    }

    func test_filing_and_unfiling_read_the_room_list_again_and_keep_no_copy() async throws {
        let fake = FakeRoomFolders(three)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.file(roomId: "room-1", folderId: "f-b"))
        try await settle(fake, calls: 3)
        XCTAssertEqual(fake.calls, ["list", "file room-1 f-b", "list"])
        XCTAssertEqual(roomReads, 1)
        folders.send(.unfile(roomId: "room-1", folderId: "f-b"))
        for _ in 0..<100 where roomReads < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(Array(fake.calls.suffix(2)), ["unfile room-1 f-b", "list"])
        XCTAssertEqual(roomReads, 2)
    }

    func test_delete_waits_for_your_confirmation_and_says_where_the_rooms_go() async {
        let fake = FakeRoomFolders(three)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.delete(folderId: "f-a"))
        XCTAssertEqual(folders.deleting?.id, "f-a")
        XCTAssertEqual(fake.calls, ["list"], "nothing is deleted before you confirm")
        XCTAssertEqual(RoomFolderSheets.deleteMessage(roomCount: 2),
                       "Its 2 rooms move back to Rooms. The rooms themselves are not deleted.")
        await folders.confirmDelete()
        XCTAssertNil(folders.deleting)
        XCTAssertEqual(fake.calls, ["list", "delete f-a", "list"])
        XCTAssertEqual(roomReads, 1)
    }

    func test_folders_turned_off_mid_change_hide_everything() async {
        let fake = FakeRoomFolders(three)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.rename(folderId: "f-a"))
        fake.on = false
        await folders.save(name: "Renamed")
        XCTAssertNil(folders.sheet)
        XCTAssertNil(folders.items)
    }

    func test_an_unknown_folder_opens_nothing() async {
        let folders = center(FakeRoomFolders(three))
        await folders.refresh()
        folders.send(.rename(folderId: "f-zz"))
        folders.send(.delete(folderId: "f-zz"))
        XCTAssertNil(folders.sheet)
        XCTAssertNil(folders.deleting)
    }
}
