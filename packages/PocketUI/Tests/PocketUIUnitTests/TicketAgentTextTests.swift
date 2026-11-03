import Foundation
import XCTest
@testable import PocketUI

final class TicketAgentTextTests: XCTestCase {
    /// sentinelayer-web `hideSignalModelName`: the signal model's name never shows on a ticket.
    func test_the_signal_models_name_is_hidden_as_the_web_hides_it() {
        XCTAssertEqual(TicketSignal.hideModelName("Route it through Jev first"), "Route it through the signal layer first")
        XCTAssertEqual(TicketSignal.hideModelName("jev-2 and JEV 1.5 and JevAPI"),
                       "the signal layer and the signal layer and the signal layer")
        XCTAssertEqual(TicketSignal.hideModelName("Jevons paradox"), "Jevons paradox", "a longer word is not the name")
        XCTAssertEqual(TicketSignal.publicTitle("   "), "(untitled)")
        XCTAssertEqual(TicketSignal.publicTitle(" Wire Jev into Omar "), "Wire the signal layer into Omar")
        let row = RoomTicketRow(id: "t", title: "Jev gate", body: "Ask jev.", status: "open")
        XCTAssertEqual(row.displayTitle, "the signal layer gate")
        XCTAssertEqual(row.displayBody, "Ask the signal layer.")
        XCTAssertEqual(row.title, "Jev gate", "edits keep the ticket's own words")
    }

    /// sentinelayer-web `ticketMintPrefill` and `ticketJobDescription`.
    func test_an_agent_for_a_ticket_is_named_from_its_id_and_starts_from_the_ticket() {
        XCTAssertEqual(TicketAgent.agentName(for: " 36d92287-aaaa-bbbb "), "mint-36d92287")
        let job = TicketAgent.jobDescription(ticketId: "36d92287-aaaa", title: "Wire Jev in", status: "open",
                                             sessionId: "room-1", body: "Do it.\r\nThen test.")
        XCTAssertEqual(job, """
        Ticket: 36d92287-aaaa
        Title: Wire the signal layer in
        Status: open
        Room: room-1

        Description:
        Do it.
        Then test.

        You were minted for this ticket. Read it, post a short plan in the room, do the work in your machine, \
        and when a PR finishes it put the line `Closes-Ticket: 36d92287` in the PR body.
        """)
        XCTAssertTrue(TicketAgent.jobDescription(ticketId: "x", title: "", status: "", sessionId: "r", body: "")
            .contains("Title: (untitled)\nStatus: unknown"))
    }
}
