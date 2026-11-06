import EventKit
import Foundation
import PocketSyncClient
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

// Connect my calendar (ticket 9583d41e), against a stand-in phone calendar and a stand-in server. Every calendar and
// event here is made up; no test reads the phone's real calendar.

/// A phone calendar with made-up events. It hands back every event, whatever calendars are asked for, so the center
/// itself must send only the picked ones.
@MainActor
private final class FakePhoneCalendar: PhoneCalendarStore {
    var access: PhoneCalendarAccess
    /// What asking iOS answers.
    var answer: PhoneCalendarAccess = .granted
    let sources: [PhoneCalendarSource]
    var events: [PhoneCalendarItem]
    private(set) var asks = 0
    private var changed: (@MainActor () -> Void)?

    init(access: PhoneCalendarAccess = .notAsked, start: Date) {
        self.access = access
        let work = PhoneCalendarSource(id: "cal-work", title: "Work", account: "iCloud")
        let home = PhoneCalendarSource(id: "cal-home", title: "Home", account: "iCloud")
        let club = PhoneCalendarSource(id: "cal-club", title: "Book club", account: "Mail")
        sources = [work, home, club]
        func item(_ id: String, _ source: PhoneCalendarSource, _ title: String, hours: Double, allDay: Bool = false)
            -> PhoneCalendarItem {
            PhoneCalendarItem(identifier: id, occurrenceStart: start.addingTimeInterval(hours * 3_600),
                              calendarId: source.id, calendarTitle: source.title, title: title,
                              start: start.addingTimeInterval(hours * 3_600),
                              end: start.addingTimeInterval((hours + 1) * 3_600), allDay: allDay,
                              location: nil)
        }
        events = [
            item("ev-1", work, "Design review", hours: 2),
            item("ev-2", work, "Pocket build check", hours: 26),
            item("ev-3", home, "Dentist", hours: 50),
            item("ev-4", club, "Chapter 6", hours: 74)
        ]
    }

    func requestAccess() async -> PhoneCalendarAccess {
        asks += 1
        access = answer
        return access
    }

    func calendars() -> [PhoneCalendarSource] { access == .granted ? sources : [] }

    func items(from start: Date, to end: Date, calendars ids: Set<String>?) async -> [PhoneCalendarItem] {
        access == .granted ? events : []
    }

    func onChange(_ changed: @escaping @MainActor () -> Void) { self.changed = changed }

    /// The phone's calendar changed.
    func change() { changed?() }

    /// The first event is renamed on the phone, and the phone says its calendar changed.
    func rename(_ title: String) {
        let first = events[0]
        events[0] = PhoneCalendarItem(identifier: first.identifier, occurrenceStart: first.occurrenceStart,
                                      calendarId: first.calendarId, calendarTitle: first.calendarTitle, title: title,
                                      start: first.start, end: first.end, allDay: first.allDay, location: nil)
        change()
    }
}

/// The server: records each send and forget; a forget can be made to fail, and the flag to be off.
private final class FakeDeviceCalendar: DeviceCalendarServing, @unchecked Sendable {
    private let lock = NSLock()
    private let on: Bool
    private var sent: [DeviceCalendarUpload] = []
    private var keys: [String] = []
    private var forgets = 0
    private var forgetFails = false

    init(on: Bool = true) { self.on = on }

    var puts: [DeviceCalendarUpload] { lock.withLock { sent } }
    var putKeys: [String] { lock.withLock { keys } }
    var deletes: Int { lock.withLock { forgets } }
    func failForgets(_ fails: Bool) { lock.withLock { forgetFails = fails } }

    func deviceEventsAvailable(now: Date) async throws -> Bool { on }

    func putDeviceEvents(_ upload: DeviceCalendarUpload, idempotencyKey: String) async throws -> Int {
        lock.withLock {
            sent.append(upload)
            keys.append(idempotencyKey)
        }
        return upload.events.count
    }

    func deleteDeviceEvents() async throws {
        let fails = lock.withLock { () -> Bool in
            forgets += 1
            return forgetFails
        }
        if fails { throw CalendarError.retryable }
    }
}

@MainActor
final class PhoneCalendarTests: XCTestCase {
    private var clock = CalendarInstant.parse("2026-11-06T15:00:00Z")!
    private var who = "acct-1"
    private var waits: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
    private let defaults = UserDefaults(suiteName: "phone-calendar-tests")!
    private let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    override func setUp() {
        super.setUp()
        defaults.removePersistentDomain(forName: "phone-calendar-tests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "phone-calendar-tests")
        super.tearDown()
    }

    private func center(_ store: FakePhoneCalendar, _ client: FakeDeviceCalendar) -> PhoneCalendarCenter {
        PhoneCalendarCenter(store: store, client: client, defaults: defaults, person: { [unowned self] in self.who },
                            calendar: newYork, now: { [unowned self] in self.clock },
                            later: { [unowned self] delay, work in self.waits.append((delay, work)) })
    }

    /// The calendar center the screens take, holding `phone`; its subscribe link's flag on or off.
    private func calendarCenter(_ phone: PhoneCalendarCenter, feedOn: Bool = false) -> CalendarCenter {
        CalendarCenter(client: NoRoomEvents(), feed: feedOn ? FeedOn() as any CalendarFeedServing : CalendarOff(),
                       vault: NoKeptLink(), person: { "acct-1" }, openURL: { _ in true }, phone: phone)
    }

    /// Waits for an element while letting the main actor run: a button's action starts a Task on the main actor, and
    /// a run loop pumped inside this test's own main-actor job never runs it (`HostedSummary.wait` would only time out).
    private func settle(until identifier: String, in window: UIWindow, timeout: TimeInterval = 15) async -> NSObject? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let found = HostedSummary.element(identifier, in: window) { return found }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// Opened, with the flag on, and connected.
    private func connected(_ store: FakePhoneCalendar, _ client: FakeDeviceCalendar) async -> PhoneCalendarCenter {
        let phone = center(store, client)
        await phone.appOpened()
        await phone.connect()
        return phone
    }

    // MARK: - Showing never sends

    /// Connecting shows the phone's events in Pocket's calendar and sends nothing; with the switch off nothing is sent,
    /// even with a calendar picked, the app opened again and the phone's calendar changed.
    func test_showing_the_phones_events_sends_nothing_and_nothing_goes_while_the_switch_is_off() async {
        let store = FakePhoneCalendar(start: clock)
        let client = FakeDeviceCalendar()
        let phone = await connected(store, client)
        XCTAssertEqual(phone.available, true)
        XCTAssertEqual(phone.access, .granted)
        XCTAssertEqual(store.asks, 1)
        let shown = await phone.items(from: clock, to: clock.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(shown.count, 4, "the events show")
        XCTAssertEqual(phone.calendars.map(\.title), ["Work", "Home", "Book club"])

        phone.setShared("cal-work", true)
        store.change()
        clock.addTimeInterval(120)
        await phone.appOpened()
        store.change()
        await phone.idle()
        XCTAssertFalse(phone.sharesWithAgents, "off until the person turns it on")
        XCTAssertTrue(client.puts.isEmpty, "nothing is sent while the switch is off")
        XCTAssertEqual(client.deletes, 0)
        XCTAssertTrue(waits.isEmpty, "and nothing waits to be sent")
    }

    // MARK: - Off forgets

    /// Turning the switch off sends one DELETE. A DELETE that does not go is sent again first, when the app next
    /// opens, and nothing is sent until it has gone.
    func test_turning_the_switch_off_sends_a_delete_and_one_that_failed_goes_first() async {
        let store = FakePhoneCalendar(start: clock)
        let client = FakeDeviceCalendar()
        let phone = await connected(store, client)
        phone.setShared("cal-work", true)
        await phone.setSharing(true)
        await phone.idle()
        XCTAssertEqual(client.puts.count, 1)

        await phone.setSharing(false)
        XCTAssertEqual(client.deletes, 1, "off forgets them on the server")
        XCTAssertEqual(client.puts.count, 1, "and sends nothing more")
        XCTAssertFalse(phone.sharesWithAgents)

        // On again an hour on, then off while the server cannot be reached.
        clock.addTimeInterval(3_600)
        await phone.setSharing(true)
        await phone.idle()
        XCTAssertEqual(client.puts.count, 2)
        client.failForgets(true)
        await phone.setSharing(false)
        XCTAssertEqual(client.deletes, 2)
        XCTAssertNotNil(phone.notice, "the person is told it did not go")

        // On again before it has gone: the forget goes first, and nothing is sent while it fails.
        clock.addTimeInterval(120)
        await phone.setSharing(true)
        await phone.idle()
        XCTAssertEqual(client.deletes, 3)
        XCTAssertEqual(client.puts.count, 2, "nothing is sent until the forget has gone")

        // Off again, and the next open sends the forget first.
        await phone.setSharing(false)
        client.failForgets(false)
        clock.addTimeInterval(120)
        await phone.appOpened()
        await phone.idle()
        XCTAssertEqual(client.deletes, 5)
        XCTAssertEqual(client.puts.count, 2)
        XCTAssertNil(phone.notice)
    }

    // MARK: - Only the picked calendars

    /// Only the calendars picked are sent, whatever the phone hands back; none picked sends nothing.
    func test_calendars_not_picked_are_never_sent() async throws {
        let store = FakePhoneCalendar(start: clock)
        let client = FakeDeviceCalendar()
        let phone = await connected(store, client)
        await phone.setSharing(true)
        await phone.idle()
        XCTAssertTrue(client.puts.isEmpty, "none picked: nothing is sent")

        phone.setShared("cal-work", true)
        await phone.idle()
        let sent = try XCTUnwrap(client.puts.first)
        XCTAssertEqual(Set(sent.events.map(\.calendar)), ["Work"])
        XCTAssertEqual(sent.events.map(\.title), ["Design review", "Pocket build check"])
        let body = String(decoding: try JSONSerialization.data(withJSONObject: sent.body), as: UTF8.self)
        XCTAssertFalse(body.contains("Dentist"))
        XCTAssertFalse(body.contains("Chapter 6"))
    }

    // MARK: - At most once a minute

    /// Sends go when the app opens and when the phone's calendar changes, at most once a minute: a change inside the
    /// minute is folded into one send at the minute.
    func test_sends_are_at_most_once_a_minute() async {
        let store = FakePhoneCalendar(start: clock)
        let client = FakeDeviceCalendar()
        let phone = await connected(store, client)
        phone.setShared("cal-work", true)
        await phone.setSharing(true)
        await phone.idle()
        XCTAssertEqual(client.puts.count, 1)

        clock.addTimeInterval(10)
        store.rename("Design review, moved")
        await phone.idle()
        XCTAssertEqual(client.puts.count, 1, "a change 10 seconds on waits")
        XCTAssertEqual(waits.map { $0.delay }, [50], "until the minute is up")

        clock.addTimeInterval(49)
        store.rename("Design review, moved again")
        await phone.appOpened()
        await phone.idle()
        XCTAssertEqual(client.puts.count, 1)
        XCTAssertEqual(waits.count, 1, "folded into the one waiting")

        clock.addTimeInterval(1)
        waits[0].work()
        await phone.idle()
        XCTAssertEqual(client.puts.count, 2, "one send at the minute")
        XCTAssertEqual(Set(client.putKeys).count, 2, "each send its own key")

        clock.addTimeInterval(1)
        store.rename("Design review, once more")
        await phone.idle()
        XCTAssertEqual(client.puts.count, 2)
        XCTAssertEqual(waits.count, 2)
        XCTAssertEqual(waits[1].delay, 59, accuracy: 0.001)
    }

    // MARK: - Every way sharing stops reaches the server

    /// Unticking the last calendar while sharing leaves nothing shared, so the server forgets what it has (it never
    /// expires an upload, and the person's agents would go on reading it). Ticking one again sends it.
    func test_unticking_the_last_calendar_forgets_what_was_shared() async {
        let store = FakePhoneCalendar(start: clock)
        let client = FakeDeviceCalendar()
        let phone = await connected(store, client)
        phone.setShared("cal-work", true)
        await phone.setSharing(true)
        await phone.idle()
        XCTAssertEqual(client.puts.count, 1)

        phone.setShared("cal-work", false)
        await phone.idle()
        XCTAssertEqual(client.deletes, 1, "the last calendar unticked: the server forgets")
        XCTAssertEqual(client.puts.count, 1)
        XCTAssertTrue(phone.sharesWithAgents, "the switch is as the person left it")

        clock.addTimeInterval(120)
        phone.setShared("cal-home", true)
        await phone.idle()
        XCTAssertEqual(client.puts.count, 2)
        XCTAssertEqual(Set(client.puts.last?.events.map(\.calendar) ?? []), ["Home"])
    }

    /// Turning calendar access off in iOS Settings while sharing stops sharing and the server forgets, by itself, the
    /// next time the app opens. While a forget has not gone, the switch stays in sight.
    func test_turning_calendar_access_off_stops_sharing_and_the_server_forgets() async {
        let store = FakePhoneCalendar(start: clock)
        let client = FakeDeviceCalendar()
        let phone = await connected(store, client)
        phone.setShared("cal-work", true)
        await phone.setSharing(true)
        await phone.idle()
        XCTAssertEqual(client.puts.count, 1)

        client.failForgets(true)
        store.access = .denied
        clock.addTimeInterval(120)
        await phone.appOpened()
        await phone.idle()
        XCTAssertEqual(client.deletes, 1, "access went: the server is told to forget")
        XCTAssertFalse(phone.sharesWithAgents)
        XCTAssertTrue(phone.forgetPending)
        XCTAssertTrue(phone.showsSharing, "the switch stays in sight while the forget has not gone")

        client.failForgets(false)
        clock.addTimeInterval(120)
        await phone.appOpened()
        await phone.idle()
        XCTAssertEqual(client.deletes, 2)
        XCTAssertFalse(phone.forgetPending)
        XCTAssertFalse(phone.showsSharing, "nothing shared, nothing to stop")
        XCTAssertEqual(client.puts.count, 1, "nothing is sent without access")
    }

    /// A send whose body is the same as the last one the server took is not sent again.
    func test_the_same_calendar_is_not_sent_twice() async {
        let store = FakePhoneCalendar(start: clock)
        let client = FakeDeviceCalendar()
        let phone = await connected(store, client)
        phone.setShared("cal-work", true)
        await phone.setSharing(true)
        await phone.idle()
        clock.addTimeInterval(120)
        await phone.appOpened()
        await phone.idle()
        XCTAssertEqual(client.puts.count, 1, "nothing changed: nothing sent")
        clock.addTimeInterval(120)
        store.rename("Design review, moved")
        await phone.idle()
        XCTAssertEqual(client.puts.count, 2)
    }

    /// The app makes one EventKit store, however often its root view is made (each pass of the App's body made one).
    func test_the_app_makes_one_eventkit_store() {
        let client = FakeDeviceCalendar()
        let first = PhoneCalendarCenter.live(client: client, person: { "acct-1" })
        let second = PhoneCalendarCenter.live(client: client, person: { "acct-1" })
        _ = PhoneCalendarCenter.live(client: client, person: { "acct-1" })
        XCTAssertFalse(first === second)
        XCTAssertEqual(EventKitPhoneCalendar.made, 1)
    }

    /// A pick whose calendar is no longer on the phone is not counted.
    func test_picks_of_calendars_gone_from_the_phone_are_not_counted() async {
        let store = FakePhoneCalendar(start: clock)
        let phone = await connected(store, FakeDeviceCalendar())
        phone.setShared("cal-work", true)
        phone.setShared("cal-gone", true)
        XCTAssertEqual(phone.sharedCalendarIds.count, 2)
        XCTAssertEqual(phone.pickedCount, 1)
    }

    // MARK: - What leaves the phone

    /// An event's notes and link never leave the phone (EventKit's attendees are never read at all): only its title,
    /// times, all-day mark, place and calendar's name are sent.
    func test_notes_attendees_and_links_never_leave_the_phone() throws {
        let eventStore = EKEventStore()
        let work = EKCalendar(for: .event, eventStore: eventStore)
        work.title = "Work"
        let event = EKEvent(eventStore: eventStore)
        event.calendar = work
        event.title = "Design review"
        event.startDate = clock
        event.endDate = clock.addingTimeInterval(3_600)
        event.notes = "Bring the blue folder"
        event.url = URL(string: "https://meet.example.test/room-7")
        let item = try XCTUnwrap(PhoneCalendarItem(event: event))
        XCTAssertEqual(item.calendarTitle, "Work")
        XCTAssertNil(item.location)

        let window = DeviceCalendarUpload.window(around: clock, in: newYork)
        let upload = PhoneCalendarCenter.upload([item], shared: [item.calendarId], window: window, calendar: newYork)
        let body = String(decoding: try JSONSerialization.data(withJSONObject: upload.body), as: UTF8.self)
        XCTAssertTrue(body.contains("Design review"))
        XCTAssertFalse(body.contains("blue folder"), "notes never leave the phone")
        XCTAssertFalse(body.contains("meet.example.test"), "links never leave the phone")
        XCTAssertNil(upload.events.first?.location, "a link is never sent as the place")
    }

    // MARK: - Hidden while the server's flag is off

    /// While the server answers 404, nothing of it shows or is asked: iOS is never asked for access, no events show,
    /// and the switch does nothing.
    func test_a_404_hides_it_all() async {
        let store = FakePhoneCalendar(start: clock)
        let client = FakeDeviceCalendar(on: false)
        let phone = center(store, client)
        await phone.appOpened()
        XCTAssertEqual(phone.available, false)
        await phone.connect()
        XCTAssertEqual(store.asks, 0, "iOS is never asked while it is off")
        let shown = await phone.items(from: clock, to: clock.addingTimeInterval(86_400))
        XCTAssertTrue(shown.isEmpty)
        await phone.setSharing(true)
        await phone.idle()
        XCTAssertFalse(phone.sharesWithAgents)
        XCTAssertTrue(client.puts.isEmpty)
    }

    // MARK: - The person's own

    /// The switch and the picks are the signed-in account's: another sign-in starts with the switch off and sends
    /// nothing, and the first account's come back with it.
    func test_another_sign_in_starts_with_the_switch_off() async {
        let store = FakePhoneCalendar(start: clock)
        let client = FakeDeviceCalendar()
        let phone = await connected(store, client)
        phone.setShared("cal-work", true)
        await phone.setSharing(true)
        await phone.idle()
        XCTAssertEqual(client.puts.count, 1)

        who = "acct-2"
        clock.addTimeInterval(120)
        await phone.appOpened()
        await phone.idle()
        XCTAssertFalse(phone.sharesWithAgents)
        XCTAssertTrue(phone.sharedCalendarIds.isEmpty)
        XCTAssertEqual(client.puts.count, 1)

        who = "acct-1"
        clock.addTimeInterval(120)
        await phone.appOpened()
        await phone.idle()
        XCTAssertTrue(phone.sharesWithAgents)
        XCTAssertEqual(phone.sharedCalendarIds, ["cal-work"])
        XCTAssertEqual(client.puts.count, 2)
    }

    // MARK: - Pocket's own calendar

    /// Pocket's own calendar shows the phone's events on their days, counted with the rooms', for VoiceOver too.
    func test_pockets_own_calendar_shows_the_phones_events_on_their_days() async {
        let store = FakePhoneCalendar(start: clock)
        let client = FakeDeviceCalendar()
        let phone = await connected(store, client)
        let board = CalendarBoard(scope: .agenda(rooms: []), client: NoRoomEvents(), calendar: newYork,
                                  now: { [unowned self] in self.clock }, phone: phone)
        await board.readPhone()
        let day = CalendarDay(clock.addingTimeInterval(2 * 3_600), in: newYork)
        XCTAssertEqual(board.phoneItems(on: day).map(\.title), ["Design review"])
        let cell = board.grid.cells.first { $0.day == day }
        XCTAssertEqual(cell?.eventCount, 1)
        XCTAssertEqual(cell?.accessibilityLabel.hasSuffix("1 event"), true)
        XCTAssertEqual(PhoneEventRow.label(board.phoneItems(on: day)[0], time: "12:00 – 1:00 PM"),
                       "Design review, 12:00 – 1:00 PM, from your phone, Work")
    }

    // MARK: - Found where the calendar is

    /// The calendar screen itself offers Connect, then the switch that lets your agents see your calendar (Carter
    /// looked there for them, not in Settings): here in a room's calendar, as in Pocket's own.
    func test_the_calendar_screen_itself_offers_connect_and_then_the_agents_switch() async throws {
        let store = FakePhoneCalendar(start: clock)
        let client = FakeDeviceCalendar()
        let phone = center(store, client)
        await phone.appOpened()
        let room = CalendarBoard(scope: .room(sessionId: "room-1", title: "Site", canAdd: true), client: NoRoomEvents(),
                                 calendar: newYork, now: { [unowned self] in self.clock })
        let window = try HostedSummary.host(NavigationStack {
            CalendarScreen(board: room, calendar: calendarCenter(phone))
        })
        defer { HostedSummary.close(window) }
        let connect = try XCTUnwrap(HostedSummary.wait(for: "pocket.calendar.connect", in: window),
                                    "Connect is on the calendar screen")
        XCTAssertTrue(connect.accessibilityActivate())
        let share = await settle(until: "pocket.calendar.share", in: window)
        XCTAssertNotNil(share, "then the agents switch, on the same screen")
        XCTAssertEqual(store.asks, 1)
        XCTAssertTrue(client.puts.isEmpty, "connecting sends nothing")
    }

    /// "Sync to my other calendars" is on the calendar screen's card too (Carter: "it doesn't give me a sync with others
    /// button"), and opens the same subscribe flow as Settings: with no link kept, it asks before it makes one.
    func test_sync_to_my_other_calendars_is_on_the_calendar_screen_and_asks_before_a_new_link() async throws {
        let phone = center(FakePhoneCalendar(start: clock), FakeDeviceCalendar())
        await phone.appOpened()
        let calendar = calendarCenter(phone, feedOn: true)
        await calendar.refresh(probeRoom: nil)
        XCTAssertTrue(calendar.showsSubscribe)
        let room = CalendarBoard(scope: .room(sessionId: "room-1", title: "Site", canAdd: true), client: NoRoomEvents(),
                                 calendar: newYork, now: { [unowned self] in self.clock })
        let window = try HostedSummary.host(NavigationStack { CalendarScreen(board: room, calendar: calendar) })
        defer {
            window.rootViewController?.presentedViewController?.dismiss(animated: false)
            HostedSummary.close(window)
        }
        let sync = try XCTUnwrap(HostedSummary.wait(for: "pocket.calendar.sync", in: window),
                                 "Sync is on the calendar screen")
        XCTAssertEqual(sync.accessibilityLabel, "Sync to my other calendars")
        XCTAssertTrue(sync.accessibilityActivate())
        let question = await settle(until: "settings.calendar.newLink.title", in: window)
        XCTAssertNotNil(question, "with no link kept it asks first, as Settings' Subscribe does")
    }
}

/// The subscribe link's flag on, with no link kept for anyone: Subscribe asks before it makes one.
private struct FeedOn: CalendarFeedServing {
    func feedAvailable() async throws -> Bool { true }
    func newSubscriptionLink() async throws -> CalendarSubscriptionLink { throw CalendarError.unavailable }
    func keptLink(_ url: URL) -> CalendarSubscriptionLink? { nil }
}

private struct NoKeptLink: CalendarLinkKeeping {
    func link(for person: String) -> URL? { nil }
    func keep(_ link: URL, for person: String) {}
    func forgetAll() {}
}

/// A calendar service with no room events.
private struct NoRoomEvents: RoomCalendarServing {
    func draftsAvailable(inRoom sessionId: String) async throws -> Bool { true }
    func events(inRoom sessionId: String) async throws -> [CalendarEvent] { [] }
    func agenda() async throws -> [CalendarEvent] { [] }
    func draft(inRoom sessionId: String, _ request: CalendarDraftRequest) async throws -> CalendarDraft {
        throw CalendarError.rejected
    }
    func save(_ event: CalendarEventCreate, inRoom sessionId: String) async throws -> CalendarEvent {
        throw CalendarError.rejected
    }
}
