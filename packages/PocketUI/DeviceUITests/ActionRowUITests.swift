#if os(iOS) && canImport(XCTest)
import XCTest

/// Ticket 52065281: at the largest text size a room row's action buttons fold into its More menu. VoiceOver reads the
/// menu as "More actions", and opening it shows the row's options, each a button VoiceOver reads by name.
final class ActionRowUITests: XCTestCase {
    func test_at_the_largest_text_size_the_more_menu_holds_the_rows_options() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRoomPreview",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["pocket.room.composer"].waitForExistence(timeout: 60),
                      "the preview room opened")
        let mores = app.buttons.matching(NSPredicate(format: "label == %@", "More actions"))
        XCTAssertTrue(mores.firstMatch.waitForExistence(timeout: 20), "a row's More menu is there, read as More actions")
        let more = try XCTUnwrap(mores.allElementsBoundByIndex.last { $0.exists && $0.isHittable },
                                 "a More menu is in sight")
        print("ACTIONROWUI more=\(more.frame) mores=\(mores.count)")
        shot("ax5-row")
        more.tap()
        let copy = app.buttons["Copy text"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the menu holds Copy text")
        let options = ["Reply", "Open thread", "Copy text", "Listen", "Like", "Dislike", "Add reaction", "Pin"]
            .filter { app.buttons[$0].exists }
        print("ACTIONROWUI menu=\(options)")
        XCTAssertTrue(options.contains("Reply") || options.contains("Open thread"), "and the reply")
        XCTAssertTrue(options.contains("Listen"), "and Listen")
        shot("ax5-more-menu")
    }

    /// Saves a screenshot where `CAL_SHOT_DIR` points (set by the runner), for the review evidence.
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CAL_SHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("action-row-\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
#endif
