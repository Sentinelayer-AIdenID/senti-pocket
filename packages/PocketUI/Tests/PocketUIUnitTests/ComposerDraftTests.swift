import Foundation
import XCTest
@testable import PocketUI

final class ComposerDraftTests: XCTestCase {
    /// Carter (#54997 reply): the same "Chat about it" as the web, so the room shows the ticket card.
    func test_chat_about_it_posts_the_webs_card_raiser_and_note() {
        let room = "00000000-0000-4000-8000-00000000a215"
        XCTAssertEqual(
            TicketDecision.chatAboutIt(sessionId: room, ticketId: "0000c215", title: "Lower [the] box",
                                       note: "  can someone take this?  ", raisedBy: "mrrcarter"),
            "[Ticket: Lower the box](/dashboard/sessions/\(room)?ticket=0000c215) — raised by mrrcarter\n\ncan someone take this?"
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


    /// Carter (#55006): a very long paste sits above the field as an attachment, and is sent after the typed words.
    func test_a_long_paste_is_held_apart_and_sent_after_the_words() {
        let block = String(repeating: "log line\n", count: 150)
        let typed = "see the log: "
        let pasted = RoomComposerDraft.pastedBlock(from: typed, to: typed + block)
        XCTAssertEqual(pasted?.draft, typed, "the draft keeps what was typed")
        XCTAssertEqual(pasted?.block, block)
        let midway = RoomComposerDraft.pastedBlock(from: "ab", to: "a" + block + "b")
        XCTAssertEqual(midway?.block, block, "a paste in the middle of the words")
        XCTAssertEqual(midway?.draft, "ab")
        XCTAssertNil(RoomComposerDraft.pastedBlock(from: "hello", to: "hello world"), "typing is never a paste")
        XCTAssertNil(RoomComposerDraft.pastedBlock(from: "", to: String(repeating: "a", count: 999)), "short of the length")
        XCTAssertEqual(RoomComposerDraft.outgoing("  look  ", blocks: ["one", "two"]), "look\n\none\n\ntwo")
        XCTAssertEqual(RoomComposerDraft.outgoing("", blocks: ["only"]), "only", "a paste alone can be sent")
        XCTAssertEqual(RoomComposerDraft.outgoing("  ", blocks: []), "")
    }

    /// Carter (#55006): a very long message shows its start and a card that opens all of it.
    func test_a_long_message_shows_its_start_and_closes_a_code_block_it_cuts() {
        XCTAssertFalse(LongMessage.isLong("short"))
        XCTAssertTrue(LongMessage.isLong(String(repeating: "x", count: 1_501)))
        XCTAssertTrue(LongMessage.isLong(Array(repeating: "line", count: 31).joined(separator: "\n")), "many short lines")
        let text = (["Intro line"] + ["```swift"] + (1...40).map { "let x\($0) = \($0)" } + ["```"]).joined(separator: "\n")
        let preview = LongMessage.preview(text)
        XCTAssertTrue(preview.hasPrefix("Intro line\n```swift\nlet x1 = 1"))
        XCTAssertTrue(preview.hasSuffix("```"), "the cut code block is closed")
        XCTAssertEqual(preview.components(separatedBy: "```").count % 2, 1, "fences come in pairs")
        XCTAssertLessThanOrEqual(preview.split(separator: "\n").count, 9)
    }

    /// Carter, 10-30: "the crash happened and I lost all the things I was saying". A room's unsent text is kept on the
    /// phone under its own key.
    func test_each_room_keeps_its_unsent_text_under_its_own_key() {
        XCTAssertEqual(RoomComposerDraft.savedKey(sessionId: "room-a"), "pocket.draft.room-a")
        XCTAssertNotEqual(RoomComposerDraft.savedKey(sessionId: "room-a"), RoomComposerDraft.savedKey(sessionId: "room-b"))
        XCTAssertGreaterThanOrEqual(RoomComposerDraft.savedAfterSend, 5, "kept long enough for the send to be on its way")
    }

    /// The keyboard can write the sent text back into the emptied box (dictation, a pending correction); that is not
    /// a paste to hold as an attachment.
    func test_the_sent_text_written_back_is_told_from_new_typing() {
        let sent = "Can you make sure the tables fit the screen"
        XCTAssertTrue(RoomComposerDraft.isWrittenBack(sent, sent: sent))
        XCTAssertTrue(RoomComposerDraft.isWrittenBack(" screen
", sent: sent), "its last word, committed late")
        XCTAssertFalse(RoomComposerDraft.isWrittenBack("Also the logo", sent: sent), "new words are new")
        XCTAssertFalse(RoomComposerDraft.isWrittenBack("  ", sent: sent))
    }
}
