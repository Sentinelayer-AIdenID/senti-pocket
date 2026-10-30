import Foundation
import XCTest
@testable import PocketUI

final class ComposerDraftTests: XCTestCase {
    /// Carter (#54997 reply): the same "Chat about it" as the web, so the room shows the ticket card.
    func test_chat_about_it_posts_the_webs_card_raiser_and_note() {
        let room = "e9e8dc5e-8d57-4603-975f-09156e3b4473"
        XCTAssertEqual(
            TicketDecision.chatAboutIt(sessionId: room, ticketId: "ba811458", title: "Lower [the] box",
                                       note: "  can someone take this?  ", raisedBy: "mrrcarter"),
            "[Ticket: Lower the box](/dashboard/sessions/\(room)?ticket=ba811458) — raised by mrrcarter\n\ncan someone take this?"
        )
        XCTAssertEqual(
            TicketDecision.chatAboutIt(sessionId: room, ticketId: "t1", title: "Fix", note: "", raisedBy: nil),
            "[Ticket: Fix](/dashboard/sessions/\(room)?ticket=t1)", "no note and no raiser: the card alone"
        )
    }

    /// Carter and warden: plain words become a ticket; the keeper files the marked message.
    func test_a_ticket_request_is_marked_once() {
        XCTAssertEqual(RoomComposerDraft.ticketRequest("  Let the text box lower when I scroll  "),
                       "🎫 Ticket: Let the text box lower when I scroll")
        XCTAssertEqual(RoomComposerDraft.ticketRequest("🎫 Ticket: already marked"), "🎫 Ticket: already marked")
    }

    func test_restored_text_fills_an_empty_composer() {
        XCTAssertEqual(RoomComposerDraft.restoring("Ship it", into: ""), "Ship it")
        XCTAssertEqual(RoomComposerDraft.restoring("Ship it", into: "  \n "), "Ship it", "whitespace counts as empty")
    }

    func test_restored_text_never_overwrites_what_you_typed_since() {
        XCTAssertEqual(RoomComposerDraft.restoring("Ship it", into: "Also"), "Also\nShip it")
    }

    func test_each_restore_request_is_distinct_even_for_the_same_text() {
        XCTAssertNotEqual(RoomComposerRestore(text: "Ship it"), RoomComposerRestore(text: "Ship it"),
                          "editing the same failed text twice must restore it twice")
    }

    func test_a_failed_row_offers_copy_when_there_is_no_composer_to_edit_in() {
        XCTAssertEqual(RoomPendingRecovery(canPost: true), .edit)
        XCTAssertEqual(RoomPendingRecovery(canPost: false), .copy,
                       "after a refusal the composer is gone, so Edit would discard the text")
    }
}
