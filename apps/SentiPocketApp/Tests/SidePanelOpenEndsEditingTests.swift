import XCTest
@testable import SentiPocketApp

/// Opening the side panel ends editing first, then changes the panel's state, so the keyboard starts going down before
/// the panel's spring (as #344's `SidePanelState.open()`). On master, path (f) with the closed panel left out of the
/// tree still hung once at the panel's open with the keyboard up (chain61b, 98bfe1f6); M3 and M4, which end editing
/// first, did not hang there. The real root's open is checked in `RootBackgroundWorkTests`' side panel test.
///
/// Mutant it must catch: the panel opened before editing ends.
@MainActor
final class SidePanelOpenEndsEditingTests: XCTestCase {
    func test_opening_ends_editing_before_the_panel_state_changes_and_closing_ends_none() {
        var openWhenEditingEnded: [Bool] = []
        var state: SidePanelState!
        state = SidePanelState(endEditing: { openWhenEditingEnded.append(state.isOpen) })

        state.open()
        XCTAssertEqual(openWhenEditingEnded, [false], "editing ended once, while the panel was still closed")
        XCTAssertTrue(state.isOpen)

        state.close()
        XCTAssertFalse(state.isOpen)
        XCTAssertEqual(openWhenEditingEnded, [false], "closing ends no editing")
    }
}
