#if os(iOS) && canImport(XCTest)
import XCTest

/// Ticket 9583d41e, the device checks of the privacy review: Pocket's own calendar on the simulator's real calendar
/// (calendar access is granted to the app, or taken back, by the runner around each test), with a made-up event that
/// has notes and a link, and every request to the device-events routes recorded by the app's stand-in server
/// (`-PocketCalendarStage connect`). The runner calls them in order, around calendar access: granted, `test_1` to
/// `test_3`; revoked, `test_4`; granted, `test_5` and `test_6`; revoked, `test_7` (no network); granted, `test_8`;
/// reset, `test_9`. Losing access turns sharing off, with no network too; regaining it never turns sharing on; and a
/// privacy reset brings Connect back. Each test keeps its own capture (`calendar-capture-<test>.jsonl`).
final class CalendarConnectUITests: XCTestCase {
    private static let bodyKeys: Set<String> = ["source", "windowStart", "windowEnd", "events"]
    private static let eventKeys: Set<String> = ["id", "calendar", "title", "start", "end", "allDay", "location"]

    private struct Sent {
        let at: Date
        let method: String
        let body: [String: Any]?
        let line: String
    }

    private var capture: String {
        let dir = ProcessInfo.processInfo.environment["CAL_SHOT_DIR"] ?? NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("calendar-capture.jsonl")
    }

    private func sent() -> [Sent] {
        guard let text = try? String(contentsOfFile: capture, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String,
                  let at = (object["at"] as? String).flatMap(iso.date(from:)) else { return nil }
            return Sent(at: at, method: method, body: object["body"] as? [String: Any], line: String(line))
        }
    }

    private func waitFor(_ method: String, count: Int, timeout: TimeInterval) -> [Sent] {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let found = sent().filter { $0.method == method }
            if found.count >= count { return found }
            sleep(1)
        }
        return sent().filter { $0.method == method }
    }

    /// The preview, its capture emptied first. `fresh` starts the switch and the picks afresh; without it they are
    /// kept from the launch before. `offline`: every request fails as with no network.
    private func launch(fresh: Bool, seed: Bool = true, offline: Bool = false) -> XCUIApplication {
        try? FileManager.default.removeItem(atPath: capture)
        let app = XCUIApplication()
        app.launchArguments = ["-PocketCalendarPreview", "-PocketCalendarStage", "connect"]
            + (fresh ? ["-PocketCalendarFresh"] : []) + (seed ? ["-PocketCalendarSeedEvent"] : [])
        app.launchEnvironment["CAL_CAPTURE_FILE"] = capture
        if offline { app.launchEnvironment["CAL_OFFLINE"] = "1" }
        app.launch()
        return app
    }

    /// Keeps the capture as `calendar-capture-<test><suffix>.jsonl`, beside the screenshots.
    private func keep(_ suffix: String = "") {
        let test = name.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? "test"
        let kept = ((capture as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("calendar-capture-\(test)\(suffix).jsonl")
        try? FileManager.default.removeItem(atPath: kept)
        try? FileManager.default.copyItem(atPath: capture, toPath: kept)
    }

    override func setUp() {
        super.setUp()
        addTeardownBlock { [weak self] in self?.keep() }
    }

    /// Taps a toggle on its switch, at its trailing edge (a tap in its middle lands on its words, which do not flip
    /// it), and waits for its value; if that missed, the switch inside it.
    private func flip(_ toggle: XCUIElement, to value: String) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        let end = Date().addingTimeInterval(5)
        while (toggle.value as? String) != value, Date() < end { usleep(200_000) }
        if (toggle.value as? String) != value { toggle.switches.firstMatch.tap() }
        XCTAssertEqual(toggle.value as? String, value, "the switch flipped")
    }

    /// Switch on, then the made-up event's own calendar ticked in Calendars to share (never just the first row), and
    /// back: the first PUT.
    private func shareTheSeedCalendar(_ app: XCUIApplication) -> XCUIElement {
        let share = app.switches["pocket.calendar.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 60), "connected: the switch is on the calendar screen\n\(app.debugDescription)")
        let seed = app.staticTexts["pocket.debug.seedCalendar"]
        XCTAssertTrue(seed.waitForExistence(timeout: 10))
        let calendarId = seed.label
        XCTAssertNotEqual(calendarId, "none", "the made-up event was added")
        flip(share, to: "1")
        let calendars = app.buttons["pocket.calendar.calendars"]
        XCTAssertTrue(calendars.waitForExistence(timeout: 10), "Calendars to share, once the switch is on")
        calendars.tap()
        let row = app.buttons["settings.phoneCalendar.calendar.\(calendarId)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the made-up event's calendar is offered\n\(app.debugDescription)")
        XCTAssertFalse(row.isSelected)
        row.tap()
        XCTAssertTrue(row.isSelected, "VoiceOver reads a picked calendar as selected")
        print("CALCONNECT ticked calendar=\(calendarId) label=\(row.label)")
        return row
    }

    /// 1. Nothing but the flag's read before the switch is on; the first send has only the contract's keys, the
    /// made-up event among them and never its notes or link; four edits in the minute make one more send, at least
    /// 59 s after; off sends DELETE; one EventKit store. VoiceOver reads the switch by its words.
    func test_1_sharing_sends_only_the_contracts_keys_at_most_once_a_minute_and_off_deletes() throws {
        let app = launch(fresh: true)
        let share = app.switches["pocket.calendar.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 60), "connected: the switch is on the calendar screen\n\(app.debugDescription)")
        XCTAssertEqual(share.label, "Let my agents see my calendar", "VoiceOver reads the switch by its words")
        XCTAssertEqual(share.value as? String, "0", "off until it is turned on")
        sleep(3)
        XCTAssertTrue(sent().filter { $0.method != "GET" }.isEmpty, "only reads before the switch is on")
        XCTAssertFalse(sent().isEmpty, "the flag was read (an empty window)")
        shot("1-connected")

        _ = shareTheSeedCalendar(app)
        shot("1-picked")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let firstPut = waitFor("PUT", count: 1, timeout: 20)
        XCTAssertEqual(firstPut.count, 1, "the picked calendar is sent")
        let put = try XCTUnwrap(firstPut.first)
        let body = try XCTUnwrap(put.body)
        XCTAssertEqual(Set(body.keys), Self.bodyKeys)
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertFalse(events.isEmpty)
        for event in events {
            XCTAssertEqual(Set(event.keys), Self.eventKeys, "exactly the contract's keys")
        }
        XCTAssertTrue(put.line.contains("Site visit (made up)"), "the made-up event is in it")
        XCTAssertFalse(put.line.contains("blue folder"), "notes never leave the phone")
        XCTAssertFalse(put.line.contains("meet.example.test"), "links never leave the phone")
        print("CALCONNECT put keys=\(body.keys.sorted()) events=\(events.count)")

        let edit = app.buttons["pocket.debug.editSeed"]
        for _ in 0..<4 {
            edit.tap()
            sleep(5)
        }
        let puts = waitFor("PUT", count: 2, timeout: 75)
        XCTAssertEqual(puts.count, 2, "edits inside a minute make one more send")
        if puts.count >= 2 {
            let gap = puts[1].at.timeIntervalSince(puts[0].at)
            XCTAssertGreaterThanOrEqual(gap, 59, "at most one send a minute: \(gap) s")
            XCTAssertTrue(puts[1].line.contains("Site visit (made up) 4"), "the last edit is what is sent")
            print("CALCONNECT second put after \(gap) s")
        }
        sleep(5)
        XCTAssertEqual(sent().filter { $0.method == "PUT" }.count, 2, "and no more")

        flip(share, to: "0")
        let deletes = waitFor("DELETE", count: 1, timeout: 20)
        XCTAssertEqual(deletes.count, 1, "off: the server is told to forget")
        XCTAssertEqual(app.staticTexts["pocket.debug.stores"].label, "EventKit stores: 1", "one EventKit store")
        shot("1-off")
        print("CALCONNECT test1 requests=\(sent().map { $0.method })")
    }

    /// 2. Unticking the last calendar while sharing: a DELETE goes.
    func test_2_unticking_the_last_calendar_sends_delete() throws {
        let app = launch(fresh: true)
        let row = shareTheSeedCalendar(app)
        XCTAssertEqual(waitFor("PUT", count: 1, timeout: 20).count, 1)
        row.tap()
        XCTAssertFalse(row.isSelected)
        XCTAssertEqual(waitFor("DELETE", count: 1, timeout: 20).count, 1, "the last calendar unticked: the server forgets")
        shot("2-unticked")
        print("CALCONNECT test2 requests=\(sent().map { $0.method })")
    }

    /// 3. Sharing left on, with the made-up event's calendar picked, for the runner to take calendar access back.
    func test_3_sharing_is_left_on_for_the_access_check() throws {
        let app = launch(fresh: true)
        _ = shareTheSeedCalendar(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(waitFor("PUT", count: 1, timeout: 20).count, 1)
        print("CALCONNECT test3 requests=\(sent().map { $0.method })")
        app.terminate()
    }

    /// 4. After the runner took calendar access back: a relaunch turns sharing off and sends DELETE by itself, and the
    /// switch stays in sight, off.
    func test_4_after_access_was_taken_back_a_delete_goes_and_the_switch_stays_off() throws {
        let app = launch(fresh: false, seed: false)
        XCTAssertEqual(waitFor("DELETE", count: 1, timeout: 30).count, 1, "access went: the server forgets")
        let share = app.switches["pocket.calendar.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), "the switch stays in sight\n\(app.debugDescription)")
        XCTAssertEqual(share.value as? String, "0", "sharing is off")
        XCTAssertTrue(sent().filter { $0.method == "PUT" }.isEmpty, "nothing is sent without access")
        shot("4-access-taken-back")
        print("CALCONNECT test4 requests=\(sent().map { $0.method })")
        app.terminate()
    }

    /// 5. Access granted again: sharing stays off and nothing is sent, until the person turns it on; then it is sent.
    /// Sharing is left on, for the cold launches.
    func test_5_regaining_access_sends_nothing_until_the_switch_is_turned_on() throws {
        let app = launch(fresh: false, seed: false)
        let share = app.switches["pocket.calendar.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 60), "\(app.debugDescription)")
        XCTAssertEqual(share.value as? String, "0", "access back: sharing stays off")
        sleep(6)
        XCTAssertTrue(sent().filter { $0.method == "PUT" }.isEmpty, "nothing is sent until the switch is on")
        flip(share, to: "1")
        XCTAssertEqual(waitFor("PUT", count: 1, timeout: 20).count, 1, "turned on: the picked calendar is sent")
        shot("5-on-again")
        print("CALCONNECT test5 requests=\(sent().map { $0.method })")
        app.terminate()
    }

    /// 6. Three cold launches with access granted and sharing on: never a DELETE.
    func test_6_three_cold_launches_with_access_send_no_delete() throws {
        var methods: [String] = []
        for launchNumber in 1...3 {
            let app = launch(fresh: false, seed: false)
            let share = app.switches["pocket.calendar.share"]
            XCTAssertTrue(share.waitForExistence(timeout: 60))
            XCTAssertEqual(share.value as? String, "1")
            sleep(6)
            let now = sent().map { $0.method }
            XCTAssertFalse(now.contains("DELETE"), "cold launch \(launchNumber): no DELETE: \(now)")
            methods += now
            keep("-launch\(launchNumber)")
            app.terminate()
        }
        print("CALCONNECT test6 requests=\(methods)")
    }

    /// 7. Access taken back again (sharing was on), and the app opened with no network: nothing goes through. The
    /// app still turns sharing off; test 8 sees it.
    func test_7_access_taken_back_and_opened_offline_nothing_goes_through() throws {
        let app = launch(fresh: false, seed: false, offline: true)
        sleep(8)
        let lines = sent()
        XCTAssertTrue(lines.allSatisfy { $0.line.contains(#""offline":true"#) }, "with no network nothing went through")
        print("CALCONNECT test7 requests=\(lines.map { $0.method }) offline=\(lines.count)")
        app.terminate()
    }

    /// 8. Access given again and the app opened online: sharing stays off (it was turned off with no network), the
    /// DELETE that waited goes, and nothing is sent.
    func test_8_access_given_again_online_sharing_stays_off_and_the_delete_goes() throws {
        let app = launch(fresh: false, seed: false)
        let share = app.switches["pocket.calendar.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 60), "\(app.debugDescription)")
        XCTAssertEqual(share.value as? String, "0", "sharing was turned off while offline")
        XCTAssertEqual(waitFor("DELETE", count: 1, timeout: 20).count, 1, "the DELETE that waited goes")
        sleep(4)
        XCTAssertTrue(sent().filter { $0.method == "PUT" }.isEmpty, "nothing is sent")
        shot("8-online-again")
        print("CALCONNECT test8 requests=\(sent().map { $0.method })")
        app.terminate()
    }

    /// 9. After a privacy reset (iOS has not asked, and Settings shows no Calendars row for Pocket): Connect my
    /// calendar is offered again, not the switch.
    func test_9_after_a_privacy_reset_connect_comes_back() throws {
        let app = launch(fresh: false, seed: false)
        let connect = app.buttons["pocket.calendar.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 60), "Connect is offered again\n\(app.debugDescription)")
        XCTAssertFalse(app.switches["pocket.calendar.share"].exists, "not the switch")
        shot("9-reset")
        print("CALCONNECT test9 requests=\(sent().map { $0.method })")
        app.terminate()
    }

    /// Saves a screenshot where `CAL_SHOT_DIR` points (set by the runner), for the review evidence.
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["CAL_SHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("calendar-connect-\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}
#endif
