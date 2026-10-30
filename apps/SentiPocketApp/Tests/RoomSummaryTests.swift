import Foundation
import XCTest
@testable import SentiPocketApp

final class RoomSummaryTests: XCTestCase {
    /// The API's answer to `POST /summary/generate`: the summary sits inside `summary`.
    func test_the_summary_is_read_from_the_apis_answer() throws {
        let body: [String: Any] = [
            "ok": true,
            "summary": ["ok": true, "summary": "  Two findings are fixed.\n\n- Build 319 is green.  ", "title": "Onboarding", "model": "gpt-5.4-mini"],
            "persisted": true
        ]
        let summary = try XCTUnwrap(RoomSummary(json: try JSONSerialization.data(withJSONObject: body)))
        XCTAssertEqual(summary.title, "Onboarding")
        XCTAssertEqual(summary.text, "Two findings are fixed.\n\n- Build 319 is green.")
        XCTAssertFalse(summary.isFallback)
    }

    func test_the_apis_own_fallback_is_marked_and_an_empty_answer_is_none() throws {
        let fallback: [String: Any] = ["ok": true, "summary": ["summary": "Outline.", "title": "", "model": "deterministic-fallback"]]
        let summary = try XCTUnwrap(RoomSummary(json: try JSONSerialization.data(withJSONObject: fallback)))
        XCTAssertTrue(summary.isFallback)
        XCTAssertNil(summary.title, "an empty title is no title")

        let empty: [String: Any] = ["ok": true, "summary": ["summary": "   "]]
        XCTAssertNil(RoomSummary(json: try JSONSerialization.data(withJSONObject: empty)))
        XCTAssertNil(RoomSummary(json: Data("not json".utf8)))
    }
}
