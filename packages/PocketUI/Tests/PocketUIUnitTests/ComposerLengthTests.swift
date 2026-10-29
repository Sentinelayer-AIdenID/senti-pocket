import Foundation
import XCTest
@testable import PocketUI

final class ComposerLengthTests: XCTestCase {
    func test_a_draft_over_the_limit_is_held_in_the_composer_with_a_reason() {
        let composer = RoomComposerState(canPost: true, disabledReason: nil, maximumLength: 10)
        XCTAssertNil(composer.lengthProblem(for: "0123456789"))
        XCTAssertNil(composer.lengthProblem(for: "  0123456789  "), "surrounding spaces are not sent")
        XCTAssertEqual(composer.lengthProblem(for: "0123456789x"), "Too long to send: 11 of 10 characters.")
        XCTAssertNil(RoomComposerState.enabled.lengthProblem(for: String(repeating: "a", count: 100_000)),
                     "no known limit, no problem")
    }

    func test_the_limit_counts_code_points_as_the_api_does() {
        let composer = RoomComposerState(canPost: true, disabledReason: nil, maximumLength: 10)
        // Six waving hands with a skin tone: six characters on screen, twelve code points to the API.
        let waves = String(repeating: "\u{1F44B}\u{1F3FD}", count: 6)
        XCTAssertEqual(waves.count, 6)
        XCTAssertEqual(composer.lengthProblem(for: waves), "Too long to send: 12 of 10 characters.")
    }

    func test_a_pending_row_keeps_its_full_text_and_only_the_display_is_cut() {
        let long = String(repeating: "b", count: 70_000)
        let row = RoomChatPendingRow(clientId: "hm_1", text: long, status: .failed(reason: "Too long", canRetry: false))
        XCTAssertEqual(row.text.count, 70_000, "retry and edit use the full text")
        XCTAssertEqual(row.displayText.count, 281)
        XCTAssertEqual(RoomChatPendingRow(clientId: "hm_2", text: "short", status: .sending).displayText, "short")
    }
}
