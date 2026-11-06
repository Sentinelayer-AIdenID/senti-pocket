import Combine
import XCTest
@testable import SentiPocketApp

/// Carter's freezes of 11-06 each came after a send or a reply, with the keyboard still up as the side panel opened or a
/// room was picked from it; one hung with the keyboard's input system on the main thread. Opening the side panel ends
/// editing first, so the keyboard starts going down before the panel's spring: the panel's state runs its end-editing
/// hook (`endAllEditing` in the app) before `isOpen` changes. The real keyboard, and the draft that must survive it, are
/// checked on a simulator by `SidePanelKeyboardUITests`.
@MainActor
final class SidePanelKeyboardTests: XCTestCase {
    func test_opening_the_side_panel_ends_editing_before_its_state_changes() {
        let seen = Seen()
        let state = SidePanelState(endEditing: {
            seen.events.append("editing ended, the panel \(seen.state?.isOpen == true ? "open" : "closed")")
        })
        seen.state = state
        let watching = state.objectWillChange.sink { _ in seen.events.append("isOpen changing") }

        state.open()

        XCTAssertEqual(seen.events, ["editing ended, the panel closed", "isOpen changing"],
                       "editing ends first, while the panel is still closed, and only then does it open")
        XCTAssertTrue(state.isOpen)
        withExtendedLifetime(watching) {}
    }

    private final class Seen {
        var events: [String] = []
        weak var state: SidePanelState?
    }
}
