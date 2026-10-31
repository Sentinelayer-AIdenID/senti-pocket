import Foundation
import PocketUI
import PocketVoice
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// The room's summary as the API answers it. The rooms and people here are made up.
final class RoomSummaryTests: XCTestCase {
    /// The answer as the API's summary documentation gives it, for a made-up room, with its usage figures left out.
    /// Its prose has a star inside a number, code marks and a strike, which the server sends as written.
    static let documentedAnswer = """
    {
      "ok": true,
      "cached": true,
      "pending": false,
      "threadSequenceId": null,
      "version": "9f2e7c1d",
      "persisted": {"ok": true, "sessionId": "room-orchid"},
      "usageMetering": null,
      "summary": {
        "ok": true,
        "format": "prose-v2",
        "summary": "lin-agent posted “Cache review” in Orchid at 14:05Z on 31 Oct, and ada-agent replied at 14:31Z. It opens: “The cache needed 6.4 GB against a 2*3 GB budget.” Next: run `make check` before ~~Friday~~ Monday.",
        "title": "Cache review",
        "mode": "basic",
        "model": "deterministic-fallback",
        "fallbackReason": "provider disabled",
        "auto": true,
        "scope": "room",
        "participants": ["lin-agent", "ada-agent", "human-sam"],
        "timeRange": {"start": "2026-10-31T14:05:12Z", "end": "2026-10-31T14:31:40Z"},
        "room": {"id": "room-orchid", "title": "Orchid", "subroom": false},
        "artifacts": [
          {"kind": "file", "ref": "REPORT.md"},
          {"kind": "sha", "ref": "5e1f0a2c"},
          {"kind": "ticket", "ref": "ORC-041"},
          {"kind": "pr", "ref": "#42"}
        ],
        "messages": 2,
        "highlights": [], "roles": {}, "topContributor": "lin-agent"
      }
    }
    """

    static let documentedProse = "lin-agent posted “Cache review” in Orchid at 14:05Z on 31 Oct, and ada-agent replied at "
        + "14:31Z. It opens: “The cache needed 6.4 GB against a 2*3 GB budget.” Next: run "
        + "`make check` before ~~Friday~~ Monday."

    /// The documented answer with some of its fields changed.
    private static func answer(_ change: (inout [String: Any], inout [String: Any]) -> Void = { _, _ in }) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(documentedAnswer.utf8)) as? [String: Any])
        var summary = try XCTUnwrap(object["summary"] as? [String: Any])
        change(&object, &summary)
        object["summary"] = summary
        return try JSONSerialization.data(withJSONObject: object)
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private var afternoon: Date { ISO8601DateFormatter().date(from: "2026-10-31T15:00:00Z") ?? Date() }

    /// The server's prose is shown exactly as written (its star inside a number, its code marks and its strike), with
    /// its time range, participants and mode in the line under it, and the reason it was written without AI in plain
    /// words. The fields the phone doesn't show (the room, artifacts by `ref`, counts) are read past.
    func test_the_documented_answer_reads_as_the_servers_prose_with_when_who_and_how_under_it() throws {
        let summary = try XCTUnwrap(RoomSummary.decode(Data(Self.documentedAnswer.utf8), now: afternoon, calendar: utc))
        XCTAssertEqual(summary.reading.prose, Self.documentedProse)
        for kept in ["2*3 GB", "`make check`", "~~Friday~~", "“Cache review”"] {
            XCTAssertTrue(summary.reading.prose.contains(kept), kept)
        }
        XCTAssertEqual(summary.title, "Cache review")
        XCTAssertEqual(summary.reading.detailParts.count, 3)
        if summary.reading.detailParts.count == 3 {
            let when = summary.reading.detailParts[0].replacingOccurrences(of: "\u{202F}", with: " ")
                .replacingOccurrences(of: "\u{2009}", with: " ")
            for piece in ["Oct 31", "2:05", "2:31"] { XCTAssertTrue(when.contains(piece), "\(when) has \(piece)") }
            XCTAssertEqual(summary.reading.detailParts[1], "lin-agent, ada-agent and sam")
            XCTAssertEqual(summary.reading.detailParts[2], "Basic summary")
        }
        XCTAssertTrue(summary.isFallback)
        XCTAssertEqual(summary.fallbackNote, "AI summaries are turned off on the server, so this one was written without AI.")
        XCTAssertFalse(summary.isPending)
    }

    /// While a model writes the summary the server answers with its basic one and `pending`; once the model is done the
    /// AI summary reads as one, with no note.
    func test_a_pending_answer_stands_in_until_the_ai_summary_is_written() throws {
        let pending = try XCTUnwrap(RoomSummary.decode(try Self.answer { object, summary in
            object["pending"] = true
            summary["fallbackReason"] = "attempt incomplete"
        }, now: afternoon, calendar: utc))
        XCTAssertTrue(pending.isPending)
        XCTAssertTrue(pending.isFallback)
        XCTAssertEqual(pending.reading.detailParts.last, "Basic summary")

        let written = try XCTUnwrap(RoomSummary.decode(try Self.answer { _, summary in
            summary["mode"] = "llm"
            summary["model"] = "server"
            summary["fallbackReason"] = nil
            summary["summary"] = "lin-agent and ada-agent agreed to run make check before Monday."
        }, now: afternoon, calendar: utc))
        XCTAssertFalse(written.isPending)
        XCTAssertFalse(written.isFallback)
        XCTAssertNil(written.fallbackNote)
        XCTAssertEqual(written.reading.detailParts.last, "AI summary")
        XCTAssertEqual(written.reading.prose, "lin-agent and ada-agent agreed to run make check before Monday.")
    }

    /// Each `fallbackReason` reads in plain words, never as the server wrote it, and only for a basic summary.
    func test_a_fallback_reason_reads_in_plain_words_and_only_for_a_basic_summary() throws {
        for reason in ["provider unavailable", "budget exhausted", "invalid prose summary: section label"] {
            let summary = try XCTUnwrap(RoomSummary.decode(try Self.answer { _, summary in
                summary["fallbackReason"] = reason
            }))
            let note = try XCTUnwrap(summary.fallbackNote, reason)
            XCTAssertFalse(note.contains(reason), note)
            XCTAssertEqual(note, SummaryProse.fallbackNote(reason))
        }
        let ai = try XCTUnwrap(RoomSummary.decode(try Self.answer { _, summary in
            summary["mode"] = "llm"
            summary["model"] = "server"
        }))
        XCTAssertNil(ai.fallbackNote, "an AI summary has no reason to give")
    }

    /// `summary` is null when the server has nothing for the room as it is now: no summary, not an error. An answer
    /// that can't be read is one.
    func test_no_summary_yet_is_none_and_an_unreadable_answer_is_an_error() throws {
        let none = try JSONSerialization.data(withJSONObject: [
            "ok": true, "summary": NSNull(), "cached": false, "pending": false, "threadSequenceId": NSNull(),
            "version": "9f2e7c1d", "persisted": NSNull(), "usageMetering": NSNull()
        ] as [String: Any])
        XCTAssertNil(try RoomSummary.decode(none))
        XCTAssertNil(RoomSummary(json: none))
        XCTAssertThrowsError(try RoomSummary.decode(Data("not json".utf8)))
        let blank = try JSONSerialization.data(withJSONObject: ["ok": true, "summary": ["summary": "  "]] as [String: Any])
        XCTAssertThrowsError(try RoomSummary.decode(blank))
    }

    /// An older server's answer, with no format: the summary sits inside `summary`, and its text is read as an older
    /// server's (its list marks go).
    func test_the_summary_is_read_from_the_apis_answer() throws {
        let body: [String: Any] = [
            "ok": true,
            "summary": ["ok": true, "summary": "  Two findings are fixed.\n\n- Build 319 is green.  ", "title": "Onboarding", "model": "server"],
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

    /// An older server's five labelled parts (no `format`) read as prose: no labels, no @ and no stars, its stock
    /// phrases gone, every name kept, and its title (the objective, mentions and all) not repeated over it.
    func test_an_older_servers_five_parts_read_as_prose_and_keep_every_name() throws {
        let text = "Objective: @human-sam @ada-agent @lin-agent *Lin's adversarial review.\n"
            + "What changed: 1 recorded events; outcomes not verified.\n"
            + "How: 1 participant(s), 0s. Top contributor: lin-agent.\n"
            + "Checks: Tests not verified; RLAIF not reported.\n"
            + "Record: deterministic transcript summary."
        let body: [String: Any] = ["ok": true, "summary": [
            "summary": text, "model": "deterministic-fallback",
            "title": "@human-sam @ada-agent @lin-agent *Lin's adversarial review."
        ]]
        let summary = try XCTUnwrap(RoomSummary(json: try JSONSerialization.data(withJSONObject: body)))
        XCTAssertEqual(summary.reading.prose, "Sam, ada-agent and lin-agent: Lin's adversarial review. Only lin-agent took part.")
        XCTAssertNil(summary.title, "the title only repeats the summary's first sentence")
        XCTAssertNil(summary.reading.details)
        XCTAssertTrue(summary.isFallback)
        XCTAssertNil(summary.fallbackNote, "an older server gives no reason")
    }

    /// The server's title is shown as written; an older server's is read like its summary.
    func test_the_servers_title_is_shown_as_written() {
        XCTAssertEqual(RoomSummary.heading("  Run `make check`, then ship.  ", format: "prose-v2", over: "ada-agent shipped."),
                       "Run `make check`, then ship.")
        XCTAssertEqual(RoomSummary.heading("**Run** `make check`.", format: nil, over: "ada-agent shipped."), "Run make check")
        XCTAssertNil(RoomSummary.heading("Session 1a2b3c4d", format: "prose-v2", over: "ada-agent shipped."))
        XCTAssertNil(RoomSummary.heading("ada-agent shipped", format: "prose-v2", over: "ada-agent shipped it today."))
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

    /// A member who isn't the owner reads the room's saved summary, as the room list has it.
    func test_the_saved_summary_reads_as_it_is() {
        let saved = RoomSummary(saved: " ada-agent ran 2*3 GB. ")
        XCTAssertEqual(saved.reading.prose, "ada-agent ran 2*3 GB.")
        XCTAssertFalse(saved.isPending)
        XCTAssertNil(saved.title)
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

/// While a model writes the summary the sheet reads it again, less and less often, until it settles.
@MainActor
final class RoomSummaryPollingTests: XCTestCase {
    private func summary(_ text: String, pending: Bool) -> RoomSummary {
        RoomSummary(reading: SummaryReading(prose: text), isFallback: pending, isPending: pending)
    }

    func test_a_pending_summary_is_read_again_until_it_settles() async throws {
        var answers: [RoomSummary?] = [summary("Basic.", pending: true), summary("AI.", pending: false)]
        var reads = 0
        var slept: [TimeInterval] = []
        var shown: [String] = []
        let last = try await RoomSummaryPolling.settle(
            summary("Basic.", pending: true),
            read: {
                reads += 1
                return answers.removeFirst()
            },
            sleep: { slept.append($0) },
            update: { shown.append($0.reading.prose) }
        )
        XCTAssertEqual(last, summary("AI.", pending: false))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(slept, Array(RoomSummaryPolling.delays.prefix(2)))
        XCTAssertEqual(shown, ["Basic.", "AI."])
        XCTAssertEqual(RoomSummaryPolling.delays, RoomSummaryPolling.delays.sorted(), "less and less often")
        XCTAssertGreaterThanOrEqual(RoomSummaryPolling.delays.reduce(0, +), 90, "past the server's own minute")
    }

    func test_a_settled_summary_is_not_read_again() async throws {
        var reads = 0
        let first = summary("AI.", pending: false)
        let last = try await RoomSummaryPolling.settle(first, read: {
            reads += 1
            return nil
        }, sleep: { _ in }, update: { _ in })
        XCTAssertEqual(last, first)
        XCTAssertEqual(reads, 0)
    }

    func test_reads_end_when_they_run_out_the_room_moves_on_or_one_fails() async throws {
        var reads = 0
        let stillPending = try await RoomSummaryPolling.settle(summary("Basic.", pending: true), read: {
            reads += 1
            return self.summary("Basic.", pending: true)
        }, sleep: { _ in }, update: { _ in })
        XCTAssertTrue(stillPending.isPending, "it says it isn't ready yet")
        XCTAssertEqual(reads, RoomSummaryPolling.delays.count)

        reads = 0
        let movedOn = try await RoomSummaryPolling.settle(summary("Basic.", pending: true), read: {
            reads += 1
            return nil
        }, sleep: { _ in }, update: { _ in })
        XCTAssertTrue(movedOn.isPending)
        XCTAssertEqual(reads, 1)

        reads = 0
        let failed = try await RoomSummaryPolling.settle(summary("Basic.", pending: true), read: {
            reads += 1
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        }, sleep: { _ in }, update: { _ in })
        XCTAssertTrue(failed.isPending)
        XCTAssertEqual(reads, 1)
    }

    func test_closing_the_sheet_stops_the_reads() async throws {
        var reads = 0
        do {
            _ = try await RoomSummaryPolling.settle(summary("Basic.", pending: true), read: {
                reads += 1
                return nil
            }, sleep: { _ in throw CancellationError() }, update: { _ in })
            XCTFail("a cancelled wait ends the reads")
        } catch is CancellationError {
            XCTAssertEqual(reads, 0)
        }
    }
}

/// A summary cut in a list offers Show more, which opens the whole summary read-only; one that fits offers nothing.
/// Hosted in a window on the simulator, as the room list draws it.
@MainActor
final class SummaryShowMoreTests: XCTestCase {
    func test_a_cut_summary_offers_show_more_and_opens_the_whole_of_it() throws {
        let whole = (1...12).map { "Step \($0): lin-agent moved the cache and ada-agent checked it on 2*3 GB." }
            .joined(separator: " ")
        let window = try HostedSummary.host(VStack(alignment: .leading) {
            SummaryPreviewText(whole, title: "Orchid", identifier: "preview.long")
                .font(.subheadline)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(20))
        defer { HostedSummary.close(window) }
        HostedSummary.pump(0.8)
        let found = HostedSummary.identifiers(in: window)
        XCTAssertTrue(found.contains("preview.long"), "\(found)")
        guard let more = HostedSummary.element("preview.long.more", in: window) else {
            return XCTFail("a cut summary offers no Show more: \(found)")
        }
        XCTAssertTrue(more.accessibilityActivate())
        HostedSummary.pump(1.2)
        let sheet = try XCTUnwrap(window.rootViewController?.presentedViewController, "Show more opened nothing")
        let text = HostedSummary.element("pocket.summary.whole.text", in: sheet.view)
        XCTAssertEqual(text?.accessibilityLabel, whole, "the whole summary, read-only")
        XCTAssertNil(HostedSummary.element("pocket.room.summary.refresh", in: sheet.view), "no Refresh where it is read-only")
        sheet.dismiss(animated: false)
        HostedSummary.pump(0.3)
    }

    func test_a_summary_that_fits_offers_no_show_more() throws {
        let window = try HostedSummary.host(VStack(alignment: .leading) {
            SummaryPreviewText("Ship it.", title: "Orchid", identifier: "preview.short")
                .font(.subheadline)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(20))
        defer { HostedSummary.close(window) }
        HostedSummary.pump(0.8)
        let found = HostedSummary.identifiers(in: window)
        XCTAssertTrue(found.contains("preview.short"), "\(found)")
        XCTAssertFalse(found.contains("preview.short.more"), "\(found)")
    }
}

/// The room's summary sheet: its owner makes the summary and can Refresh it, and while a model writes it the basic
/// summary shows with a note until the AI summary replaces it; every other member reads the saved summary, read-only.
@MainActor
final class RoomSummarySheetTests: XCTestCase {
    private struct Generator: RoomSummaryGenerating {
        let first: RoomSummary?
        let later: RoomSummary?

        func generateSummary(sessionId: String) async throws -> RoomSummary? { first }
        func readSummary(sessionId: String) async throws -> RoomSummary? { later }
    }

    private func sheet(_ generator: Generator?, saved: String? = nil) throws -> UIWindow {
        try HostedSummary.host(RoomSummarySheet(sessionId: "room-orchid", roomTitle: "Orchid", generator: generator,
                                                saved: saved, reader: MessageReader(), onClose: {}))
    }

    func test_a_member_who_isnt_the_owner_reads_the_saved_summary_without_refresh() throws {
        let window = try sheet(nil, saved: "ada-agent ran 2*3 GB and lin-agent merged it.")
        defer { HostedSummary.close(window) }
        HostedSummary.pump(1.0)
        XCTAssertEqual(HostedSummary.element("pocket.room.summary.text", in: window)?.accessibilityLabel,
                       "ada-agent ran 2*3 GB and lin-agent merged it.")
        XCTAssertNil(HostedSummary.element("pocket.room.summary.refresh", in: window), "only the owner can Refresh")
        XCTAssertNil(HostedSummary.element("pocket.room.summary.failure", in: window))
    }

    func test_the_owner_sees_the_basic_summary_while_the_ai_summary_is_written_then_the_ai_summary() throws {
        let basic = RoomSummary(reading: SummaryReading(prose: "lin-agent posted a review.", details: ["Basic summary"]),
                                isFallback: true, fallbackNote: SummaryProse.fallbackNote("attempt incomplete"),
                                isPending: true)
        let written = RoomSummary(reading: SummaryReading(prose: "lin-agent reviewed the cache and ada-agent agreed.",
                                                          details: ["AI summary"]))
        let window = try sheet(Generator(first: basic, later: written))
        defer { HostedSummary.close(window) }
        HostedSummary.pump(1.0)
        XCTAssertNotNil(HostedSummary.element("pocket.room.summary.refresh", in: window), "the owner can Refresh")
        XCTAssertNotNil(HostedSummary.element("pocket.room.summary.pending", in: window), "it says the AI summary is coming")
        XCTAssertEqual(HostedSummary.element("pocket.room.summary.text", in: window)?.accessibilityLabel,
                       "lin-agent posted a review.")
        XCTAssertNil(HostedSummary.element("pocket.room.summary.note", in: window), "no reason while it is still being written")

        // The first read again comes after RoomSummaryPolling's first delay.
        HostedSummary.pump(RoomSummaryPolling.delays[0] + 1.5)
        XCTAssertEqual(HostedSummary.element("pocket.room.summary.text", in: window)?.accessibilityLabel,
                       "lin-agent reviewed the cache and ada-agent agreed.")
        XCTAssertNil(HostedSummary.element("pocket.room.summary.pending", in: window))
    }

    func test_a_basic_summary_says_why_in_plain_words() throws {
        let basic = RoomSummary(reading: SummaryReading(prose: "lin-agent posted a review.", details: ["Basic summary"]),
                                isFallback: true, fallbackNote: SummaryProse.fallbackNote("budget exhausted"))
        let window = try sheet(Generator(first: basic, later: nil))
        defer { HostedSummary.close(window) }
        HostedSummary.pump(1.0)
        XCTAssertEqual(HostedSummary.element("pocket.room.summary.note", in: window)?.accessibilityLabel,
                       SummaryProse.fallbackNote("budget exhausted"))
        XCTAssertNil(HostedSummary.element("pocket.room.summary.pending", in: window))
    }
}

/// Hosts a view in a window on the simulator and reads it the way VoiceOver does.
@MainActor
enum HostedSummary {
    /// SwiftUI builds its accessibility elements only for an assistive technology or for UI automation. A hosted test
    /// turns UI automation on while it runs, as snapshot-testing tools do, so it reads what VoiceOver reads; `close`
    /// turns it off again, so no other test runs with it.
    private static let setAutomation: (@convention(c) (Bool) -> Void)? = {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (Bool) -> Void).self)
    }()

    static func host<Content: View>(_ content: Content) throws -> UIWindow {
        let setAutomation = try XCTUnwrap(Self.setAutomation, "UI automation could not be turned on")
        setAutomation(true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
        window.windowLevel = .normal + 5
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        return window
    }

    static func close(_ window: UIWindow) {
        window.isHidden = true
        pump(0.2)
        setAutomation?(false)
    }

    static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }

    /// Every accessibility element under a view: the views, and the elements they hold.
    static func elements(in root: Any) -> [NSObject] {
        var found: [NSObject] = []
        var queue: [Any] = [root]
        var seen = Set<ObjectIdentifier>()
        while !queue.isEmpty {
            guard let object = queue.removeFirst() as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            found.append(object)
            if let view = object as? UIView { queue.append(contentsOf: view.subviews) }
            if let children = object.accessibilityElements { queue.append(contentsOf: children) }
            let count = object.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) { queue.append(child) }
                }
            }
        }
        return found
    }

    static func identifier(of object: NSObject) -> String? {
        if let identified = object as? UIAccessibilityIdentification { return identified.accessibilityIdentifier }
        guard object.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
        return object.value(forKey: "accessibilityIdentifier") as? String
    }

    static func identifiers(in root: Any) -> [String] {
        elements(in: root).compactMap { identifier(of: $0) }.filter { !$0.isEmpty }
    }

    static func element(_ wanted: String, in root: Any) -> NSObject? {
        elements(in: root).first { identifier(of: $0) == wanted }
    }
}
