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
}
