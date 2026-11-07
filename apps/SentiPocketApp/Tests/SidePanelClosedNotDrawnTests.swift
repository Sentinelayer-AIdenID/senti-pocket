import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// The side panel is in the view tree only while it is open, or fading out after a close. Carter's freeze of 11-06
/// (#62485): a closed panel kept in the tree, faded out under the room, held its lazy list there, and putting a room in
/// place could set off a layout of all its items that never settled. A panel out of the tree is also out of reach of
/// VoiceOver (ticket 066aca7a). The frame and its layer are hosted with a panel that counts its appearances.
///
/// Mutants they must catch: the closed panel kept drawn (in the tree, faded out), as before; the panel's touch and
/// VoiceOver flags set inside the open branch (where they keep their open values while it fades out) and not on its
/// holder.
///
/// What a close and an open keep, decided one by one: the folded folders are the placement's (the root keeps it), so
/// they stay; the search text is the panel's, so a new open starts with no search; the scroll goes back to the top
/// (bringing it back would scroll the lazy list on every open); a folder being named is the root's sheet, not the
/// panel's, so a half-typed name stays.
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
        try host(frame(state, CountedPanel(presence: presence)))
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

    /// Open, close and open again inside 200 ms, and the other way round: once settled, one panel or none, never two.
    func test_open_close_open_inside_200_ms_settles_on_one_panel_and_close_open_close_on_none() throws {
        let state = SidePanelState(endEditing: {})
        let presence = Presence()
        try host(frame(state, CountedPanel(presence: presence)))
        pump(0.5)

        state.open()
        pump(0.05)
        state.close()
        pump(0.05)
        state.open()
        pump(1.2)
        XCTAssertEqual(presence.shown, 1, "open, close, open: one panel once settled")
        print("SIDE-PANEL most at once during open, close, open: \(presence.most)")

        state.close()
        pump(0.05)
        state.open()
        pump(0.05)
        state.close()
        pump(1.2)
        XCTAssertEqual(presence.shown, 0, "close, open, close: no panel once settled")
        XCTAssertLessThanOrEqual(presence.most, 2, "never more than the panel fading out and the one coming in")
    }

    /// While the closed panel fades out it is still in the tree; no touch reaches it then. The fade is made long here
    /// (1.2 s) so the touch lands well inside it, and the panel is a UIKit view, so the window's own hit test says
    /// what a finger would reach.
    func test_while_the_closed_panel_fades_out_no_touch_reaches_it() throws {
        let toggle = Toggle()
        let presence = Presence()
        try host(FadeHost(toggle: toggle, presence: presence))
        pump(0.5)

        toggle.isOpen = true
        pump(1.6)
        let probe = try XCTUnwrap(presence.probe, "the open panel's view")
        XCTAssertTrue(reaches(probe), "open: a touch on the panel reaches it")

        toggle.isOpen = false
        pump(0.3)
        XCTAssertEqual(presence.shown, 1, "0.3 s into the 1.2 s fade: the panel is still in the tree")
        XCTAssertFalse(reaches(probe), "while it fades out after the close, a touch on the panel does not reach it")

        pump(1.6)
        XCTAssertEqual(presence.shown, 0, "the fade has run: out of the tree")
    }

    /// The folded folders live in the placement the root keeps: a close and an open leave them folded.
    func test_folded_folders_stay_folded_through_a_close_and_an_open() throws {
        let (rooms, folders) = SidePanelScaleTests.fixture()
        let placement = SidePanelPlacement(rooms: rooms, folders: folders)
        let folder = try XCTUnwrap(placement.shown.rows.lazy.compactMap { row -> String? in
            if case .folder(let line) = row { return line.id } else { return nil }
        }.first)
        let state = SidePanelState(endEditing: {})
        try host(frame(state, PocketSidePanel(
            placement: placement, currentRoomId: "room-3", unreadNotifications: 2, accountName: "Alex",
            theme: .constant(.system), onSelectRoom: { _ in }, onAllRooms: {}, onNotifications: {}, onCalls: {},
            onActivity: {}, onSettings: {}, folderNotice: nil, onFolder: { _ in })))
        pump(0.5)
        state.open()
        pump(1)
        placement.toggleFolded(folder)
        pump(0.3)
        let foldedRows = placement.shown.rows.count
        XCTAssertTrue(placement.folded.contains(folder))

        state.close()
        pump(1)
        state.open()
        pump(1)
        XCTAssertTrue(placement.folded.contains(folder), "still folded after a close and an open")
        XCTAssertEqual(placement.shown.rows.count, foldedRows, "the panel shows the same folded lines")
    }

    // MARK: - Helpers

    private final class Presence {
        var shown = 0 { didSet { most = max(most, shown) } }
        var most = 0
        var appearances = 0
        var probe: UIView?
    }

    private final class Toggle: ObservableObject {
        @Published var isOpen = false
    }

    private func frame<Panel: View>(_ state: SidePanelState, _ panel: Panel) -> some View {
        SidePanelFrame(state: state, width: 300, coveredOtherwise: false, refresh: 15_000_000_000,
                       onOpen: {}, poll: {}, panel: panel, room: Color.white)
    }

    private func host<Content: View>(_ content: Content) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        self.window = window
    }

    /// Whether the window's hit test at the middle of `view` lands in it.
    private func reaches(_ view: UIView) -> Bool {
        guard let window else { return false }
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
        guard let hit = window.hitTest(point, with: nil) else { return false }
        return hit === view || hit.isDescendant(of: view)
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

    /// The layer alone, with a long fade.
    private struct FadeHost: View {
        @ObservedObject var toggle: Toggle
        let presence: Presence

        var body: some View {
            SidePanelLayer(isOpen: toggle.isOpen, width: 300, panel: TouchPanel(presence: presence))
                .animation(.linear(duration: 1.2), value: toggle.isOpen)
        }
    }

    private struct TouchPanel: View {
        let presence: Presence

        var body: some View {
            TouchProbe(presence: presence)
                .onAppear {
                    presence.shown += 1
                    presence.appearances += 1
                }
                .onDisappear { presence.shown -= 1 }
        }
    }

    private struct TouchProbe: UIViewRepresentable {
        let presence: Presence

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .systemBlue
            presence.probe = view
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {}
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}
