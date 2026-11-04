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

    /// Saves a screenshot where `CAL_SHOT_DIR` points (set by the runner), for the review evidence.
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CAL_SHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("calendar-entry-\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
#endif
