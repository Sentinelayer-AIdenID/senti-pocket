#if os(iOS) && canImport(XCTest)
import CoreFoundation
import UIKit
import XCTest

/// The four ways Carter's phone froze on build 2026110310, on the app's `-PocketRootPreview` data (made-up rooms; no
/// network): the side panel opened and closed over a room; the app sent to the background and back with the panel open;
/// after Jump to latest kept a room's newest 60 rows, a room opened from the panel; and a reply sent in a long room
/// read far up, sent to, and trimmed for the jump down, with no panel at all. Each ends with a quiet spell in
/// which nothing reads the screen, announced as `FREEZE-IDLE begin` and `FREEZE-IDLE end`, for the lane to sample the
/// app's main thread: it must be asleep, not laying out. Then the screen must answer a read within a second.
final class FreezePathsUITests: XCTestCase {
    private static let openDrawer = "com.plexaura.sentipocket.preview.root.drawer.open"
    private static let closeDrawer = "com.plexaura.sentipocket.preview.root.drawer.close"

    override func setUp() {
        continueAfterFailure = true
    }

    /// The side panel opened, closed, and opened again over a room of 100 rows.
    func test_path1_side_panel_open_and_close() throws {
        let app = launch(room: "mid")
        Self.post(Self.openDrawer)
        pause(2)
        Self.post(Self.closeDrawer)
        pause(2)
        Self.post(Self.openDrawer)
        pause(2)
        idle(app, "path1")
    }

    /// The side panel open the whole time while the app goes to the background and back three times; the quiet spell
    /// covers the panel's own read of the rooms 15 s after the last return.
    func test_path2_background_and_back_with_the_panel_open() throws {
        let app = launch(room: "mid")
        Self.post(Self.openDrawer)
        pause(3)
        for _ in 1...3 {
            XCUIDevice.shared.press(.home)
            pause(5)
            app.activate()
            pause(3)
        }
        idle(app, "path2", seconds: 25)
    }

    /// Up a room to its first message, Jump to latest (the room keeps its newest 60 rows), then the side panel opened
    /// and another room of 100 rows picked from it: the room before it closes.
    func test_path3_room_opened_from_the_panel_after_a_jump_down_trim() throws {
        let app = launch(room: "mid")
        let screen = app.descendants(matching: .any)["pocket.room.screen"]
        for _ in 0..<14 {
            if app.descendants(matching: .any)["pocket.room.message.1"].exists { break }
            screen.swipeDown(velocity: .fast)
        }
        let jump = app.descendants(matching: .any)["pocket.room.jumpToLatest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 10), "the arrow shows up the room")
        jump.tap()
        pause(3)
        Self.post(Self.openDrawer)
        let row = app.descendants(matching: .any)["pocket.drawer.room.room-long"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the room is in the side panel")
        row.tap()
        pause(2)
        idle(app, "path3")
    }

    /// Up a long room until about 300 rows are loaded (each page loads as its top comes into view), Jump to latest (the
    /// room keeps its newest 60 rows), a message sent, then a reply to the newest message sent from its menu.
    func test_path4_reply_in_a_long_room_after_a_jump_down_trim() throws {
        let app = launch(room: "long")
        let screen = app.descendants(matching: .any)["pocket.room.screen"]
        for _ in 0..<60 {
            if app.descendants(matching: .any)["pocket.room.message.705"].exists { break }
            screen.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(app.descendants(matching: .any)["pocket.room.message.705"].exists, "about 300 rows loaded")
        let jump = app.descendants(matching: .any)["pocket.room.jumpToLatest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 10), "the arrow shows up the room")
        jump.tap()
        pause(3)
        send(app, "A note sent after the jump down, as long as a paragraph would be in a busy room.")
        let newest = app.descendants(matching: .any)["pocket.room.message.1000"]
        XCTAssertTrue(newest.waitForExistence(timeout: 30), "the newest message is in view")
        newest.press(forDuration: 1.2)
        // The menu's Reply: the first of the buttons so named (the rows' own reply links come after it).
        let reply = app.buttons.matching(identifier: "Reply").firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "the message's menu offers Reply")
        reply.tap()
        send(app, "A short reply now")
        idle(app, "path4", seconds: 25)
    }

    // MARK: - Helpers

    private func send(_ app: XCUIApplication, _ text: String) {
        let composer = app.descendants(matching: .any)["pocket.room.composer"]
        guard composer.waitForExistence(timeout: 10) else { return XCTFail("no composer") }
        composer.tap()
        composer.typeText(text)
        app.descendants(matching: .any)["pocket.room.send"].tap()
        pause(1)
    }

    /// Nothing reads the screen for `seconds` while the lane samples the main thread; then a read must answer in 1 s.
    private func idle(_ app: XCUIApplication, _ path: String, seconds: TimeInterval = 20) {
        print("FREEZE-IDLE begin \(path)")
        pause(seconds)
        print("FREEZE-IDLE end \(path)")
        let start = Date()
        _ = app.descendants(matching: .any)["pocket.room.screen"].exists
        let read = Date().timeIntervalSince(start)
        print(String(format: "FREEZE-READ %@ %.2f s", path, read))
        XCTAssertEqual(app.state, .runningForeground, "\(path): the app is still in front")
        XCTAssertLessThan(read, 1, "\(path): the screen answers within a second after the quiet spell")
    }

    private func launch(room: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRootPreview", "-PocketRootRoom", room, "-LogForEachSlowPath", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["pocket.room.screen"].waitForExistence(timeout: 90), "the room opened")
        pause(5)
        return app
    }

    private static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
#endif
