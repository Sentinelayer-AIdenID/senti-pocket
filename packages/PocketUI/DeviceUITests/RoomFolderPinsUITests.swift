#if os(iOS) && canImport(XCTest)
import XCTest

/// The production folder menu receives real taps. Mutants: remove its pin hook, invert Pin/Unpin, ignore server
/// capability, or expose pin actions before an account is ready.
final class RoomFolderPinsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_native_folder_menu_pins_and_unpins_in_light_and_dark() {
        for appearance in ["light", "dark"] {
            let app = launch(extra: appearance == "dark" ? ["-ShotsDark"] : [])
            defer { app.terminate() }
            let group = app.descendants(matching: .any).matching(identifier: "pocket.drawer.pinnedFolders").firstMatch
            XCTAssertFalse(group.exists)
            expect("Calls: 0", at: app.staticTexts["folder-pins.preview.calls"])

            openFolderMenu(app)
            let pin = app.buttons["Pin to top"]
            XCTAssertTrue(pin.waitForExistence(timeout: 10), "the native menu offers Pin to top")
            XCTAssertFalse(app.buttons["Unpin"].exists)
            shot(app, "\(appearance)-pin-menu")
            pin.tap()
            expect("Calls: 1", at: app.staticTexts["folder-pins.preview.calls"])
            expect("pin:pin-fixture", at: app.staticTexts["folder-pins.preview.lastIntent"])
            XCTAssertTrue(group.waitForExistence(timeout: 10), "the same panel shows the acknowledged pin")
            XCTAssertTrue(app.buttons["Open pinned folder Planning"].exists)
            shot(app, "\(appearance)-pinned")

            openFolderMenu(app)
            let unpin = app.buttons["Unpin"]
            XCTAssertTrue(unpin.waitForExistence(timeout: 10), "the same folder now offers Unpin")
            XCTAssertFalse(app.buttons["Pin to top"].exists)
            unpin.tap()
            expect("Calls: 2", at: app.staticTexts["folder-pins.preview.calls"])
            expect("unpin:pin-fixture", at: app.staticTexts["folder-pins.preview.lastIntent"])
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: group)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
            shot(app, "\(appearance)-unpinned")
        }
    }

    func test_missing_capability_or_unresolved_account_hides_native_pin_actions() {
        for flag in ["-PocketRoomFolderPinsUnsupported", "-PocketRoomFolderPinsAccountPending"] {
            let app = launch(extra: [flag])
            defer { app.terminate() }
            expect("Calls: 0", at: app.staticTexts["folder-pins.preview.calls"])
            openFolderMenu(app)
            XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 10), "the folder's native menu is open")
            XCTAssertFalse(app.buttons["Pin to top"].exists)
            XCTAssertFalse(app.buttons["Unpin"].exists)
        }
    }

    private func launch(extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRoomFolderPinsPreview"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["pocket.drawer.folder.pin-fixture.menu"].waitForExistence(timeout: 60),
                      "the production side panel opened")
        return app
    }

    private func openFolderMenu(_ app: XCUIApplication) {
        let menu = app.buttons["pocket.drawer.folder.pin-fixture.menu"]
        XCTAssertTrue(menu.isHittable, "the actual folder menu is reachable")
        menu.tap()
    }

    private func expect(_ label: String, at element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", label),
                                             object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "expected \(label), got \(element.label)")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "folder-pins-\(Int(app.windows.firstMatch.frame.width))-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
