#if os(iOS) && canImport(XCTest)
import XCTest

/// Deleting your account from Settings (App Review 5.1.1(v)), against the made-up server of
/// `-PocketAccountDeletionPreview`, through the app's own client and screens: Delete account sits under Sign out, the
/// first tap only asks, Cancel sends nothing, the confirmation's own button sends the request once, the app signs out
/// showing the server's date, and signing in again shows the notice until Keep my account.
final class AccountDeletionUITests: XCTestCase {
    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ stage: String, largest: Bool = false, log: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketAccountDeletionPreview", "-PocketAccountDeletionStage", stage]
            + (log ? ["-PocketAccountDeletionLog"] : [])
            + (largest ? Self.largestText : [])
        app.launch()
        return app
    }

    /// Scrolls until the element can be tapped; false if it never could.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes most: Int = 16) -> Bool {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < most {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        return element.exists && element.isHittable
    }

    private func openSettings(_ app: XCUIApplication) {
        let drawer = app.buttons["pocket.drawer.open"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 60), "the signed-in root came up\n\(app.debugDescription)")
        drawer.tap()
        let settings = app.buttons["pocket.drawer.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "the side panel has Settings\n\(app.debugDescription)")
        settings.tap()
    }

    /// Settings, then Delete account: the deletion screen, with its button in reach.
    @discardableResult
    private func openDeletion(_ app: XCUIApplication) -> XCUIElement {
        openSettings(app)
        let row = app.buttons["settings.account.delete"]
        XCTAssertTrue(reveal(row, in: app), "Delete account is in Settings\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(app.staticTexts["account.delete.later"].waitForExistence(timeout: 20),
                      "the deletion screen came up\n\(app.debugDescription)")
        let request = app.buttons["account.delete.request"]
        XCTAssertTrue(reveal(request, in: app), "Delete my account can be reached\n\(app.debugDescription)")
        return request
    }

    private func serverLog(_ app: XCUIApplication) -> String {
        app.staticTexts["preview.deletion.log"].label
    }

    func test_deleting_asks_twice_sends_once_and_signs_out_with_the_servers_date() throws {
        let app = launch("none")
        openSettings(app)
        let signOut = app.buttons["settings.account.sign-out"]
        let row = app.buttons["settings.account.delete"]
        XCTAssertTrue(reveal(row, in: app), "Delete account is in Settings\n\(app.debugDescription)")
        XCTAssertTrue(signOut.exists)
        XCTAssertGreaterThan(row.frame.minY, signOut.frame.minY, "Delete account sits under Sign out")
        row.tap()

        let later = app.staticTexts["account.delete.later"]
        XCTAssertTrue(later.waitForExistence(timeout: 20), "the deletion screen came up\n\(app.debugDescription)")
        XCTAssertTrue(later.label.hasPrefix("After a waiting period"), "a number the server did not give: \(later.label)")
        let request = app.buttons["account.delete.request"]
        XCTAssertTrue(reveal(request, in: app))

        // The first yes only asks, and Cancel sends nothing.
        request.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Delete my account asks once more\n\(app.debugDescription)")
        XCTAssertTrue(alert.staticTexts["Delete your account?"].exists, alert.debugDescription)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(request.waitForExistence(timeout: 10))
        XCTAssertTrue(request.isHittable, "Cancel leaves the deletion screen as it was")
        XCTAssertFalse(app.staticTexts["account.scheduled.title"].exists, "Cancel deleted the account")

        // The confirmation's own yes sends the request.
        request.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["Delete my account"].tap()
        let scheduled = app.staticTexts["account.scheduled.title"]
        XCTAssertTrue(scheduled.waitForExistence(timeout: 30), "signed out, with the date\n\(app.debugDescription)")
        XCTAssertTrue(scheduled.label.hasPrefix("Your account will be deleted on "), scheduled.label)
        XCTAssertTrue(serverLog(app).contains("request 1,"), "one request for two yeses: \(serverLog(app))")
        let date = scheduled.label
        app.buttons["account.scheduled.done"].tap()
        let signIn = app.buttons["pocket.signin.primary"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), "the sign-in screen is under the date")

        // Signing in again shows the notice with the same date; only Keep my account stops the deletion.
        signIn.tap()
        let pending = app.staticTexts["account.pending.title"]
        XCTAssertTrue(pending.waitForExistence(timeout: 30), "a pending account signs in to its notice\n\(app.debugDescription)")
        XCTAssertEqual(pending.label, date, "the notice gives the date the server gave the request")
        app.buttons["account.pending.keep"].tap()
        XCTAssertTrue(app.buttons["pocket.drawer.open"].waitForExistence(timeout: 30), "kept: back in the app")
        XCTAssertFalse(pending.exists)
        XCTAssertTrue(serverLog(app).contains("cancel 1"), serverLog(app))
    }

    func test_the_screen_gives_the_servers_number_of_days_when_it_says() {
        let app = launch("days")
        openDeletion(app)
        let later = app.staticTexts["account.delete.later"]
        XCTAssertTrue(later.label.hasPrefix("After 7 days, "), later.label)
    }

    func test_a_refused_request_says_why_and_leaves_you_signed_in() {
        let app = launch("limited")
        let request = openDeletion(app)
        request.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["Delete my account"].tap()
        let failure = app.staticTexts["account.delete.failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 20), "the refusal is said\n\(app.debugDescription)")
        XCTAssertEqual(failure.label, "Too many tries. Wait a minute, then try again. Nothing was deleted.")
        XCTAssertTrue(request.exists, "still signed in, on the deletion screen")
        XCTAssertFalse(app.staticTexts["account.scheduled.title"].exists)
    }

    func test_after_the_date_only_sign_out_is_offered() {
        let app = launch("deadline")
        let keep = app.buttons["account.pending.keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 60), "the notice came up\n\(app.debugDescription)")
        keep.tap()
        let title = app.staticTexts["account.pending.title"]
        let passed = expectation(for: NSPredicate(format: "label == %@", "Your account is being deleted."),
                                 evaluatedWith: title)
        wait(for: [passed], timeout: 20)
        XCTAssertFalse(keep.exists, "Keep my account after the date")
        XCTAssertTrue(app.buttons["account.pending.sign-out"].exists)
    }

    /// iOS's own accessibility audit on each deletion screen at the largest text size: every control described, no
    /// clipped text, and text that grows.
    func test_the_deletion_screens_pass_the_accessibility_audit_at_the_largest_text_size() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("the audit needs iOS 17") }
        let audits: XCUIAccessibilityAuditType = [.dynamicType, .textClipped, .sufficientElementDescription]

        var app = launch("none", largest: true, log: false)
        let request = openDeletion(app)
        try app.performAccessibilityAudit(for: audits)
        request.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["Delete my account"].tap()
        XCTAssertTrue(app.staticTexts["account.scheduled.title"].waitForExistence(timeout: 30))
        try app.performAccessibilityAudit(for: audits)
        app.terminate()

        app = launch("pending", largest: true, log: false)
        XCTAssertTrue(app.buttons["account.pending.keep"].waitForExistence(timeout: 60))
        try app.performAccessibilityAudit(for: audits)
    }

    /// Pictures of each screen for review, when ACCOUNT_SHOT_DIR is set: the Mac's run sets the simulator's appearance,
    /// and ACCOUNT_SHOT_SIZE=ax5 the largest text size. Skipped otherwise.
    func test_pictures_of_each_screen() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let dir = environment["ACCOUNT_SHOT_DIR"], !dir.isEmpty else { throw XCTSkip("ACCOUNT_SHOT_DIR is not set") }
        let largest = environment["ACCOUNT_SHOT_SIZE"] == "ax5"
        let tag = environment["ACCOUNT_SHOT_TAG"] ?? (largest ? "ax5" : "390")
        func shot(_ name: String) {
            Thread.sleep(forTimeInterval: 1)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("account-\(tag)-\(name).png")
            XCTAssertNoThrow(try XCUIScreen.main.screenshot().pngRepresentation.write(to: url))
        }

        var app = launch("none", largest: largest, log: false)
        openSettings(app)
        let row = app.buttons["settings.account.delete"]
        XCTAssertTrue(reveal(row, in: app))
        shot("1-settings")
        row.tap()
        XCTAssertTrue(app.staticTexts["account.delete.later"].waitForExistence(timeout: 20))
        shot("2-sheet")
        let request = app.buttons["account.delete.request"]
        XCTAssertTrue(reveal(request, in: app))
        shot("3-sheet-button")
        request.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        shot("4-confirm")
        app.alerts.firstMatch.buttons["Delete my account"].tap()
        XCTAssertTrue(app.staticTexts["account.scheduled.title"].waitForExistence(timeout: 30))
        shot("5-scheduled")
        app.terminate()

        app = launch("pending", largest: largest, log: false)
        let keep = app.buttons["account.pending.keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 60))
        shot("6-pending")
        app.terminate()

        app = launch("deadline", largest: largest, log: false)
        XCTAssertTrue(app.buttons["account.pending.keep"].waitForExistence(timeout: 60))
        app.buttons["account.pending.keep"].tap()
        let title = app.staticTexts["account.pending.title"]
        wait(for: [expectation(for: NSPredicate(format: "label == %@", "Your account is being deleted."),
                               evaluatedWith: title)], timeout: 20)
        shot("7-deadline")
        app.terminate()

        app = launch("limited", largest: largest, log: false)
        let refused = openDeletion(app)
        refused.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        app.alerts.firstMatch.buttons["Delete my account"].tap()
        XCTAssertTrue(app.staticTexts["account.delete.failure"].waitForExistence(timeout: 20))
        shot("8-refused")
    }
}
#endif
