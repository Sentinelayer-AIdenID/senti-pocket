#if os(iOS) && canImport(XCTest)
import CoreFoundation
import XCTest

/// Opening the side panel ends editing first, so the keyboard starts going down before the panel's spring: Carter's
/// freezes of 11-06 came with the keyboard still up as the panel opened. On the app's `-PocketRootPreview` data, with the
/// software keyboard showing (the simulator's hardware keyboard disconnected; the test is skipped when it does not
/// show), a draft is typed in the room's composer and the side panel opened from its button: the keyboard goes as the
/// panel opens, and the draft is still in the composer when the panel closes. `SidePanelKeyboardTests` checks, hosted,
/// that the panel's state ends editing before it changes.
final class SidePanelKeyboardUITests: XCTestCase {
    private static let closeDrawer = "com.plexaura.sentipocket.preview.root.drawer.close"

    func test_opening_the_side_panel_puts_the_keyboard_away_and_keeps_the_draft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRootPreview", "-PocketRootRoom", "mid"]
        app.launch()
        let composer = app.descendants(matching: .any).matching(identifier: "pocket.room.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 90), "the room opened")
        composer.tap()
        guard app.keyboards.firstMatch.waitForExistence(timeout: 5) else {
            throw XCTSkip("The software keyboard is not showing: turn the simulator's hardware keyboard off to run this.")
        }
        let draft = "A note half written"
        composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft, "the draft is in the composer")

        // Whether the panel is open is the dimmed room's "Close the side panel", there only while it is: the closed
        // panel stays in the view tree, faded out under the room, so its own element is no sign of it.
        let panel = app.descendants(matching: .any).matching(identifier: "pocket.drawer").firstMatch
        let closer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Close the side panel")).firstMatch
        app.buttons.matching(identifier: "pocket.drawer.open").firstMatch.tap()
        XCTAssertTrue(closer.waitForExistence(timeout: 10), "the side panel opened")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2), "the keyboard went as the panel opened")

        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(Self.closeDrawer as CFString), nil, nil, true)
        XCTAssertTrue(closer.waitForNonExistence(timeout: 10), "the side panel closed: its Close the side panel is gone")
        XCTAssertFalse(panel.exists && panel.isHittable, "the closed side panel cannot be touched")
        let buttons = panel.exists ? Array(panel.buttons.allElementsBoundByIndex.prefix(40)) : []
        print("SIDE-PANEL closed: in the accessibility tree \(panel.exists), hittable \(panel.exists && panel.isHittable); "
              + "\(buttons.count) of its buttons in the tree (40 at most looked at), "
              + "\(buttons.filter(\.isHittable).count) of them hittable")
        XCTAssertEqual(composer.value as? String, draft, "the draft survived the panel")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "nothing raised the keyboard again")
    }
}
#endif
