import Foundation
import PocketSyncClient
import XCTest
@testable import SentiPocketApp

/// The calendar as a fake of the contract of 2026-11-04: 404 for the drafts and feed routes while a flag is off, a draft
/// that is never saved by asking for it, and a feed token that must show nowhere but the link that is opened. Titles
/// are made up.
private final class FakeCalendar: RoomCalendarServing, CalendarFeedServing, @unchecked Sendable {
    private let lock = NSLock()
    private var _draftsOn = true
    private var _feedOn = true
    private var _events: [CalendarEvent] = []
    private var _draft: Result<CalendarDraft, CalendarError> = .failure(.retryable)
    private var _saveFailure: CalendarError?
    private var _readFailure: CalendarError?
    private var _holdsSave = false
    private var _saveWaiter: CheckedContinuation<Void, Never>?
    private var _draftRequests: [(room: String, request: CalendarDraftRequest)] = []
    private var _saved: [(room: String, event: CalendarEventCreate)] = []
    private var _reads = 0
    let token: String

    init(token: String = "tok-7Hq2+secret/feed") {
        self.token = token
    }

    var draftsOn: Bool { get { lock.withLock { _draftsOn } } set { lock.withLock { _draftsOn = newValue } } }
    var feedOn: Bool { get { lock.withLock { _feedOn } } set { lock.withLock { _feedOn = newValue } } }
    var events: [CalendarEvent] { get { lock.withLock { _events } } set { lock.withLock { _events = newValue } } }
    var draftAnswer: Result<CalendarDraft, CalendarError> {
        get { lock.withLock { _draft } } set { lock.withLock { _draft = newValue } }
    }
    var saveFailure: CalendarError? {
        get { lock.withLock { _saveFailure } } set { lock.withLock { _saveFailure = newValue } }
    }
    var readFailure: CalendarError? {
        get { lock.withLock { _readFailure } } set { lock.withLock { _readFailure = newValue } }
    }
    /// Saves wait until `releaseSave()`, to act while one is out.
    var holdsSave: Bool { get { lock.withLock { _holdsSave } } set { lock.withLock { _holdsSave = newValue } } }
    var saveIsOut: Bool { lock.withLock { _saveWaiter != nil } }
    func releaseSave() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            defer { _saveWaiter = nil }
            return _saveWaiter
        }
        waiter?.resume()
    }
    var draftRequests: [(room: String, request: CalendarDraftRequest)] { lock.withLock { _draftRequests } }
    var saved: [(room: String, event: CalendarEventCreate)] { lock.withLock { _saved } }
    var reads: Int { lock.withLock { _reads } }

    func draftsAvailable(inRoom sessionId: String) async throws -> Bool { draftsOn }

    func events(inRoom sessionId: String) async throws -> [CalendarEvent] {
        lock.withLock { _reads += 1 }
        if let failure = readFailure { throw failure }
        return events
    }

    func agenda() async throws -> [CalendarEvent] {
        lock.withLock { _reads += 1 }
        return events
    }

    func draft(inRoom sessionId: String, _ request: CalendarDraftRequest) async throws -> CalendarDraft {
        lock.withLock { _draftRequests.append((sessionId, request)) }
        guard draftsOn else { throw CalendarError.unavailable }
        return try draftAnswer.get()
    }

    func save(_ event: CalendarEventCreate, inRoom sessionId: String) async throws -> CalendarEvent {
        if holdsSave {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                lock.withLock { _saveWaiter = waiter }
            }
        }
        if let failure = saveFailure { throw failure }
        lock.withLock { _saved.append((sessionId, event)) }
        return CalendarEvent(id: "saved-\(saved.count)", sessionId: sessionId, title: event.title,
                             startsAt: event.startsAt, endsAt: event.endsAt, link: event.link, notes: event.notes)
    }

    func feedAvailable() async throws -> Bool { feedOn }

    func newSubscriptionLink() async throws -> CalendarSubscriptionLink {
        guard feedOn else { throw CalendarError.unavailable }
        return CalendarSubscriptionLink.make(apiBaseURL: URL(string: "https://api.example.test"), token: token)!
    }
}

@MainActor
final class RoomCalendarTests: XCTestCase {
    private func at(_ text: String) -> Date { CalendarInstant.parse(text)! }

    private func calendar(_ zone: String, firstWeekday: Int = 1) -> Calendar {
        var calendar = CalendarBoard.personsCalendar(timeZone: TimeZone(identifier: zone)!,
                                                     locale: Locale(identifier: "en_US"))
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func makeBoard(_ fake: FakeCalendar, zone: String = "America/New_York", now: String = "2026-11-04T10:00:00-05:00",
                       scope: CalendarScope = .room(sessionId: "room-1", title: "Launch planning", canAdd: true),
                       onUnavailable: @escaping @MainActor () -> Void = {}) -> CalendarBoard {
        let instant = at(now)
        return CalendarBoard(scope: scope, client: fake, calendar: calendar(zone), now: { instant },
                             onUnavailable: onUnavailable)
    }

    private func lunchDraft(_ start: String, _ end: String?, confidence: Double? = 0.9,
                            assumptions: [String] = []) -> CalendarDraft {
        CalendarDraft(title: "Lunch with Sam", startsAt: at(start), endsAt: end.map(at),
                      link: "https://docs.example.test/plan", notes: "Bring the plan", confidence: confidence,
                      assumptions: assumptions)
    }

    // MARK: - Draft to form, in the person's zone

    /// 01:00 on November 5 in Kolkata is still November 4 in UTC: the day asked for, the zone sent and the times on the
    /// form are the person's.
    func test_the_draft_is_asked_and_shown_in_the_persons_zone() async throws {
        let fake = FakeCalendar()
        fake.draftAnswer = .success(lunchDraft("2026-11-05T13:00:00+05:30", "2026-11-05T14:00:00+05:30"))
        let board = makeBoard(fake, zone: "Asia/Kolkata", now: "2026-11-05T01:00:00+05:30")
        board.addText = "Lunch with Sam at 1"
        await board.draft()

        XCTAssertEqual(fake.draftRequests.count, 1)
        XCTAssertEqual(fake.draftRequests.first?.room, "room-1")
        XCTAssertEqual(fake.draftRequests.first?.request,
                       .text(day: CalendarDay(year: 2026, month: 11, day: 5), text: "Lunch with Sam at 1",
                             timeZone: "Asia/Kolkata"))
        let form = try XCTUnwrap(board.form)
        XCTAssertEqual(form.timeZone.identifier, "Asia/Kolkata")
        let kolkata = calendar("Asia/Kolkata")
        XCTAssertEqual(kolkata.component(.hour, from: form.startsAt), 13)
        XCTAssertEqual(kolkata.component(.day, from: form.startsAt), 5)
        XCTAssertTrue(form.hasEnd)
        XCTAssertEqual(form.title, "Lunch with Sam")
        XCTAssertEqual(form.link, "https://docs.example.test/plan")
        XCTAssertEqual(form.notes, "Bring the plan")
        let create = try form.validated(now: at("2026-11-05T01:00:00+05:30")).get()
        XCTAssertEqual(create.body["startsAt"] as? String, "2026-11-05T13:00:00+05:30")
        XCTAssertEqual(create.body["endsAt"] as? String, "2026-11-05T14:00:00+05:30")
    }

    func test_event_times_read_in_the_persons_zone() {
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{2009}", with: " ")
        }
        let event = CalendarEvent(id: "e1", sessionId: "room-1", title: "Call", startsAt: at("2026-11-04T08:00:00Z"),
                                  endsAt: at("2026-11-04T09:00:00Z"))
        XCTAssertEqual(plain(CalendarEventTime.text(event, calendar: calendar("America/New_York"))), "3:00 – 4:00 AM")
        XCTAssertEqual(plain(CalendarEventTime.text(event, calendar: calendar("Asia/Kolkata"))), "1:30 – 2:30 PM")
        let open = CalendarEvent(id: "e2", sessionId: "room-1", title: "Call", startsAt: at("2026-11-04T08:00:00Z"))
        XCTAssertEqual(plain(CalendarEventTime.text(open, calendar: calendar("Asia/Kolkata"))), "1:30 PM")
    }

    func test_the_form_lists_what_the_model_assumed_and_says_when_it_was_unsure() {
        let day = CalendarDay(year: 2026, month: 11, day: 4)
        let zone = calendar("America/New_York")
        let assumptions = ["I assumed 1 PM, Eastern", "I assumed an hour"]
        func form(_ confidence: Double?, start: String? = "2026-11-04T13:00:00-05:00") -> CalendarDraftForm {
            CalendarDraftForm(draft: CalendarDraft(title: "Lunch", startsAt: start.map(at), confidence: confidence,
                                                   assumptions: assumptions),
                              day: day, roomId: "room-1", roomTitle: "Launch planning", calendar: zone)
        }
        XCTAssertEqual(form(0.9).assumptions, assumptions)
        XCTAssertTrue(form(0.59).isLowConfidence)
        XCTAssertFalse(form(0.6).isLowConfidence)
        XCTAssertFalse(form(0.95).isLowConfidence)
        XCTAssertTrue(form(nil).isLowConfidence, "no confidence given reads as unsure")
        let timeless = form(0.9, start: nil)
        XCTAssertTrue(timeless.isLowConfidence, "no start time reads as unsure")
        XCTAssertEqual(zone.component(.hour, from: timeless.startsAt), 9, "a draft without a time starts at 9 that day")
        XCTAssertFalse(timeless.hasEnd)
    }

    // MARK: - Saving only on Save

    func test_nothing_is_saved_until_save_is_tapped() async throws {
        let fake = FakeCalendar()
        fake.draftAnswer = .success(lunchDraft("2026-11-06T13:00:00-05:00", "2026-11-06T14:00:00-05:00"))
        let board = makeBoard(fake)
        await board.loadIfNeeded()
        board.select(CalendarDay(year: 2026, month: 11, day: 6))
        board.addText = "Lunch with Sam on Friday at 1"
        await board.draft()

        XCTAssertNotNil(board.form, "the draft opens as a form")
        XCTAssertTrue(fake.saved.isEmpty, "a draft is not an event: nothing is saved before Save")
        XCTAssertTrue(board.events(on: CalendarDay(year: 2026, month: 11, day: 6)).isEmpty)

        board.form?.title = "Lunch with Sam and Ana"
        await board.save()
        XCTAssertEqual(fake.saved.count, 1)
        XCTAssertEqual(fake.saved.first?.room, "room-1")
        XCTAssertEqual(fake.saved.first?.event.title, "Lunch with Sam and Ana", "the form as edited is what is saved")
        XCTAssertNil(board.form)
        XCTAssertEqual(board.addText, "")
        XCTAssertEqual(board.events(on: CalendarDay(year: 2026, month: 11, day: 6)).map(\.title),
                       ["Lunch with Sam and Ana"], "the saved event shows on its day without reading again")
        XCTAssertEqual(fake.reads, 1)
    }

    func test_cancel_discards_the_draft_and_saves_nothing() async {
        let fake = FakeCalendar()
        fake.draftAnswer = .success(lunchDraft("2026-11-06T13:00:00-05:00", nil))
        let board = makeBoard(fake)
        board.addText = "Lunch with Sam at 1"
        await board.draft()
        XCTAssertNotNil(board.form)
        board.cancelDraft()
        XCTAssertNil(board.form)
        await board.save()
        XCTAssertTrue(fake.saved.isEmpty, "a cancelled draft cannot be saved")
        XCTAssertEqual(board.addText, "Lunch with Sam at 1", "what was typed stays, to draft again")
    }

    /// Review finding (PR #330): Cancel during a save dropped the form while the event was still being made, so the
    /// event appeared after the person had cancelled, and a new draft could save it twice. Cancel now waits.
    func test_cancel_while_the_save_is_out_keeps_the_form_and_makes_one_event() async throws {
        let fake = FakeCalendar()
        fake.draftAnswer = .success(lunchDraft("2026-11-06T13:00:00-05:00", nil))
        fake.holdsSave = true
        let board = makeBoard(fake)
        let friday = CalendarDay(year: 2026, month: 11, day: 6)
        board.select(friday)
        board.addText = "Lunch with Sam on Friday at 1"
        await board.draft()
        let saving = Task { await board.save() }
        for _ in 0..<2_000 where !fake.saveIsOut { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(fake.saveIsOut, "the save is out")
        XCTAssertTrue(board.isSaving)

        board.cancelDraft()
        XCTAssertNotNil(board.form, "Cancel does nothing while the save is out: the event may already exist")
        await board.save()
        await board.draft()

        fake.releaseSave()
        await saving.value
        XCTAssertNil(board.form, "the form closes when the save lands")
        XCTAssertEqual(fake.saved.count, 1, "one event, not two")
        XCTAssertEqual(fake.draftRequests.count, 1, "no new draft while the first was being saved")
        XCTAssertEqual(board.events(on: friday).count, 1)
    }

    /// Review finding (PR #330): Settings asked the drafts route only with a room the person could write in, so an
    /// account that only reads rooms never had the calendar asked about from Settings. Any room answers the flag.
    func test_settings_asks_about_the_calendar_with_a_room_a_viewer_reads() async {
        let viewerOnly = [(id: "dm-1", role: "owner", isDirect: true), (id: "room-a", role: "viewer", isDirect: false),
                          (id: "room-b", role: "viewer", isDirect: false)]
        XCTAssertEqual(CalendarCenter.probeRoom(in: viewerOnly), "room-a", "a room before a direct message, any role")
        XCTAssertEqual(CalendarCenter.probeRoom(in: [(id: "dm-1", role: "viewer", isDirect: true)]), "dm-1")
        XCTAssertNil(CalendarCenter.probeRoom(in: []))

        let fake = FakeCalendar()
        let center = CalendarCenter(client: fake, feed: fake, openURL: { _ in })
        await center.refresh(probeRoom: CalendarCenter.probeRoom(in: viewerOnly))
        XCTAssertTrue(center.showsCalendar, "a viewer-only account sees the calendar once drafting is on")
        XCTAssertTrue(center.showsSubscribe)
    }

    func test_a_failed_draft_says_so_and_keeps_the_text() async {
        let fake = FakeCalendar()
        fake.draftAnswer = .failure(.retryable)
        let board = makeBoard(fake)
        board.addText = "Lunch with Sam at 1"
        await board.draft()
        XCTAssertNil(board.form)
        XCTAssertEqual(board.draftProblem, "Couldn't draft that. Check your connection and try again.")
        XCTAssertEqual(board.addText, "Lunch with Sam at 1")
        XCTAssertTrue(fake.saved.isEmpty)
    }

    func test_a_save_that_fails_keeps_the_form_and_says_why() async {
        let fake = FakeCalendar()
        fake.draftAnswer = .success(lunchDraft("2026-11-06T13:00:00-05:00", nil))
        let board = makeBoard(fake)
        board.addText = "Lunch"
        await board.draft()

        board.form?.startsAt = at("2026-11-04T09:00:00-05:00")
        await board.save()
        XCTAssertEqual(board.saveProblem, "That start time has passed. Pick a later one.")
        XCTAssertTrue(fake.saved.isEmpty, "a start in the past is not sent")

        board.form?.startsAt = at("2026-11-06T13:00:00-05:00")
        board.form?.link = "http://insecure.example.test"
        await board.save()
        XCTAssertEqual(board.saveProblem, "Links need to start with https://")

        board.form?.link = ""
        fake.saveFailure = .rejected
        await board.save()
        XCTAssertNotNil(board.form, "the form stays to fix")
        XCTAssertEqual(board.saveProblem, "Senti didn't take that. Check the times and the link.")
    }

    func test_a_past_day_takes_no_new_event() async {
        let fake = FakeCalendar()
        fake.draftAnswer = .success(lunchDraft("2026-11-06T13:00:00-05:00", nil))
        let board = makeBoard(fake)
        let yesterday = CalendarDay(year: 2026, month: 11, day: 3)
        XCTAssertTrue(board.isPast(yesterday))
        XCTAssertFalse(board.isPast(CalendarDay(year: 2026, month: 11, day: 4)), "today still takes events")
        board.select(yesterday)
        board.addText = "Lunch"
        await board.draft()
        XCTAssertTrue(fake.draftRequests.isEmpty)
        XCTAssertNil(board.form)
    }

    func test_limits_say_which_one() async {
        let fake = FakeCalendar()
        let board = makeBoard(fake)
        board.addText = "Lunch"
        fake.draftAnswer = .failure(.dailyLimit)
        await board.draft()
        XCTAssertEqual(board.draftProblem, "You've used today's drafts. Try again tomorrow.")
        fake.draftAnswer = .failure(.rateLimited)
        await board.draft()
        XCTAssertEqual(board.draftProblem, "Too many tries just now. Wait a moment and try again.")
        XCTAssertEqual(board.addText, "Lunch")
    }

    func test_a_viewer_gets_no_add_field() async {
        XCTAssertFalse(CalendarCenter.canAdd(role: "viewer"))
        XCTAssertTrue(CalendarCenter.canAdd(role: "Contributor"))
        let fake = FakeCalendar()
        fake.draftAnswer = .success(lunchDraft("2026-11-06T13:00:00-05:00", nil))
        let board = makeBoard(fake, scope: .room(sessionId: "room-1", title: "Launch planning", canAdd: false))
        board.addText = "Lunch"
        await board.draft()
        XCTAssertFalse(board.canAdd)
        XCTAssertTrue(fake.draftRequests.isEmpty)
    }

    func test_from_settings_an_event_goes_to_the_room_picked() async {
        let fake = FakeCalendar()
        fake.draftAnswer = .success(lunchDraft("2026-11-06T13:00:00-05:00", nil))
        let rooms = [CalendarRoomChoice(id: "room-a", title: "A"), CalendarRoomChoice(id: "room-b", title: "B")]
        let board = makeBoard(fake, scope: .agenda(rooms: rooms))
        XCTAssertEqual(board.addRoomId, "room-a", "the first room until one is picked")
        board.addRoomId = "room-b"
        board.addText = "Lunch"
        await board.draft()
        await board.save()
        XCTAssertEqual(fake.draftRequests.map { $0.room }, ["room-b"])
        XCTAssertEqual(fake.saved.map { $0.room }, ["room-b"])
    }

    // MARK: - Flags: a 404 hides everything

    func test_a_404_hides_the_calendar_everywhere() async {
        let fake = FakeCalendar()
        fake.draftsOn = false
        fake.feedOn = false
        let center = CalendarCenter(client: fake, feed: fake, openURL: { _ in XCTFail("nothing to open") })
        XCTAssertFalse(center.showsCalendar, "hidden before the server has answered")
        XCTAssertFalse(center.showsSubscribe)
        await center.checkDrafts(probeRoom: "room-1")
        await center.refresh(probeRoom: "room-1")
        XCTAssertEqual(center.draftsOn, false)
        XCTAssertEqual(center.feedOn, false)
        XCTAssertFalse(center.showsCalendar, "the drafts route answered 404: no Calendar anywhere")
        XCTAssertFalse(center.showsSubscribe, "the feed answered 404: no Subscribe row")
        await center.subscribe()
        XCTAssertNil(center.feedNotice)

        // On, then off again while open: the calendar and its sheet go.
        fake.draftsOn = true
        fake.feedOn = true
        await center.refresh(probeRoom: "room-1")
        XCTAssertTrue(center.showsCalendar)
        XCTAssertTrue(center.showsSubscribe)
        fake.draftsOn = false
        fake.feedOn = false
        let board = makeBoard(fake, onUnavailable: { center.calendarWentAway() })
        board.addText = "Lunch"
        await board.draft()
        XCTAssertFalse(center.showsCalendar)
        XCTAssertNil(board.form)
        await center.subscribe()
        XCTAssertFalse(center.showsSubscribe)
    }

    /// The event list is not behind a flag: its 404 is a room that is not there, said in the calendar, not the
    /// calendar turned off everywhere. Opening it again reads again.
    func test_a_404_on_the_event_list_is_a_failed_read_not_the_flag() async {
        let fake = FakeCalendar()
        fake.readFailure = .unavailable
        var hidden = false
        let board = makeBoard(fake, onUnavailable: { hidden = true })
        await board.loadIfNeeded()
        XCTAssertEqual(board.load, .failed)
        XCTAssertFalse(hidden)
        fake.readFailure = nil
        await board.loadIfNeeded()
        XCTAssertEqual(board.load, .loaded)
        XCTAssertEqual(fake.reads, 2, "a failed read is read again on Try again")
    }

    func test_an_answer_that_says_neither_keeps_the_calendar_hidden_and_asks_again() async {
        final class Flaky: RoomCalendarServing, @unchecked Sendable {
            var fails = true
            func draftsAvailable(inRoom sessionId: String) async throws -> Bool {
                if fails { throw CalendarError.retryable }
                return true
            }
            func events(inRoom sessionId: String) async throws -> [CalendarEvent] { [] }
            func agenda() async throws -> [CalendarEvent] { [] }
            func draft(inRoom sessionId: String, _ request: CalendarDraftRequest) async throws -> CalendarDraft {
                throw CalendarError.retryable
            }
            func save(_ event: CalendarEventCreate, inRoom sessionId: String) async throws -> CalendarEvent {
                throw CalendarError.retryable
            }
        }
        let flaky = Flaky()
        let center = CalendarCenter(client: flaky, feed: FakeCalendar(), openURL: { _ in })
        await center.checkDrafts(probeRoom: "room-1")
        XCTAssertNil(center.draftsOn)
        XCTAssertFalse(center.showsCalendar)
        flaky.fails = false
        await center.checkDrafts(probeRoom: "room-1")
        XCTAssertTrue(center.showsCalendar)
    }

    // MARK: - The feed token

    func test_the_feed_token_shows_nowhere_but_the_opened_link() async throws {
        let fake = FakeCalendar(token: "tok-7Hq2+secret/feed")
        var opened: [URL] = []
        let center = CalendarCenter(client: fake, feed: fake, openURL: { opened.append($0) })
        await center.refresh(probeRoom: "room-1")
        await center.subscribe()

        XCTAssertEqual(opened.count, 1)
        let url = try XCTUnwrap(opened.first)
        XCTAssertEqual(url.scheme, "webcal")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, fake.token)
        let afterSubscribe = center.feedNotice

        await center.resetLink()
        XCTAssertEqual(opened.count, 1, "a reset opens nothing")
        let afterReset = center.feedNotice

        let shown = [afterSubscribe, afterReset, CalendarCenter.resetWarning,
                     String(describing: center), String(reflecting: center)].compactMap { $0 }
        for text in shown {
            XCTAssertFalse(text.contains("secret"), "the token showed in: \(text)")
            XCTAssertFalse(text.contains("tok-"), "the token showed in: \(text)")
        }
        XCTAssertEqual(afterSubscribe, CalendarCenter.opened)
        XCTAssertEqual(afterReset, CalendarCenter.reset)
    }

    // MARK: - The month and VoiceOver

    func test_voiceover_reads_each_day_with_its_events() {
        let zone = calendar("America/New_York")
        let events = [
            CalendarEvent(id: "a", sessionId: "r", title: "A", startsAt: at("2026-11-04T15:00:00Z")),
            CalendarEvent(id: "b", sessionId: "r", title: "B", startsAt: at("2026-11-04T20:00:00Z")),
            CalendarEvent(id: "c", sessionId: "r", title: "C", startsAt: at("2026-11-06T15:00:00Z")),
        ]
        let byDay = Dictionary(grouping: events) { CalendarDay($0.startsAt, in: zone) }
        let grid = CalendarMonthGrid(month: CalendarDay(year: 2026, month: 11, day: 1), eventsByDay: byDay,
                                     today: CalendarDay(year: 2026, month: 11, day: 4), calendar: zone)
        func cell(_ number: Int) -> CalendarMonthGrid.Cell? { grid.cells.first { $0.day?.day == number } }
        XCTAssertEqual(grid.title, "November 2026")
        XCTAssertEqual(cell(4)?.accessibilityLabel, "Wednesday, November 4, 2 events")
        XCTAssertEqual(cell(5)?.accessibilityLabel, "Thursday, November 5, no events")
        XCTAssertEqual(cell(6)?.accessibilityLabel, "Friday, November 6, 1 event")
        XCTAssertEqual(cell(4)?.eventCount, 2)
        XCTAssertEqual(cell(4)?.isToday, true)
        XCTAssertEqual(grid.cells.compactMap(\.day).count, 30)
        XCTAssertEqual(grid.cells.first?.day?.day, 1, "November 1, 2026 is a Sunday: no blanks from Sunday")
        XCTAssertEqual(grid.weekdays, ["S", "M", "T", "W", "T", "F", "S"])

        let mondayFirst = CalendarMonthGrid(month: CalendarDay(year: 2026, month: 11, day: 1), eventsByDay: [:],
                                            today: CalendarDay(year: 2026, month: 11, day: 4),
                                            calendar: calendar("America/New_York", firstWeekday: 2))
        XCTAssertEqual(mondayFirst.cells.prefix(while: { $0.day == nil }).count, 6)
        XCTAssertEqual(mondayFirst.weekdays.first, "M")
    }

    func test_the_month_is_laid_out_once_per_change_and_read_once_per_open() async {
        let fake = FakeCalendar()
        fake.events = [CalendarEvent(id: "a", sessionId: "room-1", title: "A", startsAt: at("2026-11-12T15:00:00Z"))]
        let board = makeBoard(fake)
        await board.loadIfNeeded()
        XCTAssertEqual(fake.reads, 1)
        let builds = board.gridBuilds
        for number in 1...20 { board.select(CalendarDay(year: 2026, month: 11, day: number)) }
        XCTAssertEqual(board.gridBuilds, builds, "picking days does not lay the month out again")
        board.showMonth(1)
        XCTAssertEqual(board.gridBuilds, builds + 1)
        XCTAssertEqual(board.grid.title, "December 2026")
        XCTAssertNil(board.selected, "today is not in December")
        board.showMonth(-1)
        XCTAssertEqual(board.gridBuilds, builds + 2)
        XCTAssertEqual(board.selected, CalendarDay(year: 2026, month: 11, day: 4), "back in today's month, today")
        await board.loadIfNeeded()
        XCTAssertEqual(fake.reads, 1, "no second read while open: reads happen when the calendar opens")
        XCTAssertEqual(board.grid.cells.first { $0.day?.day == 12 }?.eventCount, 1)
    }
}
