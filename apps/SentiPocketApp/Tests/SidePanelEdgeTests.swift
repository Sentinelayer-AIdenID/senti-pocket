import Combine
import CoreGraphics
import PocketUI
import XCTest
@testable import SentiPocketApp

/// Carter, 11-06: a drag all the way from the left edge opens the side panel. A drag that starts within
/// `SidePanelEdgeDrag.zone` of the screen's left edge and goes right is the edge's: editing ends at its first move (the
/// keyboard starts going down before the room follows the finger), and let go far enough it opens the panel as the
/// button does, through `SidePanelState.open`. Anywhere else a drag stays the room's, and a row's swipe to reply still
/// replies. Nothing opens under a sheet. The drags themselves are driven on a simulator by `SidePanelEdgeSwipeUITests`.
@MainActor
final class SidePanelEdgeTests: XCTestCase {
    private let width: CGFloat = 300

    /// Mutant: the edge's drag opening the panel by setting `isOpen` itself, past `open` and its end-editing step.
    func test_an_edge_drag_ends_editing_first_and_opens_as_the_button_does() {
        let (state, seen, watching) = watched()

        XCTAssertTrue(state.beginEdgeDrag(start: CGPoint(x: 5, y: 400), translation: CGSize(width: 12, height: 2),
                                          allowed: true), "a drag from 5 pt is the edge's")
        XCTAssertEqual(seen.events, ["editing ended, the panel closed"],
                       "editing ends at the drag's first move, before the room follows the finger")
        XCTAssertTrue(state.edgeClaim.isClaimed, "the rows leave the drag to the edge")

        state.endEdgeDrag(translation: 160, predicted: 220, width: width)
        XCTAssertEqual(seen.events, ["editing ended, the panel closed", "editing ended, the panel closed", "opening"],
                       "let go past a third of the way, it opens as the button opens it: editing ended, then open")
        XCTAssertTrue(state.isOpen)
        XCTAssertFalse(state.edgeClaim.isClaimed, "the rows have their swipe back")
        withExtendedLifetime(watching) {}
    }

    /// A short drag from the edge, let go, opens nothing; the room springs back.
    func test_a_short_edge_drag_opens_nothing() {
        let (state, seen, watching) = watched()
        XCTAssertTrue(state.beginEdgeDrag(start: CGPoint(x: 3, y: 300), translation: CGSize(width: 10, height: 0),
                                          allowed: true))
        state.endEdgeDrag(translation: 60, predicted: 90, width: width)
        XCTAssertFalse(state.isOpen, "a third of the way not reached, nor flung past half of it")
        XCTAssertEqual(seen.events, ["editing ended, the panel closed"])
        XCTAssertFalse(state.edgeClaim.isClaimed)
        withExtendedLifetime(watching) {}
    }

    /// Mutant: the edge's zone too wide (60 pt), so a drag from 40 pt is taken from the row.
    func test_a_drag_from_40_pt_stays_the_rooms_and_its_swipe_to_reply_still_replies() {
        let (state, seen, watching) = watched()
        let start = CGPoint(x: 40, y: 400)
        let translation = CGSize(width: 30, height: 2)

        XCTAssertFalse(state.beginEdgeDrag(start: start, translation: translation, allowed: true),
                       "a drag from 40 pt is not the edge's")
        XCTAssertFalse(state.edgeClaim.isClaimed)
        XCTAssertTrue(RoomRowSwipe.tracks(translation: translation, start: start, sideScrolls: [],
                                          edgeClaimed: state.edgeClaim.isClaimed),
                      "the row under it follows it: its swipe to reply replies")
        state.endEdgeDrag(translation: 200, predicted: 260, width: width)
        XCTAssertFalse(state.isOpen, "letting it go opens nothing")
        XCTAssertEqual(seen.events, [], "nothing ended editing, nothing opened")

        // The control: the same drag from the edge itself is the edge's, and the row leaves it alone.
        XCTAssertTrue(state.beginEdgeDrag(start: CGPoint(x: 2, y: 400), translation: translation, allowed: true))
        XCTAssertFalse(RoomRowSwipe.tracks(translation: translation, start: CGPoint(x: 2, y: 400), sideScrolls: [],
                                           edgeClaimed: state.edgeClaim.isClaimed),
                       "a drag the edge has taken is never a swipe to reply")
        withExtendedLifetime(watching) {}
    }

    /// Mutant: the edge opening the panel whatever covers the room.
    func test_no_edge_open_under_a_sheet() {
        let (state, seen, watching) = watched()
        let allowed = SidePanelEdgeDrag.allowed(open: false, covered: true, roomPushed: false, voiceOver: false)
        XCTAssertFalse(allowed, "a sheet over the room: the edge opens nothing")

        XCTAssertFalse(state.beginEdgeDrag(start: CGPoint(x: 4, y: 400), translation: CGSize(width: 40, height: 1),
                                           allowed: allowed))
        state.endEdgeDrag(translation: 250, predicted: 300, width: width)
        XCTAssertFalse(state.isOpen)
        XCTAssertEqual(seen.events, [], "nothing ended editing under the sheet, nothing opened")
        XCTAssertFalse(state.edgeClaim.isClaimed)

        // Nor with a room pushed (the system's edge goes back), nor with VoiceOver on (the button is theirs), nor open;
        // and with nothing of these, it may.
        XCTAssertFalse(SidePanelEdgeDrag.allowed(open: false, covered: false, roomPushed: true, voiceOver: false))
        XCTAssertFalse(SidePanelEdgeDrag.allowed(open: false, covered: false, roomPushed: false, voiceOver: true))
        XCTAssertFalse(SidePanelEdgeDrag.allowed(open: true, covered: false, roomPushed: false, voiceOver: false))
        XCTAssertTrue(SidePanelEdgeDrag.allowed(open: false, covered: false, roomPushed: false, voiceOver: false))
        withExtendedLifetime(watching) {}
    }

    /// A drag mostly up or down from the edge is the room's scroll, not the edge's.
    func test_a_drag_up_from_the_edge_stays_the_rooms_scroll() {
        let (state, seen, watching) = watched()
        XCTAssertFalse(state.beginEdgeDrag(start: CGPoint(x: 6, y: 500), translation: CGSize(width: 4, height: -30),
                                           allowed: true))
        XCTAssertEqual(seen.events, [])
        withExtendedLifetime(watching) {}
    }

    // MARK: - Helpers

    private final class Seen {
        var events: [String] = []
        weak var state: SidePanelState?
    }

    /// A panel state whose end-editing step and opening and closing are written down, in order.
    private func watched() -> (SidePanelState, Seen, AnyCancellable) {
        let seen = Seen()
        let state = SidePanelState(endEditing: {
            seen.events.append("editing ended, the panel \(seen.state?.isOpen == true ? "open" : "closed")")
        })
        seen.state = state
        let watching = state.$isOpen.dropFirst().sink { open in seen.events.append(open ? "opening" : "closing") }
        return (state, seen, watching)
    }
}
