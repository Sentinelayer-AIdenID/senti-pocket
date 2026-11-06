import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// The side panel is in the view tree only while it is open, or fading out after a close. Carter's freeze of 11-06
/// (#62485): a closed panel kept in the tree, faded out under the room, held its lazy list there, and putting a room in
/// place could set off a layout of all its items that never settled. A panel out of the tree is also out of reach of
/// VoiceOver (ticket 066aca7a). The frame is hosted with a panel that counts its appearances.
///
/// Mutant it must catch: the closed panel kept drawn (in the tree, faded out), as before.
@MainActor
final class SidePanelClosedNotDrawnTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        pump(0.3)
        super.tearDown()
    }

    func test_the_closed_side_panel_is_not_in_the_tree_and_the_open_one_is() throws {
        let state = SidePanelState(endEditing: {})
        let presence = Presence()
        let frame = SidePanelFrame(state: state, width: 300, coveredOtherwise: false, refresh: 15_000_000_000,
                                   onOpen: {}, poll: {}, panel: CountedPanel(presence: presence),
                                   room: Color.white)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: frame)
        window.makeKeyAndVisible()
        self.window = window
        pump(0.5)
        XCTAssertEqual(presence.shown, 0, "closed from the start: the panel is not in the tree")

        state.open()
        pump(1)
        XCTAssertEqual(presence.shown, 1, "open: the panel is in the tree")
        XCTAssertEqual(presence.appearances, 1)

        state.close()
        pump(1)
        XCTAssertEqual(presence.shown, 0, "closed again: the panel left the tree once its fade had run")

        state.open()
        pump(1)
        XCTAssertEqual(presence.shown, 1, "open again: in the tree again")
        XCTAssertEqual(presence.appearances, 2, "made again for this open")
    }

    // MARK: - Helpers

    private final class Presence {
        var shown = 0
        var appearances = 0
    }

    private struct CountedPanel: View {
        let presence: Presence

        var body: some View {
            Color.blue
                .onAppear {
                    presence.shown += 1
                    presence.appearances += 1
                }
                .onDisappear { presence.shown -= 1 }
        }
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}
