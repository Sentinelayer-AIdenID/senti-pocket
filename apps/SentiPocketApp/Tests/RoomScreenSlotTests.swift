import SwiftUI
import XCTest
import PocketVoice
@testable import SentiPocketApp

/// The room screen on screen is made once for what it is opened with (`RoomScreenSlot`): the room, its saved summary and
/// whether direct messages are on. Draws of the root with none of those changed, and draws of the slot's view (SwiftUI
/// was seen to make a room screen again at a draw of the root without asking its host's `==`, 11-06), give the same
/// screen; a change of any of them makes it once more.
@MainActor
final class RoomScreenSlotTests: XCTestCase {
    private var made: [String?] = []

    private func maker() -> @MainActor (RoomRoute, String?) -> RoomChatScreen {
        let api = RootPreviewAPI(postsPerSecond: 0, onePage: false, openRoomId: nil)
        let reader = MessageReader()
        return { [weak self] route, summary in
            self?.made.append(summary)
            return RoomChatScreen(route: route, transport: api, reader: reader, onReauthenticationRequired: {})
        }
    }

    func test_the_same_opening_keeps_its_revision_and_its_screen_is_made_once() {
        let slot = RoomScreenSlot()
        let route = RoomRoute(sessionId: "room-a", title: "A")
        let make = maker()
        let revision = slot.open(route, savedSummary: "What it is about", directMessagesOn: false, make: make)
        XCTAssertNotNil(slot.screen)
        for _ in 1...5 {
            XCTAssertEqual(slot.open(route, savedSummary: "What it is about", directMessagesOn: false, make: make), revision,
                           "a draw of the root with nothing changed keeps the revision")
            _ = RoomScreenSlotView(slot: slot, revision: revision).body
            XCTAssertNotNil(slot.screen)
        }
        XCTAssertEqual(made, ["What it is about"], "made once for the same opening, however often it is drawn")
    }

    func test_a_changed_opening_makes_the_screen_once_more() {
        let slot = RoomScreenSlot()
        let route = RoomRoute(sessionId: "room-a", title: "A")
        let make = maker()
        let first = slot.open(route, savedSummary: nil, directMessagesOn: false, make: make)
        _ = slot.screen
        let summary = slot.open(route, savedSummary: "Now with a summary", directMessagesOn: false, make: make)
        XCTAssertNotEqual(summary, first, "a new saved summary is a new revision")
        _ = slot.screen
        _ = slot.screen
        let direct = slot.open(route, savedSummary: "Now with a summary", directMessagesOn: true, make: make)
        XCTAssertNotEqual(direct, summary, "direct messages turning on is a new revision")
        _ = slot.screen
        let moved = slot.open(RoomRoute(sessionId: "room-a", title: "A", focusSequenceId: 12),
                              savedSummary: "Now with a summary", directMessagesOn: true, make: make)
        XCTAssertNotEqual(moved, direct, "the room opened at a message is a new revision")
        _ = slot.screen
        XCTAssertEqual(made, [nil, "Now with a summary", "Now with a summary", "Now with a summary"],
                       "made once for each opening")
    }

    func test_slots_are_kept_for_the_rooms_shown_and_let_go_after() {
        let slots = RoomScreenSlots()
        let a = RoomRoute(sessionId: "room-a", title: "A")
        let b = RoomRoute(sessionId: "room-b", title: "B")
        let slotA = slots.slot(for: a)
        XCTAssertTrue(slots.slot(for: a) === slotA, "the same room keeps its slot")
        _ = slots.slot(for: b)
        slots.keep([b])
        XCTAssertFalse(slots.slot(for: a) === slotA, "a room no longer shown lost its slot")
    }
}
