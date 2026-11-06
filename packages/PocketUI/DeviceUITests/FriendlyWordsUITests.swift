#if os(iOS) && canImport(XCTest)
import XCTest

/// Plain words on the first screens a new person meets (Carter, 2026-11-06, ticket 693f0cc5), on the root preview's
/// made-up rooms, which have no boxes: the list is Chats, the side panel says New chat and Search chats; a room's bar
/// reads "Room info" and "Talk"; Room info starts with the people and says nothing about boxes; the
/// ring of who is here never covers the start of the room, at the default text size or the largest; the speech model is
/// only under Settings' Advanced; and Activity says what happened and who did it, with no server numbers, tokens or ids.
final class FriendlyWordsUITests: XCTestCase {
    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(room: String = "none", largest: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // -PocketRootCreates: the preview can make a chat, so the side panel offers New chat.
        app.launchArguments = ["-PocketRootPreview", "-PocketRootCreates", "-PocketRootRoom", room]
            + (largest ? Self.largestText : []) + extra
        app.launch()
        return app
    }

    /// Every label on screen: the texts, and the buttons (a row's words are often its button's label).
    private func words(in element: XCUIElement) -> [String] {
        (element.staticTexts.allElementsBoundByIndex + element.buttons.allElementsBoundByIndex).map(\.label)
    }

    private func openSidePanel(_ app: XCUIApplication) {
        let drawer = app.buttons["pocket.drawer.open"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 60), "the signed-in root came up\n\(app.debugDescription)")
        drawer.tap()
        XCTAssertTrue(app.buttons["pocket.drawer.settings"].waitForExistence(timeout: 20), "the side panel opened")
    }

    func test_the_first_screens_say_chats() {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 60), "the list is Chats\n\(app.debugDescription)")
        for word in words(in: app) {
            XCTAssertFalse(word.localizedCaseInsensitiveContains("session"), "the list still says sessions: \(word)")
        }
        let drawer = app.buttons["pocket.drawer.open"]
        XCTAssertTrue(drawer.label.hasPrefix("Chats and settings"), "the side panel button to VoiceOver: \(drawer.label)")
        openSidePanel(app)
        let newChat = app.buttons["pocket.drawer.newRoom"]
        XCTAssertTrue(newChat.exists)
        XCTAssertEqual(newChat.label, "New chat")
        XCTAssertTrue(app.staticTexts["Chats"].exists, "the side panel's list is Chats\n\(app.debugDescription)")
        XCTAssertEqual(app.textFields["pocket.drawer.search"].placeholderValue, "Search chats")
    }

    func test_the_speech_model_is_only_under_advanced() {
        let app = launch()
        openSidePanel(app)
        app.buttons["pocket.drawer.settings"].tap()
        let signOut = app.buttons["settings.account.sign-out"]
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
        // Down the whole first screen: no speech-model row anywhere on it.
        var swipes = 0
        while true {
            XCTAssertFalse(app.descendants(matching: .any)["settings.whisper.status"].exists,
                           "the speech model is on Settings' first screen")
            XCTAssertFalse(app.buttons["settings.whisper.choose-file"].exists)
            if (signOut.exists && signOut.isHittable) || swipes >= 16 { break }
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(signOut.isHittable, "came to the end of Settings\n\(app.debugDescription)")
        let advanced = app.buttons["settings.advanced"]
        XCTAssertTrue(advanced.exists, "Settings has Advanced")
        XCTAssertEqual(advanced.label, "Advanced")
        advanced.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.whisper.status"].waitForExistence(timeout: 10),
                      "the speech model is under Advanced\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["settings.whisper.choose-file"].exists)
    }

    func test_a_rooms_bar_says_room_info_and_room_info_has_no_box_words() {
        let app = launch(room: "mid")
        XCTAssertTrue(app.descendants(matching: .any)["pocket.room.composer"].waitForExistence(timeout: 60), "the room opened")
        let info = app.buttons["pocket.room.flight"]
        XCTAssertTrue(info.waitForExistence(timeout: 20), app.navigationBars.debugDescription)
        XCTAssertEqual(info.label, "Room info")
        // The preview's rooms can talk (-PocketRootCreates): the button is there, and says what it shows.
        let talk = app.buttons["pocket.room.talk"]
        XCTAssertTrue(talk.waitForExistence(timeout: 10), "no Talk in the bar: \(app.navigationBars.debugDescription)")
        XCTAssertEqual(talk.label, "Talk")
        info.tap()
        let panel = app.descendants(matching: .any)["pocket.flight"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        XCTAssertTrue(panel.staticTexts["Room info"].exists)
        let read = words(in: panel)
        for word in read {
            XCTAssertFalse(word.localizedCaseInsensitiveContains("box"), "box words for a person without boxes: \(word)")
            XCTAssertFalse(word.localizedCaseInsensitiveContains("flight"), word)
            XCTAssertFalse(word.contains("now ago"), word)
        }
        let people = panel.staticTexts["People"]
        XCTAssertTrue(people.exists, "the room's people are listed: \(read)")
        let agents = panel.staticTexts["Agents"]
        if agents.exists { XCTAssertLessThan(people.frame.minY, agents.frame.minY, "the people come first") }
    }

    func test_the_ring_never_covers_the_start_of_the_room() {
        for largest in [false, true] {
            let app = launch(room: "room-000", largest: largest)
            XCTAssertTrue(app.descendants(matching: .any)["pocket.room.composer"].waitForExistence(timeout: 60))
            let start = app.staticTexts["pocket.room.start"]
            var swipes = 0
            while !(start.exists && start.isHittable), swipes < 8 {
                app.swipeDown(velocity: .fast)
                swipes += 1
            }
            XCTAssertTrue(start.exists, "came to the start of the room\n\(app.debugDescription)")
            let ring = app.descendants(matching: .any)["pocket.room.presence"]
            XCTAssertTrue(ring.waitForExistence(timeout: 20), "who is here shows")
            XCTAssertFalse(ring.frame.intersects(start.frame),
                           "the ring covers the start of the room (\(largest ? "AX5" : "default size")): ring \(ring.frame), start \(start.frame)")
            app.terminate()
        }
    }

    func test_activity_says_what_happened_with_no_server_numbers() {
        let app = launch(room: "mid", extra: ["-PocketRootActivity"])
        XCTAssertTrue(app.descendants(matching: .any)["pocket.room.composer"].waitForExistence(timeout: 60))
        openSidePanel(app)
        app.buttons["pocket.drawer.activity"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["pocket.activity.screen"].waitForExistence(timeout: 20),
                      "Activity opened\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Message")).firstMatch
                        .waitForExistence(timeout: 20), "the preview's events came\n\(app.debugDescription)")
        let read = words(in: app)
        XCTAssertTrue(read.contains { $0.contains("Acknowledged") }, "\(read)")
        XCTAssertTrue(read.contains { $0.contains("Update") }, "a type the app does not know reads as an update: \(read)")
        XCTAssertTrue(read.contains { $0.contains("A person") }, "a person known only by a Google account's id: \(read)")
        XCTAssertTrue(read.contains { $0.contains("review-agent") }, "an agent by its id: \(read)")
        for word in read {
            XCTAssertNil(word.range(of: #"#\d"#, options: .regularExpression), "a server number: \(word)")
            XCTAssertFalse(word.contains("_"), "a server token: \(word)")
            XCTAssertFalse(word.localizedCaseInsensitiveContains("human-"), "an id: \(word)")
            XCTAssertNil(word.range(of: "[0-9a-f]{12,}", options: [.regularExpression, .caseInsensitive]), "an id's hex: \(word)")
            XCTAssertFalse(word.contains("nimbus"), "the name an agent gives itself: \(word)")
        }
        XCTAssertEqual(app.buttons["Saved summaries"].label, "Saved summaries")
    }

    /// Pictures of each screen for review, when FRIENDLY_SHOT_DIR is set; the Mac's run sets the appearance, and
    /// FRIENDLY_SHOT_SIZE=ax5 the largest text size. On master (the "before" pictures) a screen it does not have is
    /// pictured as it is there.
    func test_pictures_of_each_screen() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let dir = environment["FRIENDLY_SHOT_DIR"], !dir.isEmpty else { throw XCTSkip("FRIENDLY_SHOT_DIR is not set") }
        let largest = environment["FRIENDLY_SHOT_SIZE"] == "ax5"
        let tag = environment["FRIENDLY_SHOT_TAG"] ?? (largest ? "ax5" : "390")
        func shot(_ name: String) {
            Thread.sleep(forTimeInterval: 1)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("friendly-\(tag)-\(name).png")
            XCTAssertNoThrow(try XCUIScreen.main.screenshot().pngRepresentation.write(to: url))
        }

        var app = launch(largest: largest)
        XCTAssertTrue(app.buttons["pocket.drawer.open"].waitForExistence(timeout: 60))
        shot("1-list")
        openSidePanel(app)
        shot("2-side-panel")
        app.buttons["pocket.drawer.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
        shot("5-settings")
        var swipes = 0
        while !app.buttons["settings.account.sign-out"].isHittable, swipes < 16 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        shot("6-settings-end")
        if app.buttons["settings.advanced"].exists {
            app.buttons["settings.advanced"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["settings.whisper.status"].waitForExistence(timeout: 10))
            shot("7-advanced")
        }
        app.terminate()

        app = launch(room: "mid", largest: largest, extra: ["-PocketRootActivity"])
        XCTAssertTrue(app.descendants(matching: .any)["pocket.room.composer"].waitForExistence(timeout: 60))
        app.buttons["pocket.room.flight"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["pocket.flight"].waitForExistence(timeout: 20))
        shot("4-room-info")
        app.descendants(matching: .any)["pocket.flight.close"].tap()
        openSidePanel(app)
        app.buttons["pocket.drawer.activity"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["pocket.activity.screen"].waitForExistence(timeout: 20))
        shot("8-activity")
        app.terminate()

        // Last, as it is unchanged at the default size: the top of a room of 30 messages, a few swipes up. A slow
        // swipe under load can then cost no other picture.
        app = launch(room: "room-000", largest: largest)
        XCTAssertTrue(app.descendants(matching: .any)["pocket.room.composer"].waitForExistence(timeout: 60))
        let start = app.staticTexts["pocket.room.start"]
        var up = 0
        while !(start.exists && start.isHittable), up < 6 {
            app.swipeDown(velocity: .fast)
            up += 1
        }
        shot("3-room-top")
    }
}
#endif
