import Foundation
import PocketUI
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
        XCTAssertEqual(summary.reading.prose, "Two findings are fixed.\n\nBuild 319 is green.")
        XCTAssertNil(summary.reading.details)
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

    /// Carter (10-31): the real summary an older server sent reads as prose: no labels, no mentions, no stars and no
    /// stock phrases, and its title (the objective, mentions and all) is not repeated over it.
    func test_an_older_servers_five_parts_read_as_prose_without_labels_mentions_or_boilerplate() throws {
        let text = "Objective: @human-mrrcarter @gpt-astra-carter @pocket-forge *Warden's adversarial review.\n"
            + "What changed: 1 recorded events; outcomes not verified.\n"
            + "How: 1 participant(s), 0s. Top contributor: claude-warden.\n"
            + "Checks: Tests not verified; RLAIF not reported.\n"
            + "Record: 1408 tokens, $0.0000; deterministic transcript summary."
        let body: [String: Any] = ["ok": true, "summary": [
            "summary": text, "model": "deterministic-fallback",
            "title": "@human-mrrcarter @gpt-astra-carter @pocket-forge *Warden's adversarial review."
        ]]
        let summary = try XCTUnwrap(RoomSummary(json: try JSONSerialization.data(withJSONObject: body)))
        XCTAssertEqual(summary.reading.prose, "Warden's adversarial review. Only claude-warden took part.")
        XCTAssertNil(summary.title, "the title only repeats the summary's first sentence")
        XCTAssertNil(summary.reading.details)
        XCTAssertTrue(summary.isFallback)
    }

    /// The server's prose (`format: "prose-v2"`): the paragraph as written, cleaned, with its time range,
    /// participants and mode in the line under it, and a title that says more than the first sentence.
    func test_the_servers_prose_reads_with_when_who_and_how_under_it() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = Locale(identifier: "en_US")
        let body: [String: Any] = ["ok": true, "cached": false, "summary": [
            "format": "prose-v2",
            "summary": "Carter asked on Friday for room summaries in prose. @claude-warden reviewed the API change; "
                + "pocket-forge rebuilt the phone's sheet in PR #292.",
            "title": "Prose summaries for rooms",
            "participants": ["human-mrrcarter", "claude-warden", "pocket-forge"],
            "timeRange": ["start": "2026-10-31T13:02:00Z", "end": "2026-10-31T13:40:00Z"],
            "room": ["id": "room-1", "title": "Pocket", "subroom": false] as [String: Any],
            "artifacts": [["kind": "pr", "id": "292"]],
            "scope": "room",
            "mode": "llm",
            "model": "server"
        ] as [String: Any]]
        let summary = try XCTUnwrap(RoomSummary(json: try JSONSerialization.data(withJSONObject: body),
                                                now: ISO8601DateFormatter().date(from: "2026-10-31T15:00:00Z") ?? Date(),
                                                calendar: calendar))
        XCTAssertEqual(summary.reading.prose, "Carter asked on Friday for room summaries in prose. claude-warden reviewed "
            + "the API change; pocket-forge rebuilt the phone's sheet in PR #292.")
        XCTAssertEqual(summary.title, "Prose summaries for rooms")
        XCTAssertEqual(summary.reading.detailParts.count, 3)
        guard summary.reading.detailParts.count == 3 else { return }
        XCTAssertTrue(summary.reading.detailParts[0].contains("Oct 31"), summary.reading.detailParts[0])
        XCTAssertEqual(summary.reading.detailParts[1], "mrrcarter, claude-warden and pocket-forge")
        XCTAssertEqual(summary.reading.detailParts[2], "Model summary")
        XCTAssertFalse(summary.isFallback)
    }

    /// A summary with nothing in it but stock phrases says so, instead of showing an empty sheet.
    func test_a_summary_of_stock_phrases_alone_says_there_is_not_enough_yet() throws {
        let body: [String: Any] = ["ok": true, "summary": [
            "summary": "Objective: No objective reported\nWhat changed: 0 recorded events; outcomes not verified.",
            "model": "deterministic-fallback", "title": "Session 1a2b3c4d"
        ]]
        let summary = try XCTUnwrap(RoomSummary(json: try JSONSerialization.data(withJSONObject: body)))
        XCTAssertEqual(summary.reading.prose, RoomSummary.nothingYet)
        XCTAssertNil(summary.title, "a title that only names the room by id is no title")
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
