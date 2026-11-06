import EventKit
import Foundation
import PocketSyncClient
import SwiftUI
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
    let events: [PhoneCalendarItem]
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

    func items(from start: Date, to end: Date, calendars ids: Set<String>?) -> [PhoneCalendarItem] {
        access == .granted ? events : []
    }

    func onChange(_ changed: @escaping @MainActor () -> Void) { self.changed = changed }

    /// The phone's calendar changed.
    func change() { changed?() }
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
        XCTAssertEqual(phone.items(from: clock, to: clock.addingTimeInterval(7 * 86_400)).count, 4, "the events show")
        XCTAssertEqual(phone.calendars.map(\.title), ["Work", "Home", "Book club"])

        phone.setShared("cal-work", true)
        store.change()
        clock.addTimeInterval(120)
        await phone.appOpened()
        store.change()
        await phone.idle()
        XCTAssertFalse(phone.sharesWithAgents, "off until she turns it on")
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
        XCTAssertNotNil(phone.notice, "she is told it did not go")

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

    /// Only the calendars she picked are sent, whatever the phone hands back; none picked sends nothing.
    func test_calendars_she_did_not_pick_are_never_sent() async throws {
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
        store.change()
        await phone.idle()
        XCTAssertEqual(client.puts.count, 1, "a change 10 seconds on waits")
        XCTAssertEqual(waits.map { $0.delay }, [50], "until the minute is up")

        clock.addTimeInterval(49)
        store.change()
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
        store.change()
        await phone.idle()
        XCTAssertEqual(client.puts.count, 2)
        XCTAssertEqual(waits.count, 2)
        XCTAssertEqual(waits[1].delay, 59, accuracy: 0.001)
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
        XCTAssertTrue(phone.items(from: clock, to: clock.addingTimeInterval(86_400)).isEmpty)
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
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.calendar.share", in: window),
                        "then the agents switch, on the same screen")
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
        defer { HostedSummary.close(window) }
        let sync = try XCTUnwrap(HostedSummary.wait(for: "pocket.calendar.sync", in: window),
                                 "Sync is on the calendar screen")
        XCTAssertEqual(sync.accessibilityLabel, "Sync to my other calendars")
        XCTAssertTrue(sync.accessibilityActivate())
        XCTAssertNotNil(HostedSummary.wait(for: "settings.calendar.newLink.title", in: window),
                        "with no link kept it asks first, as Settings' Subscribe does")
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
