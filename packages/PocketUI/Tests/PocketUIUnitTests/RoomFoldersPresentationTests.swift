import Foundation
import PocketContracts
import XCTest
@testable import PocketUI

/// The side panel's placing of rooms: your folders (Carter, 10-25), and each direct message under the room it was opened
/// from. Rooms and people are made up.
final class RoomFoldersPresentationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func room(_ id: String, folder: String? = nil, unread: Int = 0, minutesAgo: Double = 0) -> PocketSidePanel.Room {
        PocketSidePanel.Room(id: id, title: "Room \(id)", subtitle: nil, lastActivity: base.addingTimeInterval(-minutesAgo * 60),
                             activity: RoomListActivity(humansOnline: nil, agentsOnline: nil, unread: unread), folderId: folder)
    }

    private func dm(_ id: String, from origin: String?, minutesAgo: Double?, unread: Int = 0) -> PocketSidePanel.Room {
        PocketSidePanel.Room(id: id, title: "Person \(id)", subtitle: nil,
                             lastActivity: minutesAgo.map { base.addingTimeInterval(-$0 * 60) },
                             activity: RoomListActivity(humansOnline: nil, agentsOnline: nil, unread: unread),
                             direct: PocketSidePanel.Direct(name: "Person \(id)", isAgent: false, originRoomId: origin),
                             folderId: "f-a")
    }

    private let folders = [
        RoomFolderItem(id: "f-b", name: "Clients", position: 1),
        RoomFolderItem(id: "f-a", name: "Launch", position: 0)
    ]

    func test_folders_in_your_order_with_their_rooms_then_the_rest_under_rooms() {
        let layout = SidePanelLayout.make([
            room("r1", folder: "f-b"), room("r2"), room("r3", folder: "f-a"), room("r4", folder: "f-gone"), room("r5", folder: "f-a")
        ], folders: folders)
        XCTAssertEqual(layout.folders.map(\.folder.name), ["Launch", "Clients"])
        XCTAssertEqual(layout.folders[0].entries.map(\.id), ["r3", "r5"], "in the room list's order")
        XCTAssertEqual(layout.folders[1].entries.map(\.id), ["r1"])
        XCTAssertEqual(layout.rooms.map(\.id), ["r2", "r4"], "a folder not in your list files nothing")
        XCTAssertTrue(layout.messages.isEmpty)
    }

    func test_a_direct_message_sits_under_its_room_newest_first_wherever_that_room_is() {
        let layout = SidePanelLayout.make([
            room("r1", folder: "f-a"),
            dm("d-old", from: "r1", minutesAgo: 90),
            room("r2"),
            dm("d-new", from: "r1", minutesAgo: 5),
            dm("d-never", from: "r1", minutesAgo: nil),
            dm("d-r2", from: "r2", minutesAgo: 30)
        ], folders: folders)
        XCTAssertEqual(layout.folders[0].entries.map(\.id), ["r1"])
        XCTAssertEqual(layout.folders[0].entries[0].directs.map(\.id), ["d-new", "d-old", "d-never"])
        XCTAssertEqual(layout.rooms.map(\.id), ["r2"])
        XCTAssertEqual(layout.rooms[0].directs.map(\.id), ["d-r2"])
        XCTAssertTrue(layout.messages.isEmpty, "every direct message found its room")
    }

    func test_a_direct_message_whose_room_is_gone_or_not_listed_goes_under_messages() {
        let layout = SidePanelLayout.make([
            room("r1"),
            dm("d-null", from: nil, minutesAgo: 50),
            dm("d-elsewhere", from: "r-not-listed", minutesAgo: 10),
            dm("d-from-dm", from: "d-null", minutesAgo: 20)
        ], folders: nil)
        XCTAssertEqual(layout.rooms.map(\.id), ["r1"])
        XCTAssertTrue(layout.rooms[0].directs.isEmpty)
        XCTAssertEqual(layout.messages.map(\.id), ["d-elsewhere", "d-from-dm", "d-null"], "newest first")
    }

    func test_with_folders_off_every_room_is_under_rooms_and_messages_still_nest() {
        let layout = SidePanelLayout.make([room("r1", folder: "f-a"), dm("d1", from: "r1", minutesAgo: 1)], folders: nil)
        XCTAssertTrue(layout.folders.isEmpty)
        XCTAssertEqual(layout.rooms.map(\.id), ["r1"])
        XCTAssertEqual(layout.rooms[0].directs.map(\.id), ["d1"])
    }

    func test_a_direct_message_is_never_filed_in_a_folder() {
        XCTAssertNil(dm("d1", from: nil, minutesAgo: 1).folderId)
        let layout = SidePanelLayout.make([dm("d1", from: nil, minutesAgo: 1)], folders: folders)
        XCTAssertTrue(layout.folders.allSatisfy(\.entries.isEmpty))
        XCTAssertEqual(layout.messages.map(\.id), ["d1"])
    }

    func test_a_folded_folder_counts_its_rooms_and_their_messages_unread() {
        let layout = SidePanelLayout.make([
            room("r1", folder: "f-a", unread: 3), dm("d1", from: "r1", minutesAgo: 1, unread: 2), room("r2", folder: "f-a")
        ], folders: folders)
        XCTAssertEqual(layout.folders[0].unread, 5)
        XCTAssertEqual(layout.folders[1].unread, 0)
    }

    func test_ties_in_position_keep_one_order() {
        let tied = [RoomFolderItem(id: "z", name: "Beta", position: 0), RoomFolderItem(id: "y", name: "alpha", position: 0),
                    RoomFolderItem(id: "x", name: "Alpha", position: 0)]
        XCTAssertEqual(RoomFolderItem.ordered(tied).map(\.id), ["x", "y", "z"])
    }

    func test_search_finds_a_direct_message_by_whom_it_is_with() {
        let rooms = [room("r1"), dm("d1", from: "r1", minutesAgo: 1)]
        XCTAssertEqual(PocketSidePanel.filter(rooms, by: "person d1").map(\.id), ["d1"])
        XCTAssertEqual(PocketSidePanel.directAccessibilityLabel(name: "Sam", isAgent: false, isCurrent: false, unread: 2),
                       "Direct message with Sam, 2 unread")
        XCTAssertEqual(PocketSidePanel.directAccessibilityLabel(name: "review-agent", isAgent: true, isCurrent: true, unread: 0),
                       "Direct message with review-agent, an agent, open now")
    }

    func test_the_name_sheet_checks_the_name_and_the_cap_before_sending() {
        XCTAssertEqual(RoomFolderSheetCheck.check("  Launch ", isNew: true, folderCount: 3), .ok("Launch"))
        XCTAssertEqual(RoomFolderSheetCheck.check("", isNew: true, folderCount: 3), .problem("Give the folder a name."))
        XCTAssertEqual(RoomFolderSheetCheck.check(String(repeating: "a", count: 61), isNew: false, folderCount: 3),
                       .problem("A folder name is at most 60 characters."))
        XCTAssertEqual(RoomFolderSheetCheck.check("Launch", isNew: true, folderCount: 100),
                       .problem(RoomFolderName.limitMessage), "a 101st folder is not offered")
        XCTAssertEqual(RoomFolderSheetCheck.check("Launch", isNew: false, folderCount: 100), .ok("Launch"),
                       "renaming at the cap is fine")
    }
}

/// The side panel's rows are one loop, one view each, so its lazy list builds only the rows it shows; a lazy list's
/// ids must be unique.
extension RoomFoldersPresentationTests {
    func test_every_row_has_its_own_id_even_when_the_server_repeats_a_folder() {
        let twice = folders + [RoomFolderItem(id: "f-a", name: "Launch", position: 0)]
        let rooms = [room("r1", folder: "f-a"), dm("d1", from: "r1", minutesAgo: 5), room("r2"),
                     dm("d2", from: nil, minutesAgo: 9)]
        let ids = SidePanelLayout.make(rooms, folders: twice).rows(folded: FoldedFolders()).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "every row has its own id")
        XCTAssertEqual(ids.filter { $0 == "folder:f-a" }.count, 1, "the repeated folder shows once")
    }
}
