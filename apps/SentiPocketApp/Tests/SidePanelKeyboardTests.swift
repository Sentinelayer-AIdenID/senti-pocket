import Foundation
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// Carter's freezes of 11-06 each came after a send or a reply, with the keyboard still up as the side panel opened or a
/// room was picked from it; one hung with the keyboard's input system on the main thread. Opening the side panel ends
/// editing first (`SidePanelState.open`), so the keyboard starts going down before the panel's spring: the room's
/// composer is not first responder once the panel opens, with a draft in it or empty as a send leaves it.
@MainActor
final class SidePanelKeyboardTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        pump(0.4)
        UserDefaults.standard.removeObject(forKey: "pocket.lastRoomId")
        super.tearDown()
    }

    func test_opening_the_side_panel_ends_editing_in_the_room_composer() throws {
        let api = RootPreviewAPI(postsPerSecond: 0, onePage: false, openRoomId: RootPreviewAPI.midRoom)
        UserDefaults.standard.set(RootPreviewAPI.midRoom, forKey: "pocket.lastRoomId")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AuthenticatedRootView(
            authenticationEpoch: 1,
            whisperModelCoordinator: WhisperModelProvisioningCoordinator(),
            incomingLinks: IncomingLinkInbox(),
            services: api.services,
            onSignOut: {},
            onReauthenticationRequired: { _ in }
        )
        .environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        self.window = window
        var composer: UITextView?
        let end = Date().addingTimeInterval(30)
        while Date() < end, composer == nil {
            pump(0.2)
            composer = Self.find("pocket.room.composer", in: window)
        }
        let field = try XCTUnwrap(composer, "the room's composer is on screen")
        pump(1)
        // Empty, as a send leaves it (the keyboard still up), then with a draft in it.
        for (label, draft) in [("straight after a send", ""), ("with a draft in it", "A note half written")] {
            XCTAssertTrue(field.becomeFirstResponder(), "\(label): the composer takes the keyboard")
            if !draft.isEmpty { field.insertText(draft) }
            XCTAssertTrue(field.isFirstResponder, "\(label): the composer has the keyboard")
            RootPreview.requestDrawer(true)
            pump(0.05)
            XCTAssertFalse(field.isFirstResponder, "\(label): opening the side panel ends editing before its spring")
            pump(1)
            XCTAssertFalse(field.isFirstResponder, "\(label): and nothing takes the keyboard back while it is open")
            RootPreview.requestDrawer(false)
            pump(1)
        }
    }

    private static func find(_ identifier: String, in view: UIView) -> UITextView? {
        if let text = view as? UITextView, text.accessibilityIdentifier == identifier { return text }
        for child in view.subviews {
            if let found = find(identifier, in: child) { return found }
        }
        return nil
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}
