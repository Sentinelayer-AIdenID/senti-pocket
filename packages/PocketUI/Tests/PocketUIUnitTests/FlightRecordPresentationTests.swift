import Foundation
import XCTest
@testable import PocketUI

final class FlightRecordPresentationTests: XCTestCase {
    /// The web's figures: one decimal below 10, a small positive value never reads as zero, a minimum reads "at least".
    func test_room_figures_read_as_the_web_writes_them() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(FlightRecordState.Totals.amount(12.46, locale: us), "12")
        XCTAssertEqual(FlightRecordState.Totals.amount(3.14, locale: us), "3.1")
        XCTAssertEqual(FlightRecordState.Totals.amount(0.01, locale: us), "<0.1")
        XCTAssertEqual(FlightRecordState.Totals.amount(1234, locale: us), "1,234")
        XCTAssertEqual(FlightRecordState.Totals.shown(3.14, isMinimum: true, locale: us), "≥3.1")
        XCTAssertEqual(FlightRecordState.Totals.shown(0.01, isMinimum: true, locale: us), ">0")
        XCTAssertEqual(FlightRecordState.Totals.dayUnit(1.02, locale: us), "day")
        XCTAssertEqual(FlightRecordState.Totals.dayUnit(2, locale: us), "days")
        XCTAssertEqual(FlightRecordState.Totals.usd(412.4, locale: us), "$412")
        XCTAssertEqual(FlightRecordState.Totals.usd(41.5, locale: us), "$41.50")
    }

    func test_commands_read_as_one_short_line() {
        XCTAssertEqual(FlightRecordState.command("/bin/bash -lc \"git add src tests\""), "git add src tests")
        XCTAssertEqual(FlightRecordState.command("/bin/bash -lc \"git add src/services/session_breakout_service.py"),
                       "git add src/services/session_breakout_service.py", "a record cut before the closing quote")
        XCTAssertEqual(FlightRecordState.command("pytest -q\nsecond line"), "pytest -q")
        XCTAssertTrue(FlightRecordState.command(String(repeating: "x", count: 400)).hasSuffix("…"))
    }

    func test_thoughts_and_commands_merge_newest_first_with_how_commands_ended() {
        let lines = FlightRecordState.lines(
            narration: [("2026-10-29T19:24:23Z", "Reading the brief."), ("2026-10-29T19:30:00Z", "Tests pass.")],
            commands: [("2026-10-29T19:25:00Z", "pytest -q", 1), ("2026-10-29T19:29:00Z", "pytest -q", 0),
                       ("2026-10-29T19:29:30Z", "git push", nil)]
        )
        XCTAssertEqual(lines.map(\.text), ["Tests pass.", "git push", "pytest -q", "pytest -q", "Reading the brief."])
        XCTAssertEqual(lines.map(\.tone), [.neutral, .neutral, .ok, .fail, .neutral])
        XCTAssertEqual(lines.map(\.isCommand), [false, true, true, true, false])
        XCTAssertEqual(FlightRecordState.lines(narration: Array(repeating: ("", "x"), count: 50), commands: []).count, 30)
    }
}
