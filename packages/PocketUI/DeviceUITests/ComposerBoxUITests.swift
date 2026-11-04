#if os(iOS) && canImport(XCTest)
import XCTest

/// The room's writing box, measured on screen (review of the composer fix): one line empty, growing with the text to
/// six lines at most, and one line again once the message is sent.
final class ComposerBoxUITests: XCTestCase {
    func test_the_box_grows_to_six_lines_and_is_one_line_after_a_send() {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRoomPreview"]
        app.launch()
        let box = app.descendants(matching: .any)["pocket.room.composer"]
        XCTAssertTrue(box.waitForExistence(timeout: 30))
        let oneLine = box.frame.height
        box.tap()
        box.typeText(String(repeating: "A longer note for the room, line after line. ", count: 8))
        let grown = box.frame.height
        XCTAssertGreaterThan(grown, oneLine * 3, "it grew with the text")
        XCTAssertLessThanOrEqual(grown, oneLine * 6 + 2, "six lines at most")
        app.descendants(matching: .any)["pocket.room.send"].tap()
        let deadline = Date().addingTimeInterval(5)
        while box.frame.height > oneLine + 1, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(box.frame.height, oneLine, accuracy: 1, "one line again after the send")
        XCTAssertEqual((box.value as? String) ?? "", "", "and empty")
    }
}
#endif
