#if DEBUG
import PocketVoice
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// A room left is let go (ticket 02a80e6f). Each room's media lives as long as the app (`RoomMediaUploadCoordinator`'s
/// `forRoom`), and a closure stored on it that wrote the room screen's state held that screen, and the room it showed,
/// for good: every room opened stayed alive, with what it still ran. The rooms' coordinators are counted as they live
/// (`RootPreview.meter.liveRooms`, held weakly); a room screen is shown on the preview's data and then dropped, each
/// inside an autoreleasepool so nothing the test itself keeps holds the room.
///
/// Mutant it must catch: a closure that holds the room's screen, stored on the room's media and never taken away.
@MainActor
final class RoomScreenReleaseTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        pump(0.3)
        super.tearDown()
    }

    func test_a_room_screen_shown_then_dropped_lets_its_room_go() throws {
        let meter = RootPreview.meter
        pump(0.5)
        let before = meter.liveRooms
        try autoreleasepool {
            let api = RootPreviewAPI(postsPerSecond: 0, onePage: false, openRoomId: RootPreviewAPI.midRoom)
            try show(UIHostingController(rootView: AnyView(screen(RootPreviewAPI.midRoom, api))))
        }
        pump(3)
        XCTAssertEqual(meter.liveRooms - before, 1, "the room on screen is alive")

        autoreleasepool {
            window?.isHidden = true
            window?.rootViewController = nil
            window = nil
        }
        XCTAssertTrue(settles(at: before), "the room left is let go: \(meter.liveRooms - before) still alive")
    }

    /// Ten rooms opened one after another, as the side panel does: the one on screen is alive, the nine left are not.
    func test_ten_room_switches_leave_one_room_alive_not_ten() throws {
        let meter = RootPreview.meter
        pump(0.5)
        let before = meter.liveRooms
        let api = RootPreviewAPI(postsPerSecond: 0, onePage: false, openRoomId: nil)
        let rooms = (0..<10).map { String(format: "room-%03d", $0) }
        var host: UIHostingController<AnyView>?
        try autoreleasepool {
            let made = UIHostingController(rootView: AnyView(screen(rooms[0], api)))
            try show(made)
            host = made
        }
        pump(1)
        for room in rooms.dropFirst() {
            autoreleasepool { host?.rootView = AnyView(screen(room, api)) }
            pump(1)
        }
        XCTAssertTrue(settles(at: before + 1),
                      "after ten rooms, the one on screen is alive and the nine left are let go: "
                        + "\(meter.liveRooms - before) alive")
    }

    // MARK: - Helpers

    private func screen(_ sessionId: String, _ api: RootPreviewAPI) -> some View {
        RoomChatScreen(route: RoomRoute(sessionId: sessionId, title: sessionId), transport: api,
                       reader: MessageReader(), onReauthenticationRequired: {})
            .id(sessionId)
    }

    private func show(_ controller: UIViewController) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
    }

    /// Whether the live rooms come to `count` within 5 s.
    private func settles(at count: Int) -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if RootPreview.meter.liveRooms == count { return true }
            pump(0.1)
        }
        return RootPreview.meter.liveRooms == count
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}
#endif
