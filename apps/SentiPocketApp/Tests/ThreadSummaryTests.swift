import Foundation
import PocketUI
import XCTest
@testable import SentiPocketApp

/// Carter, #55474: "I wish I had the summarized here at top level before I even open the thread." What the on-device
/// model reads, and what the row shows.
final class ThreadSummaryTests: XCTestCase {
    private func reply(_ seq: Int64, _ author: String, _ text: String, minutes: Double) -> RoomChatMessageInput {
        RoomChatMessageInput(id: "r\(seq)", sequenceId: 55474, kind: .message, authorId: author, authorName: author,
                             isHuman: author.hasPrefix("human-"), text: text, timestamp: "",
                             date: Date(timeIntervalSince1970: 1_793_000_000 + minutes * 60))
    }

    func test_the_model_reads_who_said_what_oldest_first_without_signatures() {
        let lines = ThreadSummaryInput.lines([
            reply(3, "claude-warden", "CI is **green**", minutes: 3),
            reply(1, "astra-gnu-runbook", "Recorded your update.\n⟂ speech 4e37b573 · managed", minutes: 1),
            reply(2, "astra-gnu-runbook", String(repeating: "long ", count: 200), minutes: 2)
        ])
        XCTAssertEqual(lines.first, "astra-gnu-runbook: Recorded your update.")
        XCTAssertTrue(lines[1].hasSuffix("…"))
        XCTAssertLessThanOrEqual(lines[1].count, "astra-gnu-runbook: ".count + ThreadSummaryInput.maximumLineLength + 1)
        XCTAssertEqual(lines.last, "claude-warden: CI is green")
    }

    func test_only_the_newest_replies_of_a_long_thread_are_read() {
        let many = (0..<40).map { reply(Int64($0), "box", "step \($0)", minutes: Double($0)) }
        let lines = ThreadSummaryInput.lines(many)
        XCTAssertEqual(lines.count, ThreadSummaryInput.maximumLines)
        XCTAssertEqual(lines.last, "box: step 39")
    }

    func test_the_answer_is_one_plain_bounded_paragraph() {
        XCTAssertEqual(ThreadSummaryInput.cleaned("**Done.** The PR\nis merged.\n\n# Next"), "Done. The PR is merged. Next")
        XCTAssertNil(ThreadSummaryInput.cleaned("  \n "))
        let long = ThreadSummaryInput.cleaned(String(repeating: "word ", count: 100))
        XCTAssertEqual(long?.count, ThreadSummaryInput.maximumSummaryLength + 1)
    }

    /// Carter (10-30): the record is "the specific commit block or cryptographic hash mapping the work directly back".
    /// It is copied from the thread, never written by the model, and plain words or numbers are not taken for one.
    func test_the_record_is_the_commits_prs_and_builds_the_thread_names_each_once() {
        let lines = [
            "claude-warden: #253 (bf68d264): pass. Merged at 402ef9d3 after #1054.",
            "pocket-forge: TestFlight 2026103014 is live from 6bcfc61f; #253 again.",
            "astra-web: decade added deadbeef cafe 1234567 and 3.14",
            "claude-warden: reply #55514: re-review below"
        ]
        XCTAssertEqual(ThreadSummaryInput.record(in: lines),
                       ["#253", "bf68d264", "402ef9d3", "#1054", "2026103014", "6bcfc61f"])
    }

    /// Carter (10-31): the parts read as one paragraph in his order, without labels. An empty part and a stock
    /// "None mentioned" are left out, the ids the thread names come last, and with no objective there is no summary.
    func test_the_summary_is_one_paragraph_in_carters_order_without_labels() throws {
        let text = try XCTUnwrap(ThreadSummaryInput.composed(
            objective: "Stop Pocket freezing at send.", changed: "A send from up the history reopens the room.",
            how: "pocket-forge changed RoomChatView; warden reviewed.", checks: "None mentioned", record: ["#262", "cdec7a2c"]))
        XCTAssertEqual(text, "Stop Pocket freezing at send. A send from up the history reopens the room. "
            + "pocket-forge changed RoomChatView; warden reviewed. The thread names #262 and cdec7a2c.")
        for mark in ["Objective", "What changed", "How:", "Checks", "Record", "**", "`", "None mentioned"] {
            XCTAssertFalse(text.contains(mark), mark)
        }
        XCTAssertEqual(SummaryReading(text).prose, text, "the row shows the prose as written")
        XCTAssertEqual(ThreadSummaryInput.composed(objective: "Ship it", changed: "", how: "", checks: "", record: []), "Ship it.")
        XCTAssertNil(ThreadSummaryInput.composed(objective: " ", changed: "x", how: "y", checks: "z", record: []))
    }

    /// Under the summary: when the thread's replies were written, and who wrote them, most replies first.
    func test_the_line_under_a_thread_summary_says_when_and_who() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = Locale(identifier: "en_US")
        let thread = [
            reply(1, "claude-warden", "Reviewed.", minutes: 0),
            reply(2, "pocket-forge", "Fixed.", minutes: 30),
            reply(3, "pocket-forge", "Pushed.", minutes: 42)
        ]
        let details = ThreadSummaryInput.details(thread, now: Date(timeIntervalSince1970: 1_793_010_000), calendar: calendar)
        XCTAssertEqual(details.count, 2)
        guard details.count == 2 else { return }
        let when = details[0].replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{2009}", with: " ")
        for piece in ["Oct 26", "7:33", "8:15"] { XCTAssertTrue(when.contains(piece), "\(when) has \(piece)") }
        XCTAssertEqual(details[1], "pocket-forge and claude-warden")
        XCTAssertEqual(ThreadSummaryInput.details([], calendar: calendar), [])
    }
}
