#if os(iOS) && canImport(XCTest)
import XCTest

/// The scroll-up freeze (ticket 575678a1): in a room with pinned messages, two drags toward older messages took the
/// list to its top, and its bounce there kept the main thread laying the list out for good. On the DEBUG preview room
/// (`-PocketRoomPreview`: made-up messages, with pins), the drags of the room's own flow tests, from the same points,
/// each followed by a read of the screen that must answer within a second.
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
        let screen = app.descendants(matching: .any)["pocket.room.screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        sleep(6)
        for drag in 1...4 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
            sleep(1)
            let started = Date()
            XCTAssertTrue(screen.exists, "drag \(drag): the room is still there")
            let read = Date().timeIntervalSince(started)
            print(String(format: "SCROLLUP drag %d read %.2f s", drag, read))
            XCTAssertLessThan(read, 1, "drag \(drag): the screen answers within a second")
        }
        XCTAssertTrue(pinned.exists, "the pins are still shown above the messages")
    }
}
#endif
