import Foundation
import XCTest
@testable import PocketUI

/// A summary reads as prose. The server's prose (`format: "prose-v2"`) is shown exactly as written. An older server's
/// five labelled lines ("Objective:", "What changed:", "How:", "Checks:", "Record:") read as sentences, without their
/// labels or that server's own stock phrases, and with every name its mentions stand for. The people and the room here
/// are made up.
final class SummaryProseTests: XCTestCase {
    /// An older server's outline of a made-up room: five labels, mentions addressing people, a stray Markdown star,
    /// and the stock phrases that server wrote when it knew nothing.
    static let legacyOutline = """
    Objective: @human-sam @ada-agent @lin-agent *Lin's adversarial review.
    What changed: 1 recorded events; outcomes not verified.
    How: 1 participant(s), 0s. Top contributor: lin-agent.
    Checks: Tests not verified; RLAIF not reported.
    Record: deterministic transcript summary.
    """

    // MARK: - The server's prose is shown as written

    /// The server strips only paired emphasis, so a lone star can reach the phone: "2*3 GB" must stay that.
    func test_the_servers_prose_keeps_a_star_inside_a_number() {
        let text = "lin-agent found the cache needed 6.4 GB against a 2*3 GB budget."
        XCTAssertEqual(SummaryProse.server(text, format: "prose-v2"), text)
        XCTAssertEqual(SummaryReading(server: text, format: "prose-v2").prose, text)
    }

    /// Clients don't parse the server's prose: code marks, strikes, stars, mentions and words that look like labels all
    /// stay as the server wrote them. Only the whitespace around it goes.
    func test_the_servers_prose_is_never_rewritten() {
        let text = "Run `make check` before ~~Friday~~ Monday; the *draft* stays with @ada-agent. Checks: none yet."
        XCTAssertEqual(SummaryProse.server("  \(text)\n\n", format: "prose-v2"), text)
        XCTAssertEqual(SummaryReading(server: text, format: "prose-v2", details: ["AI summary"]).prose, text)
        XCTAssertEqual(SummaryProse.server(text, format: "prose-v3"), text, "a newer format is the server's prose too")

        // An older server's text (no format) is still read as before.
        XCTAssertEqual(SummaryProse.server(text, format: nil),
                       "Run make check before Friday Monday; the draft stays with ada-agent. Checks: none yet.")
        XCTAssertEqual(SummaryProse.server(text, format: " "), SummaryProse.legacy(text), "a blank format is no format")
    }

    /// The room list carries a room's saved summary without its format: the server's prose shows as written, and only
    /// an older server's five labelled lines are read into sentences.
    func test_a_saved_summary_is_read_only_when_it_is_an_older_servers_outline() {
        let prose = "ada-agent ran `make check` on 2*3 GB and lin-agent merged #42."
        XCTAssertEqual(SummaryProse.saved("\n\(prose) "), prose)
        XCTAssertEqual(SummaryProse.saved(Self.legacyOutline),
                       "Sam, ada-agent and lin-agent: Lin's adversarial review. Only lin-agent took part.")
    }

    // MARK: - An older server's five labelled lines

    func test_an_older_servers_outline_reads_without_labels_or_stock_phrases_and_keeps_every_name() {
        let prose = SummaryProse.legacy(Self.legacyOutline)
        XCTAssertEqual(prose, "Sam, ada-agent and lin-agent: Lin's adversarial review. Only lin-agent took part.")
        for label in ["Objective", "What changed", "How:", "Checks", "Record"] {
            XCTAssertFalse(prose.contains(label), "label \(label)")
        }
        for stock in ["recorded events", "not verified", "RLAIF", "deterministic", "participant(s)"] {
            XCTAssertFalse(prose.contains(stock), "stock phrase \(stock)")
        }
        XCTAssertFalse(prose.contains("@"))
        XCTAssertFalse(prose.contains("*"))
        XCTAssertFalse(prose.contains("\n"), "one paragraph")
    }

    /// A model's five parts (the shape the older server's own tests use) read as sentences, the record as "See …".
    func test_a_model_written_five_part_summary_reads_as_sentences() {
        let text = """
        Objective: Ship the feature
        What changed: Added a handler
        How: Used the existing route
        Checks: Tests reported passing; RLAIF not reported
        Record: PR #42
        """
        XCTAssertEqual(SummaryProse.legacy(text),
                       "Ship the feature. Added a handler. Used the existing route. Tests reported passing. See PR #42.")
    }

    /// The phone's own summaries were once labelled in bold with the record in code marks.
    func test_bold_labels_and_code_marks_go_too() {
        let text = "**Objective:** Stop the room freezing at send.\n**What changed:** A send reopens the room.\n"
            + "**Checks:** None mentioned\n**Record:** `#12`, `a1b2c3d4`"
        XCTAssertEqual(SummaryProse.legacy(text), "Stop the room freezing at send. A send reopens the room. See #12, a1b2c3d4.")
        XCTAssertEqual(SummaryProse.legacy("**Objective**: Ship it.\n- How: by hand"), "Ship it. By hand.")
    }

    /// Only the older server's exact stock phrases go, each beside a clause that says something, which stays.
    func test_each_stock_phrase_goes_and_what_is_said_stays() {
        let cases: [(String, String)] = [
            ("What changed: 3 recorded events; the pin moved.", "The pin moved."),
            ("What changed: Outcomes not verified; the pin moved.", "The pin moved."),
            ("Checks: Tests not verified; lint passed.", "Lint passed."),
            ("Checks: RLAIF not reported; CI passed.", "CI passed."),
            ("Checks: RLAIF: not reported; CI passed.", "CI passed."),
            ("Checks: CI passed; RLAIF passed.", "CI passed; RLAIF passed."),
            ("Record: deterministic transcript summary; PR #7.", "See PR #7."),
            ("Record: Not reported", ""),
            ("Objective: No objective reported\nWhat changed: The pin moved.", "The pin moved.")
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SummaryProse.legacy(text), expected, text)
        }
    }

    /// A negative with something in it is said, even in an older server's outline: only its exact stock phrases go.
    func test_real_negatives_in_an_older_servers_outline_are_kept() {
        let cases: [(String, String)] = [
            ("Checks: Tests were not verified.", "Tests were not verified."),
            ("Checks: No tests found.", "No tests found."),
            ("Checks: No tests reported; no regressions found.", "No tests reported; no regressions found."),
            ("Checks: RLAIF was not run because the grader was down.", "RLAIF was not run because the grader was down."),
            ("What changed: Outcomes were not verified on device.", "Outcomes were not verified on device.")
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SummaryProse.legacy(text), expected, text)
        }
    }

    /// The phone's own parts lose only the placeholder its model writes for a part the thread says nothing about. Its
    /// negatives are content, even one worded like the older server's stock phrase.
    func test_the_phones_own_parts_keep_their_negatives() {
        XCTAssertEqual(SummaryProse.sentences(["Fix the send freeze.", "Tests were not verified.", "No tests found.",
                                               "None mentioned"]),
                       "Fix the send freeze. Tests were not verified. No tests found.")
        XCTAssertEqual(SummaryProse.sentences(["Ship it", "Tests not verified", "Outcomes not verified; lint passed"]),
                       "Ship it. Tests not verified. Outcomes not verified; lint passed.")
        XCTAssertEqual(SummaryProse.sentences(["Ship it.", "None.", "N/A", "none mentioned."]), "Ship it.")
    }

    /// The outline's counts say who took part, and for how long when it was a minute or more.
    func test_an_outlines_counts_say_who_took_part() {
        XCTAssertEqual(SummaryProse.legacy("How: 3 participant(s), 750s. Top contributor: lin-agent."),
                       "3 participants took part over 13 minutes; lin-agent contributed most.")
        XCTAssertEqual(SummaryProse.legacy("How: 2 participant(s), 4000s. Top contributor: human-sam."),
                       "2 participants took part over an hour; sam contributed most.")
        XCTAssertEqual(SummaryProse.legacy("How: 1 participant(s), 0s. Top contributor: n/a."), "", "nothing said")
    }

    /// A record of ids reads "See …"; a record that is already a sentence stays one.
    func test_a_record_of_ids_reads_see_and_a_sentence_stays_a_sentence() {
        XCTAssertEqual(SummaryProse.legacy("Record: #12, a1b2c3d4"), "See #12, a1b2c3d4.")
        XCTAssertEqual(SummaryProse.legacy("Record: Merged as #12."), "Merged as #12.")
    }

    /// Every mention keeps the name it stands for, without its @: several in a row read as a list, and mentions that
    /// open a sentence before a new one starts (who it was for) are followed by a colon.
    func test_mentions_keep_their_names() {
        let cases: [(String, String)] = [
            ("@ada-agent @lin-agent approved the fix.", "ada-agent and lin-agent approved the fix."),
            ("@human-sam @ada-agent The build is green.", "sam and ada-agent: The build is green."),
            ("@lin-agent, please look. It is ready.", "lin-agent, please look. It is ready."),
            ("Done. @ada-agent Ship it.", "Done. ada-agent: Ship it."),
            ("@lin-agent fixed the freeze with @human-sam.", "lin-agent fixed the freeze with sam."),
            ("Merged after review. cc @ada-agent @lin-agent", "Merged after review. cc ada-agent and lin-agent"),
            ("Asked @all to retest.", "Asked everyone to retest."),
            ("Mail ops@example.com about it.", "Mail ops@example.com about it.")
        ]
        for (text, expected) in cases {
            XCTAssertEqual(SummaryProse.legacy(text), expected, text)
        }
        XCTAssertEqual(SummaryProse.sentences(["@ada-agent @lin-agent approved the fix."]),
                       "ada-agent and lin-agent approved the fix.", "the phone's own parts keep names too")
        XCTAssertEqual(SummaryProse.legacy("Objective: @ada-agent @lin-agent approved the fix."),
                       "ada-agent and lin-agent approved the fix.")
    }

    /// No Markdown mark shows in an older server's text: emphasis, links, code, headings and bullets. A star between
    /// two digits is not a mark.
    func test_markdown_marks_never_show_in_an_older_servers_text() {
        XCTAssertEqual(
            SummaryProse.legacy("**Paste validation** is *fixed*; see [the PR](https://example.com/o/r/pull/7) and `build 319`."),
            "Paste validation is fixed; see the PR and build 319."
        )
        XCTAssertEqual(SummaryProse.legacy("## Next\n- Ship the retry counter\n- Ask Alex"), "Next. Ship the retry counter. Ask Alex.")
        XCTAssertEqual(SummaryProse.legacy("The budget was 2*3 GB, *not* 8."), "The budget was 2*3 GB, not 8.")
    }

    /// Text keeps its paragraphs and words, and a sentence that merely starts like a label is not one.
    func test_prose_keeps_its_paragraphs_and_is_never_read_as_labels() {
        let text = "Sam asked for prose summaries on Friday.\n\nHow it went: the server now writes them."
        XCTAssertEqual(SummaryProse.legacy(text), text)
        XCTAssertEqual(SummaryReading(prose: "  Current work  ").prose, "Current work")
        XCTAssertEqual(SummaryReading(legacy: "**Objective:** Ship it.").prose, "Ship it.")
    }

    // MARK: - The quiet line

    /// The server's prose summary fields as `summary/generate` answers them, for a made-up room.
    static let proseV2: [String: Any] = [
        "format": "prose-v2",
        "summary": "Sam asked on Friday for room summaries in prose. ada-agent reviewed the API change and lin-agent "
            + "rebuilt the phone's sheet; both shipped in PR #42.",
        "title": "Prose summaries",
        "participants": ["human-sam", ["displayName": "ada-agent"], ["id": "lin-agent"], "@kit-agent", "rho-agent"] as [Any],
        "timeRange": ["start": "2026-10-31T09:02:00Z", "end": "2026-10-31T09:40:00.123Z"],
        "room": ["id": "room-orchid", "title": "Orchid", "subroom": false] as [String: Any],
        "artifacts": [["kind": "pr", "ref": "#42"]],
        "scope": "room",
        "mode": "basic"
    ]

    func test_the_prose_v2_summary_reads_as_its_paragraph_with_when_who_and_how_under_it() {
        let text = Self.proseV2["summary"] as? String ?? ""
        let reading = SummaryReading(server: text, format: Self.proseV2["format"] as? String,
                                     details: SummaryProse.details(server: Self.proseV2, now: date("2026-10-31T12:00:00Z"),
                                                                   calendar: utc))
        XCTAssertEqual(reading.prose, text)
        XCTAssertEqual(reading.detailParts.count, 3)
        guard reading.detailParts.count == 3 else { return }
        let when = plain(reading.detailParts[0])
        for piece in ["Oct 31", "9:02", "9:40"] { XCTAssertTrue(when.contains(piece), "\(when) has \(piece)") }
        XCTAssertFalse(when.contains("2026"), "this year's dates leave the year out: \(when)")
        XCTAssertEqual(reading.detailParts[1], "sam, ada-agent, lin-agent and 2 more")
        XCTAssertEqual(reading.detailParts[2], "Basic summary")
        XCTAssertEqual(reading.details, reading.detailParts.joined(separator: " · "))
        XCTAssertEqual(reading.spokenDetails, reading.detailParts.joined(separator: ", "))
    }

    func test_each_field_of_the_quiet_line_is_read_on_its_own_and_left_out_when_absent() {
        let now = date("2026-10-31T12:00:00Z")
        XCTAssertEqual(SummaryProse.details(server: [:], now: now, calendar: utc), [])
        XCTAssertEqual(SummaryProse.details(server: ["timeRange": NSNull(), "participants": NSNull(), "mode": NSNull()],
                                            now: now, calendar: utc), [], "JSON nulls are absent fields")
        XCTAssertEqual(SummaryProse.details(server: ["mode": "llm"], now: now, calendar: utc), ["AI summary"])
        XCTAssertEqual(SummaryProse.details(server: ["mode": "basic"], now: now, calendar: utc), ["Basic summary"])
        XCTAssertEqual(SummaryProse.details(server: ["mode": "deterministic"], now: now, calendar: utc), ["Basic summary"])
        XCTAssertEqual(SummaryProse.details(server: ["mode": "model"], now: now, calendar: utc), ["AI summary"])
        XCTAssertEqual(SummaryProse.details(server: ["mode": "long_message"], now: now, calendar: utc), ["Long message"])
        XCTAssertEqual(SummaryProse.details(server: ["participants": ["lin-agent", "human-alex"]], now: now, calendar: utc),
                       ["lin-agent and alex"])
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
        XCTAssertEqual(SummaryProse.details(server: ["timeRange": "Friday *morning*"], now: now, calendar: utc),
                       ["Friday *morning*"], "the server's words, as written")
    }

    /// Why a basic summary was written without AI, in plain words: never the server's own reason as it came.
    func test_a_fallback_reason_reads_in_plain_words() {
        let reasons = ["provider disabled", "provider unavailable", "reader cannot generate", "budget exhausted",
                       "invalid prose summary: ungrounded number", "provider attempt failed", "attempt incomplete",
                       "some_new_reason"]
        var notes = Set<String>()
        for reason in reasons {
            guard let note = SummaryProse.fallbackNote(reason) else {
                XCTFail("no note for \(reason)")
                continue
            }
            notes.insert(note)
            XCTAssertFalse(note.lowercased().contains(reason), "\(reason) shown as it came: \(note)")
            for word in ["provider", "invalid", "prose summary", "ungrounded", "_"] {
                XCTAssertFalse(note.lowercased().contains(word), "\(reason): \(note)")
            }
            XCTAssertTrue(note.contains("without AI"), note)
        }
        XCTAssertEqual(SummaryProse.fallbackNote("provider disabled"),
                       "AI summaries are turned off on the server, so this one was written without AI.")
        XCTAssertEqual(SummaryProse.fallbackNote(" Budget Exhausted "),
                       "Today's AI summaries are used up, so this one was written without AI. Try again tomorrow.")
        XCTAssertGreaterThanOrEqual(notes.count, 5, "each kind of reason says its own thing")
        XCTAssertNil(SummaryProse.fallbackNote(nil))
        XCTAssertNil(SummaryProse.fallbackNote("  "))
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
