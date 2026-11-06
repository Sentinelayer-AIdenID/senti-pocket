#if os(iOS) && canImport(XCTest)
import XCTest

/// The room's ⋯ menu has Calendar while drafting is on, and it opens the room's month (the preview room with made-up
/// events; `-PocketCalendarInRoom` gives it the entry). Each day reads to VoiceOver as "Wednesday, November 4, 2 events".
final class CalendarEntryUITests: XCTestCase {
    func test_calendar_is_in_the_rooms_more_menu_and_opens_the_month() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRoomPreview", "-PocketCalendarInRoom"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["pocket.room.composer"].waitForExistence(timeout: 60),
                      "the preview room opened")

        let more = app.navigationBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 20), "the room has a ⋯ menu\n\(app.navigationBars.debugDescription)")
        more.tap()
        let entry = app.buttons["Calendar"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Calendar is in the ⋯ menu\n\(app.debugDescription)")
        shot("menu")
        entry.tap()

        let month = app.staticTexts["pocket.calendar.month"]
        XCTAssertTrue(month.waitForExistence(timeout: 20), "the calendar opened on a month")
        let days = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pocket.calendar.day.'"))
        XCTAssertGreaterThanOrEqual(days.count, 28, "every day of the month is a button")
        let label = days.element(boundBy: 0).label
        XCTAssertNotNil(label.range(of: #"^[A-Z][a-z]+day, [A-Z][a-z]+ 1, (no events|1 event|\d+ events)$"#,
                                    options: .regularExpression),
                        "VoiceOver reads the day, its date and its events: \(label)")
        shot("calendar")
    }

    /// Review P3 (#330): VoiceOver reads an event with its notes, and its link is a button of its own, reached and
    /// read apart from the row (not folded into one combined element). The preview's November 12 has a dinner with
    /// notes and a rehearsal with a link.
    func test_an_event_reads_its_notes_and_its_link_is_a_button_of_its_own() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketCalendarPreview", "-PocketCalendarStage", "day"]
        app.launch()

        // Queried as a set, so a link folded into a combined row fails this test's own assertions, not the query.
        let links = app.buttons.matching(identifier: "pocket.calendar.event.p4.link")
        let link = links.firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 60), "the link is its own button\n\(app.debugDescription)")
        XCTAssertEqual(links.count, 1, "the link is its own button, one element apart from its row")
        XCTAssertEqual(link.label, "Open link for Launch rehearsal", "the link is its own button, read as itself")
        var swipes = 0
        while !link.isHittable, swipes < 8 {
            app.swipeUp(velocity: .slow)
            swipes += 1
        }
        XCTAssertTrue(link.isHittable, "the link can be reached on its own")

        let rehearsal = app.descendants(matching: .any).matching(identifier: "pocket.calendar.event.p4").firstMatch
        XCTAssertTrue(rehearsal.exists)
        XCTAssertTrue(rehearsal.label.hasPrefix("Launch rehearsal, "), rehearsal.label)
        XCTAssertFalse(rehearsal.label.contains("Open link"), "the link is not read inside the row: \(rehearsal.label)")
        let dinner = app.descendants(matching: .any).matching(identifier: "pocket.calendar.event.p6").firstMatch
        XCTAssertTrue(dinner.exists)
        XCTAssertTrue(dinner.label.hasSuffix("Table for eight."), "the row reads its notes: \(dinner.label)")
        shot("day-events")
    }

    /// Follow-up to #330: at the largest text size, Subscribe (no link kept) and Reset each ask in a sheet whose message
    /// can be seen whole on the screen at once (scrolled to it if need be). As confirmation dialogs they were narrow
    /// popovers that showed a line or two of it.
    func test_the_link_questions_present_as_sheets_that_show_their_whole_message_at_ax5() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketCalendarPreview", "-PocketCalendarStage", "subscribe",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let screen = app.windows.firstMatch.frame
        for (row, id) in [("settings.calendar.subscribe", "settings.calendar.newLink"),
                          ("settings.calendar.reset", "settings.calendar.resetLink")] {
            let button = app.buttons[row]
            var swipes = 0
            while !(button.exists && button.isHittable), swipes < 14 {
                app.swipeUp(velocity: .slow)
                swipes += 1
            }
            XCTAssertTrue(button.isHittable, "\(row) can be reached")
            button.tap()
            let message = app.staticTexts["\(id).message"]
            XCTAssertTrue(message.waitForExistence(timeout: 10), "\(id): the question shows its message in a sheet")
            var scrolls = 0
            while message.exists, !screen.contains(message.frame), scrolls < 4 {
                app.swipeUp(velocity: .slow)
                scrolls += 1
            }
            print("CALAX5UI \(id) message \(message.frame) screen \(screen) scrolls \(scrolls)")
            XCTAssertTrue(screen.contains(message.frame), "\(id): the whole message can be seen on the screen at once")
            shot("question-\(id)-ax5")
            let cancel = app.buttons["\(id).cancel"]
            if cancel.exists { cancel.tap() }
            sleep(1)
        }
    }

    /// Saves a screenshot where `CAL_SHOT_DIR` points (set by the runner), for the review evidence.
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CAL_SHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("calendar-entry-\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
#endif
