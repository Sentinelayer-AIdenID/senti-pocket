import Foundation
import PocketContracts
import XCTest
@testable import PocketUI

/// Folders inside folders (Carter, 11-04): the tree built from the server's flat list, what a folded folder counts, where
/// a folder can move, and the folded folders kept by id. Folder and room names are made up.
final class RoomFolderTreeTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func folder(_ id: String, in parent: String? = nil, at position: Int = 0, made minutes: Double? = nil,
                        rooms: Int = 0, total: Int? = nil) -> RoomFolderItem {
        RoomFolderItem(id: id, name: "Folder \(id)", parentId: parent, position: position, roomCount: rooms,
                       totalRoomCount: total, createdAt: minutes.map { base.addingTimeInterval($0 * 60) })
    }

    private func room(_ id: String, in folder: String? = nil, unread: Int = 0) -> PocketSidePanel.Room {
        PocketSidePanel.Room(id: id, title: "Room \(id)", subtitle: nil, lastActivity: base,
                             activity: RoomListActivity(humansOnline: nil, agentsOnline: nil, unread: unread),
                             folderId: folder)
    }

    private func dm(_ id: String, from origin: String, unread: Int) -> PocketSidePanel.Room {
        PocketSidePanel.Room(id: id, title: "Person \(id)", subtitle: nil, lastActivity: base,
                             activity: RoomListActivity(humansOnline: nil, agentsOnline: nil, unread: unread),
                             direct: PocketSidePanel.Direct(name: "Person \(id)", isAgent: false, originRoomId: origin))
    }

    /// Studio > Sketches > Ideas; Ops > Night shift; Notes.
    private var three: [RoomFolderItem] {
        [folder("notes", at: 2), folder("ideas", in: "sketches"), folder("ops", at: 1), folder("night", in: "ops"),
         folder("sketches", in: "studio"), folder("studio", at: 0)]
    }

    private func shape(_ tree: RoomFolderTree) -> [String] {
        tree.nodes.map { "\($0.depth):\($0.id)" }
    }

    // MARK: building the tree

    func test_each_folder_follows_its_parent_in_your_order_at_its_level() {
        let tree = RoomFolderTree.build(three)
        XCTAssertEqual(shape(tree), ["1:studio", "2:sketches", "3:ideas", "1:ops", "2:night", "1:notes"])
        XCTAssertEqual(tree.node("studio")?.childIds, ["sketches"])
        XCTAssertEqual(tree.node("studio")?.height, 3)
        XCTAssertEqual(tree.node("ops")?.height, 2)
        XCTAssertEqual(tree.node("notes")?.height, 1)
        XCTAssertEqual(tree.descendants(of: "studio"), ["sketches", "ideas"])
        XCTAssertEqual(tree.descendants(of: "ops"), ["night"])
        XCTAssertEqual(tree.descendants(of: "notes"), [])
    }

    /// Side by side: by position, then the older first, then by id; a folder without a time after those with one.
    func test_folders_side_by_side_go_by_position_then_when_made_then_id() {
        let tree = RoomFolderTree.build([
            folder("c", at: 1, made: 1), folder("b", at: 0, made: 5), folder("a", at: 0, made: 9),
            folder("e", at: 0), folder("d", at: 0), folder("f", at: 1, made: 0)
        ])
        XCTAssertEqual(tree.nodes.map(\.id), ["b", "a", "d", "e", "f", "c"])
        XCTAssertEqual(tree.nodes.map(\.siblingIndex), [0, 1, 2, 3, 4, 5], "all six at the top level, in that order")
        XCTAssertEqual(tree.node("a")?.siblingCount, 6)
    }

    func test_a_folder_whose_parent_is_not_listed_is_at_the_top_level() {
        let tree = RoomFolderTree.build([folder("a", at: 1), folder("orphan", in: "gone", at: 0), folder("self", in: "self", at: 2)])
        XCTAssertEqual(shape(tree), ["1:orphan", "1:a", "1:self"])
        XCTAssertNil(tree.node("orphan")?.parentId)
        XCTAssertNil(tree.node("self")?.parentId, "a folder in itself: the top level")
    }

    /// A in B and B in A: the first of them in your order goes to the top level, the other stays inside it. Nothing is
    /// lost and nothing loops.
    func test_a_loop_in_the_data_is_broken_at_its_first_folder_which_goes_to_the_top() {
        let tree = RoomFolderTree.build([folder("b", in: "a", at: 1), folder("a", in: "c", at: 0),
                                         folder("c", in: "b", at: 2), folder("x", in: "c", at: 0)])
        XCTAssertEqual(shape(tree), ["1:a", "2:b", "3:c", "3:x"], "a goes to the top; b, c and x stay, x beside c")
        XCTAssertEqual(Set(tree.nodes.map(\.id)), ["a", "b", "c", "x"])
        let two = RoomFolderTree.build([folder("q", in: "p", at: 0), folder("p", in: "q", at: 0, made: 1)])
        XCTAssertEqual(shape(two), ["1:p", "2:q"], "position tie: the older one goes to the top")
    }

    /// The server allows 3 levels. Deeper data is flattened: each extra level sits beside the level-3 folder it was
    /// under, in order, and its rooms still show.
    func test_levels_past_3_in_the_data_sit_at_level_3_and_nothing_is_lost() {
        let chain = [folder("l1"), folder("l2", in: "l1"), folder("l3", in: "l2"), folder("l4", in: "l3"),
                     folder("l5", in: "l4"), folder("l4b", in: "l3", at: 1), folder("other", at: 1)]
        let tree = RoomFolderTree.build(chain)
        XCTAssertEqual(shape(tree), ["1:l1", "2:l2", "3:l3", "3:l4", "3:l5", "3:l4b", "1:other"])
        XCTAssertEqual(tree.nodes.map(\.depth).max(), 3)
        XCTAssertEqual(tree.node("l5")?.parentId, "l2")
        XCTAssertEqual(tree.node("l2")?.childIds, ["l3", "l4", "l5", "l4b"])
        let layout = SidePanelLayout.make([room("deep", in: "l5")], folders: chain)
        XCTAssertEqual(layout.folders.first { $0.id == "l5" }?.entries.map(\.id), ["deep"])
        XCTAssertTrue(layout.rooms.isEmpty)
    }

    func test_one_folder_per_id_and_none_for_an_empty_list() {
        let tree = RoomFolderTree.build([folder("a", at: 0), folder("a", in: "b", at: 5), folder("b", at: 1)])
        XCTAssertEqual(shape(tree), ["1:a", "1:b"], "the first listing wins")
        XCTAssertTrue(RoomFolderTree.build([]).isEmpty)
        XCTAssertTrue(SidePanelLayout.make([room("r1")], folders: []).folders.isEmpty)
    }

    /// An empty folder says so when open. One with only folders inside does not: those are what is in it.
    func test_an_empty_folder_says_so_and_one_with_folders_inside_does_not() {
        let layout = SidePanelLayout.make([room("r-idea", in: "ideas")], folders: three)
        let rows = layout.rows(folded: FoldedFolders())
        XCTAssertEqual(rows.map(\.id), [
            "folder:studio", "folder:sketches", "folder:ideas", "room:r-idea",
            "folder:ops", "folder:night", "empty:night", "folder:notes", "empty:notes"
        ])
    }

    // MARK: the side panel's lines and counts

    func test_rooms_and_their_direct_messages_sit_under_their_folder_at_its_level_then_your_rooms() {
        let layout = SidePanelLayout.make([
            room("r-studio", in: "studio"), dm("d1", from: "r-studio", unread: 0), room("r-night", in: "night"),
            room("r-free"), room("r-lost", in: "gone")
        ], folders: three)
        let rows = layout.rows(folded: FoldedFolders())
        XCTAssertEqual(rows.map(\.id), [
            "folder:studio", "room:r-studio", "direct:d1", "folder:sketches", "folder:ideas", "empty:ideas",
            "folder:ops", "folder:night", "room:r-night", "folder:notes", "empty:notes",
            "label:unfiled", "room:r-free", "room:r-lost"
        ])
        XCTAssertTrue(rows.contains(.room(room("r-night", in: "night"), depth: 2)))
        XCTAssertTrue(rows.contains(.direct(dm("d1", from: "r-studio", unread: 0), depth: 1)))
        XCTAssertTrue(rows.contains(.room(room("r-free"), depth: 0)))
        XCTAssertTrue(rows.contains(.label(id: "unfiled", title: "Your rooms")))
    }

    /// Folded, a folder hides its rooms and every folder inside it, and shows the server's total for all of them and
    /// the unread of its whole subtree, direct messages included.
    func test_a_folded_folder_shows_its_total_and_the_unread_of_everything_inside_it() {
        var folders = three
        folders[folders.firstIndex { $0.id == "studio" }!] = folder("studio", at: 0, rooms: 1, total: 4)
        let layout = SidePanelLayout.make([
            room("r-studio", in: "studio", unread: 1), dm("d1", from: "r-studio", unread: 2),
            room("r-sketch", in: "sketches", unread: 4), room("r-idea", in: "ideas", unread: 8),
            dm("d2", from: "r-idea", unread: 16), room("r-night", in: "night", unread: 32), room("r-free", unread: 64)
        ], folders: folders)
        XCTAssertEqual(layout.folders.map(\.unread), [31, 28, 24, 32, 32, 0],
                       "studio, sketches, ideas, ops, night, notes: each its own and everything inside it")

        let rows = layout.rows(folded: FoldedFolders(["studio"]))
        XCTAssertEqual(rows.prefix(2).map(\.id), ["folder:studio", "folder:ops"], "nothing of studio's shows")
        guard case .folder(let line) = rows[0] else { return XCTFail("no folder line") }
        XCTAssertTrue(line.folded)
        XCTAssertEqual(line.unread, 31)
        XCTAssertEqual(line.folder.totalRoomCount, 4, "the server's count of every room inside it")

        let inner = layout.rows(folded: FoldedFolders(["sketches"]))
        XCTAssertEqual(inner.prefix(5).map(\.id), ["folder:studio", "room:r-studio", "direct:d1", "folder:sketches",
                                                   "folder:ops"], "a folded level-2 folder hides only what is in it")
    }

    func test_a_folder_line_knows_its_place_among_those_beside_it_and_whether_a_folder_can_go_in() {
        let rows = SidePanelLayout.make([], folders: three).rows(folded: FoldedFolders())
        let lines = rows.compactMap { row -> SidePanelLayout.FolderLine? in
            if case .folder(let line) = row { return line } else { return nil }
        }
        XCTAssertEqual(lines.map(\.id), ["studio", "sketches", "ideas", "ops", "night", "notes"])
        XCTAssertEqual(lines.map(\.isFirst), [true, true, true, false, true, false])
        XCTAssertEqual(lines.map(\.isLast), [false, true, true, false, true, true])
        XCTAssertEqual(lines.map(\.canHoldFolder), [true, true, false, true, true, true], "level 3 holds no folder")
    }

    func test_with_folders_off_there_are_no_folder_lines_and_no_your_rooms_label() {
        let rows = SidePanelLayout.make([room("r1", in: "studio"), room("r2")], folders: nil).rows(folded: FoldedFolders())
        XCTAssertEqual(rows.map(\.id), ["room:r1", "room:r2"])
    }

    func test_voiceover_reads_a_folder_with_its_level_rooms_unread_and_state() {
        XCTAssertEqual(PocketSidePanel.folderAccessibilityLabel(name: "Studio", depth: 2, rooms: 3, unread: 1, folded: true),
                       "Studio, folder, level 2, 3 rooms, 1 unread, collapsed")
        XCTAssertEqual(PocketSidePanel.folderAccessibilityLabel(name: "Notes", depth: 1, rooms: 1, unread: 0, folded: false),
                       "Notes, folder, level 1, 1 room, 0 unread, expanded")
    }

    // MARK: where a folder can move

    /// Moving Sketches (it holds Ideas, so it is 2 levels tall): the top level, and the level-1 folders other than the
    /// one it is in, which is ticked. Not itself, not Ideas inside it, and not Night shift (level 2 + 2 levels = 4).
    func test_move_to_offers_only_places_that_keep_3_levels_and_never_itself_or_inside_it() {
        let tree = RoomFolderTree.build(three)
        let sketches = tree.destinations(movingFolder: "sketches")
        XCTAssertEqual(sketches.map(\.id), ["top", "studio", "ops", "notes"])
        XCTAssertEqual(sketches.filter(\.isCurrent).map(\.id), ["studio"])

        let studio = tree.destinations(movingFolder: "studio")
        XCTAssertEqual(studio.map(\.id), ["top"], "3 levels tall: only the top level, where it is")
        XCTAssertEqual(studio.first?.isCurrent, true)

        let ideas = tree.destinations(movingFolder: "ideas")
        XCTAssertEqual(ideas.map(\.id), ["top", "studio", "sketches", "ops", "night", "notes"],
                       "a single folder can go into any folder above level 3")
        XCTAssertEqual(ideas.filter(\.isCurrent).map(\.id), ["sketches"])

        let night = tree.destinations(movingFolder: "night")
        XCTAssertFalse(night.contains { $0.id == "ideas" }, "level 3 holds no folder")
        XCTAssertFalse(night.contains { $0.id == "night" })
        XCTAssertTrue(tree.destinations(movingFolder: "unknown").isEmpty)
    }

    func test_a_room_can_move_to_any_folder_and_the_one_it_is_in_is_ticked() {
        let tree = RoomFolderTree.build(three)
        let places = tree.destinations(movingRoomIn: "night")
        XCTAssertEqual(places.map(\.id), ["studio", "sketches", "ideas", "ops", "night", "notes"])
        XCTAssertEqual(places.filter(\.isCurrent).map(\.id), ["night"])
        XCTAssertEqual(places.map(\.depth), [1, 2, 3, 1, 2, 1])
    }

    func test_siblings_are_the_folders_beside_it_in_order() {
        let tree = RoomFolderTree.build(three)
        XCTAssertEqual(tree.siblings(of: "ops").map(\.id), ["studio", "ops", "notes"])
        XCTAssertEqual(tree.siblings(of: "night").map(\.id), ["night"])
        XCTAssertTrue(tree.canHoldFolder("sketches"))
        XCTAssertFalse(tree.canHoldFolder("ideas"))
        XCTAssertFalse(tree.canHoldFolder("unknown"))
    }

    // MARK: folded folders, kept

    @MainActor
    func test_folded_folders_are_kept_by_id_across_launches() async {
        let suite = "pocket.tests.folded.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("no defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        // As the panel kept them before folders nested: one id per line.
        defaults.set("notes", forKey: FoldedFolders.storageKey)

        let first = SidePanelPlacement(defaults: defaults)
        XCTAssertEqual(first.folded.ids, ["notes"])
        first.update(rooms: [room("r1", in: "night")], folders: three)
        await first.settle()
        first.toggleFolded("ops")
        first.toggleFolded("notes")
        XCTAssertEqual(defaults.string(forKey: FoldedFolders.storageKey), "ops")
        XCTAssertFalse(first.shown.rows.contains { $0.id == "folder:night" }, "folded: what is inside it hides")

        let relaunched = SidePanelPlacement(defaults: defaults)
        relaunched.update(rooms: [room("r1", in: "night")], folders: three)
        await relaunched.settle()
        XCTAssertTrue(relaunched.folded.contains("ops"))
        XCTAssertFalse(relaunched.folded.contains("notes"))
        XCTAssertFalse(relaunched.shown.rows.contains { $0.id == "room:r1" })
        XCTAssertTrue(relaunched.shown.rows.contains { $0.id == "empty:notes" }, "notes is open again")
    }

    // MARK: placing off the main thread, writing only for a change

    /// The side panel's rule (#325): a read that finds what is shown places nothing and writes nothing.
    @MainActor
    func test_a_read_that_finds_nothing_new_places_nothing_and_writes_nothing() async {
        let placement = SidePanelPlacement(defaults: nil)
        let rooms = [room("r1", in: "studio", unread: 2), room("r2")]
        placement.update(rooms: rooms, folders: three)
        await placement.settle()
        XCTAssertEqual(placement.builds, 1)
        var writes = 0
        let watch = placement.objectWillChange.sink { writes += 1 }
        defer { watch.cancel() }
        placement.update(rooms: rooms, folders: three)
        await placement.settle()
        placement.update(rows: [], folders: three)
        await placement.settle()
        XCTAssertEqual(writes, 1, "the same rooms: nothing; no rooms: one write")
        XCTAssertEqual(placement.builds, 2)
        XCTAssertTrue(placement.shown.rows.allSatisfy { if case .room = $0 { return false } else { return true } })
    }

    /// A newer read replaces one still being placed: the last one asked is the one shown.
    @MainActor
    func test_the_last_read_is_the_one_shown() async {
        let placement = SidePanelPlacement(defaults: nil)
        for index in 0..<20 {
            placement.update(rooms: [room("r\(index)")], folders: three)
        }
        await placement.settle()
        XCTAssertEqual(placement.shown.rooms.map(\.id), ["r19"])
        XCTAssertTrue(placement.shown.rows.contains { $0.id == "room:r19" })
    }
}
