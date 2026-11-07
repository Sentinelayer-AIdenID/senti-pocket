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
        let placed = placements(in: window)

        // Listen on its first reply, as the reply's Listen does.
        RootPreview.requestRoom(.readAloud(id: RoomReadAloud.reply("reply-165-1"), text: "Reply 1 to message 165."))
        pump(3)
        XCTAssertEqual(ReadAloudSource.shared.sessionId, RootPreviewAPI.midRoom, "reading started in this room")
        XCTAssertNotNil(presentedThread, "the thread stays open while its reply is read")
        XCTAssertEqual(meter.roomScreens - screens, 0, "reading makes no new room screen")
        XCTAssertEqual(meter.rootBodies - rootBodies, 0, "reading draws the player, never the root")
        assertSamePlacements(placed, placements(in: window), "starting to read")
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

    /// While a message is read, the room screen's body never runs: the bar draws at each sentence, pause and play, the
    /// room only when what is read starts or stops. And the bar sits over the room, never in its list's inset, so starting
    /// or stopping a reading never lays the list out again (#360: a top inset that changes keeps the list laying itself
    /// out).
    func test_a_reading_draws_its_bar_never_the_room_screen_and_never_places_the_list_again() throws {
        let window = try hostRoot(links: IncomingLinkInbox())
        let meter = RootPreview.meter
        let reader = try XCTUnwrap(meter.reader, "the root's reader")
        let placed = placements(in: window)
        XCTAssertTrue(placed.values.contains { $0.height > window.bounds.height / 2 }, "the room's list is measured")

        RootPreview.requestRoom(.readAloud(id: RoomReadAloud.message(165), text: Self.longText))
        wait("the room shows the bar", seconds: 10) { meter.readAloudBars["room"]?["bar"] != nil }
        pump(1.5)
        assertSamePlacements(placed, placements(in: window), "starting to read")

        // Pause and play, as the bar's button does: each changes what the reader says, as each sentence does.
        let bodies = meter.roomScreenBodies
        let drawn = meter.readAloudSlotBodies["room"] ?? 0
        for _ in 1...3 {
            reader.pause()
            pump(0.5)
            reader.resume()
            pump(0.5)
        }
        let barDraws = (meter.readAloudSlotBodies["room"] ?? 0) - drawn
        print("BGAUDIT read aloud in the room: bar draws \(barDraws), room screen bodies \(meter.roomScreenBodies - bodies) "
              + "over 3 pauses and plays")
        XCTAssertGreaterThanOrEqual(barDraws, 6, "the bar drew at each pause and play")
        XCTAssertEqual(meter.roomScreenBodies - bodies, 0, "the room screen's body never ran while it read")

        RootPreview.requestRoom(.stopReadingAloud)
        pump(1.5)
        assertSamePlacements(placed, placements(in: window), "stopping")
    }

    /// Reading goes on when you leave its room (Carter, 10-30): the room you open shows the bar over its top, and its
    /// title takes you back to the message.
    func test_a_reading_from_another_room_shows_its_bar_over_the_room_on_screen() throws {
        let links = IncomingLinkInbox()
        let window = try hostRoot(links: links)
        let meter = RootPreview.meter
        RootPreview.requestRoom(.readAloud(id: RoomReadAloud.message(165), text: Self.longText))
        wait("the room shows the bar", seconds: 10) { meter.readAloudBars["room"]?["bar"] != nil }
        XCTAssertNil(meter.readAloudBars["other"]?["bar"], "in its own room, the room's bar")

        let url = try XCTUnwrap(URL(string: "https://sentinelayer.com/dashboard/sessions/\(RootPreviewAPI.longRoom)"))
        XCTAssertTrue(links.receive(url))
        wait("the other room shows the bar", seconds: 15) { meter.readAloudBars["other"]?["bar"] != nil }
        let bar = try XCTUnwrap(meter.readAloudBars["other"]?["bar"])
        XCTAssertLessThan(bar.minY, window.bounds.height * 0.3, "at the top of the room on screen (\(bar))")
        XCTAssertEqual(ReadAloudSource.shared.sessionId, RootPreviewAPI.midRoom, "still the first room's message")
    }

    private static let longText = (1...12).map { "This is sentence \($0) of the message." }.joined(separator: " ")

    /// The signed-in root as the app hosts it, on room-mid, once its first reads are in.
    private func hostRoot(links: IncomingLinkInbox) throws -> UIWindow {
        let api = RootPreviewAPI(postsPerSecond: 0, onePage: false, openRoomId: RootPreviewAPI.midRoom)
        UserDefaults.standard.set(RootPreviewAPI.midRoom, forKey: "pocket.lastRoomId")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AuthenticatedRootView(
            authenticationEpoch: 1,
            whisperModelCoordinator: WhisperModelProvisioningCoordinator(),
            incomingLinks: links,
            services: api.services,
            onSignOut: {},
            onReauthenticationRequired: { _ in }
        )
        .environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        self.window = window
        wait("the room's first reads", seconds: 30) { ["rooms", "history", "actions"].allSatisfy { api.callCount($0) > 0 } }
        pump(2.5)
        return window
    }

    /// Where each list on screen shows its content, by list: its frame in the window less its content inset, which a top
    /// inset that comes and goes changes. Lists are the outermost scroll views (a row's own side-scrolling strip moves
    /// with the list, and is left out), never the composer's text view.
    private func placements(in window: UIWindow) -> [ObjectIdentifier: CGRect] {
        var found: [ObjectIdentifier: CGRect] = [:]
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !(scroll is UITextView) {
                if !scroll.isHidden, let frame = scroll.superview?.convert(scroll.frame, to: nil) {
                    found[ObjectIdentifier(scroll)] = frame.inset(by: scroll.adjustedContentInset)
                }
                return
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found
    }

    private func assertSamePlacements(_ before: [ObjectIdentifier: CGRect], _ after: [ObjectIdentifier: CGRect],
                                      _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let kept = before.keys.filter { after[$0] != nil }
        XCTAssertFalse(kept.isEmpty, "\(what): the scroll views measured before are still there", file: file, line: line)
        for key in kept where before[key]?.integral != after[key]?.integral {
            XCTFail("\(what) placed a list again: \(String(describing: before[key])) became \(String(describing: after[key]))",
                    file: file, line: line)
        }
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
