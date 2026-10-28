import Foundation
import XCTest
@testable import PocketUI

final class RoomBreakoutPresentationTests: XCTestCase {
    func test_card_lines_name_two_people_and_count_the_rest() {
        let card = RoomBreakoutCard(childSessionId: "c", title: "T", participantNames: ["warden", "coral", "griff", "box"], messageCount: 1)
        XCTAssertEqual(card.participantsLine, "warden, coral +2")
        XCTAssertEqual(card.messagesLine, "1 message")
        XCTAssertNil(RoomBreakoutCard(childSessionId: "c", title: "T").participantsLine, "withheld people are not guessed")
        XCTAssertEqual(RoomBreakoutCard(childSessionId: "c", title: "T", messageCount: 12).messagesLine, "12 messages")
    }

    func test_an_outcome_only_says_all_acknowledged_when_everyone_did() {
        typealias Ack = RoomBreakoutOutcomeCard.Acknowledgement
        let all = RoomBreakoutOutcomeCard(childSessionId: "c", text: "x", authorName: "coral",
                                          acknowledgements: [Ack(name: "coral", state: .ack), Ack(name: "warden", state: .ack)])
        XCTAssertEqual(all.acknowledgementSummary, "All 2 acknowledged")
        let mixed = RoomBreakoutOutcomeCard(childSessionId: "c", text: "x", authorName: "coral", acknowledgements: [
            Ack(name: "coral", state: .ack), Ack(name: "warden", state: .disagree), Ack(name: "box", state: .missing)
        ])
        XCTAssertEqual(mixed.acknowledgementSummary, "1 of 3 acknowledged · disagreed: warden · waiting on: box")
        XCTAssertEqual(RoomBreakoutOutcomeCard(childSessionId: "c", text: "x", authorName: "a", acknowledgements: []).acknowledgementSummary,
                       "No acknowledgements were required")
    }

    func test_the_list_shows_open_breakouts_first_then_the_newest() {
        let old = RoomBreakoutCard(childSessionId: "old", title: "Old", createdDate: Date(timeIntervalSince1970: 100))
        let new = RoomBreakoutCard(childSessionId: "new", title: "New", createdDate: Date(timeIntervalSince1970: 200))
        let closed = RoomBreakoutCard(childSessionId: "closed", title: "Closed", isOpen: false, createdDate: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(RoomBreakoutOrdering.sorted([old, closed, new]).map(\.childSessionId), ["new", "old", "closed"])
    }

    func test_a_protected_failure_hides_breakout_cards() {
        let cards = ["c": RoomBreakoutCard(childSessionId: "c", title: "T")]
        let shown = RoomChatPresentationState(sessionId: "r", title: "R", messages: [], breakouts: cards)
        XCTAssertEqual(shown.breakouts.count, 1)
        let denied = RoomChatPresentationState(sessionId: "r", title: "R", messages: [], failure: .accessDenied, breakouts: cards)
        XCTAssertTrue(denied.breakouts.isEmpty)
    }
}
