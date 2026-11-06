#if os(iOS) && canImport(XCTest)
import CoreFoundation
import XCTest

/// Carter's freeze of 11-06 (#62485, build 02): a reply to a reply from the room's box with the keyboard up, the side
/// panel about 3 s later, another room picked from it, then back to the first room; the main thread stopped as that
/// room went in and never came back. On the build Mac (path f, M3) about one fresh launch in three hung there, with
/// the closed side panel still in the view tree; with the panel left out of the tree while closed, none did. On the
/// app's `-PocketRootPreview` data with replies shown in the room (`-PocketRootInlineReplies`), three rounds of it:
/// after each switch nothing reads the screen for 15 s, then a read must answer within a second; and once the panel
/// is closed, nothing of it is left in the accessibility tree (ticket 066aca7a).
final class SidePanelPickAfterReplyUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func test_a_reply_to_a_reply_then_another_room_and_back_never_freezes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRootPreview", "-PocketRootRoom", "mid", "-PocketRootInlineReplies"]
        app.launch()
        XCTAssertTrue(screen(app).waitForExistence(timeout: 90), "the room opened")
        pause(4)
        for round in 1...3 {
            // A reply shown in the room, answered from the room's box.
            let replies = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier BEGINSWITH %@)",
                                      "pocket.room.reply.", "pocket.room.reply.minimize."))
                .allElementsBoundByIndex
            let reply = try XCTUnwrap(replies.last { $0.isHittable && $0.frame.height > 20 },
                                      "round \(round): a reply shown in the room is on screen")
            let start = reply.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 160, dy: 0)), withVelocity: .slow,
                        thenHoldForDuration: 0.05)
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pocket.room.composer.replying").firstMatch
                            .waitForExistence(timeout: 5), "round \(round): the reply opened in the room's box")
            app.descendants(matching: .any).matching(identifier: "pocket.room.composer").firstMatch.tap()
            print("round \(round): software keyboard up \(app.keyboards.firstMatch.waitForExistence(timeout: 3))")
            app.typeText("Answering that reply, round \(round).")
            app.descendants(matching: .any).matching(identifier: "pocket.room.send").firstMatch.tap()
            pause(3)

            // The panel, the Long room, 15 s; the panel, back to the review room, 15 s.
            openPanel(app, round: round)
            pause(2)
            tapRoom(app, "room-long", round: round)
            quiet(app, "round \(round), the Long room in place")
            closedPanelIsGone(app, round: round)
            openPanel(app, round: round)
            pause(2)
            tapRoom(app, "room-mid", round: round)
            quiet(app, "round \(round), back in the review room")
            closedPanelIsGone(app, round: round)
        }
    }

    // MARK: - Helpers

    private func screen(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "pocket.room.screen").firstMatch
    }

    private func closer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Close the side panel")).firstMatch
    }

    /// The panel opened from its button: open once the dimmed room's "Close the side panel" shows. A tap right after a
    /// reply to a reply is sometimes not answered (a separate ticket), so a second tap is allowed and logged.
    private func openPanel(_ app: XCUIApplication, round: Int) {
        for tap in 1...2 {
            app.buttons.matching(identifier: "pocket.drawer.open").firstMatch.tap()
            if closer(app).waitForExistence(timeout: 3) { return }
            print("round \(round): the side panel did not open on tap \(tap)")
        }
        XCTFail("round \(round): the side panel did not open")
    }

    private func tapRoom(_ app: XCUIApplication, _ id: String, round: Int) {
        let row = app.descendants(matching: .any).matching(identifier: "pocket.drawer.room.\(id)").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10) && row.isHittable, "round \(round): \(id) is in the side panel")
        row.tap()
    }

    /// Nothing reads the screen for 15 s (the phone's hang began 5 s after the switch), then a read answers in 1 s.
    private func quiet(_ app: XCUIApplication, _ moment: String) {
        pause(15)
        let begin = Date()
        _ = screen(app).exists
        let read = Date().timeIntervalSince(begin)
        print(String(format: "%@: read %.2f s", moment, read))
        XCTAssertEqual(app.state, .runningForeground, "\(moment): the app is still in front")
        XCTAssertLessThan(read, 1, "\(moment): the screen answers within a second")
    }

    /// The closed panel has left the tree: neither it nor any of its buttons can be reached.
    private func closedPanelIsGone(_ app: XCUIApplication, round: Int) {
        XCTAssertFalse(closer(app).exists, "round \(round): the panel closed")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "pocket.drawer").firstMatch.exists,
                       "round \(round): the closed panel is not in the accessibility tree")
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
#endif
