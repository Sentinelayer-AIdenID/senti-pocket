#if os(iOS) && canImport(XCTest)
import XCTest

/// Ticket 77fcdd2b: in the room's composer, with words typed and a photo and a PDF in the tray, a tap on the PDF opens
/// it full screen; Remove there takes only it out, and back in the composer the words and the photo are as they were.
/// The preview room's composer starts with both files (`-PocketRoomComposerTrayPreview`).
final class ComposerFileOpenUITests: XCTestCase {
    func test_a_chip_opens_full_screen_and_remove_there_keeps_the_draft_and_the_other_files() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRoomPreview", "-PocketRoomComposerTrayPreview"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["pocket.room.composer"].waitForExistence(timeout: 60),
                      "the preview room opened")
        // Found once the room has opened: before, neither kind of field exists yet.
        let composer = app.textViews["pocket.room.composer"].exists ? app.textViews["pocket.room.composer"]
            : app.textFields["pocket.room.composer"]
        XCTAssertTrue(composer.exists, "the composer is a text view or a text field")
        let photo = app.buttons["Open site.png"]
        let pdf = app.buttons["Open plan.pdf"]
        XCTAssertTrue(pdf.waitForExistence(timeout: 20), "the tray's files are buttons that open them")
        XCTAssertTrue(photo.exists)

        let field = app.descendants(matching: .any)["pocket.room.composer"]
        field.tap()
        field.typeText("Here are the plans")
        let typed = (composer.value as? String) ?? ""
        print("COMPOSERFILE typed=\(typed)")
        shot("tray-before")

        pdf.tap()
        let remove = app.buttons["pocket.room.media.viewer.remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "the PDF opens full screen, with Remove")
        XCTAssertEqual(remove.label, "Remove plan.pdf")
        shot("viewer-pdf")
        remove.tap()

        XCTAssertTrue(field.waitForExistence(timeout: 10), "back in the composer")
        XCTAssertFalse(app.buttons["Open plan.pdf"].waitForExistence(timeout: 2), "the PDF is out of the tray")
        XCTAssertTrue(app.buttons["Open site.png"].exists, "the photo stays")
        let after = (composer.value as? String) ?? ""
        print("COMPOSERFILE after=\(after)")
        XCTAssertTrue(after.contains("Here are the plans"), "the words typed stay: \(after)")
        shot("tray-after")

        // Done changes nothing.
        app.buttons["Open site.png"].tap()
        let done = app.buttons["pocket.room.media.viewer.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the photo opens full screen")
        shot("viewer-photo")
        done.tap()
        XCTAssertTrue(app.buttons["Open site.png"].waitForExistence(timeout: 10), "the photo is still in the tray")
        XCTAssertTrue(((composer.value as? String) ?? "").contains("Here are the plans"))
    }

    /// The upload ring sits over the chip's middle while it uploads (the preview's uploads never finish): a tap on the
    /// chip's centre still opens it.
    func test_tapping_a_chips_centre_while_its_ring_shows_opens_it() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRoomPreview", "-PocketRoomComposerTrayPreview"]
        app.launch()
        let photo = app.buttons["Open site.png"]
        XCTAssertTrue(photo.waitForExistence(timeout: 60), "the tray's photo is there")
        let ring = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR label == %@",
                                                                         "Uploading", "Getting ready"))
        XCTAssertTrue(ring.firstMatch.waitForExistence(timeout: 20), "its ring shows: it is still on its way")
        print("COMPOSERFILE ring=\(ring.firstMatch.label) frame=\(ring.firstMatch.frame) chip=\(photo.frame)")
        shot("ring-before-tap")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.buttons["pocket.room.media.viewer.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "a tap on the ring's middle opens the photo")
        shot("ring-tap-opened")
        done.tap()
    }

    /// Saves a screenshot where `CAL_SHOT_DIR` points (set by the runner), for the review evidence.
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CAL_SHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("composer-file-\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
#endif
