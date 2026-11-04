#if os(iOS) && canImport(XCTest)
import XCTest

/// Report, Block and the AI consent in the DEBUG preview room (`-PocketRoomPreview`): sample rows with agents in the
/// room, a local sender and reporter, and an AI consent that is not given at launch.
final class RoomSafetyFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRoomPreview"]
        app.launch()
        return app
    }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Types into the room's box once the keyboard is up for it.
    private func write(_ text: String, in app: XCUIApplication) {
        let composer = el(app, "pocket.room.composer")
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15))
        composer.typeText(text)
    }

    /// Someone else's message near the bottom of the preview room (sam, 118), long-pressed for its menu.
    private func openMenu(_ app: XCUIApplication) {
        let message = el(app, "pocket.room.message.118")
        XCTAssertTrue(message.waitForExistence(timeout: 30))
        // The room's live message lands a few seconds in; then the list is drawn down until Sam's message is clear of
        // the pinned strip.
        sleep(6)
        // Hittable is no guide here (the strip floats over the list): the message's place is.
        for _ in 0..<8 where message.frame.midY < app.frame.height * 0.4 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
            sleep(1)
        }
        XCTAssertGreaterThan(message.frame.midY, app.frame.height * 0.4)
        message.press(forDuration: 1.2)
        // The menu's items take a tap only once it has finished opening.
        _ = app.buttons["Report…"].waitForExistence(timeout: 10)
        sleep(1)
    }

    /// Taps a menu item; a tap the opening menu did not take (it is still there) is tapped again.
    private func choose(_ item: XCUIElement, then next: XCUIElement) {
        item.tap()
        if !next.waitForExistence(timeout: 10), item.exists {
            item.tap()
        }
        XCTAssertTrue(next.waitForExistence(timeout: 10))
    }

    func test_the_first_send_asks_once_and_not_now_keeps_the_draft() {
        let app = launch()
        let composer = el(app, "pocket.room.composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        write("Ship it tonight", in: app)
        app.buttons["pocket.room.send"].tap()

        let notNow = el(app, "pocket.aiConsent.notNow")
        XCTAssertTrue(notNow.waitForExistence(timeout: 5), "a room with agents asks before the first send")
        XCTAssertTrue(el(app, "pocket.aiConsent.notice").label.hasPrefix("What you share in a room"))
        notNow.tap()
        XCTAssertTrue(notNow.waitForNonExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Ship it tonight", "Not now keeps the draft")
        XCTAssertFalse(app.staticTexts["Ship it tonight"].exists, "and sends nothing")

        app.buttons["pocket.room.send"].tap()
        let ok = el(app, "pocket.aiConsent.ok")
        XCTAssertTrue(ok.waitForExistence(timeout: 5), "asked again until OK")
        ok.tap()
        // The preview room never echoes a send, so its pending row goes after a moment: the box emptying is the send.
        XCTAssertTrue(waitFor { (composer.value as? String) != "Ship it tonight" }, "OK sends it")

        write("And the retry counter", in: app)
        app.buttons["pocket.room.send"].tap()
        XCTAssertTrue(waitFor { (composer.value as? String) != "And the retry counter" }, "the next send goes at once")
        XCTAssertFalse(el(app, "pocket.aiConsent.ok").exists, "asked once")
    }

    func test_block_shows_their_messages_as_one_line_and_show_reveals_one() {
        let app = launch()
        openMenu(app)
        let block = app.buttons["Block Sam"]
        XCTAssertTrue(block.waitForExistence(timeout: 5), "someone else's message offers Block")
        XCTAssertTrue(app.buttons["Report…"].exists, "and Report")
        let confirm = el(app, "pocket.block.confirm")
        choose(block, then: confirm)
        confirm.tap()

        let hidden = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pocket.room.blocked.' AND NOT identifier ENDSWITH '.show'"))
        XCTAssertTrue(hidden.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(el(app, "pocket.room.message.118").exists, "their message is one line now")
        XCTAssertTrue(app.staticTexts["Message from someone you blocked"].exists)
        let lines = hidden.count

        let show = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pocket.room.blocked.' AND identifier ENDSWITH '.show'"))
        var shown = false
        for index in 0..<show.count where show.element(boundBy: index).isHittable {
            show.element(boundBy: index).tap()
            shown = true
            break
        }
        XCTAssertTrue(shown)
        XCTAssertTrue(waitFor { hidden.count == lines - 1 }, "Show opens that one, and no other")
    }

    func test_report_sends_then_thanks_and_offers_to_block() {
        let app = launch()
        openMenu(app)
        let report = app.buttons["Report…"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        let send = el(app, "pocket.report.send")
        choose(report, then: send)
        // A reason first: Send without one sends nothing (a toolbar button's enabled state isn't read reliably).
        send.tap()
        XCTAssertFalse(el(app, "pocket.report.thanks").waitForExistence(timeout: 2), "a reason first")
        el(app, "pocket.report.reason.harassment").tap()
        send.tap()
        XCTAssertTrue(el(app, "pocket.report.thanks").waitForExistence(timeout: 10))
        XCTAssertEqual(el(app, "pocket.report.thanks").label, "Thanks. We'll review it within 24 hours.")
        XCTAssertTrue(el(app, "pocket.report.blockToo").exists, "it offers to block them too")
        el(app, "pocket.report.done").tap()
        XCTAssertTrue(el(app, "pocket.report.done").waitForNonExistence(timeout: 5))
    }

    private func waitFor(_ condition: () -> Bool) -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            usleep(100_000)
        }
        return condition()
    }
}
#endif
