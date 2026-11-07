import Foundation
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// Ticket bcdba8f3 (Carter, on a call): minimize a call to a small bar, to read, scroll, open threads and type while it
/// goes on. What the bar says and asks of its call.
final class VoiceCallBarStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func test_the_time_is_minutes_and_seconds_since_the_call_started() {
        let call = VoiceCallBarState(title: "forge", startedAt: start)
        XCTAssertEqual(call.time(at: start), "0:00")
        XCTAssertEqual(call.time(at: start.addingTimeInterval(9.9)), "0:09")
        XCTAssertEqual(call.time(at: start.addingTimeInterval(151)), "2:31")
        XCTAssertEqual(call.time(at: start.addingTimeInterval(3_665)), "61:05",
                       "minutes go on past an hour, as on the call screen")
        XCTAssertEqual(call.time(at: start.addingTimeInterval(-5)), "0:00",
                       "a clock a little behind never shows a minus")
    }

    func test_before_and_after_its_clock_the_bar_says_what_the_call_is_doing() {
        let at = start.addingTimeInterval(8)
        XCTAssertEqual(VoiceCallBarState(title: "forge", startedAt: start, isRinging: true).time(at: at), "Ringing…")
        XCTAssertEqual(VoiceCallBarState(title: "forge", startedAt: start, isEnding: true).time(at: at), "Ending…")
    }

    func test_voiceover_reads_who_the_call_is_with_and_its_time() {
        let at = start.addingTimeInterval(151)
        XCTAssertEqual(VoiceCallBarState(title: "forge", startedAt: start).spokenLabel(at: at), "Call with forge, 2:31")
        XCTAssertEqual(VoiceCallBarState(title: "forge", startedAt: start, isMuted: true).spokenLabel(at: at),
                       "Call with forge, 2:31, muted")
        XCTAssertEqual(VoiceCallBarState(title: "forge", startedAt: start, isRinging: true).spokenLabel(at: at),
                       "Call with forge, ringing")
        XCTAssertEqual(VoiceCallBarState(title: "forge and ada", startedAt: start).spokenLabel(at: at),
                       "Call with forge and ada, 2:31")
        XCTAssertEqual(VoiceCallBarState(title: "forge", startedAt: start, isEnding: true).spokenLabel(at: at),
                       "Call with forge, ending")
    }

    func test_a_voice_rooms_bar_shows_what_its_call_screen_shows() {
        var call = VoiceRoomState(with: ["forge"], startedAt: start)
        XCTAssertEqual(VoiceCallBarState(call), VoiceCallBarState(title: "forge", startedAt: start, isRinging: true),
                       "nobody has picked up yet")
        call.joined = ["forge"]
        call.isMuted = true
        XCTAssertEqual(VoiceCallBarState(call), VoiceCallBarState(title: "forge", startedAt: start, isMuted: true))
        call.phase = .ending
        XCTAssertTrue(VoiceCallBarState(call).isEnding)
        call.phase = .ended
        XCTAssertTrue(VoiceCallBarState(call).isEnding)
        XCTAssertEqual(VoiceCallBarState(VoiceRoomState(with: [], startedAt: start)).title, "everyone", "a meeting")
        XCTAssertEqual(VoiceCallBarState(VoiceRoomState(with: ["forge", "ada"], startedAt: start)).title,
                       "forge and ada")
    }

    func test_mute_and_end_ask_the_call_and_a_tap_on_the_bar_asks_it_nothing() {
        let call = VoiceCallBarState(title: "forge", startedAt: start)
        XCTAssertEqual(call.muteLabel, "Mute")
        XCTAssertEqual(call.intent(for: .toggleMute), .setMuted(true))
        XCTAssertEqual(call.intent(for: .end), .hangUp)
        XCTAssertNil(call.intent(for: .open), "a tap on the bar opens the call screen, and asks the call nothing")
        let muted = VoiceCallBarState(title: "forge", startedAt: start, isMuted: true)
        XCTAssertEqual(muted.muteLabel, "Unmute")
        XCTAssertEqual(muted.intent(for: .toggleMute), .setMuted(false))
        let ending = VoiceCallBarState(title: "forge", startedAt: start, isEnding: true)
        XCTAssertNil(ending.intent(for: .toggleMute), "nothing more is asked of a call hanging up")
        XCTAssertNil(ending.intent(for: .end))
    }
}

@MainActor
private final class QuietListener: VoiceListening {
    func start(partial: @escaping @MainActor (String) -> Void) async throws {}
    func stop() async -> String { "" }
    func cancel() {}
}

@MainActor
private final class QuietSpeaker: VoiceSpeaking {
    func speak(_ markdown: String, as speaker: String, finished: @escaping @MainActor () -> Void) {}
    func stop() {}
}

@MainActor
private final class QuietAudio: VoiceRoomAudioSession {
    func activate() throws {}
    func deactivate() {}
}

private final class QuietPoster: VoiceRoomPosting, @unchecked Sendable {
    func postCallStarted(sessionId: String, text: String, clientId: String) async throws {}

    func postVoiceTurn(sessionId: String, text: String, clientId: String) async throws {}

    func uploadTranscript(sessionId: String, filename: String, markdown: String,
                          clientId: String) async throws -> VoiceTranscriptAttachment {
        VoiceTranscriptAttachment(attachmentId: "att-1", filename: filename, kind: "text", contentType: "text/markdown",
                                  sizeBytes: markdown.utf8.count, status: "ready")
    }

    func postCallEnded(sessionId: String, text: String, transcript: VoiceTranscriptAttachment?,
                       clientId: String) async throws {}
}

/// The bar of a real voice room: it shows the call as it changes, and its Mute and End reach the call.
@MainActor
final class VoiceCallBarModelTests: XCTestCase {
    func test_the_bar_follows_its_call_and_its_mute_and_end_reach_it() async throws {
        var ended = false
        let room = VoiceRoomCoordinator(
            sessionId: "room_call_bar_\(UUID().uuidString)", with: ["forge"], you: "mrrcarter",
            ownAuthorIds: ["human-mrrcarter"], listener: QuietListener(), speaker: QuietSpeaker(), audio: QuietAudio(),
            poster: QuietPoster(), onEnded: { ended = true }
        )
        let bar = VoiceCallBarModel(room)
        XCTAssertEqual(bar.state, VoiceCallBarState(room.state))
        XCTAssertEqual(bar.state.title, "forge")
        XCTAssertTrue(bar.state.isRinging, "nobody has picked up")

        let mute = try XCTUnwrap(bar.state.intent(for: .toggleMute))
        bar.send(mute)
        XCTAssertTrue(room.state.isMuted, "the bar's Mute mutes the call")
        XCTAssertTrue(bar.state.isMuted, "and the bar shows it")
        XCTAssertEqual(bar.state.muteLabel, "Unmute")

        let end = try XCTUnwrap(bar.state.intent(for: .end))
        bar.send(end)
        let deadline = Date().addingTimeInterval(5)
        while !ended, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(ended, "the bar's End hangs the call up, and its room takes the call screen and the bar away")
        XCTAssertTrue(bar.state.isEnding, "the bar shows the call ending")
        XCTAssertNil(bar.state.intent(for: .end), "and asks nothing more of it")
        XCTAssertTrue(room.state.phase == .ending || room.state.phase == .ended, "\(room.state.phase)")
    }
}

/// Minimizing hides the call screen's window and nothing else: the call stays on, and the bar brings the same screen
/// back.
@MainActor
final class VoiceCallMinimizeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        VoiceCallWindow.shared.hide()
        HostedSummary.pump(0.4)
    }

    override func tearDown() {
        VoiceCallWindow.shared.hide()
        HostedSummary.pump(0.4)
        super.tearDown()
    }

    func test_minimize_hides_only_the_call_screen_and_the_bar_brings_the_same_one_back() throws {
        let calls = VoiceCallWindow.shared
        var asked: [VoiceRoomIntent] = []
        let bar = VoiceCallBarModel(state: VoiceCallBarState(title: "forge", startedAt: Date())) { asked.append($0) }
        XCTAssertTrue(calls.show(Color.black, bar: bar), "the call screen opens over the test host")
        HostedSummary.pump(0.5)
        let screen = try XCTUnwrap(calls.callWindow)
        XCTAssertFalse(screen.isHidden)
        XCTAssertNil(calls.minimized, "on screen, not minimized")

        calls.minimize()
        XCTAssertTrue(calls.minimized === bar, "the bar shows at once")
        HostedSummary.pump(0.6)
        XCTAssertTrue(screen.isHidden, "the call screen's window hides once it has slid down")
        XCTAssertTrue(calls.callWindow === screen, "the call screen is kept for when it comes back, not made again")
        XCTAssertTrue(calls.isShowing, "a call is still on, so banners stay quiet")
        XCTAssertTrue(CallPresence.shared.isOn, "and no alert comes up over it")
        XCTAssertTrue(asked.isEmpty, "minimizing asks nothing of the call: \(asked)")

        calls.restore()
        XCTAssertNil(calls.minimized, "the bar goes as the call screen comes back")
        XCTAssertFalse(screen.isHidden, "the same call screen shows again")
        HostedSummary.pump(0.6)
        XCTAssertEqual(screen.rootViewController?.view.transform, .identity, "slid back into place")

        calls.minimize()
        HostedSummary.pump(0.6)
        calls.hide()
        XCTAssertNil(calls.minimized, "a call that ends takes its bar with it")
        XCTAssertFalse(calls.isShowing)
        XCTAssertTrue(asked.isEmpty, "\(asked)")
    }

    /// A question call gives no bar: it has no Minimize, and is never hidden without a way back.
    func test_a_call_screen_without_a_bar_is_never_minimized() throws {
        let calls = VoiceCallWindow.shared
        XCTAssertTrue(calls.show(Color.black), "the call screen opens over the test host")
        HostedSummary.pump(0.5)
        calls.minimize()
        HostedSummary.pump(0.6)
        XCTAssertNil(calls.minimized)
        XCTAssertFalse(try XCTUnwrap(calls.callWindow).isHidden, "still on screen")
    }

    func test_the_call_screen_offers_minimize_at_its_top_left() throws {
        let panel = VoiceRoomPanel(state: VoiceRoomState(with: ["forge"]), meter: VoiceLevelMeter(), partnerLab: nil,
                                   onMinimize: {}, send: { _ in })
        let window = try HostedSummary.host(panel)
        defer { HostedSummary.close(window) }
        let minimize = try XCTUnwrap(HostedSummary.wait(for: "pocket.voice.minimize", in: window),
                                     "\(HostedSummary.identifiers(in: window))")
        XCTAssertEqual(minimize.accessibilityLabel, "Minimize the call")
        let frame = minimize.accessibilityFrame
        XCTAssertGreaterThanOrEqual(frame.width, 44, "\(frame)")
        XCTAssertGreaterThanOrEqual(frame.height, 44, "\(frame)")
        XCTAssertLessThan(frame.midX, window.bounds.midX, "at the top left, across from Add (\(frame))")
        XCTAssertLessThan(frame.midY, window.bounds.midY, "at the top left, across from Add (\(frame))")
        attachPicture(of: window, name: "The call screen with Minimize")
    }

    func test_a_call_screen_with_nowhere_to_minimize_to_offers_no_minimize() throws {
        let panel = VoiceRoomPanel(state: VoiceRoomState(with: ["forge"]), meter: VoiceLevelMeter(), partnerLab: nil,
                                   send: { _ in })
        let window = try HostedSummary.host(panel)
        defer { HostedSummary.close(window) }
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.voice.end", in: window),
                        "\(HostedSummary.identifiers(in: window))")
        XCTAssertNil(HostedSummary.element("pocket.voice.minimize", in: window), "no Minimize without a bar to go to")
    }
}

/// The bar on the signed-in root as the app hosts it (scripted rooms, room-mid open): it floats over the room and never
/// moves a list, VoiceOver reads it, and it sits under the navigation bar, far from the composer's Send.
@MainActor
final class VoiceCallBarRootTests: XCTestCase {
    private var window: UIWindow?
    private var api: RootPreviewAPI?

    override func setUp() {
        super.setUp()
        VoiceCallWindow.shared.hide()
        HostedSummary.pump(0.4)
    }

    override func tearDown() {
        VoiceCallWindow.shared.hide()
        if let window { HostedSummary.close(window) }
        window = nil
        api = nil
        HostedSummary.pump(0.4)
        super.tearDown()
    }

    /// #360 and #379: a list whose top inset changed as a bar came and went kept laying itself out, and froze the
    /// phone. The bar coming (a call minimized) and going (the call screen back, or the call ended) leaves every list
    /// where it was, the room's message list among them, and draws neither the root nor a new room screen. The rows on
    /// screen stay where they were too: the bar covers a row, never moves it.
    func test_the_bar_comes_and_goes_without_moving_any_list() throws {
        let window = try hostRoot()
        let meter = RootPreview.meter
        let placed = placements(in: window)
        let tallest = try XCTUnwrap(placed.max { $0.value.height < $1.value.height }, "a list is on screen")
        XCTAssertGreaterThan(tallest.value.height, window.bounds.height / 2,
                             "the tallest list is the room's messages (\(tallest.value))")
        let list = tallest.value
        let rows = settledRows(in: window, list: list, "before the bar")
        XCTAssertFalse(rows.isEmpty, "rows of the room are on screen, inside its list, to compare")
        let rootBodies = meter.rootBodies
        let screens = meter.roomScreens

        let bar = VoiceCallBarModel(state: Self.call()) { _ in }
        minimizeACall(bar, in: window)
        assertSamePlacements(placed, placements(in: window), tallest: tallest.key, "the bar coming")
        assertSameRows(rows, settledRows(in: window, list: list, "with the bar"), "the bar coming")

        VoiceCallWindow.shared.restore()
        HostedSummary.pump(1.5)
        XCTAssertNil(HostedSummary.element("pocket.callBar.open", in: window),
                     "the bar goes as the call screen comes back")
        assertSamePlacements(placed, placements(in: window), tallest: tallest.key, "the bar going for the call screen")
        assertSameRows(rows, settledRows(in: window, list: list, "the call screen back"),
                       "the bar going for the call screen")

        VoiceCallWindow.shared.minimize()
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.callBar.open", in: window), "minimized again")
        HostedSummary.pump(1)
        VoiceCallWindow.shared.hide()
        HostedSummary.pump(1.5)
        XCTAssertNil(HostedSummary.element("pocket.callBar.open", in: window), "the bar goes with the call")
        assertSamePlacements(placed, placements(in: window), tallest: tallest.key, "the bar going with the call")
        assertSameRows(rows, settledRows(in: window, list: list, "the call ended"), "the bar going with the call")

        print("BGAUDIT call bar: root bodies \(meter.rootBodies - rootBodies), "
              + "room screens \(meter.roomScreens - screens)")
        XCTAssertEqual(meter.rootBodies - rootBodies, 0, "the bar draws itself, never the root")
        XCTAssertEqual(meter.roomScreens - screens, 0, "and never makes the room screen again")
    }

    func test_voiceover_reads_the_bar_and_reaches_mute_and_end_each_44_points() throws {
        let window = try hostRoot()
        let bar = VoiceCallBarModel(state: Self.call()) { _ in }
        minimizeACall(bar, in: window)

        let open = try XCTUnwrap(HostedSummary.element("pocket.callBar.open", in: window))
        let label = open.accessibilityLabel ?? ""
        let now = Date()
        let readable = (-2...1).map { bar.state.spokenLabel(at: now.addingTimeInterval(TimeInterval($0))) }
        XCTAssertTrue(label.hasPrefix("Call with forge, 2:"), label)
        XCTAssertTrue(readable.contains(label), "\(label) is not one of \(readable)")
        XCTAssertTrue(open.accessibilityTraits.contains(.button), "a tap on it brings the call screen back")
        let mute = try XCTUnwrap(HostedSummary.element("pocket.callBar.mute", in: window))
        XCTAssertEqual(mute.accessibilityLabel, "Mute")
        let end = try XCTUnwrap(HostedSummary.element("pocket.callBar.end", in: window))
        XCTAssertEqual(end.accessibilityLabel, "End call")
        for (name, element) in [("the bar", open), ("Mute", mute), ("End", end)] {
            let frame = element.accessibilityFrame
            XCTAssertGreaterThanOrEqual(frame.height, 44, "\(name) is at least 44 pt tall (\(frame))")
            XCTAssertGreaterThanOrEqual(frame.width, 44, "\(name) is at least 44 pt wide (\(frame))")
        }

        // Where it sits: under the navigation bar, never over its buttons, and far above the composer's Send.
        let shown = window.convert(open.accessibilityFrame, from: nil)
        let drawer = try XCTUnwrap(HostedSummary.element("pocket.drawer.open", in: window), "the side panel's button")
        let drawerFrame = window.convert(drawer.accessibilityFrame, from: nil)
        XCTAssertGreaterThanOrEqual(shown.minY, drawerFrame.maxY - 1,
                                    "under the navigation bar and its buttons (\(shown), \(drawerFrame))")
        let send = try XCTUnwrap(HostedSummary.element("pocket.room.send", in: window), "the composer's Send")
        let sendFrame = window.convert(send.accessibilityFrame, from: nil)
        XCTAssertLessThan(shown.maxY, sendFrame.minY - 100, "far above Send (\(shown), \(sendFrame))")
        attachPicture(of: window, name: "A call minimized to its bar over the room")

        var muted = bar.state
        muted.isMuted = true
        bar.show(muted)
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.callBar.mute", in: window, label: "Unmute"),
                        "muted, it says Unmute")
        let mutedLabel = HostedSummary.element("pocket.callBar.open", in: window)?.accessibilityLabel ?? ""
        XCTAssertTrue(mutedLabel.hasSuffix(", muted"), mutedLabel)
    }

    /// A call with forge, two and a half minutes in.
    private static func call() -> VoiceCallBarState {
        VoiceCallBarState(title: "forge", startedAt: Date().addingTimeInterval(-151))
    }

    /// The signed-in root as the app hosts it, on room-mid, once its first reads are in, read as VoiceOver reads it.
    private func hostRoot() throws -> UIWindow {
        let api = RootPreviewAPI(postsPerSecond: 0, onePage: false, openRoomId: RootPreviewAPI.midRoom)
        UserDefaults.standard.set(RootPreviewAPI.midRoom, forKey: "pocket.lastRoomId")
        let window = try HostedSummary.host(AuthenticatedRootView(
            authenticationEpoch: 1,
            whisperModelCoordinator: WhisperModelProvisioningCoordinator(),
            incomingLinks: IncomingLinkInbox(),
            services: api.services,
            onSignOut: {},
            onReauthenticationRequired: { _ in }
        )
        .environment(\.scenePhase, .active))
        self.window = window
        self.api = api
        let firstReads = ["rooms", "history", "actions"]
        let end = Date().addingTimeInterval(30)
        while Date() < end, !firstReads.allSatisfy({ api.callCount($0) > 0 }) { HostedSummary.pump(0.1) }
        XCTAssertTrue(firstReads.allSatisfy { api.callCount($0) > 0 }, "the room's first reads")
        HostedSummary.pump(2.5)
        return window
    }

    /// A call's screen shown and minimized, as its Minimize does: the bar shows over the room.
    private func minimizeACall(_ bar: VoiceCallBarModel, in window: UIWindow) {
        XCTAssertTrue(VoiceCallWindow.shared.show(Color.black, bar: bar), "the call screen opens")
        HostedSummary.pump(0.5)
        VoiceCallWindow.shared.minimize()
        let shown = HostedSummary.wait(for: "pocket.callBar.open", in: window)
        let ids = HostedSummary.identifiers(in: window).filter { $0.hasPrefix("pocket") }
        XCTAssertNotNil(shown, "the bar shows: \(ids)")
        HostedSummary.pump(1)
    }

    /// Where each list shows its content: its frame in the window inset by its `adjustedContentInset`, which a top
    /// inset that comes and goes changes. Lists are the outermost scroll views (a row's own sideways strip moves with
    /// its list, and is left out), never a text view.
    private func placements(in window: UIWindow) -> [ObjectIdentifier: CGRect] {
        var found: [ObjectIdentifier: CGRect] = [:]
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !(scroll is UITextView) {
                if !scroll.isHidden, let frame = scroll.superview?.convert(scroll.frame, to: window) {
                    found[ObjectIdentifier(scroll)] = frame.inset(by: scroll.adjustedContentInset)
                }
                return
            }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found
    }

    /// The room's message rows wholly on screen inside its list (`list`: where the list shows its content, in the
    /// window), by message, as VoiceOver finds them. A list that kept its frame and insets but moved its rows (its
    /// content padded for a bar) shows here. Rows off screen are left out: their frames are where the list last laid
    /// them out, not where they are.
    private func rowsOnScreen(in window: UIWindow, list: CGRect) -> [String: CGRect] {
        var found: [String: CGRect] = [:]
        for element in HostedSummary.elements(in: window) {
            guard let id = HostedSummary.identifier(of: element), id.hasPrefix("pocket.room.message.") else { continue }
            let frame = window.convert(element.accessibilityFrame, from: nil)
            if list.contains(frame) { found[id] = frame }
        }
        return found
    }

    /// The rows on screen once the room has settled. A row's "Viewed by" line arrives after the row shows (it is read
    /// 0.3 s after the row is reported viewed, and again every 15 s) and adds a line to it; the scripted room answers
    /// every later read the same, and no message arrives. Settled: the views have been read, and two readings a second
    /// apart find the same rows in the same places, with no read of the views between them. Up to 10 s.
    private func settledRows(in window: UIWindow, list: CGRect, _ when: String,
                             file: StaticString = #filePath, line: UInt = #line) -> [String: CGRect] {
        guard let api else {
            XCTFail("\(when): no room hosted", file: file, line: line)
            return [:]
        }
        let end = Date().addingTimeInterval(10)
        var rows = rowsOnScreen(in: window, list: list)
        var reads = api.callCount("views")
        while Date() < end {
            HostedSummary.pump(1)
            let again = rowsOnScreen(in: window, list: list)
            let readsAgain = api.callCount("views")
            if reads > 0, readsAgain == reads, !again.isEmpty, Set(again.keys) == Set(rows.keys),
               moved(from: rows, to: again).isEmpty {
                return again
            }
            rows = again
            reads = readsAgain
        }
        XCTFail("\(when): the room's rows did not settle within 10 s (views read \(reads) times)",
                file: file, line: line)
        return rows
    }

    /// The rows in both readings whose frames differ by more than half a point on any side.
    private func moved(from before: [String: CGRect], to after: [String: CGRect]) -> [String] {
        before.keys.sorted().filter { id in
            guard let was = before[id], let now = after[id] else { return false }
            return abs(now.minX - was.minX) > 0.5 || abs(now.minY - was.minY) > 0.5
                || abs(now.width - was.width) > 0.5 || abs(now.height - was.height) > 0.5
        }
    }

    /// The same rows, by message, settled before and after, on screen inside the list both times, in the same places:
    /// the bar covers a row, never moves it.
    private func assertSameRows(_ before: [String: CGRect], _ after: [String: CGRect], _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let compared = before.keys.filter { after[$0] != nil }
        XCTAssertFalse(compared.isEmpty, "\(what): no row on screen before is on screen after, to compare",
                       file: file, line: line)
        for id in moved(from: before, to: after) {
            let was = before[id].map { "\($0)" } ?? "none"
            let now = after[id].map { "\($0)" } ?? "none"
            XCTFail("\(what) moved \(id): \(was) became \(now)", file: file, line: line)
        }
    }

    private func assertSamePlacements(_ before: [ObjectIdentifier: CGRect], _ after: [ObjectIdentifier: CGRect],
                                      tallest: ObjectIdentifier, _ what: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(after[tallest], "\(what): the room's message list is still there to compare",
                        file: file, line: line)
        for (key, was) in before {
            guard let now = after[key] else { continue }
            let moved = abs(now.minX - was.minX) > 0.5 || abs(now.minY - was.minY) > 0.5
                || abs(now.width - was.width) > 0.5 || abs(now.height - was.height) > 0.5
            if moved {
                let which = key == tallest ? "the room's messages" : "a list"
                XCTFail("\(what) placed \(which) again: \(was) became \(now)", file: file, line: line)
            }
        }
    }
}

private extension XCTestCase {
    /// A picture of the window on the simulator, kept in the test results.
    @MainActor
    func attachPicture(of window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
