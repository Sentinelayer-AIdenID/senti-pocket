#if os(iOS) && canImport(XCTest)
import XCTest

/// Carter, 11-06: a drag all the way from the left edge opens the side panel, the room following the finger. On the
/// app's `-PocketRootPreview` data: a drag from 3 pt opens it, and puts the keyboard away when it is up; a drag from
/// 40 pt on a message is still its swipe to reply, and the panel stays closed; a drag from the edge over a message opens
/// the panel and no reply. Whether the panel is open is the dimmed room's "Close the side panel", there only while it is.
/// `SidePanelEdgeTests` checks, hosted, what decides each of these.
final class SidePanelEdgeSwipeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func test_a_drag_from_the_left_edge_opens_the_side_panel_and_puts_the_keyboard_away() throws {
        let app = launch()
        let composer = app.descendants(matching: .any).matching(identifier: "pocket.room.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "the room's composer is there")
        composer.tap()
        let keyboardUp = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        print("SIDE-EDGE software keyboard up before the drag: \(keyboardUp)")

        drag(app, fromX: 3, y: app.frame.height * 0.45, by: 240)
        XCTAssertTrue(closer(app).waitForExistence(timeout: 5), "a drag from the left edge opened the side panel")
        if keyboardUp {
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2), "the keyboard went as it opened")
        }
    }

    func test_a_drag_from_40_pt_on_a_message_replies_and_leaves_the_panel_closed() throws {
        let app = launch()
        let row = try messageRow(app)
        drag(app, fromX: 40, y: row.frame.minY + row.frame.height * 0.6, by: 120)
        let replying = app.descendants(matching: .any).matching(identifier: "pocket.room.composer.replying").firstMatch
        XCTAssertTrue(replying.waitForExistence(timeout: 5), "a drag from 40 pt on a message is its swipe to reply")
        XCTAssertFalse(closer(app).exists, "and the side panel stayed closed")
    }

    func test_a_drag_from_the_edge_over_a_message_opens_the_panel_and_no_reply() throws {
        let app = launch()
        let row = try messageRow(app)
        drag(app, fromX: 3, y: row.frame.minY + row.frame.height * 0.6, by: 240)
        XCTAssertTrue(closer(app).waitForExistence(timeout: 5), "from the edge, over a message, the panel opened")
        let replying = app.descendants(matching: .any).matching(identifier: "pocket.room.composer.replying").firstMatch
        XCTAssertFalse(replying.exists, "and the message under it was not answered")
    }

    // MARK: - Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRootPreview", "-PocketRootRoom", "mid"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pocket.room.screen").firstMatch
                        .waitForExistence(timeout: 90), "the room opened")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        return app
    }

    /// The dimmed room's "Close the side panel": there only while the panel is open.
    private func closer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Close the side panel")).firstMatch
    }

    /// The lowest message on screen that starts at the room's left (someone else's, with the avatar), whose middle a
    /// drag from 40 pt lands on.
    private func messageRow(_ app: XCUIApplication) throws -> XCUIElement {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "pocket.room.message.")).allElementsBoundByIndex
        let row = rows.last { $0.frame.minX < 30 && $0.frame.height > 40 && $0.isHittable }
        return try XCTUnwrap(row, "a message from someone else is on screen")
    }

    /// A drag to the right from (`x`, `y`), in the screen's points.
    private func drag(_ app: XCUIApplication, fromX x: CGFloat, y: CGFloat, by distance: CGFloat) {
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let start = origin.withOffset(CGVector(dx: x, dy: y))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)))
    }
}
#endif
