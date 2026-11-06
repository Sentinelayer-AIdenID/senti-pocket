#if os(iOS) && canImport(XCTest)
import XCTest

/// The call screen over a room (Carter, 11-05), on the preview room's scripted call.
final class CallScreenUITests: XCTestCase {
    /// A call answered while the room's box is being written in: the call comes up and no keyboard shows over it. One
    /// came up with no box to type in and could not be put away.
    func test_no_keyboard_shows_while_a_call_is_up() {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRoomPreview", "-PocketCallScreenPreview"]
        app.launch()
        let box = app.descendants(matching: .any)["pocket.room.composer"]
        XCTAssertTrue(box.waitForExistence(timeout: 30))
        box.tap()
        let panel = app.descendants(matching: .any)["pocket.voice.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "the call comes up as the keyboard does")
        let noKeyboard = NSPredicate(format: "count == 0")
        expectation(for: noKeyboard, evaluatedWith: app.keyboards, handler: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.keyboards.count, 0, "no keyboard over the call")

        // Using the call screen brings none back.
        app.descendants(matching: .any)["pocket.voice.speaker"].tap()
        app.descendants(matching: .any)["pocket.voice.mute"].tap()
        panel.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(app.keyboards.count, 0, "still none")
    }

    /// The Speaker button says whether it is on and switches; the agent the turn went to is named.
    func test_the_speaker_button_reads_on_or_off_and_the_answering_agent_is_named() {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRoomPreview", "-PocketCallScreenNow"]
        app.launch()
        let speaker = app.buttons["pocket.voice.speaker"]
        XCTAssertTrue(speaker.waitForExistence(timeout: 30))
        XCTAssertEqual(speaker.label, "Speaker")
        XCTAssertEqual(speaker.value as? String, "On")
        speaker.tap()
        XCTAssertEqual(speaker.value as? String, "Off", "VoiceOver hears it is off")
        let answering = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Reviewer is answering")).firstMatch
        XCTAssertTrue(answering.exists, "who the turn went to is named")
    }
}
#endif
