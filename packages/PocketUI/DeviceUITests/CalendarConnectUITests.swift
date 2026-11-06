#if os(iOS) && canImport(XCTest)
import XCTest

/// Ticket 9583d41e, the device checks of the privacy review: Pocket's own calendar on the simulator's real calendar
/// (calendar access granted to the app beforehand), with a made-up event that has notes and a link, and every request
/// to the device-events routes recorded by the app's stand-in server (`-PocketCalendarStage connect`). Nothing is sent
/// before the switch is on; a send carries only the contract's keys, never the notes or the link; edits inside a
/// minute make at most one send a minute; off sends DELETE; and the app holds one EventKit store.
final class CalendarConnectUITests: XCTestCase {
    private static let bodyKeys: Set<String> = ["source", "windowStart", "windowEnd", "events"]
    private static let eventKeys: Set<String> = ["id", "calendar", "title", "start", "end", "allDay", "location"]

    private struct Sent {
        let at: Date
        let method: String
        let body: [String: Any]?
        let line: String
    }

    private func sent(_ path: String) -> [Sent] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String,
                  let at = (object["at"] as? String).flatMap(iso.date(from:)) else { return nil }
            return Sent(at: at, method: method, body: object["body"] as? [String: Any], line: String(line))
        }
    }

    private func waitFor(_ path: String, _ method: String, count: Int, timeout: TimeInterval) -> [Sent] {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let found = sent(path).filter { $0.method == method }
            if found.count >= count { return found }
            sleep(1)
        }
        return sent(path).filter { $0.method == method }
    }

    func test_sharing_sends_only_the_contracts_keys_at_most_once_a_minute_and_off_deletes() throws {
        let dir = ProcessInfo.processInfo.environment["CAL_SHOT_DIR"] ?? NSTemporaryDirectory()
        let capture = (dir as NSString).appendingPathComponent("calendar-capture.jsonl")
        try? FileManager.default.removeItem(atPath: capture)
        let app = XCUIApplication()
        app.launchArguments = ["-PocketCalendarPreview", "-PocketCalendarStage", "connect", "-PocketCalendarSeedEvent"]
        app.launchEnvironment["CAL_CAPTURE_FILE"] = capture
        app.launch()

        let share = app.switches["pocket.calendar.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 60), "connected: the switch is on the calendar screen\n\(app.debugDescription)")
        XCTAssertEqual(share.label, "Let my agents see my calendar", "VoiceOver reads the switch by its words")
        XCTAssertEqual(share.value as? String, "0", "off until it is turned on")
        sleep(3)
        XCTAssertTrue(sent(capture).filter { $0.method != "GET" }.isEmpty, "nothing is sent before the switch is on")
        XCTAssertFalse(sent(capture).isEmpty, "the flag was read (an empty window)")
        shot("1-connected")

        share.tap()
        XCTAssertEqual(share.value as? String, "1")
        let calendars = app.buttons["pocket.calendar.calendars"]
        XCTAssertTrue(calendars.waitForExistence(timeout: 10), "Calendars to share, once the switch is on")
        sleep(2)
        XCTAssertTrue(sent(capture).filter { $0.method == "PUT" }.isEmpty, "none picked: nothing is sent")
        calendars.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                   "settings.phoneCalendar.calendar.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the phone's calendars to pick")
        XCTAssertFalse(row.isSelected)
        row.tap()
        XCTAssertTrue(row.isSelected, "VoiceOver reads a picked calendar as selected")
        shot("2-picked")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let firstPut = waitFor(capture, "PUT", count: 1, timeout: 20)
        XCTAssertEqual(firstPut.count, 1, "the picked calendar is sent")
        let put = try XCTUnwrap(firstPut.first)
        let body = try XCTUnwrap(put.body)
        XCTAssertEqual(Set(body.keys), Self.bodyKeys)
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertFalse(events.isEmpty, "the made-up event is in it")
        for event in events {
            XCTAssertEqual(Set(event.keys), Self.eventKeys, "exactly the contract's keys")
        }
        XCTAssertTrue(put.line.contains("Site visit (made up)"))
        XCTAssertFalse(put.line.contains("blue folder"), "notes never leave the phone")
        XCTAssertFalse(put.line.contains("meet.example.test"), "links never leave the phone")
        print("CALCONNECT put keys=\(body.keys.sorted()) events=\(events.count) eventKeys=\(events.first.map { $0.keys.sorted() } ?? [])")

        // Four edits inside the minute: one more send, at the minute.
        let edit = app.buttons["pocket.debug.editSeed"]
        for _ in 0..<4 {
            edit.tap()
            sleep(5)
        }
        let puts = waitFor(capture, "PUT", count: 2, timeout: 75)
        XCTAssertEqual(puts.count, 2, "edits inside a minute make one more send")
        if puts.count >= 2 {
            let gap = puts[1].at.timeIntervalSince(puts[0].at)
            XCTAssertGreaterThanOrEqual(gap, 59, "at most one send a minute: \(gap) s")
            XCTAssertTrue(puts[1].line.contains("Site visit (made up) 4"), "the last edit is what is sent")
            print("CALCONNECT second put after \(gap) s")
        }
        sleep(5)
        XCTAssertEqual(sent(capture).filter { $0.method == "PUT" }.count, 2, "and no more")

        share.tap()
        let deletes = waitFor(capture, "DELETE", count: 1, timeout: 20)
        XCTAssertEqual(deletes.count, 1, "off: the server is told to forget")
        XCTAssertEqual(app.staticTexts["pocket.debug.stores"].label, "EventKit stores: 1", "one EventKit store")
        shot("3-off")
        print("CALCONNECT requests=\(sent(capture).map { $0.method })")
    }

    /// Saves a screenshot where `CAL_SHOT_DIR` points (set by the runner), for the review evidence.
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CAL_SHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("calendar-connect-\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
#endif
