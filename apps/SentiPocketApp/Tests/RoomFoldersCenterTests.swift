import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// Your folders as a fake of the API's contract (sentinelayer-api #1125): 404 for everything when the flag is off, 404
/// for a folder that is gone, and whatever refusal a test sets for the next call.
private final class FakeRoomFolders: RoomFoldersServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _on = true
    private var _folders: [RoomFolder] = []
    private var _calls: [String] = []
    private var _keys: [String?] = []
    private var _failNext: RoomFolderError?
    private var next = 1
    /// Holds the next list read or move until the test lets it go (a slow link).
    private var _holdNextList = false
    private var _holdNextMove = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var holdNextList: Bool { get { lock.withLock { _holdNextList } } set { lock.withLock { _holdNextList = newValue } } }
    var holdNextMove: Bool { get { lock.withLock { _holdNextMove } } set { lock.withLock { _holdNextMove = newValue } } }
    var holding: Int { lock.withLock { held.count } }

    func releaseHeld() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    private func pause(if flag: ReferenceWritableKeyPath<FakeRoomFolders, Bool>) async {
        let hold: Bool = lock.withLock {
            let value = self[keyPath: flag]
            return value
        }
        guard hold else { return }
        lock.withLock { self[keyPath: flag] = false }
        await withCheckedContinuation { continuation in lock.withLock { held.append(continuation) } }
    }

    func setFolders(_ folders: [RoomFolder]) { lock.withLock { _folders = folders } }

    var on: Bool { get { lock.withLock { _on } } set { lock.withLock { _on = newValue } } }
    var failNext: RoomFolderError? { get { lock.withLock { _failNext } } set { lock.withLock { _failNext = newValue } } }
    var calls: [String] { lock.withLock { _calls } }
    /// The Idempotency-Key of each create.
    var keys: [String?] { lock.withLock { _keys } }

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
        let seen = lock.withLock { _folders }  // what the server had when the read was made
        await pause(if: \._holdNextList)
        return seen
    }

    func createFolder(named name: String, in parentFolderId: String?, idempotencyKey: String?) async throws -> RoomFolder {
        lock.withLock { _keys.append(idempotencyKey) }
        try note("create \(name)" + (parentFolderId.map { " in \($0)" } ?? ""))
        return lock.withLock {
            let folder = RoomFolder(id: "f-new\(next)", name: name, parentFolderId: parentFolderId, position: _folders.count)
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
        await pause(if: \._holdNextMove)
        return RoomFolder(id: folderId, name: "moved", position: position)
    }

    func moveFolder(_ folderId: String, into parentFolderId: String?) async throws -> RoomFolder {
        try note("move \(folderId) into \(parentFolderId ?? "top")")
        return RoomFolder(id: folderId, name: "moved", parentFolderId: parentFolderId, position: 0)
    }

    func deleteFolder(_ folderId: String) async throws {
        try note("delete \(folderId)")
        lock.withLock { _folders.removeAll { $0.id == folderId } }
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
    private let three = [RoomFolder(id: "f-a", name: "Studio", position: 0, roomCount: 2),
                         RoomFolder(id: "f-b", name: "Ops", position: 1, roomCount: 1),
                         RoomFolder(id: "f-c", name: "Notes", position: 2)]
    /// Studio > Sketches > Ideas; Ops > Night shift; Notes.
    private let nested = [RoomFolder(id: "f-a", name: "Studio", position: 0, roomCount: 1, totalRoomCount: 3),
                          RoomFolder(id: "f-s", name: "Sketches", parentFolderId: "f-a", position: 0, roomCount: 1,
                                     totalRoomCount: 2),
                          RoomFolder(id: "f-i", name: "Ideas", parentFolderId: "f-s", position: 0, roomCount: 1),
                          RoomFolder(id: "f-b", name: "Ops", position: 1),
                          RoomFolder(id: "f-n", name: "Night shift", parentFolderId: "f-b", position: 0),
                          RoomFolder(id: "f-c", name: "Notes", position: 2)]
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

    func test_the_side_panels_folders_carry_their_parent_counts_and_time() async {
        let fake = FakeRoomFolders([RoomFolder(id: "f-s", name: "Sketches", parentFolderId: "f-a", position: 3,
                                               roomCount: 1, totalRoomCount: 4, createdAt: "2026-11-04T10:17:00+00:00")])
        let folders = center(fake)
        await folders.refresh()
        let item = folders.items?.first
        XCTAssertEqual(item?.parentId, "f-a")
        XCTAssertEqual(item?.position, 3)
        XCTAssertEqual(item?.totalRoomCount, 4)
        XCTAssertEqual(item?.createdAt, ParsedSessionTimestamp("2026-11-04T10:17:00+00:00").date)
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

    func test_new_folder_inside_makes_it_in_that_folder() async {
        let fake = FakeRoomFolders(nested)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.createInside(folderId: "f-n"))
        XCTAssertEqual(folders.sheet, .createInside(nested[4]))
        XCTAssertEqual(RoomFolderSheets.place(folders.sheet!), "Inside “Night shift”")
        await folders.save(name: "Rota")
        XCTAssertEqual(fake.calls, ["list", "create Rota in f-n", "list"])
        XCTAssertNil(folders.sheet)
        XCTAssertEqual(roomReads, 1)
    }

    func test_a_level_3_folder_offers_no_folder_inside() async {
        let folders = center(FakeRoomFolders(nested))
        await folders.refresh()
        folders.send(.createInside(folderId: "f-i"))
        XCTAssertNil(folders.sheet, "Ideas is at level 3")
    }

    /// A retry after a lost answer sends the same key, so the server answers with the folder it made; another name is
    /// another create, with another key.
    func test_a_retried_create_sends_the_same_key_and_another_name_a_new_one() async {
        let fake = FakeRoomFolders(three)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.createInside(folderId: "f-a"))
        fake.failNext = .retryable
        await folders.save(name: "Sketches")
        XCTAssertNotNil(folders.sheet, "not saved: the sheet stays")
        await folders.save(name: "Sketches")
        await folders.refresh()
        folders.send(.create(fileRoomId: nil))
        await folders.save(name: "Sketches")
        let keys = fake.keys
        XCTAssertEqual(keys.count, 3)
        XCTAssertNotNil(keys[0])
        XCTAssertEqual(keys[0], keys[1], "the same create tried again")
        XCTAssertNotEqual(keys[1], keys[2], "another place is another create")
    }

    /// Each refusal the API sends as a 409 reads as its own plain line, and the sheet stays open with it.
    func test_each_409_on_a_create_keeps_the_sheet_and_says_its_line() async {
        let cases: [(RoomFolderError, String)] = [
            (.duplicateName, "There's already a folder with that name here."),
            (.limitReached, "You've reached 100 folders."),
            (.tooDeep, "Folders go 3 levels deep at most.")
        ]
        for (error, line) in cases {
            let fake = FakeRoomFolders(nested)
            let folders = center(fake)
            await folders.refresh()
            folders.send(.createInside(folderId: "f-s"))
            fake.failNext = error
            await folders.save(name: "Late")
            XCTAssertEqual(folders.sheet, .createInside(nested[1]), "\(error)")
            XCTAssertEqual(folders.sheetProblem, line)
            XCTAssertEqual(fake.calls, ["list", "create Late in f-s", "list"], "the folders are read again")
            XCTAssertEqual(roomReads, 0)
        }
    }

    func test_the_409_lines() {
        XCTAssertEqual(RoomFoldersCenter.line(for: .tooDeep), "Folders go 3 levels deep at most.")
        XCTAssertEqual(RoomFoldersCenter.line(for: .cycle), "A folder can't go inside itself.")
        XCTAssertEqual(RoomFoldersCenter.line(for: .duplicateName), "There's already a folder with that name here.")
        XCTAssertEqual(RoomFoldersCenter.line(for: .limitReached), "You've reached 100 folders.")
        XCTAssertEqual(RoomFoldersCenter.line(for: .duplicateName, deleting: true),
                       "A folder inside has the same name as one at that level. Rename one of them first.")
        XCTAssertNil(RoomFoldersCenter.line(for: .retryable))
        XCTAssertNil(RoomFoldersCenter.line(for: .gone))
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

    // MARK: Move to…

    /// The picker for Sketches (it holds Ideas): the top level and the level-1 folders, Studio ticked; never itself,
    /// Ideas or Night shift.
    func test_move_to_offers_only_valid_places_and_moves_there() async {
        let fake = FakeRoomFolders(nested)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.pickParent(folderId: "f-s"))
        XCTAssertEqual(folders.sheet, .moveFolder(nested[1]))
        XCTAssertEqual(folders.destinations.map(\.id), ["top", "f-a", "f-b", "f-c"])
        XCTAssertEqual(folders.destinations.filter(\.isCurrent).map(\.id), ["f-a"])
        await folders.pick("f-b")
        XCTAssertEqual(fake.calls, ["list", "move f-s into f-b", "list"])
        XCTAssertNil(folders.sheet)
        XCTAssertEqual(roomReads, 1)
    }

    func test_moving_to_the_top_level_sends_no_parent_and_picking_where_it_is_sends_nothing() async {
        let fake = FakeRoomFolders(nested)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.pickParent(folderId: "f-n"))
        await folders.pick(nil)
        XCTAssertEqual(fake.calls, ["list", "move f-n into top", "list"])
        folders.send(.pickParent(folderId: "f-n"))
        await folders.pick("f-b")
        XCTAssertEqual(fake.calls.count, 3, "it is in Ops already")
        XCTAssertNil(folders.sheet)
    }

    /// The server is the judge: a move it refuses keeps the picker open with the reason, and the folders are read
    /// again (another device may have changed them).
    func test_each_409_on_a_move_keeps_the_picker_and_says_its_line() async {
        let cases: [(RoomFolderError, String)] = [
            (.tooDeep, "Folders go 3 levels deep at most."),
            (.cycle, "A folder can't go inside itself."),
            (.duplicateName, "There's already a folder with that name here.")
        ]
        for (error, line) in cases {
            let fake = FakeRoomFolders(nested)
            let folders = center(fake)
            await folders.refresh()
            folders.send(.pickParent(folderId: "f-i"))
            fake.failNext = error
            await folders.pick("f-n")
            XCTAssertEqual(folders.sheet, .moveFolder(nested[2]), "\(error)")
            XCTAssertEqual(folders.sheetProblem, line)
            XCTAssertEqual(fake.calls, ["list", "move f-i into f-n", "list"])
            XCTAssertNil(folders.notice)
        }
    }

    func test_folders_turned_off_while_the_picker_is_open_close_it() async {
        let fake = FakeRoomFolders(nested)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.pickParent(folderId: "f-s"))
        fake.on = false
        await folders.pick("f-c")
        XCTAssertNil(folders.sheet)
        XCTAssertNil(folders.items)
    }

    // MARK: Move to folder… (a room)

    func test_a_rooms_picker_lists_the_tree_ticks_its_folder_and_files_it() async {
        let fake = FakeRoomFolders(nested)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.pickFolder(roomId: "room-1", folderId: "f-n"))
        XCTAssertEqual(folders.destinations.map(\.id), ["f-a", "f-s", "f-i", "f-b", "f-n", "f-c"])
        XCTAssertEqual(folders.destinations.map(\.depth), [1, 2, 3, 1, 2, 1])
        XCTAssertEqual(folders.destinations.filter(\.isCurrent).map(\.id), ["f-n"])
        await folders.pick("f-n")
        XCTAssertEqual(fake.calls, ["list"], "where it is already: nothing sent")
        folders.send(.pickFolder(roomId: "room-1", folderId: "f-n"))
        await folders.pick("f-i")
        XCTAssertEqual(fake.calls, ["list", "file room-1 f-i", "list"])
        XCTAssertEqual(roomReads, 1)
    }

    func test_new_folder_from_a_rooms_picker_files_the_room_in_it() async {
        let fake = FakeRoomFolders(nested)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.pickFolder(roomId: "room-1", folderId: nil))
        folders.newFolderForPickedRoom()
        XCTAssertEqual(folders.sheet, .create(fileRoomId: "room-1"))
        await folders.save(name: "Garden")
        XCTAssertEqual(Array(fake.calls.suffix(3)), ["create Garden", "file room-1 f-new1", "list"])
    }

    // MARK: Move up and down, file and unfile

    func test_move_up_and_down_go_among_the_folders_beside_it_and_the_ends_do_not_move() async throws {
        let fake = FakeRoomFolders(nested)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.move(folderId: "f-a", up: true))
        folders.send(.move(folderId: "f-n", up: false))
        folders.send(.move(folderId: "f-s", up: true))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fake.calls, ["list"], "the first cannot go up, the last cannot go down, an only folder neither")
        folders.send(.move(folderId: "f-c", up: true))
        try await settle(fake, calls: 3)
        XCTAssertEqual(fake.calls, ["list", "move f-c 1", "list"], "Notes is third at the top level: up is place 1")
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

    // MARK: Delete

    func test_delete_waits_for_your_confirmation_and_says_what_moves_up() async {
        let fake = FakeRoomFolders(nested)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.delete(folderId: "f-a"))
        XCTAssertEqual(folders.deleting?.id, "f-a")
        XCTAssertEqual(fake.calls, ["list"], "nothing is deleted before you confirm")
        XCTAssertEqual(RoomFolderName.deleteMessage, "Its folders and rooms move up one level. No rooms are deleted.")
        await folders.confirmDelete()
        XCTAssertNil(folders.deleting)
        XCTAssertEqual(fake.calls, ["list", "delete f-a", "list"])
        XCTAssertEqual(roomReads, 1)
    }

    /// Review of #331: an older read of the folders that lands after a newer one never puts back what it saw.
    func test_an_older_folders_read_landing_late_never_replaces_a_newer_one() async {
        let fake = FakeRoomFolders(three)
        let folders = center(fake)
        fake.holdNextList = true
        let older = Task { await folders.refresh() }
        while fake.holding == 0 { await Task.yield() }
        fake.setFolders(Array(three.prefix(2)))  // a folder was deleted elsewhere
        await folders.refresh()                   // the newer read lands first
        XCTAssertEqual(folders.folders?.map(\.id), ["f-a", "f-b"])
        fake.releaseHeld()
        await older.value
        XCTAssertEqual(folders.folders?.map(\.id), ["f-a", "f-b"], "the late, older read is dropped")
    }

    /// Review of #331: two fast taps on Move up move the folder once, not twice from the old order.
    func test_two_fast_moves_move_the_folder_once() async {
        let fake = FakeRoomFolders(three)
        let folders = center(fake)
        await folders.refresh()
        fake.holdNextMove = true
        folders.send(.move(folderId: "f-c", up: true))
        while fake.holding == 0 { await Task.yield() }
        folders.send(.move(folderId: "f-c", up: true))  // a second tap while the first is on its way
        for _ in 0..<20 { await Task.yield() }
        fake.releaseHeld()
        for _ in 0..<200 where fake.calls.filter({ $0.hasPrefix("list") }).count < 2 { await Task.yield() }
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("move") }, ["move f-c 1"])
    }

    /// The alert's Delete, in the order SwiftUI runs it: the tap, then the alert closing (which clears `deleting`),
    /// then the task the tap started. The folder is still deleted (review of #331: a task that read `deleting` itself
    /// found it cleared and deleted nothing, with no error).
    func test_the_alerts_delete_still_deletes_after_the_alert_has_closed() async {
        let fake = FakeRoomFolders(nested)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.delete(folderId: "f-a"))
        let task = folders.deleteFromAlert()
        folders.deleting = nil  // the alert's binding, as it closes
        await task?.value
        XCTAssertEqual(fake.calls, ["list", "delete f-a", "list"])
        XCTAssertNil(folders.deleting)
    }

    /// The server refuses a delete that would put a folder inside it beside one of the same name: the folder stays,
    /// and the side panel says what to do.
    func test_a_delete_refused_for_a_promoted_childs_name_keeps_the_folder_and_says_so() async {
        let fake = FakeRoomFolders(nested)
        let folders = center(fake)
        await folders.refresh()
        folders.send(.delete(folderId: "f-s"))
        fake.failNext = .duplicateName
        await folders.confirmDelete()
        XCTAssertEqual(folders.notice,
                       "A folder inside has the same name as one at that level. Rename one of them first.")
        XCTAssertEqual(folders.items?.map(\.id).contains("f-s"), true, "the folder is kept")
        XCTAssertEqual(fake.calls, ["list", "delete f-s", "list"])
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
        folders.send(.pickParent(folderId: "f-zz"))
        folders.send(.createInside(folderId: "f-zz"))
        XCTAssertNil(folders.sheet)
        XCTAssertNil(folders.deleting)
    }
}
