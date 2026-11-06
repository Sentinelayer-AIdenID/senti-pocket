import Combine
import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// Background work never slows the app: a read that finds nothing new writes nothing (every write draws the root, the
/// side panel or the room again), nothing recurring runs while the app is not in front or its screen cannot be seen,
/// and opening the side panel draws none of the room's rows and reads only what the panel shows that is not fresh.
@MainActor
final class RootBackgroundWorkTests: XCTestCase {
    private var window: UIWindow?
    private var watching: AnyCancellable?

    /// Each test reads only its own root's calendar entry: a window left by an earlier test could still write it.
    override func setUp() {
        super.setUp()
        RootPreview.meter.forgetCalendarEntry()
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        pump(0.4)
        UserDefaults.standard.removeObject(forKey: "pocket.lastRoomId")
        super.tearDown()
    }

    // MARK: - A read that finds nothing new writes nothing

    func test_a_quiet_room_list_read_that_finds_the_same_rooms_writes_nothing() async {
        let sessions = SessionListCoordinator(repository: SessionRepository(transport: Self.api()))
        await sessions.refreshSessions().value
        XCTAssertFalse(sessions.state.rows.isEmpty)
        let writes = count(sessions)
        await sessions.refreshSessions(quietly: true).value
        await sessions.refreshSessions(quietly: true).value
        XCTAssertEqual(writes(), 0, "the side panel's re-read that finds the same rooms writes nothing")
        // A refresh someone asked for still shows itself: its spinner, then the time of the read.
        await sessions.refreshSessions().value
        XCTAssertEqual(writes(), 2)
    }

    func test_a_bell_poll_that_finds_the_same_notifications_writes_nothing() async {
        let bell = NotificationsCoordinator(transport: Self.api(), marker: nil, onReauthenticationRequired: {})
        await bell.refresh()
        XCTAssertEqual(bell.unreadCount, 6)
        let writes = count(bell)
        await bell.refresh()
        XCTAssertEqual(writes(), 0, "a poll that finds the same notifications writes nothing")
        await bell.refresh(force: true)
        XCTAssertEqual(writes(), 1, "a read someone asked for shows its time")
    }

    func test_waiting_on_you_writes_once_per_read_and_not_at_all_when_nothing_changed() async {
        let waiting = WaitingOnYouCoordinator(transport: Self.api(), sender: AcceptsEverything())
        await waiting.refresh()
        XCTAssertEqual(waiting.state.total, 6)
        let writes = count(waiting)
        await waiting.refresh()
        XCTAssertEqual(writes(), 0, "a read that finds the same asks writes nothing")
    }

    func test_folders_and_direct_message_settings_that_did_not_change_write_nothing() async {
        let api = Self.api()
        let folders = RoomFoldersCenter(client: api, onRoomsChanged: {})
        let direct = DirectMessagesCenter(client: api)
        await folders.refresh()
        await direct.refresh()
        XCTAssertEqual(folders.folders?.count, 5)
        XCTAssertTrue(direct.isAvailable)
        let folderWrites = count(folders)
        let directWrites = count(direct, into: &directWatch)
        await folders.refresh()
        await direct.refresh()
        XCTAssertEqual(folderWrites(), 0, "the same folders write nothing")
        XCTAssertEqual(directWrites(), 0, "the same settings write nothing")
    }

    private var directWatch: AnyCancellable?

    func test_a_room_frame_that_changes_nothing_writes_nothing() async {
        let stream = ControlledRoomStream()
        let room = Self.makeRoom(stream)
        room.resume()
        await waitUntil("the room opened") { room.state.rows.count >= 3 }
        stream.yield(.frame(.message(Self.message(3))))
        await settle()
        let writes = count(room)
        // The newest message again, as a reconnect replays it, and a keep-alive.
        stream.yield(.frame(.message(Self.message(3))))
        stream.yield(.frame(.control))
        await settle()
        XCTAssertEqual(writes(), 0, "a frame that changes nothing writes nothing: every write draws the room's rows")
        room.pause()
    }

    // MARK: - The side panel over a room

    /// The phone's freezes came right after the side panel opened over a room. Opening it must not draw the room's rows
    /// (nothing in them changed), and reads the rooms once (the panel's poll) and nothing read in the last 15 s.
    func test_opening_the_side_panel_draws_no_message_row_and_reads_only_the_rooms() throws {
        let api = Self.api()
        UserDefaults.standard.set(RootPreviewAPI.midRoom, forKey: "pocket.lastRoomId")
        // The root observes its link inbox: a change announced there draws the root again and changes nothing else.
        let links = IncomingLinkInbox()
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
        // In front, as the app is when its side panel opens (a window made by a test has no scene phase of its own).
        .environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        self.window = window
        let shown = Date()
        // The room opens at its newest rows, the root's first reads land, and the root settles (`settleRoot`).
        settleRoot(api) { links.objectWillChange.send() }
        // The reads the root made as it was shown count as fresh for `panelFreshness` (15 s), which the reads asserted
        // below rely on: how long the root took to settle is printed.
        print("BGAUDIT settled \(String(format: "%.1f", Date().timeIntervalSince(shown))) s after the root was shown")
        let draws = RenderTrace.snapshot().draws
        let reads = Self.reads(api)
        let meter = RootPreview.meter
        let screens = meter.roomScreens
        let screenBodies = meter.roomScreenBodies
        let rootBodies = meter.rootBodies

        RootPreview.requestDrawer(true)
        pump(2)
        XCTAssertEqual(RenderTrace.snapshot().draws - draws, 0, "opening the side panel draws none of the room's rows")
        XCTAssertEqual(meter.roomScreens - screens, 0, "opening the side panel makes no new room screen")
        // The panel's frame watches whether it is open (`SidePanelFrame`): the root, whose draws put the room screen in
        // place, does not draw again.
        XCTAssertEqual(meter.rootBodies - rootBodies, 0, "opening the side panel does not draw the root")
        // How often the room's screen ran its body is printed, not asserted: it reads environment values the panel's
        // cover passes through, and what costs (a new screen, its rows) is asserted above.
        print("BGAUDIT room screen bodies as the panel opened: \(meter.roomScreenBodies - screenBodies)")
        let after = Self.reads(api)
        XCTAssertEqual(after["rooms"]! - reads["rooms"]!, 1, "the rooms are read once as the panel opens")
        for name in ["bell", "waiting", "folders", "dmSettings"] {
            XCTAssertEqual(after[name]! - reads[name]!, 0, "\(name) was read moments ago: not again")
        }
        RootPreview.requestDrawer(false)
        pump(1.5)
        XCTAssertEqual(RenderTrace.snapshot().draws - draws, 0, "closing it draws none either")
        XCTAssertEqual(meter.roomScreens - screens, 0, "closing it makes no new room screen either")
        XCTAssertEqual(meter.rootBodies - rootBodies, 0, "closing it does not draw the root either")
    }

    /// Carter's phone froze on 11-06 right after a room was picked in the side panel. A draw of the root that changes
    /// nothing makes no room screen (`RoomScreenSlot`); a room picked in the panel makes exactly one, the new room's,
    /// and the room it replaced is let go: once the screen settles, no two rooms are alive.
    func test_picking_another_room_makes_one_room_screen_and_lets_the_other_go() throws {
        let api = Self.api()
        UserDefaults.standard.set(RootPreviewAPI.midRoom, forKey: "pocket.lastRoomId")
        // The root observes its link inbox: a change announced there draws the root again and changes nothing else.
        let links = IncomingLinkInbox()
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
        settleRoot(api) { links.objectWillChange.send() }
        let meter = RootPreview.meter
        let screens = meter.roomScreens
        let rootBodies = meter.rootBodies
        let liveRooms = meter.liveRooms

        links.objectWillChange.send()
        pump(1)
        XCTAssertGreaterThan(meter.rootBodies - rootBodies, 0, "the root drew again")
        XCTAssertEqual(meter.roomScreens - screens, 0, "a draw of the root that changes nothing makes no room screen")

        RootPreview.requestDrawer(true)
        pump(1)
        RootPreview.requestRoom("room-000")
        quiet { [RenderTrace.snapshot().draws, meter.roomScreens, api.totalCalls] }
        XCTAssertEqual(meter.roomScreens - screens, 1, "picking another room makes one room screen, the new room's")
        // The room it replaced goes once nothing holds it any more.
        let end = Date().addingTimeInterval(10)
        while Date() < end, meter.liveRooms > liveRooms { pump(0.2) }
        XCTAssertEqual(meter.liveRooms, liveRooms, "the room it replaced is let go: no two rooms alive")
    }

    // MARK: - The calendar's changes leave the root and its room alone

    /// Review (#330): the root keeps the calendar's center without watching it, as it keeps the side panel's placement.
    /// A calendar change (here the room's drafts check answering after the root has settled, as a slow or edge-held
    /// answer does) draws the ⋯ entry and Settings only: never the root again, never a new room screen, no row.
    func test_a_calendar_answer_after_the_root_settles_draws_no_root_no_room_screen_and_no_row() throws {
        try measureCalendarAnswer(on: false)
    }

    /// The same with the calendar on: the ⋯ entry, a modifier on the navigation root, gains its Calendar item (it watches
    /// the calendar itself, so it updates without the root), and the room screen inside it is not made again.
    func test_the_calendar_turning_on_after_the_root_settles_makes_no_new_room_screen() throws {
        try measureCalendarAnswer(on: true)
    }

    private func measureCalendarAnswer(on: Bool) throws {
        let api = Self.api()
        UserDefaults.standard.set(RootPreviewAPI.midRoom, forKey: "pocket.lastRoomId")
        let gate = GatedCalendar()
        defer { gate.answer(false) }
        var services = api.services
        services.calendar = gate
        let links = IncomingLinkInbox()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AuthenticatedRootView(
            authenticationEpoch: 1,
            whisperModelCoordinator: WhisperModelProvisioningCoordinator(),
            incomingLinks: links,
            services: services,
            onSignOut: {},
            onReauthenticationRequired: { _ in }
        )
        .environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        self.window = window
        settleRoot(api) { links.objectWillChange.send() }
        // The room's ⋯ entry asked whether drafting is on; the answer is held until now.
        let end = Date().addingTimeInterval(10)
        while Date() < end, gate.asks == 0 { pump(0.1) }
        XCTAssertEqual(gate.asks, 1, "the room's ⋯ entry asked about the calendar once")
        let meter = RootPreview.meter
        XCTAssertEqual(meter.calendarEntryOffers, false, "before the answer the room's ⋯ entry offers no Calendar")
        let rootBodies = meter.rootBodies
        let screens = meter.roomScreens
        let draws = RenderTrace.snapshot().draws

        gate.answer(on)
        pump(1.5)
        XCTAssertEqual(meter.roomScreens - screens, 0, "a calendar change makes no new room screen")
        XCTAssertEqual(meter.rootBodies - rootBodies, 0, "a calendar change does not draw the root again")
        XCTAssertEqual(RenderTrace.snapshot().draws - draws, 0, "a calendar change draws none of the room's rows")
        XCTAssertEqual(meter.calendarEntryOffers, on,
                       on ? "the room's ⋯ entry offers Calendar once the answer is on: it watched the answer"
                          : "the room's ⋯ entry still offers no Calendar")
        print("BGAUDIT calendar answer \(on): root bodies \(meter.rootBodies - rootBodies), "
              + "room screens \(meter.roomScreens - screens)")
    }

    /// An arrival draws the row that arrived (and the one before it, whose grouping may change), never every row the
    /// list has made: with an accessibility client reading the screen the list keeps them all, and a busy room drew
    /// every one of them at every arrival.
    func test_an_arrival_draws_the_new_row_not_every_row() throws {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        func input(_ seq: Int64) -> RoomChatMessageInput {
            let author = seq.isMultiple(of: 3) ? "human-alex" : "review-agent"
            let date = start.addingTimeInterval(Double(seq) * 600)
            return RoomChatMessageInput(id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: author,
                                        authorName: author, isHuman: author.hasPrefix("human-"),
                                        text: "Message \(seq), long enough to wrap onto a second line on a phone screen.",
                                        timestamp: ISO8601DateFormatter().string(from: date), date: date)
        }
        func state(_ count: Int64) -> RoomChatPresentationState {
            RoomChatPresentationState(sessionId: "arrivals", title: "Room", messages: (1...count).map(input),
                                      ownAuthorIds: ["human-alex"], connection: .live,
                                      composer: RoomComposerState(canPost: true, disabledReason: nil), canReact: true)
        }
        let room = ArrivingRoom(state(40))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ArrivingRoomHost(room: room))
        window.makeKeyAndVisible()
        self.window = window
        // Opened and scrolled to its newest rows, and an update that changes nothing draws no row (`settle`).
        settle(updating: { room.objectWillChange.send() }) { [RenderTrace.snapshot().draws] }
        let drawn = RenderTrace.snapshot().draws
        XCTAssertGreaterThan(drawn, 4, "the room drew its rows")
        // Rows the list made and keeps, as a reader who went up the room and came back leaves it.
        room.state = state(41)
        settleDrawing()
        let arrival = RenderTrace.snapshot().draws - drawn
        print("BGAUDIT arrival drew \(arrival) rows (the room had drawn \(drawn))")
        XCTAssertLessThanOrEqual(arrival, 3, "an arrival draws the new row, not every row the list has made")
        // What a row shows still changes it: an edit, a reaction, a receipt draws that row again.
        let beforeEdit = RenderTrace.snapshot().draws
        var edited = (1...41).map(input)
        edited[40] = RoomChatMessageInput(id: "evt-41", sequenceId: 41, kind: .message, authorId: "review-agent",
                                          authorName: "review-agent", isHuman: false, text: "Message 41, edited.",
                                          timestamp: edited[40].timestamp, isEdited: true, date: edited[40].date)
        room.state = RoomChatPresentationState(sessionId: "arrivals", title: "Room", messages: edited,
                                               ownAuthorIds: ["human-alex"], connection: .live,
                                               composer: RoomComposerState(canPost: true, disabledReason: nil),
                                               canReact: true)
        pump(1.5)
        XCTAssertGreaterThanOrEqual(RenderTrace.snapshot().draws - beforeEdit, 1, "the edited row is drawn again")
    }

    // MARK: - Helpers

    private static func api() -> RootPreviewAPI {
        RootPreviewAPI(postsPerSecond: 0, onePage: false, openRoomId: RootPreviewAPI.midRoom)
    }

    private static func reads(_ api: RootPreviewAPI) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: ["rooms", "bell", "waiting", "folders", "dmSettings"].map { ($0, api.callCount($0)) })
    }

    /// Counts the changes `object` announces from now on.
    private func count<Object: ObservableObject>(_ object: Object) -> () -> Int {
        var watch: AnyCancellable?
        let counter = count(object, into: &watch)
        watching = watch
        return counter
    }

    private func count<Object: ObservableObject>(_ object: Object, into watch: inout AnyCancellable?) -> () -> Int {
        let box = Counter()
        watch = object.objectWillChange.sink { _ in box.value += 1 }
        return { box.value }
    }

    private final class Counter { var value = 0 }

    /// A calendar whose drafts check waits until the test answers it; everything else is off.
    private final class GatedCalendar: RoomCalendarServing, CalendarFeedServing, @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Bool, Never>] = []
        private var _asks = 0

        var asks: Int { lock.withLock { _asks } }

        func answer(_ on: Bool) {
            let held = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
                defer { waiting = [] }
                return waiting
            }
            held.forEach { $0.resume(returning: on) }
        }

        func draftsAvailable(inRoom sessionId: String) async throws -> Bool {
            await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
                lock.withLock {
                    _asks += 1
                    waiting.append(waiter)
                }
            }
        }

        func events(inRoom sessionId: String) async throws -> [CalendarEvent] { throw CalendarError.unavailable }
        func agenda() async throws -> [CalendarEvent] { throw CalendarError.unavailable }
        func draft(inRoom sessionId: String, _ request: CalendarDraftRequest) async throws -> CalendarDraft {
            throw CalendarError.unavailable
        }
        func save(_ event: CalendarEventCreate, inRoom sessionId: String) async throws -> CalendarEvent {
            throw CalendarError.unavailable
        }
        func feedAvailable() async throws -> Bool { false }
        func newSubscriptionLink() async throws -> CalendarSubscriptionLink { throw CalendarError.unavailable }
        func keptLink(_ url: URL) -> CalendarSubscriptionLink? { nil }
    }

    private final class ArrivingRoom: ObservableObject {
        @Published var state: RoomChatPresentationState
        init(_ state: RoomChatPresentationState) { self.state = state }
    }

    private struct ArrivingRoomHost: View {
        @ObservedObject var room: ArrivingRoom
        var body: some View {
            NavigationStack { RoomChatView(state: room.state) { _ in } }
        }
    }

    static func message(_ seq: Int64) -> RoomMessage {
        RoomMessage(id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: "review-agent", authorName: "review-agent",
                    isHuman: false, text: "Message \(seq).", timestamp: "2026-11-04T09:00:0\(seq).000000+00:00")
    }

    static func sequences(_ room: RoomChatCoordinator) -> [Int64] {
        room.state.rows.compactMap { row in
            if case .message(let message) = row { return message.sequenceId }
            return nil
        }
    }

    static func makeRoom(_ stream: ControlledRoomStream) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: stream,
            ownAuthorIds: ["human-alex"],
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            onReauthenticationRequired: {}
        )
    }

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)", file: file, line: line)
    }

    /// Runs the main run loop until no row has been drawn for a second (at most 15 s): the room has taken in what
    /// arrived, on a loaded machine too.
    private func settleDrawing() {
        quiet { [RenderTrace.snapshot().draws] }
    }

    /// Runs the main run loop until `activity` has not moved for a second (at most 15 s).
    private func quiet(_ activity: () -> [Int]) {
        let end = Date().addingTimeInterval(15)
        var last = activity()
        var quietSince = Date()
        while Date() < end, Date().timeIntervalSince(quietSince) < 1 {
            pump(0.1)
            let now = activity()
            if now != last {
                last = now
                quietSince = Date()
            }
        }
    }

    /// Settled: `activity` has not moved for a second, and then an update that changes nothing (`update`) moves nothing
    /// either. Measured, not assumed: a view SwiftUI first built during layout (the room screen under the navigation
    /// stack, the rows the list made as it scrolled to its newest) can run its body once more at the next update, with
    /// nothing it shows changed and without its `==` being asked. Started cold on a loaded machine, that next update was
    /// the one a test measured: the side panel's open (a room screen made again, no row drawn) or an arrival (the four
    /// rows made by the last scroll drawn again with the new one). So the room is updated with nothing changed until
    /// such an update moves nothing, up to five times; a room that still moves is measured as it is, and the assertions
    /// say what it did.
    private func settle(updating update: () -> Void, _ activity: () -> [Int]) {
        quiet(activity)
        for attempt in 1...5 {
            let before = activity()
            update()
            quiet(activity)
            let after = activity()
            print("BGAUDIT settle: update \(attempt) that changed nothing moved \(before) to \(after)")
            if after == before { return }
        }
    }

    /// The hosted root has settled (`settle`): its first reads were asked for (the rooms, the bell, Waiting on you,
    /// folders and direct-message settings, and the open room's history, reactions and who is here), then nothing was
    /// read (who viewed what included), no row drawn and no room screen made for a second, and an update of the root
    /// that changes nothing (`update`) read, drew and made nothing. Who viewed what is not waited for by name: in 1 of
    /// 15 runs on the build Mac the room did not read it in 33 s, which would leave the reads the root made at launch
    /// older than the panel's 15 s.
    private func settleRoot(_ api: RootPreviewAPI, update: () -> Void) {
        let firstReads = ["rooms", "bell", "waiting", "folders", "dmSettings", "history", "actions", "presence"]
        let end = Date().addingTimeInterval(30)
        while Date() < end, firstReads.contains(where: { api.callCount($0) == 0 }) { pump(0.1) }
        XCTAssertEqual(firstReads.filter { api.callCount($0) == 0 }, [], "the root and its room made their first reads")
        settle(updating: update) { [RenderTrace.snapshot().draws, RootPreview.meter.roomScreens, api.totalCalls] }
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}

/// A room of three messages whose live stream the test feeds (also used by `BackgroundGatesTests`).
final class ControlledRoomStream: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<RoomStreamEvent>.Continuation?
    private var waiting: [RoomStreamEvent] = []

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        let messages = (1...3).map { seq in
            RoomMessage(id: "evt-\(seq)", sequenceId: Int64(seq), kind: .message, authorId: "review-agent",
                        authorName: "review-agent", isHuman: false, text: "Message \(seq).",
                        timestamp: "2026-11-04T09:00:0\(seq).000000+00:00")
        }
        return RoomEventPage(messages: messages, maxSequence: 3, nextBeforeSequence: 1, hasMore: false)
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> {
        AsyncStream { continuation in
            let queued: [RoomStreamEvent] = lock.withLock {
                self.continuation = continuation
                defer { waiting = [] }
                return waiting
            }
            queued.forEach { continuation.yield($0) }
        }
    }

    func yield(_ event: RoomStreamEvent) {
        let continuation: AsyncStream<RoomStreamEvent>.Continuation? = lock.withLock {
            if self.continuation == nil { waiting.append(event) }
            return self.continuation
        }
        continuation?.yield(event)
    }
}

private struct AcceptsEverything: RoomMessageSending {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {}
}
