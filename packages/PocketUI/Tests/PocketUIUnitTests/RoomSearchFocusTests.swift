import XCTest
@testable import PocketUI

final class RoomSearchFocusTests: XCTestCase {
    func test_matches_after_the_cutoff_preserve_every_character() {
        let text = String(repeating: "before ", count: 250) + "Néedle tail needle"
        XCTAssertTrue(LongMessage.isLong(text))
        XCTAssertFalse(LongMessage.preview(text).contains("Néedle"))
        let parts = RoomSearchText.fragments(text, query: "needle")
        XCTAssertEqual(parts.map(\.text).joined(), text)
        XCTAssertEqual(parts.filter(\.isMatch).map(\.text), ["Néedle", "needle"])
    }

    func test_query_words_are_literal_and_overlapping_matches_do_not_duplicate_text() {
        let text = "<script> ** cafe CAFÉ [x] a+b banana 👋"
        let parts = RoomSearchText.fragments(text, query: "<script> [x] a+b café ana banana")
        XCTAssertEqual(parts.map(\.text).joined(), text)
        XCTAssertEqual(parts.filter(\.isMatch).map(\.text), ["<script>", "cafe", "CAFÉ", "[x]", "a+b", "banana"])
        XCTAssertEqual(RoomSearchText.fragments(text, query: "missing").map(\.text).joined(), text)
        XCTAssertFalse(RoomSearchText.fragments(text, query: " ").contains(where: \.isMatch))
    }

    func test_only_the_selected_message_gets_the_expansion_and_highlight() throws {
        func message(_ sequence: Int64) -> RoomChatMessageInput {
            RoomChatMessageInput(id: "event-\(sequence)", sequenceId: sequence, kind: .message,
                                 authorId: "human-reader", authorName: "Reader", isHuman: true,
                                 text: String(repeating: "long ", count: 250) + "needle",
                                 timestamp: "2026-11-01T12:00:00Z")
        }
        let focus = RoomSearchFocus(sequenceId: 2, query: "needle")
        let state = RoomChatPresentationState(sessionId: "chat", title: "Chat",
                                              messages: [message(1), message(2)], searchFocus: focus)
        let rows = state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(state.searchFocus(for: try XCTUnwrap(rows.first)))
        XCTAssertEqual(state.searchFocus(for: try XCTUnwrap(rows.last)), focus)
        XCTAssertNil(state.focusSequenceId, "the expanded target survives after the initial row jump is handled")
    }
}
