import PocketSyncClient
import PocketUI
import SwiftUI
import XCTest
@testable import SentiPocketApp

/// Carter, #62471: "some times I try to listen while I have a reply open, it minimizes the page I'm reading from and
/// then I see the overlay. I need to still be able to see the page." Starting Read aloud from a reply in an open thread,
/// on the signed-in root as the app hosts it (scripted rooms): the thread stays presented, no new room screen is made,
/// and the root is not drawn again.
@MainActor
final class ReadAloudThreadTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        RootPreview.requestRoom(.stopReadingAloud)
        window?.rootViewController?.dismiss(animated: false)
        window?.isHidden = true
        window = nil
        pump(0.4)
        super.tearDown()
    }

    func test_reading_a_reply_aloud_keeps_its_thread_open_and_draws_no_root() throws {
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
        let firstReads = ["rooms", "history", "actions"]
        wait("the room's first reads", seconds: 30) { firstReads.allSatisfy { api.callCount($0) > 0 } }
        pump(2)

        // The newest message's thread, opened as a tap on its replies opens it.
        RootPreview.requestRoom(.openThread(sequenceId: 165))
        wait("the thread is presented", seconds: 10) { self.presentedThread != nil }
        pump(1.5)
        XCTAssertNotNil(presentedThread, "the thread is open before reading starts")
        let meter = RootPreview.meter
        let rootBodies = meter.rootBodies
        let screens = meter.roomScreens

        // Listen on its first reply, as the reply's Listen does.
        RootPreview.requestRoom(.readAloud(id: RoomReadAloud.reply("reply-165-1"), text: "Reply 1 to message 165."))
        pump(3)
        XCTAssertEqual(ReadAloudSource.shared.sessionId, RootPreviewAPI.midRoom, "reading started in this room")
        XCTAssertNotNil(presentedThread, "the thread stays open while its reply is read")
        XCTAssertEqual(meter.roomScreens - screens, 0, "reading makes no new room screen")
        XCTAssertEqual(meter.rootBodies - rootBodies, 0, "reading draws the player, never the root")
        print("BGAUDIT read aloud from a thread: root bodies \(meter.rootBodies - rootBodies), "
              + "room screens \(meter.roomScreens - screens), thread presented \(presentedThread != nil)")
    }

    /// The sheet over the root, if one is up and not leaving.
    private var presentedThread: UIViewController? {
        guard let presented = window?.rootViewController?.presentedViewController, !presented.isBeingDismissed else {
            return nil
        }
        return presented
    }

    private func wait(_ what: String, seconds: TimeInterval, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !done() { pump(0.1) }
        XCTAssertTrue(done(), what)
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}
