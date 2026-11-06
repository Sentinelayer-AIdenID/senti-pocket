import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// The side panel is in the view tree only while it is open, or fading out after a close. Carter's freeze of 11-06
/// (#62485): a closed panel kept in the tree, faded out under the room, held its lazy list there, and putting a room in
/// place could set off a layout of all its items that never settled. A panel out of the tree is also out of reach of
/// VoiceOver (ticket 066aca7a). The layer is hosted as the root holds it, under a room that slides aside on the root's
/// spring, with a panel that counts its appearances.
///
/// Mutant it must catch: the closed panel kept drawn (in the tree, faded out), as before.
@MainActor
final class SidePanelLayerTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        pump(0.3)
        super.tearDown()
    }

    func test_the_closed_side_panel_is_not_in_the_tree_and_the_open_one_is() throws {
        let toggle = Toggle()
        let presence = Presence()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Host(toggle: toggle, presence: presence))
        window.makeKeyAndVisible()
        self.window = window
        pump(0.5)
        XCTAssertEqual(presence.shown, 0, "closed from the start: the panel is not in the tree")

        toggle.isOpen = true
        pump(1)
        XCTAssertEqual(presence.shown, 1, "open: the panel is in the tree")
        XCTAssertEqual(presence.appearances, 1)

        toggle.isOpen = false
        pump(1)
        XCTAssertEqual(presence.shown, 0, "closed again: the panel left the tree once its fade had run")

        toggle.isOpen = true
        pump(1)
        XCTAssertEqual(presence.shown, 1, "open again: in the tree again")
        XCTAssertEqual(presence.appearances, 2, "made again for this open")
    }

    // MARK: - Helpers

    private final class Toggle: ObservableObject {
        @Published var isOpen = false
    }

    private final class Presence {
        var shown = 0
        var appearances = 0
    }

    /// The layer under a room that slides aside, on the root's spring.
    private struct Host: View {
        @ObservedObject var toggle: Toggle
        let presence: Presence

        var body: some View {
            ZStack(alignment: .leading) {
                SidePanelLayer(isOpen: toggle.isOpen, width: 300, panel: CountedPanel(presence: presence))
                Color.white.offset(x: toggle.isOpen ? 300 : 0)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toggle.isOpen)
        }
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
