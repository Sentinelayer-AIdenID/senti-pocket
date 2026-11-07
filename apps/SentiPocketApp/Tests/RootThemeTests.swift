import Combine
import PocketSyncClient
import PocketUI
import SwiftUI
import XCTest
@testable import SentiPocketApp

/// The root draws again only when what it shows really changes (ticket cfb0383e, #382). Its two stored keys, the
/// theme and the last room, were `@AppStorage`: while unset, each drew the root again on any UserDefaults change notice,
/// and UIKit posts one when a class first registers its defaults (the first TextKit 2 text view laid out in the process
/// does), so a test that measured the root failed only when it happened to lay out the process's first text view. These
/// tests post such a notice themselves, so they fail on that root whatever ran before them.
@MainActor
final class RootThemeTests: XCTestCase {
    private var window: UIWindow?
    /// The root's two stored keys, as they were before each test (each test unsets or writes them).
    private var saved: [String: Any] = [:]
    private static let rootKeys = [PocketThemeStore.key, AuthenticatedRootView.lastRoomKey]

    override func setUp() {
        super.setUp()
        saved = [:]
        for key in Self.rootKeys { saved[key] = UserDefaults.standard.object(forKey: key) }
        // Unset, as on a phone that never picked one: the case the root redrew in.
        UserDefaults.standard.removeObject(forKey: PocketThemeStore.key)
    }

    override func tearDown() {
        window?.rootViewController?.dismiss(animated: false)
        window?.isHidden = true
        window = nil
        pump(0.4)
        for key in Self.rootKeys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func test_a_defaults_notice_that_changes_nothing_draws_no_root() throws {
        let window = try showRoot()
        // Both of the root's stored keys unset, as on a first launch: the room reopened at launch was named by the last
        // room, which is now forgotten too. The root is let settle again before measuring.
        UserDefaults.standard.removeObject(forKey: AuthenticatedRootView.lastRoomKey)
        settleRootBodies()
        XCTAssertNil(UserDefaults.standard.object(forKey: PocketThemeStore.key), "the theme is unset")
        XCTAssertNil(UserDefaults.standard.object(forKey: AuthenticatedRootView.lastRoomKey), "the last room is unset")
        let meter = RootPreview.meter
        let rootBodies = meter.rootBodies
        let screens = meter.roomScreens

        // What UIKit does the first time a TextKit 2 text view lays out, and another key written: neither key is
        // the root's.
        UserDefaults.standard.register(defaults: ["pocket.test.registered.\(UUID().uuidString)": true])
        pump(1)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pocket.test.unrelated")
        pump(1)

        XCTAssertEqual(meter.rootBodies - rootBodies, 0, "a defaults notice that changes nothing draws no root")
        XCTAssertEqual(meter.roomScreens - screens, 0, "and makes no new room screen")
        XCTAssertNil(UserDefaults.standard.object(forKey: PocketThemeStore.key), "no theme was written")
        XCTAssertNil(UserDefaults.standard.object(forKey: AuthenticatedRootView.lastRoomKey),
                     "no last room was written")
        _ = window
        UserDefaults.standard.removeObject(forKey: "pocket.test.unrelated")
    }

    func test_each_theme_pick_draws_the_root_once_and_themes_it_and_the_same_pick_draws_nothing() throws {
        let window = try showRoot()
        let meter = RootPreview.meter

        var rootBodies = meter.rootBodies
        RootPreview.requestTheme(.dark)
        pump(1)
        XCTAssertEqual(meter.rootBodies - rootBodies, 1, "a pick draws the root once")
        XCTAssertEqual(UserDefaults.standard.string(forKey: PocketThemeStore.key), "dark",
                       "the pick is written to UserDefaults")
        XCTAssertEqual(style(of: window), .dark, "and the app is dark")

        rootBodies = meter.rootBodies
        RootPreview.requestTheme(.light)
        pump(1)
        XCTAssertEqual(meter.rootBodies - rootBodies, 1, "another pick draws the root once")
        XCTAssertEqual(style(of: window), .light, "and the app is light")

        rootBodies = meter.rootBodies
        RootPreview.requestTheme(.light)
        pump(1)
        XCTAssertEqual(meter.rootBodies - rootBodies, 0, "picking the theme already shown draws nothing")

        // Written elsewhere (Settings, another scene): the root follows it.
        rootBodies = meter.rootBodies
        UserDefaults.standard.set(PocketThemePreference.dark.rawValue, forKey: PocketThemeStore.key)
        pump(1)
        XCTAssertEqual(meter.rootBodies - rootBodies, 1, "a theme written elsewhere draws the root once")
        XCTAssertEqual(style(of: window), .dark, "and the app follows it")
    }

    /// The last room is read once at launch and written as rooms open; nothing the root draws depends on it, so writing
    /// it, the same room again or another, draws no root. (As `@AppStorage` each write drew the root again. An unset
    /// last room did not react to a notice that changed nothing, unlike the theme: measured, so it is tested this way.)
    func test_the_last_room_written_draws_no_root() throws {
        _ = try showRoot()
        let meter = RootPreview.meter
        let rootBodies = meter.rootBodies
        let screens = meter.roomScreens

        UserDefaults.standard.set(RootPreviewAPI.midRoom, forKey: AuthenticatedRootView.lastRoomKey)
        pump(1)
        UserDefaults.standard.set("room-000", forKey: AuthenticatedRootView.lastRoomKey)
        pump(1)
        UserDefaults.standard.set(RootPreviewAPI.midRoom, forKey: AuthenticatedRootView.lastRoomKey)
        pump(1)

        XCTAssertEqual(meter.rootBodies - rootBodies, 0, "the last room written, the same or another, draws no root")
        XCTAssertEqual(meter.roomScreens - screens, 0, "and makes no new room screen")
    }

    func test_the_store_publishes_only_a_real_change() {
        let suite = "pocket.test.theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(PocketThemePreference.light.rawValue, forKey: PocketThemeStore.key)
        let store = PocketThemeStore(defaults: defaults)
        XCTAssertEqual(store.preference, .light, "read once at the start")
        var published = 0
        let watch = store.objectWillChange.sink { published += 1 }
        defer { watch.cancel() }

        store.set(.light)
        defaults.register(defaults: ["pocket.test.registered": true])
        pump(0.3)
        XCTAssertEqual(published, 0, "the same theme, and a notice that changes no theme, publish nothing")

        store.set(.dark)
        pump(0.3)
        XCTAssertEqual(published, 1, "a real change publishes once")
        XCTAssertEqual(store.preference, .dark)
        XCTAssertEqual(defaults.string(forKey: PocketThemeStore.key), "dark")

        defaults.set(PocketThemePreference.system.rawValue, forKey: PocketThemeStore.key)
        pump(0.3)
        XCTAssertEqual(published, 2, "a change written elsewhere publishes once")
        XCTAssertEqual(store.preference, .system)
    }

    // MARK: - Helpers

    /// The signed-in root on the preview's data, its room open, settled: its first reads made and its root bodies
    /// still for a second (at most 15 s).
    private func showRoot() throws -> UIWindow {
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
        let end = Date().addingTimeInterval(30)
        while Date() < end, !firstReads.allSatisfy({ api.callCount($0) > 0 }) { pump(0.1) }
        XCTAssertTrue(firstReads.allSatisfy { api.callCount($0) > 0 }, "the root's first reads")
        settleRootBodies()
        return window
    }

    /// Runs the main run loop until the root has not run its body for a second (at most 15 s).
    private func settleRootBodies() {
        let quietEnd = Date().addingTimeInterval(15)
        var last = RootPreview.meter.rootBodies
        var quietSince = Date()
        while Date() < quietEnd, Date().timeIntervalSince(quietSince) < 1 {
            pump(0.1)
            if RootPreview.meter.rootBodies != last {
                last = RootPreview.meter.rootBodies
                quietSince = Date()
            }
        }
    }

    private func style(of window: UIWindow) -> UIUserInterfaceStyle {
        window.rootViewController?.traitCollection.userInterfaceStyle ?? window.traitCollection.userInterfaceStyle
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}
