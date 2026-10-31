import Foundation
import XCTest
@testable import PocketUI

/// Carter (10-31): a summary reads as prose with its meat and bones (who, what, when, why and where), never as
/// "Objective:", "What changed:", "How:", "Checks:" or "Record:" lines, and never with a raw @-mention or a Markdown star.
final class SummaryProseTests: XCTestCase {
    /// The real summary Carter was shown: five labels, three mentions addressing people, a stray Markdown star, and
    /// four stock phrases that say nothing.
    static let realLegacy = """
    Objective: @human-mrrcarter @gpt-astra-carter @pocket-forge *Warden's adversarial review.
    What changed: 1 recorded events; outcomes not verified.
    How: 1 participant(s), 0s. Top contributor: claude-warden.
    Checks: Tests not verified; RLAIF not reported.
    Record: 1408 tokens, $0.0000; deterministic transcript summary.
    """

    func test_the_real_legacy_summary_reads_without_labels_mentions_or_boilerplate() {
        let prose = SummaryProse.prose(Self.realLegacy)
        XCTAssertEqual(prose, "Warden's adversarial review. Only claude-warden took part.")
        for label in ["Objective", "What changed", "How:", "Checks", "Record"] {
            XCTAssertFalse(prose.contains(label), "label \(label)")
        }
        for stock in ["recorded events", "not verified", "RLAIF", "tokens", "$", "deterministic", "participant(s)"] {
            XCTAssertFalse(prose.contains(stock), "stock phrase \(stock)")
        }
        XCTAssertFalse(prose.contains("@"))
        XCTAssertFalse(prose.contains("*"))
        XCTAssertFalse(prose.contains("\n"), "one paragraph")
    }

    /// A model's five parts (the shape the API's own tests use) read as sentences, the record as "See …".
    func test_a_model_written_five_part_summary_reads_as_sentences() {
        let text = """
        Objective: Ship the feature
        What changed: Added a handler
        How: Used the existing route
        Checks: Tests reported passing; RLAIF not reported
        Record: PR #42
        """
        XCTAssertEqual(SummaryProse.prose(text),
                       "Ship the feature. Added a handler. Used the existing route. Tests reported passing. See PR #42.")
    }

    /// The phone's own summaries were labelled in bold with the record in code marks, until 10-31.
    func test_bold_labels_and_code_marks_go_too() {
        let text = "**Objective:** Stop Pocket freezing at send.\n**What changed:** A send reopens the room.\n"
            + "**Checks:** None mentioned\n**Record:** `#262`, `cdec7a2c`"
        XCTAssertEqual(SummaryProse.prose(text), "Stop Pocket freezing at send. A send reopens the room. See #262, cdec7a2c.")
        XCTAssertEqual(SummaryProse.prose("**Objective**: Ship it.\n- How: by hand"), "Ship it. By hand.")
    }

    /// Each stock phrase on its own, beside one that says something, so each rule is seen to work.
    func test_each_stock_phrase_goes_and_what_is_said_stays() {
        let cases: [(String, String)] = [
            ("What changed: 3 recorded events; the pin moved.", "The pin moved."),
            ("What changed: Outcomes not verified; the pin moved.", "The pin moved."),
            ("Checks: Tests not verified; lint passed.", "Lint passed."),
            ("Checks: RLAIF not reported; CI passed.", "CI passed."),
            ("Checks: CI passed; RLAIF passed.", "CI passed; RLAIF passed."),
            ("Record: deterministic transcript summary; PR #7.", "See PR #7."),
            ("Record: 1,408 tokens, $0.0123; PR #7.", "See PR #7."),
            ("Objective: No objective reported\nWhat changed: The pin moved.", "The pin moved."),
            ("Checks: No tests reported; no regressions found.", "No regressions found.")
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SummaryProse.prose(text), expected, text)
        }
    }

    /// The outline's counts say who took part, and for how long when it was a minute or more.
    func test_an_outlines_counts_say_who_took_part() {
        XCTAssertEqual(SummaryProse.prose("How: 3 participant(s), 750s. Top contributor: claude-warden."),
                       "3 participants took part over 13 minutes; claude-warden contributed most.")
        XCTAssertEqual(SummaryProse.prose("How: 2 participant(s), 4000s. Top contributor: human-mrrcarter."),
                       "2 participants took part over an hour; mrrcarter contributed most.")
        XCTAssertEqual(SummaryProse.prose("How: 1 participant(s), 0s. Top contributor: n/a."), "", "nothing said")
    }

    /// A record of ids reads "See …"; a record that is already a sentence stays one.
    func test_a_record_of_ids_reads_see_and_a_sentence_stays_a_sentence() {
        XCTAssertEqual(SummaryProse.prose("Record: #262, cdec7a2c"), "See #262, cdec7a2c.")
        XCTAssertEqual(SummaryProse.prose("Record: Merged as #262."), "Merged as #262.")
    }

    /// Mentions that address people go; a person named in a sentence keeps their name, without the @.
    func test_mentions_that_address_people_go_and_named_people_keep_their_names() {
        XCTAssertEqual(SummaryProse.prose("@human-mrrcarter @pocket-forge The build is green."), "The build is green.")
        XCTAssertEqual(SummaryProse.prose("@claude-warden, please look. It is ready."), "Please look. It is ready.")
        XCTAssertEqual(SummaryProse.prose("Done. @pocket-forge Ship it."), "Done. Ship it.")
        XCTAssertEqual(SummaryProse.prose("@claude-warden fixed the freeze with @human-mrrcarter."),
                       "claude-warden fixed the freeze with mrrcarter.")
        XCTAssertEqual(SummaryProse.prose("Merged after review. cc @pocket-forge @claude-warden"), "Merged after review.")
        XCTAssertEqual(SummaryProse.prose("Asked @all to retest."), "Asked everyone to retest.")
        XCTAssertEqual(SummaryProse.prose("Mail ops@example.com about it."), "Mail ops@example.com about it.")
    }

    /// No Markdown mark shows: emphasis, links, code, headings and bullets.
    func test_markdown_marks_never_show() {
        XCTAssertEqual(
            SummaryProse.prose("**Paste validation** is *fixed*; see [the PR](https://github.com/o/r/pull/7) and `build 319`."),
            "Paste validation is fixed; see the PR and build 319."
        )
        XCTAssertEqual(SummaryProse.prose("## Next\n- Ship the retry counter\n- Ask Alex"), "Next. Ship the retry counter. Ask Alex.")
    }

    /// Prose keeps its paragraphs and words, and a sentence that merely starts like a label is not one.
    func test_prose_keeps_its_paragraphs_and_is_never_read_as_labels() {
        let text = "Carter asked for prose summaries on Friday.\n\nHow it went: the server now writes them."
        XCTAssertEqual(SummaryProse.prose(text), text)
        XCTAssertEqual(SummaryReading("  Current work  ").prose, "Current work")
    }

    // MARK: - The server's prose (format "prose-v2")

    /// The server's prose summary as `summary/generate` will answer it: the paragraph, and the time range, participants
    /// and mode its quiet line reads.
    static let proseV2: [String: Any] = [
        "format": "prose-v2",
        "summary": "Carter asked on Friday for room summaries in prose. @claude-warden reviewed **the API change** "
            + "and pocket-forge rebuilt the phone's sheet; both shipped in PR #292.",
        "title": "Prose summaries",
        "participants": ["human-mrrcarter", ["displayName": "claude-warden"], ["id": "pocket-forge"], "@astra-web", "codex"] as [Any],
        "timeRange": ["start": "2026-10-31T09:02:00Z", "end": "2026-10-31T09:40:00.123Z"],
        "room": ["id": "room-1", "title": "Pocket", "subroom": false] as [String: Any],
        "artifacts": [["kind": "pr", "id": "292"]],
        "scope": "room",
        "mode": "basic"
    ]

    func test_the_prose_v2_summary_reads_as_its_paragraph_with_when_who_and_how_under_it() {
        let reading = SummaryReading(Self.proseV2["summary"] as? String ?? "",
                                     details: SummaryProse.details(server: Self.proseV2, now: date("2026-10-31T12:00:00Z"),
                                                                   calendar: utc))
        XCTAssertEqual(reading.prose, "Carter asked on Friday for room summaries in prose. claude-warden reviewed the API "
            + "change and pocket-forge rebuilt the phone's sheet; both shipped in PR #292.")
        XCTAssertEqual(reading.detailParts.count, 3)
        guard reading.detailParts.count == 3 else { return }
        let when = plain(reading.detailParts[0])
        for piece in ["Oct 31", "9:02", "9:40"] { XCTAssertTrue(when.contains(piece), "\(when) has \(piece)") }
        XCTAssertFalse(when.contains("2026"), "this year's dates leave the year out: \(when)")
        XCTAssertEqual(reading.detailParts[1], "mrrcarter, claude-warden, pocket-forge and 2 more")
        XCTAssertEqual(reading.detailParts[2], "Basic summary")
        XCTAssertEqual(reading.details, reading.detailParts.joined(separator: " · "))
        XCTAssertEqual(reading.spokenDetails, reading.detailParts.joined(separator: ", "))
    }

    func test_each_field_of_the_quiet_line_is_read_on_its_own_and_left_out_when_absent() {
        let now = date("2026-10-31T12:00:00Z")
        XCTAssertEqual(SummaryProse.details(server: [:], now: now, calendar: utc), [])
        XCTAssertEqual(SummaryProse.details(server: ["timeRange": NSNull(), "participants": NSNull(), "mode": NSNull()],
                                            now: now, calendar: utc), [], "JSON nulls are absent fields")
        XCTAssertEqual(SummaryProse.details(server: ["mode": "llm"], now: now, calendar: utc), ["Model summary"])
        XCTAssertEqual(SummaryProse.details(server: ["mode": "deterministic"], now: now, calendar: utc), ["Basic summary"])
        XCTAssertEqual(SummaryProse.details(server: ["mode": "model"], now: now, calendar: utc), ["Model summary"])
        XCTAssertEqual(SummaryProse.details(server: ["mode": "long_message"], now: now, calendar: utc), ["Long message"])
        XCTAssertEqual(SummaryProse.details(server: ["participants": ["claude-warden", "human-alex"]], now: now, calendar: utc),
                       ["claude-warden and alex"])
        XCTAssertEqual(SummaryProse.details(server: ["participants": "a, b, c"], now: now, calendar: utc), ["a, b and c"])

        let lastYear = SummaryProse.details(server: ["timeRange": ["from": "2025-12-30T22:00:00Z", "to": "2025-12-31T01:00:00Z"]],
                                            now: now, calendar: utc)
        XCTAssertEqual(lastYear.count, 1)
        XCTAssertTrue(plain(lastYear.first ?? "").contains("2025"), "\(lastYear)")

        let moment = SummaryProse.details(server: ["timeRange": "2026-10-31T09:02:00Z"], now: now, calendar: utc)
        XCTAssertEqual(moment.map(plain), [plain(SummaryProse.when(from: date("2026-10-31T09:02:00Z"),
                                                                    to: date("2026-10-31T09:02:00Z"), now: now, calendar: utc) ?? "")])
        XCTAssertFalse(plain(moment.first ?? "").contains("–"), "one moment is one time")

        let epoch = SummaryProse.details(server: ["timeRange": [1_793_000_000, 1_793_002_520]], now: now, calendar: utc)
        XCTAssertTrue(plain(epoch.first ?? "").contains("7:33"), "\(epoch)")
        XCTAssertTrue(plain(epoch.first ?? "").contains("8:15"), "\(epoch)")
        XCTAssertEqual(SummaryProse.details(server: ["timeRange": "Friday morning"], now: now, calendar: utc), ["Friday morning"])
    }

    // MARK: - Helpers

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? Date(timeIntervalSince1970: 0)
    }

    /// Formatted dates with plain spaces: the formatters put thin and narrow spaces around the dash and before AM.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{2009}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
