#if os(iOS) && canImport(XCTest)
import XCTest

/// Native alert taps exercise the production modifier. Mutants: Cancel writes, End loses its captured confirmation
/// when the binding clears, or one confirmation acknowledges twice.
final class ChatLifecycleUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_cancel_does_not_write_and_end_acknowledges_once_in_light_and_dark() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-PocketChatLifecyclePreview"] + (appearance == "dark" ? ["-ShotsDark"] : [])
            app.launch()
            defer { app.terminate() }
            let entry = app.buttons["chat-lifecycle.preview.end"]
            XCTAssertTrue(entry.waitForExistence(timeout: 60), "the production alert preview opened")
            expect("Calls: 0", at: app.staticTexts["chat-lifecycle.preview.calls"])
            expect("Changes: 0", at: app.staticTexts["chat-lifecycle.preview.changes"])

            entry.tap()
            let alert = app.alerts["End this chat for everyone?"]
            XCTAssertTrue(alert.waitForExistence(timeout: 10))
            XCTAssertTrue(alert.staticTexts["No one can post in it after this."].exists)
            XCTAssertTrue(alert.buttons["End"].exists)
            XCTAssertTrue(alert.buttons["Cancel"].exists)
            shot(app, "\(appearance)-confirmation")
            alert.buttons["Cancel"].tap()
            waitForDismissal(alert)
            expect("Calls: 0", at: app.staticTexts["chat-lifecycle.preview.calls"])
            expect("Changes: 0", at: app.staticTexts["chat-lifecycle.preview.changes"])

            entry.tap()
            XCTAssertTrue(alert.waitForExistence(timeout: 10))
            alert.buttons["End"].tap()
            waitForDismissal(alert)
            expect("Calls: 1", at: app.staticTexts["chat-lifecycle.preview.calls"])
            expect("Changes: 1", at: app.staticTexts["chat-lifecycle.preview.changes"])
            expect("end:preview-account:preview-chat", at: app.staticTexts["chat-lifecycle.preview.lastCall"])
            expect("preview-chat", at: app.staticTexts["chat-lifecycle.preview.changedChat"])
            shot(app, "\(appearance)-acknowledged")
        }
    }

    private func expect(_ label: String, at element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", label),
                                             object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "expected \(label), got \(element.label)")
    }

    private func waitForDismissal(_ alert: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alert)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "the native alert dismissed")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "chat-lifecycle-\(Int(app.windows.firstMatch.frame.width))-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
