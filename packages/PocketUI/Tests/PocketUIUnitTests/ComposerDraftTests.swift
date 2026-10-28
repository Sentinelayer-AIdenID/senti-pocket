import Foundation
import XCTest
@testable import PocketUI

final class ComposerDraftTests: XCTestCase {
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
