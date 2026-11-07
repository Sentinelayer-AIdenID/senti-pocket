import PocketSyncClient
import PocketUI
import SwiftUI
import XCTest
@testable import SentiPocketApp

/// Carter, #62471: "some times I try to listen while I have a reply open, it minimizes the page I'm reading from and
/// then I see the overlay. I need to still be able to see the page." Starting Read aloud from a reply in an open thread,
/// on the signed-in root as the app hosts it (scripted rooms): the thread stays presented, no new room screen is made,
/// the root is not drawn again, and the bar is one thin line at the top of the thread, every control at least 44 pt.
/// (On master, CI showed the root drawn twice and the room screen made twice as reading started: what can take a thread
/// away. It did not show the thread itself going.)
@MainActor
final class ReadAloudThreadTests: XCTestCase {
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        RootPreview.meter.forgetReadAloudBars()
    }

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

        // The bar: at the top of the thread, one thin line, each control at least 44 pt.
        let height = window.bounds.height
        let thread = try XCTUnwrap(meter.readAloudBars["thread"], "the thread shows the bar over its page")
        let bar = try XCTUnwrap(thread["bar"])
        XCTAssertLessThan(bar.minY, height * 0.3, "at the top of the thread, not its foot (\(bar))")
        XCTAssertLessThanOrEqual(bar.height, 64, "one thin line (\(bar.height) pt)")
        for name in ["title", "pause", "close"] {
            let control = try XCTUnwrap(thread[name], name)
            XCTAssertGreaterThanOrEqual(control.height, 44, "\(name) is at least 44 pt tall")
            if name != "title" { XCTAssertGreaterThanOrEqual(control.width, 44, "\(name) is at least 44 pt wide") }
        }
        let room = try XCTUnwrap(meter.readAloudBars["room"]?["bar"], "the room shows it too, under the thread")
        XCTAssertLessThan(room.minY, height * 0.3, "at the top of the room (\(room))")
    }

    /// At the largest accessibility text size the bar keeps its title on the screen, cut short if it must be, and every
    /// control inside the screen and at least 44 pt: there, the position used to push the title out and Close off the
    /// screen. VoiceOver still reads the whole title and position.
    func test_at_the_largest_text_size_the_bar_keeps_its_title_and_controls_on_the_screen() throws {
        let state = ReadAloudBarState(title: "Ada Lovelace-Byron about the voice room rollout", isPaused: false,
                                      elapsedBefore: 600, sentenceStartedAt: nil, sentenceLength: 0, total: 754,
                                      hasGoodVoice: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: VStack(spacing: 0) {
            ReadAloudBar(state: state) { _ in }
                .onPreferenceChange(ReadAloudBarFrames.self) { RootPreview.meter.readAloudBarLaidOut("largest text", $0) }
            Spacer()
        }
        .environment(\.dynamicTypeSize, .accessibility5))
        window.makeKeyAndVisible()
        self.window = window
        wait("the bar is laid out", seconds: 10) { RootPreview.meter.readAloudBars["largest text"]?["close"] != nil }
        pump(1)

        let frames = try XCTUnwrap(RootPreview.meter.readAloudBars["largest text"])
        let screen = window.bounds
        print("BGAUDIT read aloud bar at the largest text size, screen \(screen.width) pt: "
              + ["bar", "title", "line", "pause", "close"].map { name in "\(name) \(String(describing: frames[name]))" }
                .joined(separator: ", "))
        for name in ["bar", "title", "line", "pause", "close"] {
            let frame = try XCTUnwrap(frames[name], name)
            XCTAssertGreaterThanOrEqual(frame.minX, screen.minX - 0.5, "\(name) starts on the screen (\(frame))")
            XCTAssertLessThanOrEqual(frame.maxX, screen.maxX + 0.5, "\(name) ends on the screen (\(frame))")
        }
        for name in ["pause", "close"] {
            let control = try XCTUnwrap(frames[name])
            XCTAssertGreaterThanOrEqual(control.width, 44, "\(name) is at least 44 pt wide (\(control))")
            XCTAssertGreaterThanOrEqual(control.height, 44, "\(name) is at least 44 pt tall (\(control))")
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(frames["title"]).height, 44, "the title is at least 44 pt tall")
        let line = try XCTUnwrap(frames["line"])
        XCTAssertGreaterThanOrEqual(line.width, 60, "the title shows, cut short if it must be (\(line.width) pt)")
        XCTAssertLessThanOrEqual(try XCTUnwrap(frames["bar"]).height, 64, "still one thin line")
        XCTAssertEqual(state.spokenLine(600), "Reading Ada Lovelace-Byron about the voice room rollout, "
                       + "10 minutes of about 12 minutes 34 seconds", "VoiceOver reads the whole title and position")
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
