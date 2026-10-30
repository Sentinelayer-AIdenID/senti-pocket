import Foundation
import XCTest
@testable import PocketSyncClient

/// Ticket 931e1d2e: one list of what waits on you, read from `GET /api/v1/me/waiting`, answered with the web's line.
final class SentiWaitingTests: XCTestCase {
    func test_the_page_reads_each_ask_and_the_total_and_skips_malformed_rows() throws {
        let page = try JSONDecoder().decode(SentiWaitingPage.self, from: Data("""
        {"total": 7, "nextCursor": "c2", "items": [
          {"kind": "decision", "roomId": "e9e8dc5e-8d57-4603-975f-09156e3b4473", "roomTitle": "Senti-expansion-proj",
           "ticketId": "931e1d2e-27b8-4bd8-822b-b2ff06fd8b85", "title": "Rotate the signer",
           "question": "Rotate now or after the release?", "options": ["Now", " After ", ""], "custom": true,
           "askedAt": "2026-10-30T18:00:00Z", "askedBy": "claude-warden", "assignee": "pocket-forge"},
          {"kind": "decision", "roomId": "../etc", "ticketId": "t-2", "title": "Bad room"},
          {"kind": "decision", "roomId": "room-1", "title": "No ticket"}
        ]}
        """.utf8))
        XCTAssertEqual(page.total, 7, "the badge counts beyond this page")
        XCTAssertEqual(page.nextCursor, "c2")
        XCTAssertEqual(page.items.count, 1)
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.options, ["Now", "After"], "trimmed, empties dropped")
        XCTAssertTrue(item.custom)
        XCTAssertEqual(item.askedBy, "claude-warden")
        XCTAssertEqual(item.assignee, "pocket-forge")
    }

    /// The same strings as sentinelayer-web `ticketDecision.test.ts` for `decisionChatLine`.
    func test_the_answer_is_the_webs_decision_line_word_for_word() {
        let card = "[Ticket: Rotate the signer](/dashboard/sessions/room-1?ticket=t-1)"
        func item(_ assignee: String?) -> SentiWaitingItem {
            SentiWaitingItem(roomId: "room-1", roomTitle: "Room", ticketId: "t-1", title: "Rotate the signer",
                             question: "?", assignee: assignee)
        }
        XCTAssertEqual(item("fable-xhigh").answerLine("Yes"), "Decision on \(card): Yes @fable-xhigh")
        XCTAssertEqual(item("fable-xhigh").answerLine("Custom", detail: "  ship Monday  "),
                       "Decision on \(card): Custom — ship Monday @fable-xhigh")
        XCTAssertEqual(item("7a0b1c2d-0000-4000-8000-00000000aaaa").answerLine("Go with blue", personName: "mrrCarter"),
                       "Decision on \(card): Go with blue (for mrrCarter)")
        XCTAssertEqual(item(nil).answerLine("No"), "Decision on \(card): No")
    }

    func test_the_card_keeps_to_one_line_without_brackets_and_encodes_its_link() {
        let item = SentiWaitingItem(roomId: "room 1", roomTitle: "", ticketId: "t:1", title: "Fix [the]\nlogo\t now",
                                    question: "")
        XCTAssertEqual(item.answerLine("Yes"),
                       "Decision on [Ticket: Fix the logo now](/dashboard/sessions/room%201?ticket=t%3A1): Yes")
        let untitled = SentiWaitingItem(roomId: "r", roomTitle: "", ticketId: "t", title: "  ", question: "")
        XCTAssertEqual(untitled.answerLine("Yes"), "Decision on [Ticket: (untitled)](/dashboard/sessions/r?ticket=t): Yes")
    }
}
