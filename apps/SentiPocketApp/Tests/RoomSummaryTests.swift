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

    /// Carter, #55375: Summarize "says it doesn't work". It was a 503 from the edge, which never reached the server.
    func test_a_failure_says_what_happened_and_reports_what_an_agent_needs() {
        let edge = RoomSummaryFailure(status: 503, requestId: nil)
        XCTAssertEqual(edge.message, "Summaries aren't open on the server yet.")
        XCTAssertEqual(edge.report(build: "2026103006"),
                       "Pocket problem: Summarize this room failed with HTTP 503, refused before it reached the server (no request id). Build 2026103006.")

        let server = RoomSummaryFailure(status: 503, requestId: "req-d9c4fee4d002")
        XCTAssertEqual(server.message, "The summary service didn't answer (error 503). Try again in a minute.")
        XCTAssertTrue(server.report(build: "1").contains("request id `req-d9c4fee4d002`"))

        XCTAssertEqual(RoomSummaryFailure(status: 403, requestId: "r").message, "Only the room's owner can summarize it.")
        XCTAssertEqual(RoomSummaryFailure(status: 429, requestId: "r").message,
                       "That's the most summaries for this minute. Try again in a minute.")
    }
}
