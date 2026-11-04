#if os(iOS) && canImport(XCTest)
import XCTest

/// An agent chat that feels alive, on screen (Carter, #61655, #61679, #61720): the Working row of an agent working now
/// opens to every step and folds again; a finished one says how long it worked; Senti thinks at the bottom with its
/// avatar and a phrase; your message the agent read says "Seen"; a crowd of agents is three rows and "+1 working"; a new
/// room opens with one of its lines. With `SHOTS_DIR` set (`TEST_RUNNER_SHOTS_DIR` from xcodebuild) each step is also
/// saved there as a picture, named with `SHOTS_PREFIX`.
final class AgentChatAliveUITests: XCTestCase {
    private func launch(_ argument: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [argument]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func shoot(_ name: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["SHOTS_DIR"], !directory.isEmpty else { return }
        let prefix = environment["SHOTS_PREFIX"].map { $0 + "-" } ?? ""
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(prefix)\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    func test_working_rows_open_and_fold_and_senti_thinks() {
        let app = launch("-PocketAgentChatPreview")
        let live = element(app, "pocket.room.working.506.build-agent")
        XCTAssertTrue(live.waitForExistence(timeout: 30), "the box working on your newest message has its row")
        XCTAssertEqual(live.label, "build-agent is working: Writing the fix so retryCount resets only after success")
        let senti = element(app, "pocket.room.sentiThinking")
        XCTAssertTrue(senti.waitForExistence(timeout: 10), "Senti is thinking at the bottom")
        XCTAssertEqual(senti.label, "Senti is thinking", "one label, never each phrase")
        // A reader at the bottom sees it come: the room follows it above the composer.
        let composer = element(app, "pocket.room.composer")
        let shown = Date().addingTimeInterval(5)
        while senti.frame.maxY > composer.frame.minY + 1, Date() < shown {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertLessThanOrEqual(senti.frame.maxY, composer.frame.minY + 1,
                                 "Senti's line is above the composer (line \(senti.frame), composer \(composer.frame))")
        XCTAssertTrue(element(app, "pocket.room.seen").waitForExistence(timeout: 10), "the box read your message: Seen")
        shoot("live")
        // A new phrase every 2 s keeps one line: the room below the reader never grows with it.
        let sentiHeight = senti.frame.height
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        XCTAssertEqual(senti.frame.height, sentiHeight, accuracy: 0.5, "the next phrase is the same height")

        let steps = element(app, "pocket.room.working.506.build-agent.steps")
        XCTAssertFalse(steps.exists)
        live.tap()
        XCTAssertTrue(steps.waitForExistence(timeout: 5), "a tap shows every step")
        XCTAssertTrue(steps.label.contains("Reading the retry counter code"), steps.label)
        XCTAssertTrue(steps.label.contains("Running the onboarding tests on the simulator"), steps.label)
        shoot("expanded")
        live.tap()
        let deadline = Date().addingTimeInterval(5)
        while steps.exists, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertFalse(steps.exists, "a second tap folds them")

        let done = element(app, "pocket.room.working.501.build-agent")
        if !done.isHittable { app.swipeDown() }
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertEqual(done.label, "build-agent worked for 2 minutes 14 seconds", "finished: how long it worked")
        XCTAssertEqual(done.frame.height, live.frame.height, accuracy: 0.5,
                       "a row is one line live or finished: finishing moves nothing below or above it")
        shoot("done")
        done.tap()
        XCTAssertTrue(element(app, "pocket.room.working.501.build-agent.steps").waitForExistence(timeout: 5),
                      "a finished row keeps its steps")
        shoot("done-expanded")
    }

    func test_a_crowd_of_agents_is_three_rows_then_how_many_more() {
        let app = launch("-PocketAgentChatCrowd")
        let more = element(app, "pocket.room.working.506.more")
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        XCTAssertEqual(more.label, "+1 working")
        XCTAssertTrue(element(app, "pocket.room.working.506.test-agent").exists, "newest first")
        XCTAssertTrue(element(app, "pocket.room.working.506.review-agent").exists)
        XCTAssertTrue(element(app, "pocket.room.working.506.build-agent").exists)
        XCTAssertFalse(element(app, "pocket.room.working.506.docs-agent").exists, "the fourth waits behind +1")
        shoot("crowd")
        more.tap()
        XCTAssertTrue(element(app, "pocket.room.working.506.docs-agent").waitForExistence(timeout: 5))
    }

    func test_a_new_room_opens_with_one_of_its_lines() {
        let app = launch("-PocketRoomIntroPreview")
        let intro = element(app, "pocket.room.intro")
        XCTAssertTrue(intro.waitForExistence(timeout: 30))
        XCTAssertFalse(intro.label.isEmpty)
        XCTAssertFalse(app.staticTexts["No messages yet"].exists)
        shoot("intro")
        let first = intro.label
        app.terminate()
        let again = launch("-PocketRoomIntroPreview")
        XCTAssertTrue(element(again, "pocket.room.intro").waitForExistence(timeout: 30))
        XCTAssertEqual(element(again, "pocket.room.intro").label, first, "the same room, the same day: the same line")
    }
}
#endif
