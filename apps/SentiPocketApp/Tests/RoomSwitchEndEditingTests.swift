import Foundation
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// Picking a room in the side panel, and its All rooms, put another room (or your rooms) in place of the one on screen,
/// and the room's composer goes with it: editing ends first, through the side panel's own end-editing step
/// (`SidePanelState.switchRoom`), so the keyboard starts going down before the room goes. A root hosted on the preview's
/// data, with its end-editing step written down beside each room it puts in place (`RootPreviewMeter.roomPutInPlace`).
@MainActor
final class RoomSwitchEndEditingTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        pump(0.4)
        RootPreview.meter.onRoomPutInPlace = nil
        UserDefaults.standard.removeObject(forKey: "pocket.lastRoomId")
        super.tearDown()
    }

    /// Mutants: picking a room ending editing past the panel's step (`endAllEditing()` straight), or after the room is
    /// in place.
    func test_picking_a_room_ends_editing_before_the_room_is_put_in_place() throws {
        let log = try hostRoot()
        RootPreview.requestDrawer(true)
        pump(1)
        log.events.removeAll()

        RootPreview.requestRoom("room-000")
        pump(1)
        XCTAssertEqual(log.events, ["editing ended", "room-000 put in place"],
                       "editing ends, through the panel's step, before the picked room takes the room's place")
    }

    /// Mutants: All rooms ending editing past the panel's step, or after your rooms are in place.
    func test_all_rooms_ends_editing_before_your_rooms_take_the_rooms_place() throws {
        let log = try hostRoot()
        RootPreview.requestDrawer(true)
        pump(1)
        log.events.removeAll()

        RootPreview.requestAllRooms()
        pump(1)
        XCTAssertEqual(log.events, ["editing ended", "your rooms put in place"],
                       "editing ends, through the panel's step, before your rooms take the room's place")
    }

    // MARK: - Helpers

    private final class Log {
        var events: [String] = []
    }

    /// The root on the preview's data, its last room (the review room) reopened, then nothing written down yet.
    private func hostRoot() throws -> Log {
        let log = Log()
        let api = RootPreviewAPI(postsPerSecond: 0, onePage: false, openRoomId: RootPreviewAPI.midRoom)
        UserDefaults.standard.set(RootPreviewAPI.midRoom, forKey: "pocket.lastRoomId")
        RootPreview.meter.onRoomPutInPlace = { sessionId in
            log.events.append("\(sessionId ?? "your rooms") put in place")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AuthenticatedRootView(
            authenticationEpoch: 1,
            whisperModelCoordinator: WhisperModelProvisioningCoordinator(),
            incomingLinks: IncomingLinkInbox(),
            services: api.services,
            onSignOut: {},
            onReauthenticationRequired: { _ in },
            endEditing: { log.events.append("editing ended") }
        )
        .environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        self.window = window
        let reopened = "\(RootPreviewAPI.midRoom) put in place"
        let end = Date().addingTimeInterval(30)
        while Date() < end, !log.events.contains(reopened) { pump(0.1) }
        XCTAssertTrue(log.events.contains(reopened), "the last room reopened once the room list loaded")
        pump(1)
        log.events.removeAll()
        return log
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}
