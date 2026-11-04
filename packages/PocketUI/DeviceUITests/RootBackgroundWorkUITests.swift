#if os(iOS) && canImport(XCTest)
import CoreFoundation
import UIKit
import XCTest

/// The signed-in root with its side panel, on the app's `-PocketRootPreview` data (made-up rooms; no network), driven
/// through the sequences that froze build 2026110308 on a phone, and read the way an accessibility client reads it.
///
/// A UI test reads the app through its accessibility tree: each query below is what VoiceOver, Voice Control, Switch
/// Control, Full Keyboard Access or the system reading the screen asks of the app. Each read's time is printed with a
/// BGAUDIT prefix, and no read may take `longestRead` or more. The app's own freeze watch writes any stall over 1.5 s,
/// which the lane reads after the run.
final class RootBackgroundWorkUITests: XCTestCase {
    private static let openDrawer = "com.plexaura.sentipocket.preview.root.drawer.open"
    private static let closeDrawer = "com.plexaura.sentipocket.preview.root.drawer.close"
    /// The longest one read of the app's accessibility tree may take.
    private static let longestRead: TimeInterval = 1

    override func setUp() {
        continueAfterFailure = true
    }

    /// Reading a few lines up a busy room (three posts a second): every read of the screen answers within a second.
    func test_reading_up_a_busy_room_answers_each_accessibility_read_within_a_second() throws {
        let app = launch(room: "long", "-PocketRootStream", "3")
        let screen = app.descendants(matching: .any)["pocket.room.screen"]
        // A few lines up, away from the bottom, while the room keeps arriving below.
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        print("BGAUDIT scrolled up")
        if ProcessInfo.processInfo.environment["BGAUDIT_NO_READS"] != nil {
            // The same burst with nothing reading the screen, for the lane to measure the app alone.
            pause(30)
            print("BGAUDIT quiet burst done")
            return
        }
        var reads: [TimeInterval] = []
        for index in 1...6 {
            reads.append(read("busy room read \(index)") { _ = app.debugDescription.count })
            pause(1)
        }
        let longest = reads.max() ?? 0
        print(String(format: "BGAUDIT busy room longest read %.2f s", longest))
        XCTAssertLessThan(longest, Self.longestRead, "an accessibility read of a busy room answers within a second")
    }

    /// #61725's steps: a room of 165 rows, read up to its top, Jump to latest from up the room (the room keeps its newest
    /// 60 rows), two sends, a quiet spell, then the side panel opened and closed with the screen read each time.
    func test_side_panel_over_a_room_just_trimmed_for_the_jump_down() throws {
        let app = launch(room: "mid")
        let screen = app.descendants(matching: .any)["pocket.room.screen"]
        for _ in 0..<14 {
            if app.descendants(matching: .any)["pocket.room.message.1"].exists { break }
            screen.swipeDown(velocity: .fast)
        }
        let jump = app.descendants(matching: .any)["pocket.room.jumpToLatest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 10), "the arrow shows up the room")
        read("jump down") { jump.tap() }
        pause(3)
        send(app, "Two words.")
        send(app, "And two more.")
        pause(Self.quietSpell)
        if ProcessInfo.processInfo.environment["BGAUDIT_TOGGLES_ONLY"] != nil {
            // The side panel opened and closed ten times with nothing reading the screen, for the lane to measure the
            // app alone (1.5 s open, 1.5 s closed).
            print("BGAUDIT toggles start")
            for _ in 1...10 {
                Self.post(Self.openDrawer)
                pause(1.5)
                Self.post(Self.closeDrawer)
                pause(1.5)
            }
            print("BGAUDIT toggles end")
            pause(3)
            return
        }
        var reads: [TimeInterval] = []
        for round in 1...5 {
            Self.post(Self.openDrawer)
            reads.append(read("panel open \(round)") {
                _ = app.descendants(matching: .any)["pocket.drawer"].waitForExistence(timeout: 60)
            })
            reads.append(read("whole tree, panel open \(round)") { _ = app.debugDescription.count })
            Self.post(Self.closeDrawer)
            pause(1.5)
            reads.append(read("whole tree, panel closed \(round)") { _ = app.debugDescription.count })
        }
        let longest = reads.max() ?? 0
        print(String(format: "BGAUDIT side panel longest read %.2f s", longest))
        XCTAssertLessThan(longest, Self.longestRead, "the screen answers as the side panel opens and closes")
    }

    /// #61648's steps: a room picked from the side panel, then a quiet spell while the bell's and Waiting on you's reads
    /// land, the screen read after each.
    func test_room_picked_from_the_side_panel_then_the_reads_land() throws {
        let app = launch(room: "long")
        Self.post(Self.openDrawer)
        let row = app.descendants(matching: .any)["pocket.drawer.room.room-mid"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the room is in the side panel")
        read("pick a room") { row.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["pocket.room.message.165"].waitForExistence(timeout: 30))
        var reads: [TimeInterval] = []
        for index in 1...8 {
            pause(5)
            reads.append(read("after the pick \(index)") { _ = app.debugDescription.count })
        }
        let longest = reads.max() ?? 0
        print(String(format: "BGAUDIT picked room longest read %.2f s", longest))
        XCTAssertLessThan(longest, Self.longestRead, "the screen answers while the bell and Waiting on you read again")
    }

    // MARK: - Helpers

    /// The quiet spell before the side panel opens; the phone's was 70 s.
    private static var quietSpell: TimeInterval {
        Double(ProcessInfo.processInfo.environment["BGAUDIT_QUIET"] ?? "") ?? 20
    }

    private func launch(room: String, _ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketRootPreview", "-PocketRootRoom", room] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["pocket.room.screen"].waitForExistence(timeout: 90), "the room opened")
        pause(5)
        return app
    }

    private func send(_ app: XCUIApplication, _ text: String) {
        let composer = app.descendants(matching: .any)["pocket.room.composer"]
        guard composer.waitForExistence(timeout: 10) else { return XCTFail("no composer") }
        composer.tap()
        composer.typeText(text)
        app.descendants(matching: .any)["pocket.room.send"].tap()
        pause(1)
    }

    @discardableResult
    private func read(_ step: String, _ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        let seconds = Date().timeIntervalSince(start)
        print(String(format: "BGAUDIT %@ %.2f s", step, seconds))
        return seconds
    }

    private static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
#endif
