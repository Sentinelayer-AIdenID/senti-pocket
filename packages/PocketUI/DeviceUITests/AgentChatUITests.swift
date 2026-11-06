#if os(iOS) && canImport(XCTest)
import XCTest

/// A chat made for one agent, measured on screen (Carter, #61655 and #61679): it is called what it is for, the people
/// ring at the top never covers the first message, what the agent says shows in full without the relay's signature,
/// and the composer says how to reach the agent.
final class AgentChatUITests: XCTestCase {
    func test_an_agent_chat_shows_its_first_message_below_the_ring_and_the_agent_in_full() {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketAgentChatPreview"]
        app.launch()

        let ring = app.descendants(matching: .any)["pocket.room.presence"]
        XCTAssertTrue(ring.waitForExistence(timeout: 30), "who is here shows")
        // At the top of the room, where its first message is.
        let list = app.scrollViews.firstMatch
        for _ in 0..<3 { list.swipeDown() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let first = app.descendants(matching: .any)["pocket.room.message.501"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), "the first message shows")
        XCTAssertGreaterThanOrEqual(first.frame.minY, ring.frame.maxY - 0.5,
                                    "the first message starts below the ring (ring \(ring.frame), message \(first.frame))")

        let post = app.descendants(matching: .any)["pocket.room.message.503"]
        XCTAssertTrue(post.waitForExistence(timeout: 10), "the agent's post is a full message, not a quiet line")
        XCTAssertFalse(app.descendants(matching: .any)["pocket.room.quiet.00000000-0000-4000-8000-000000000503"].exists)
        let signed = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "⟂ speech"))
        XCTAssertEqual(signed.count, 0, "the relay's signature line stays hidden")

        let box = app.descendants(matching: .any)["pocket.room.composer"]
        XCTAssertTrue(box.waitForExistence(timeout: 10))
        XCTAssertEqual(box.label, "@name to reach an agent", "the composer says how to reach the agent")

        XCTAssertFalse(app.navigationBars.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "New agent"))
            .firstMatch.exists, "the chat is not called New agent")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "build-agent · "))
            .firstMatch.exists, "it is called for its agent and job")
    }
}
#endif
