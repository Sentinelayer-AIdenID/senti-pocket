#if os(iOS) && canImport(XCTest)
import XCTest

/// The scroll-up freeze (ticket 575678a1): in a room with pinned messages, drags toward older messages took the list to
/// its top, the pinned strip's height moved as the list bounced there, the list's frame followed it, and the main
/// thread laid the list out for good. On the DEBUG preview room (`-PocketRoomPreview`: made-up messages, with pins), the
/// drags of the room's own flow tests, from the same points, until the room's start shows: after each drag the screen
/// answers within a second, the strip keeps its height, and the strip sits above the list, never over it.
final class RoomScrollUpFreezeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func test_drags_to_the_top_of_a_room_with_pins_never_hang() {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRoomPreview"]
        app.launch()
        let pinned = app.descendants(matching: .any)["pocket.room.pinned"]
        XCTAssertTrue(pinned.waitForExistence(timeout: 30), "the room has its pins")
        let list = app.descendants(matching: .any)["pocket.room.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let start = app.descendants(matching: .any)["pocket.room.startOfRoom"]
        sleep(6)
        let height = pinned.frame.height
        print(String(format: "SCROLLUP strip %.1f pt, list top %.1f, strip bottom %.1f",
                     height, list.frame.minY, pinned.frame.maxY))
        XCTAssertLessThanOrEqual(pinned.frame.maxY, list.frame.minY + 0.5, "the strip sits above the list, not over it")
        for drag in 1...4 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
            sleep(1)
            let started = Date()
            XCTAssertTrue(list.exists, "drag \(drag): the room is still there")
            let read = Date().timeIntervalSince(started)
            print(String(format: "SCROLLUP drag %d read %.2f s, strip %.1f pt", drag, read, pinned.frame.height))
            XCTAssertLessThan(read, 1, "drag \(drag): the screen answers within a second")
            XCTAssertEqual(pinned.frame.height, height, accuracy: 0.5, "drag \(drag): the strip keeps its height")
            XCTAssertLessThanOrEqual(pinned.frame.maxY, list.frame.minY + 0.5, "drag \(drag): the strip stays above the list")
        }
        XCTAssertTrue(start.exists, "the drags reached the room's start, where it bounced")
    }
}
#endif
