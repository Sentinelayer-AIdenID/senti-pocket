#if os(iOS) && canImport(XCTest)
import XCTest

/// #336 review: a room row's swipe to reply, and a thread reply's, listen for a drag to the right, and so does a strip of
/// photos dragged back to its first photo. Dragging a strip must scroll it and never open a reply. The preview room's
/// last message (`-PocketRoomStripPreview`) has twelve photos, and its one reply has twelve more.
///
/// The strips are dragged first, with nothing over them; the swipes that do open a reply (the checks that this test can
/// see one) come after, because opening a reply in the room raises the keyboard over the room's strip.
final class AttachmentStripUITests: XCTestCase {
    func test_dragging_a_strip_back_to_its_first_photo_never_opens_a_reply() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRoomPreview", "-PocketRoomStripPreview"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["pocket.room.composer"].waitForExistence(timeout: 60),
                      "the preview room opened")

        // In the room: the last message's strip.
        let row = app.descendants(matching: .any)["pocket.room.message.126"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the message with twelve photos is there")
        let replying = app.descendants(matching: .any)["pocket.room.composer.replying"]
        let firstSite = app.buttons["site-1.jpg, 1 of 12"]
        XCTAssertTrue(firstSite.waitForExistence(timeout: 10), "its strip starts at its first photo")
        var lifts = 0
        while !inSight(firstSite), lifts < 3 {
            app.swipeUp(velocity: .slow)
            lifts += 1
        }
        XCTAssertTrue(inSight(firstSite), "the strip's first photo is in sight, nothing over it")
        let strip = row.descendants(matching: .any)["pocket.room.attachment.strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "the strip is there")
        dragStripForwardThenBack(strip, photos: "site", in: app, opened: replying, place: "room")

        // In the thread: its reply's strip.
        let open = row.buttons["pocket.room.openThread"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "the message has its reply")
        open.tap()
        let firstSide = app.buttons["side-1.jpg, 1 of 12"]
        XCTAssertTrue(firstSide.waitForExistence(timeout: 20), "the thread opened on the reply with twelve photos")
        // The room's strip is still there behind the thread: the reply's is the one holding its photos.
        let replyStrip = app.descendants(matching: .any).matching(identifier: "pocket.room.attachment.strip")
            .allElementsBoundByIndex
            .first { $0.buttons["side-1.jpg, 1 of 12"].exists }
        let threadStrip = try XCTUnwrap(replyStrip, "the reply's strip is there")
        XCTAssertTrue(inSight(firstSide), "the reply's first photo is in sight, nothing over it")
        let answering = app.staticTexts["Replying to build-agent"]
        dragStripForwardThenBack(threadStrip, photos: "side", in: app, opened: answering, place: "thread")

        // The check can fail: a swipe right on the reply's words answers it.
        let replyWords = app.staticTexts["Twelve more from the other side."]
        XCTAssertTrue(replyWords.waitForExistence(timeout: 5), "the reply's words are there")
        drag(replyWords, from: 0.1, by: 160, velocity: .slow)
        XCTAssertTrue(answering.waitForExistence(timeout: 5), "a swipe right on the reply's words answers it (the control)")
        log("thread control: answering=\(answering.exists)")
        shot("thread-control-answer")
        let stop = app.buttons["Stop replying to build-agent"]
        if stop.exists { stop.tap() }
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the thread can be closed")
        done.tap()

        // And in the room: a swipe right on the message's words opens a reply.
        let words = row.staticTexts["Twelve photos from the site walk."]
        XCTAssertTrue(words.waitForExistence(timeout: 10), "the message's words are there")
        XCTAssertTrue(inSight(words), "the message's words are in sight")
        drag(words, from: 0.1, by: 160, velocity: .slow)
        XCTAssertTrue(replying.waitForExistence(timeout: 5), "a swipe right on the words opens a reply (the control)")
        log("room control: replying=\(replying.exists)")
        shot("room-control-reply")
    }

    /// Scrolls the strip of `<photos>-1.jpg` to `<photos>-12.jpg` two drags forward (the first photo goes, a later one
    /// comes into sight, the strip still in sight), then back to its first photo with a slow drag, a fast one and a slow
    /// one, checking after each drag back that no reply opened; at the end the first photo is in sight again.
    private func dragStripForwardThenBack(_ strip: XCUIElement, photos: String, in app: XCUIApplication,
                                          opened: XCUIElement, place: String) {
        let first = app.buttons["\(photos)-1.jpg, 1 of 12"]
        let laterInSight = { (3...12).first { self.inSight(app.buttons["\(photos)-\($0).jpg, \($0) of 12"]) } }
        XCTAssertTrue(inSight(strip), "\(place): the strip is in sight before it is dragged")
        drag(strip, from: 0.85, by: -240, velocity: .slow)
        drag(strip, from: 0.85, by: -240, velocity: .slow)
        sleep(1)
        let later = laterInSight()
        log("\(place) forward: firstInSight=\(inSight(first)) laterInSight=\(later.map { String($0) } ?? "none") "
            + "stripInSight=\(inSight(strip)) opened=\(opened.exists)")
        XCTAssertTrue(inSight(strip), "\(place): the strip is still in sight after scrolling it")
        XCTAssertFalse(inSight(first), "\(place): the strip scrolled forward, away from its first photo")
        XCTAssertNotNil(later, "\(place): a later photo (3 to 12) came into sight")
        shot("\(place)-strip-forward")
        log("\(place) photos before the drags back: \(places(photos, in: app))")
        for (index, velocity) in [XCUIGestureVelocity.slow, .fast, .slow].enumerated() {
            drag(strip, from: 0.15, by: 260, velocity: velocity)
            sleep(1)
            log("\(place) drag back \(index + 1): opened=\(opened.exists) firstInSight=\(inSight(first)) "
                + "photos: \(places(photos, in: app))")
            XCTAssertFalse(opened.exists, "\(place): dragging the strip back (drag \(index + 1)) does not open a reply")
        }
        XCTAssertTrue(inSight(first), "\(place): the strip is back at its first photo")
        shot("\(place)-strip-back")
    }

    private func drag(_ element: XCUIElement, from x: CGFloat, by dx: CGFloat, velocity: XCUIGestureVelocity) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: dx, dy: 0)), withVelocity: velocity,
                    thenHoldForDuration: 0.05)
    }

    /// Where each photo of the strip that is built sits on the screen: "<n>@<left edge>", so a log shows whether a drag
    /// moved the strip (even under the keyboard, which hides it from a tap but not from its frame).
    private func places(_ photos: String, in app: XCUIApplication) -> String {
        (1...12).compactMap { number -> String? in
            let photo = app.buttons["\(photos)-\(number).jpg, \(number) of 12"]
            return photo.exists ? "\(number)@\(Int(photo.frame.minX))" : nil
        }.joined(separator: " ")
    }

    /// There, and with nothing over it (a photo the lazy strip has not built is not there at all).
    private func inSight(_ element: XCUIElement) -> Bool {
        element.exists && element.isHittable
    }

    private func log(_ line: String) {
        print("STRIPSWIPE \(line)")
    }

    /// Saves a screenshot where `CAL_SHOT_DIR` points (set by the runner), for the review evidence.
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CAL_SHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("strip-swipe-\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
#endif
