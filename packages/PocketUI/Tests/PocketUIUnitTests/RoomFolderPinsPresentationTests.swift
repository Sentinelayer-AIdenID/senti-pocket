import XCTest
@testable import PocketUI

final class RoomFolderPinsPresentationTests: XCTestCase {
    private func folder(_ id: String, position: Int = 0, pin: Int? = nil, supported: Bool = true) -> RoomFolderItem {
        RoomFolderItem(id: id, name: id, position: position, pinnedPosition: pin, supportsPinning: supported)
    }

    func test_pin_ui_requires_supported_fields_on_the_whole_list_including_unpinned_nulls() {
        XCTAssertFalse(RoomFolderPinsPresentation.isAvailable([]))
        XCTAssertFalse(RoomFolderPinsPresentation.isAvailable([folder("old", supported: false)]))
        XCTAssertFalse(RoomFolderPinsPresentation.isAvailable([folder("old", supported: false), folder("new", pin: 0)]))
        XCTAssertTrue(RoomFolderPinsPresentation.isAvailable([folder("new")]))
        XCTAssertTrue(RoomFolderPinsPresentation.ordered([folder("new")]).isEmpty)
    }

    func test_pins_are_ordered_separately_from_sibling_positions_and_do_not_change_the_room_tree() {
        let folders = [folder("Work", position: 0, pin: 1), folder("Ideas", position: 1, pin: 0), folder("Notes", position: 2)]
        XCTAssertEqual(RoomFolderPinsPresentation.ordered(folders).map(\.id), ["Ideas", "Work"])
        XCTAssertEqual(RoomFolderTree.build(folders).nodes.map(\.id), ["Work", "Ideas", "Notes"])
    }

    func test_drag_and_accessibility_moves_preserve_the_complete_pin_set() {
        XCTAssertEqual(RoomFolderPinsPresentation.reordered(["a", "b", "c"], moving: "a", to: "c"), ["b", "c", "a"])
        XCTAssertEqual(RoomFolderPinsPresentation.reordered(["a", "b", "c"], moving: "c", to: "a"), ["c", "a", "b"])
        XCTAssertEqual(RoomFolderPinsPresentation.reordered(["a", "b"], moving: "foreign", to: "a"), ["a", "b"])
    }

    func test_at_most_ten_pins_and_the_exact_limit_message() {
        let folders = (0...10).map { folder("f-\($0)", pin: $0) }
        XCTAssertEqual(RoomFolderPinsPresentation.ordered(folders).count, 10)
        XCTAssertEqual(RoomFolderPinsPresentation.limitMessage, "You can pin up to 10 folders.")
    }
}
