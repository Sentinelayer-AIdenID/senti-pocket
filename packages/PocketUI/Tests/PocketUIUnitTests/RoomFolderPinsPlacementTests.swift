#if canImport(SwiftUI)
import Combine
import Foundation
import PocketContracts
import XCTest
@testable import PocketUI

/// Exercises the same row-to-panel background placement used by the root, including its unchanged-input gate.
@MainActor
final class RoomFolderPinsPlacementTests: XCTestCase {
    private func rows() throws -> [SessionRowPresentation] {
        let data = Data("""
        [
          {"sessionId":"r-a","title":"Planning","status":"active","archiveStatus":"active", "visibility":"private",
           "membershipRole":"owner","agentCount":0,"eventCount":1,"totalCostUsd":0,"folderId":"a"},
          {"sessionId":"r-b","title":"Ideas","status":"active","archiveStatus":"active", "visibility":"private",
           "membershipRole":"owner","agentCount":0,"eventCount":1,"totalCostUsd":0,"folderId":"b"},
          {"sessionId":"r-other","title":"Other chat","status":"active","archiveStatus":"active", "visibility":"private",
           "membershipRole":"owner","agentCount":0,"eventCount":1,"totalCostUsd":0}
        ]
        """.utf8)
        let sessions = try JSONDecoder().decode([SessionSummary].self, from: data)
        return SessionListPresentationState(sessions: sessions, includesArchived: false,
                                            hasMore: false, provenance: .fixture).rows
    }

    private func folders(pins: [String] = ["b", "a"], unsupported: String? = nil) -> [RoomFolderItem] {
        ["a", "b", "c"].enumerated().map { position, id in
            RoomFolderItem(id: id, name: "Folder \(id)", position: position,
                           pinnedPosition: pins.firstIndex(of: id), supportsPinning: id != unsupported)
        }
    }

    /// Mutant: remove the production input-equality guard and the repeat reads place and publish again.
    func test_unchanged_rows_and_pins_do_not_place_or_publish_again() async throws {
        let placement = SidePanelPlacement(defaults: nil)
        let rows = try rows()
        let folders = folders()
        placement.update(rows: rows, folders: folders)
        await placement.settle()
        let first = placement.shown
        XCTAssertEqual(placement.builds, 1)
        XCTAssertEqual(first.layout.pinnedFolders.map(\.id), ["b", "a"])
        XCTAssertTrue(first.layout.pinsAvailable)
        var writes = 0
        let watch = placement.objectWillChange.sink { writes += 1 }
        defer { watch.cancel() }

        for _ in 0..<3 {
            placement.update(rows: rows, folders: folders)
            await placement.settle()
        }
        XCTAssertEqual(placement.builds, 1, "unchanged pins and rows reuse the existing placement")
        XCTAssertEqual(writes, 0, "an unchanged poll does not redraw the panel")
        XCTAssertEqual(placement.shown, first)

        placement.toggleFolded("a")
        XCTAssertEqual(placement.builds, 1, "opening or folding an existing folder does not rebuild pin order")
        XCTAssertEqual(placement.shown.layout.pinnedFolders, first.layout.pinnedFolders)
    }

    /// Mutants: leave pin order out of the input comparison, or use pin order to move ordinary folder rows.
    func test_a_pin_order_change_places_once_and_keeps_the_ordinary_rows_in_place() async throws {
        let placement = SidePanelPlacement(defaults: nil)
        let rows = try rows()
        placement.update(rows: rows, folders: folders())
        await placement.settle()
        let ordinaryIds = placement.shown.rows.map(\.id)
        let ordinaryRooms = placement.shown.rooms
        var writes = 0
        let watch = placement.objectWillChange.sink { writes += 1 }
        defer { watch.cancel() }

        let reordered = folders(pins: ["a", "b"])
        placement.update(rows: rows, folders: reordered)
        await placement.settle()
        XCTAssertEqual(placement.builds, 2)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(placement.shown.layout.pinnedFolders.map(\.id), ["a", "b"])
        XCTAssertEqual(placement.shown.rows.map(\.id), ordinaryIds)
        XCTAssertEqual(placement.shown.rooms, ordinaryRooms)

        placement.update(rows: rows, folders: reordered)
        await placement.settle()
        XCTAssertEqual(placement.builds, 2, "reading the acknowledged pin order again does not place it again")
        XCTAssertEqual(writes, 1)
    }

    /// Mutant: retain cached capability or shortcuts after an older server omits a pin field.
    func test_the_background_placement_updates_capability_with_its_pin_order() async throws {
        let placement = SidePanelPlacement(defaults: nil)
        let rows = try rows()
        placement.update(rows: rows, folders: folders())
        await placement.settle()
        let ordinaryIds = placement.shown.rows.map(\.id)

        placement.update(rows: rows, folders: folders(unsupported: "c"))
        await placement.settle()
        XCTAssertEqual(placement.builds, 2)
        XCTAssertFalse(placement.shown.layout.pinsAvailable)
        XCTAssertTrue(placement.shown.layout.pinnedFolders.isEmpty)
        XCTAssertEqual(placement.shown.rows.map(\.id), ordinaryIds)
    }
}
#endif
