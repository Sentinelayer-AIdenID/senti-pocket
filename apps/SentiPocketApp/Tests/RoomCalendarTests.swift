import Foundation
import PocketSyncClient
import Security
import SwiftUI
import UIKit
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
    private var _mints = 0
    private var _linkFailure: CalendarError?
    let token: String

    init(token: String = "made-up+feed/value") {
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
    /// How many new links were made (each one stops the one before).
    var mints: Int { lock.withLock { _mints } }
    var linkFailure: CalendarError? {
        get { lock.withLock { _linkFailure } } set { lock.withLock { _linkFailure = newValue } }
    }

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

    /// The first link carries `token`; each later one `token-2`, `token-3`...: a new link every time, as the API does.
    func newSubscriptionLink() async throws -> CalendarSubscriptionLink {
        guard feedOn else { throw CalendarError.unavailable }
        if let failure = linkFailure { throw failure }
        let count = lock.withLock { () -> Int in
            _mints += 1
            return _mints
        }
        let value = count == 1 ? token : "\(token)-\(count)"
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved)!
        return CalendarSubscriptionLink.make(apiBaseURL: Self.api,
                                             feedURL: "https://api.example.test/api/v1/me/calendar.ics?token=\(encoded)")!
    }

    func keptLink(_ url: URL) -> CalendarSubscriptionLink? { CalendarSubscriptionLink.kept(url, apiBaseURL: Self.api) }

    static let api = URL(string: "https://api.example.test")
}

/// What the system was asked to open, and whether it opened it.
@MainActor
private final class Opener {
    var opened: [URL] = []
    var opens = true

    func open(_ url: URL) -> Bool {
        opened.append(url)
        return opens
    }
}

/// Calendar routes that count each ask and answer as told: nothing (a 503), off (a 404) or on.
private final class CountingProbes: RoomCalendarServing, CalendarFeedServing, @unchecked Sendable {
    enum Answer { case unanswered, off, on }

    private let lock = NSLock()
    private var _drafts = Answer.unanswered
    private var _feed = Answer.unanswered
    private var _draftAsks = 0
    private var _feedAsks = 0

    var drafts: Answer { get { lock.withLock { _drafts } } set { lock.withLock { _drafts = newValue } } }
    var feed: Answer { get { lock.withLock { _feed } } set { lock.withLock { _feed = newValue } } }
    var draftAsks: Int { lock.withLock { _draftAsks } }
    var feedAsks: Int { lock.withLock { _feedAsks } }

    private static func reply(_ answer: Answer) throws -> Bool {
        switch answer {
        case .unanswered: throw CalendarError.retryable
        case .off: return false
        case .on: return true
        }
    }

    func draftsAvailable(inRoom sessionId: String) async throws -> Bool {
        lock.withLock { _draftAsks += 1 }
        return try Self.reply(drafts)
    }

    func feedAvailable() async throws -> Bool {
        lock.withLock { _feedAsks += 1 }
        return try Self.reply(feed)
    }

    func events(inRoom sessionId: String) async throws -> [CalendarEvent] { [] }
    func agenda() async throws -> [CalendarEvent] { [] }
    func draft(inRoom sessionId: String, _ request: CalendarDraftRequest) async throws -> CalendarDraft {
        throw CalendarError.retryable
    }
    func save(_ event: CalendarEventCreate, inRoom sessionId: String) async throws -> CalendarEvent {
        throw CalendarError.retryable
    }
    func newSubscriptionLink() async throws -> CalendarSubscriptionLink { throw CalendarError.retryable }
    func keptLink(_ url: URL) -> CalendarSubscriptionLink? { nil }
}

/// An in-memory Keychain with the system's rules for the calls the vault makes: class, service and account match; data
/// or attributes come back as asked, one or all; a second item for the same account is a duplicate. It records every
/// item added, as added.
private final class TestKeychain: KeychainItems, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String: Any]] = []
    private var added: [[String: Any]] = []
    private static let keys = [kSecClass as String, kSecAttrService as String, kSecAttrAccount as String]

    var addedItems: [[String: Any]] { lock.withLock { added } }

    private static func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
        keys.allSatisfy { key in
            guard let wanted = query[key] else { return true }
            return (item[key] as? String) == (wanted as? String)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            if items.contains(where: { Self.matches($0, attributes) }) { return errSecDuplicateItem }
            items.append(attributes)
            added.append(attributes)
            return errSecSuccess
        }
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        lock.withLock {
            let found = items.filter { Self.matches($0, query) }
            guard let first = found.first else { return (errSecItemNotFound, nil) }
            let wantsData = query[kSecReturnData as String] as? Bool == true
            func answer(_ item: [String: Any]) -> AnyObject {
                wantsData ? item[kSecValueData as String] as AnyObject
                    : item.filter { $0.key != kSecValueData as String } as NSDictionary
            }
            let all = (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
            let result: AnyObject = all ? found.map(answer) as NSArray : answer(first)
            return (errSecSuccess, result)
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            let before = items.count
            items.removeAll { Self.matches($0, query) }
            return items.count < before ? errSecSuccess : errSecItemNotFound
        }
    }
}

/// A clock the tests move by hand.
private final class TestNow {
    var now = CalendarInstant.parse("2026-11-04T10:00:00-05:00")!
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
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

    /// System Keychain items a test made, under a service of its own, removed after it.
    private var systemVaults: [CalendarLinkVault] = []

    override func tearDown() {
        systemVaults.forEach { $0.forgetAll() }
        systemVaults = []
        super.tearDown()
    }

    /// The vault as the app has it, on an in-memory Keychain.
    private func testVault(_ keychain: TestKeychain = TestKeychain()) -> CalendarLinkVault {
        CalendarLinkVault(service: "com.plexaura.sentipocket.tests.calendar-link.\(UUID().uuidString)", keychain: keychain)
    }

    /// The app's sign-in as it runs, its clearing pointed at `links`.
    private func makeSignIn(clearing links: CalendarLinkVault, stored: @escaping () -> Bool,
                            signOut: @escaping () -> Void) -> SignInCoordinator {
        SignInCoordinator(login: {}, isLoggedIn: stored, signOut: signOut,
                          clearProtectedLocalState: { SignInCoordinator.clearPersonalState(calendarLinks: links) })
    }

    /// Skips where the host has no Keychain: a simulator app built unsigned, as CI builds it, is refused with
    /// errSecMissingEntitlement. The signed build runs the test.
    private func requireSystemKeychain() throws {
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.plexaura.sentipocket.tests.keychain-probe",
                                    kSecAttrAccount as String: UUID().uuidString,
                                    kSecValueData as String: Data("probe".utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemAdd(probe as CFDictionary, nil)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: "com.plexaura.sentipocket.tests.keychain-probe"] as CFDictionary)
        if status == errSecMissingEntitlement {
            throw XCTSkip("This host has no Keychain (a simulator app built unsigned); the signed build runs this test.")
        }
        XCTAssertEqual(status, errSecSuccess, "the system Keychain refused an item")
    }

    private func makeCenter(client: any RoomCalendarServing, feed: any CalendarFeedServing,
                            vault: (any CalendarLinkKeeping)? = nil, person: String? = "person-a",
                            opener: Opener? = nil, clock: TestNow? = nil) -> CalendarCenter {
        let opener = opener ?? Opener()
        return CalendarCenter(client: client, feed: feed, vault: vault ?? testVault(), person: { person },
                              openURL: { opener.open($0) }, now: { clock?.now ?? Date() })
    }

    private func makeCenter(_ fake: FakeCalendar, vault: (any CalendarLinkKeeping)? = nil, person: String? = "person-a",
                            opener: Opener? = nil, clock: TestNow? = nil) -> CalendarCenter {
        makeCenter(client: fake, feed: fake, vault: vault, person: person, opener: opener, clock: clock)
    }

    private func feedLink(_ value: String) -> URL {
        URL(string: "webcal://api.example.test/api/v1/me/calendar.ics?token=\(value)")!
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
        let center = makeCenter(fake)
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
        fake.draftAnswer = .failure(.rejected)
        await board.draft()
        XCTAssertEqual(board.draftProblem, "Senti couldn't draft that for this day. Try saying it another way.",
                       "a 400 is the words or the day, not the connection")
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
        let clock = TestNow()
        let opener = Opener()
        let center = makeCenter(fake, opener: opener, clock: clock)
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
        XCTAssertFalse(center.confirmsNewLink)

        // On, then off again while open: the calendar and its sheet go. An "off" is asked again after ten minutes.
        fake.draftsOn = true
        fake.feedOn = true
        clock.advance(9 * 60)
        await center.refresh(probeRoom: "room-1")
        XCTAssertFalse(center.showsCalendar, "an off answer is not asked again within ten minutes")
        clock.advance(60)
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
        await center.confirmNewLink()
        XCTAssertFalse(center.showsSubscribe, "making a link answered 404: no Subscribe row")
        XCTAssertTrue(opener.opened.isEmpty)
    }

    /// A 404 with a calendar code (a real not-found) is a read that failed, said in the calendar; a 404 without one
    /// is the calendar turned off, which hides it everywhere. Opening it again reads again.
    func test_a_404_with_a_calendar_code_is_a_failed_read_and_without_one_hides_the_calendar() async {
        let fake = FakeCalendar()
        fake.readFailure = .notFound
        var hidden = false
        let board = makeBoard(fake, onUnavailable: { hidden = true })
        await board.loadIfNeeded()
        XCTAssertEqual(board.load, .failed)
        XCTAssertFalse(hidden, "a real not-found does not hide the calendar")
        fake.readFailure = nil
        await board.loadIfNeeded()
        XCTAssertEqual(board.load, .loaded)
        XCTAssertEqual(fake.reads, 2, "a failed read is read again on Try again")

        fake.readFailure = .unavailable
        let off = makeBoard(fake, onUnavailable: { hidden = true })
        await off.loadIfNeeded()
        XCTAssertTrue(hidden, "a 404 without a calendar code is the calendar off")
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
        let clock = TestNow()
        let center = makeCenter(client: flaky, feed: FakeCalendar(), clock: clock)
        await center.checkDrafts(probeRoom: "room-1")
        XCTAssertNil(center.draftsOn)
        XCTAssertFalse(center.showsCalendar)
        flaky.fails = false
        clock.advance(60)
        await center.checkDrafts(probeRoom: "room-1")
        XCTAssertTrue(center.showsCalendar)
    }

    // MARK: - The feed token

    func test_the_feed_token_shows_nowhere_but_the_opened_link() async throws {
        let fake = FakeCalendar(token: "made-up+feed/value")
        let opener = Opener()
        let center = makeCenter(fake, opener: opener)
        await center.refresh(probeRoom: "room-1")
        await center.subscribe()
        await center.confirmNewLink()

        XCTAssertEqual(opener.opened.count, 1)
        let url = try XCTUnwrap(opener.opened.first)
        XCTAssertEqual(url.scheme, "webcal")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, fake.token)
        let afterSubscribe = center.feedNotice

        await center.resetLink()
        XCTAssertEqual(opener.opened.count, 1, "a reset opens nothing")
        let afterReset = center.feedNotice

        let shown = [afterSubscribe, afterReset, CalendarCenter.resetWarning, CalendarCenter.newLinkWarning,
                     String(describing: center), String(reflecting: center)].compactMap { $0 }
        for text in shown {
            XCTAssertFalse(text.contains(fake.token), "the token showed in: \(text)")
            XCTAssertFalse(text.contains("made-up"), "the token showed in: \(text)")
        }
        XCTAssertEqual(afterSubscribe, CalendarCenter.opened)
        XCTAssertEqual(afterReset, CalendarCenter.reset)
    }

    // MARK: - The subscribe link, kept for the person (review P2, #330)

    /// Subscribe with a kept link opens it again and makes none, so a calendar already subscribed keeps updating. The
    /// link outlives a relaunch (a new center, the same Keychain).
    func test_a_second_subscribe_opens_the_kept_link_and_makes_no_new_one() async throws {
        let fake = FakeCalendar()
        let vault = testVault()
        let opener = Opener()
        let center = makeCenter(fake, vault: vault, opener: opener)
        await center.refresh(probeRoom: "room-1")
        await center.subscribe()
        await center.confirmNewLink()
        XCTAssertEqual(fake.mints, 1)
        let first = try XCTUnwrap(opener.opened.first)
        XCTAssertEqual(vault.link(for: "person-a"), first, "the link is kept for the person who made it")

        await center.subscribe()
        await center.subscribe()
        XCTAssertEqual(fake.mints, 1, "a second Subscribe made a new link, which stops the subscribed calendar")
        XCTAssertFalse(center.confirmsNewLink, "with a kept link nothing is asked")
        XCTAssertEqual(opener.opened, [first, first, first], "each Subscribe opens the kept link")
        XCTAssertEqual(center.feedNotice, CalendarCenter.opened)

        let relaunched = makeCenter(fake, vault: vault, opener: opener)
        await relaunched.refresh(probeRoom: "room-1")
        await relaunched.subscribe()
        XCTAssertEqual(fake.mints, 1, "after a relaunch the kept link opens again")
        XCTAssertEqual(opener.opened.last, first)
    }

    /// With no kept link (a new phone, or after a sign-out) Subscribe asks first, in the review's words; only a yes
    /// makes a link, and exactly one.
    func test_with_no_kept_link_subscribe_asks_then_makes_one_link() async {
        let fake = FakeCalendar()
        let opener = Opener()
        let center = makeCenter(fake, opener: opener)
        await center.refresh(probeRoom: "room-1")
        XCTAssertEqual(CalendarCenter.newLinkWarning,
                       "This makes a new subscribe link. A calendar already using an older link stops updating.")

        await center.subscribe()
        XCTAssertTrue(center.confirmsNewLink, "no kept link: Subscribe asks before it makes one")
        XCTAssertEqual(fake.mints, 0, "nothing is made before the person says yes")
        XCTAssertTrue(opener.opened.isEmpty)
        center.confirmsNewLink = false // Cancel
        XCTAssertEqual(fake.mints, 0, "Cancel makes nothing")

        await center.subscribe()
        XCTAssertTrue(center.confirmsNewLink)
        await center.confirmNewLink()
        XCTAssertFalse(center.confirmsNewLink)
        XCTAssertEqual(fake.mints, 1, "one yes, one link")
        XCTAssertEqual(opener.opened.count, 1)
        XCTAssertEqual(center.feedNotice, CalendarCenter.opened)
    }

    /// Reset (which asks first, in the view) replaces the kept link; Subscribe then opens the new one without making a
    /// third.
    func test_reset_replaces_the_kept_link() async throws {
        let fake = FakeCalendar()
        let vault = testVault()
        let opener = Opener()
        let center = makeCenter(fake, vault: vault, opener: opener)
        await center.refresh(probeRoom: "room-1")
        await center.subscribe()
        await center.confirmNewLink()
        let first = try XCTUnwrap(vault.link(for: "person-a"))

        await center.resetLink()
        XCTAssertEqual(fake.mints, 2)
        let second = try XCTUnwrap(vault.link(for: "person-a"))
        XCTAssertNotEqual(second, first, "Reset keeps the new link in place of the old")
        XCTAssertEqual(vault.accounts(), ["person-a"], "one link kept, not two")
        XCTAssertEqual(opener.opened, [first], "a reset opens nothing")
        XCTAssertEqual(center.feedNotice, CalendarCenter.reset)

        await center.subscribe()
        XCTAssertEqual(fake.mints, 2, "Subscribe after a reset opens the new link without making another")
        XCTAssertEqual(opener.opened.last, second)
    }

    /// The link does not cross a sign-out: the sign-in's clearing drops it.
    func test_signing_out_forgets_the_kept_link() async {
        let vault = testVault()
        vault.keep(feedLink("made-up-one"), for: "person-a")
        var stored = true
        let signIn = makeSignIn(clearing: vault, stored: { stored }, signOut: { stored = false })
        XCTAssertEqual(vault.accounts(), ["person-a"], "a launch with someone signed in keeps their link")

        await signIn.handle(.signOut)?.value
        XCTAssertEqual(signIn.phase, .signedOut)
        XCTAssertTrue(vault.accounts().isEmpty, "the kept link outlived the sign-out")
    }

    /// Another person signing in on this phone never gets the last person's link: a link is read only for the person it
    /// was kept for, and another person's is dropped. A launch with no one signed in (anyone may sign in next) drops it.
    func test_an_account_switch_never_opens_the_last_persons_link() async {
        let fake = FakeCalendar()
        let vault = testVault()
        vault.keep(feedLink("made-up-one"), for: "person-a")
        XCTAssertEqual(vault.accounts(), ["person-a"])
        let opener = Opener()
        let center = makeCenter(fake, vault: vault, person: "person-b", opener: opener)
        await center.refresh(probeRoom: "room-1")
        await center.subscribe()
        XCTAssertTrue(opener.opened.isEmpty, "person B opened person A's link")
        XCTAssertTrue(center.confirmsNewLink, "person B has no link yet: Subscribe asks")
        XCTAssertTrue(vault.accounts().isEmpty, "person A's link is dropped, not kept beside B's")
        await center.confirmNewLink()
        XCTAssertEqual(vault.accounts(), ["person-b"])

        let launched = testVault()
        launched.keep(feedLink("made-up-two"), for: "person-a")
        XCTAssertEqual(launched.accounts(), ["person-a"])
        _ = makeSignIn(clearing: launched, stored: { false }, signOut: {})
        XCTAssertTrue(launched.accounts().isEmpty, "a launch with no one signed in kept the last person's link")
    }

    /// Account deletion (#306): the server's yes ends the account's sessions, then the app signs out. Ending this
    /// phone's call ring with the old bearer then gets a 401; the link goes all the same, as it does on any later 401.
    func test_account_deletion_forgets_the_kept_link() async {
        let vault = testVault()
        vault.keep(feedLink("made-up-one"), for: "person-a")
        XCTAssertEqual(vault.accounts(), ["person-a"])
        var stored = true
        let signIn = makeSignIn(clearing: vault, stored: { stored }, signOut: { stored = false })
        signIn.onWillSignOut = {
            signIn.invalidateAuthentication()
            throw DeviceRingRegistrationError.reauthenticationRequired
        }
        await signIn.handle(.signOut)?.value
        XCTAssertTrue(vault.accounts().isEmpty, "the deleted account's link outlived its sign-out")

        vault.keep(feedLink("made-up-two"), for: "person-a")
        XCTAssertEqual(vault.accounts(), ["person-a"])
        stored = true
        let next = makeSignIn(clearing: vault, stored: { stored }, signOut: { stored = false })
        next.invalidateAuthentication(expectedEpoch: next.authenticationEpoch)
        XCTAssertEqual(next.phase, .reauthenticationRequired)
        XCTAssertTrue(vault.accounts().isEmpty, "a refused credential (a deleted account's) kept the link")
    }

    /// The link is added as a Keychain item readable only while the phone is unlocked and never leaving it (no backup,
    /// no other device, never synced): kSecAttrAccessibleWhenUnlockedThisDeviceOnly.
    func test_the_kept_link_is_a_this_device_only_keychain_item() async {
        let fake = FakeCalendar()
        let keychain = TestKeychain()
        let vault = testVault(keychain)
        let center = makeCenter(fake, vault: vault)
        await center.refresh(probeRoom: "room-1")
        await center.subscribe()
        await center.confirmNewLink()
        XCTAssertNotNil(vault.link(for: "person-a"))
        XCTAssertEqual(keychain.addedItems.count, 1)
        let item = keychain.addedItems.first ?? [:]
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertNil(item[kSecAttrSynchronizable as String], "never synced to another device")
        XCTAssertEqual(item[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(vault.accessibility(for: "person-a"), kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    /// In the system Keychain itself (where the host has one): the item reads back as this-device-only, and the app's
    /// own sign-in clearing, as the app runs it, drops the live item on sign-out and on a refused credential.
    func test_in_the_system_keychain_the_link_is_this_device_only_and_goes_with_the_sign_in() async throws {
        try requireSystemKeychain()
        let vault = CalendarLinkVault(service: "com.plexaura.sentipocket.tests.calendar-link.\(UUID().uuidString)")
        systemVaults.append(vault)
        vault.keep(feedLink("made-up-one"), for: "person-a")
        XCTAssertEqual(vault.link(for: "person-a"), feedLink("made-up-one"))
        XCTAssertEqual(vault.accessibility(for: "person-a"), kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                       "the system Keychain reports another accessibility class")

        let live = CalendarLinkVault.live
        live.forgetAll()
        defer { live.forgetAll() }
        live.keep(feedLink("made-up-two"), for: "person-a")
        XCTAssertEqual(live.accounts(), ["person-a"])
        var stored = true
        let signIn = SignInCoordinator(login: {}, isLoggedIn: { stored }, signOut: { stored = false })
        await signIn.handle(.signOut)?.value
        XCTAssertTrue(live.accounts().isEmpty, "the app's sign-out left the link in the Keychain")

        live.keep(feedLink("made-up-three"), for: "person-a")
        stored = true
        let next = SignInCoordinator(login: {}, isLoggedIn: { stored }, signOut: { stored = false })
        next.invalidateAuthentication(expectedEpoch: next.authenticationEpoch)
        XCTAssertTrue(live.accounts().isEmpty, "the app's refused-credential path left the link in the Keychain")
    }

    /// The link is never written outside the Keychain: not in UserDefaults, not in any file of the app's container, not
    /// in what the rows say. The file search finds a file planted with the same text first, so it can fail.
    func test_the_kept_link_is_written_nowhere_but_the_keychain() async throws {
        let marker = "kept-only-in-the-keychain-\(Int.random(in: 100_000...999_999))"
        let needle = Data(marker.utf8)
        func filesHolding() -> [String] {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            var found: [String] = []
            let walk = FileManager.default.enumerator(at: home, includingPropertiesForKeys: keys)
            while let file = walk?.nextObject() as? URL {
                let values = try? file.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= 8_000_000,
                      let data = try? Data(contentsOf: file), data.range(of: needle) != nil else { continue }
                found.append(file.lastPathComponent)
            }
            return found
        }
        let planted = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("calendar-link-control.txt")
        try needle.write(to: planted)
        XCTAssertEqual(filesHolding(), ["calendar-link-control.txt"], "the search finds the planted file")
        try FileManager.default.removeItem(at: planted)

        let fake = FakeCalendar(token: marker)
        let vault = testVault()
        let center = makeCenter(fake, vault: vault)
        await center.refresh(probeRoom: "room-1")
        await center.subscribe()
        await center.confirmNewLink()
        await center.subscribe()
        XCTAssertEqual(vault.link(for: "person-a")?.absoluteString.contains(marker), true, "the Keychain has it")
        UserDefaults.standard.synchronize()

        XCTAssertFalse(String(describing: UserDefaults.standard.dictionaryRepresentation()).contains(marker),
                       "the link is in UserDefaults")
        XCTAssertEqual(filesHolding(), [], "the link is in a file")
        for text in [center.feedNotice, String(describing: center), String(reflecting: center)].compactMap({ $0 }) {
            XCTAssertFalse(text.contains(marker), "the link shows in: \(text)")
        }
    }

    /// Without knowing who is signed in, no link is opened, made or kept.
    func test_nothing_is_opened_or_made_without_knowing_who_is_signed_in() async {
        let fake = FakeCalendar()
        let vault = testVault()
        vault.keep(feedLink("made-up-one"), for: "person-a")
        let opener = Opener()
        let center = makeCenter(fake, vault: vault, person: nil, opener: opener)
        await center.refresh(probeRoom: "room-1")
        await center.subscribe()
        XCTAssertTrue(opener.opened.isEmpty)
        XCTAssertFalse(center.confirmsNewLink)
        XCTAssertEqual(center.feedNotice, CalendarCenter.noPerson)
        await center.resetLink()
        XCTAssertEqual(fake.mints, 0)
    }

    /// Review P3 (#330): a refused link (403) says the account can't, as the app's other refusals do ("This account
    /// can't make rooms right now."), not "check your connection".
    func test_a_refused_link_says_the_account_cannot_not_the_connection() async {
        let fake = FakeCalendar()
        fake.linkFailure = .forbidden
        let opener = Opener()
        let center = makeCenter(fake, opener: opener)
        await center.refresh(probeRoom: "room-1")
        await center.subscribe()
        await center.confirmNewLink()
        XCTAssertEqual(center.feedNotice, "This account can't make a calendar link right now.")
        XCTAssertEqual(center.feedNotice?.localizedCaseInsensitiveContains("connection"), false)
        XCTAssertTrue(opener.opened.isEmpty)
        await center.resetLink()
        XCTAssertEqual(center.feedNotice, "This account can't make a calendar link right now.")
    }

    /// Review P3 (#330): "Apple Calendar opened" only when the system says it opened the link.
    func test_apple_calendar_opened_is_said_only_when_the_link_opened() async {
        let fake = FakeCalendar()
        let opener = Opener()
        opener.opens = false
        let center = makeCenter(fake, opener: opener)
        await center.refresh(probeRoom: "room-1")
        await center.subscribe()
        await center.confirmNewLink()
        XCTAssertEqual(opener.opened.count, 1, "the system was asked")
        XCTAssertEqual(center.feedNotice, CalendarCenter.notOpened, "said opened when the system did not open it")
        opener.opens = true
        await center.subscribe()
        XCTAssertEqual(center.feedNotice, CalendarCenter.opened)
        XCTAssertEqual(fake.mints, 1, "the link made when it did not open is kept and opened again")
    }

    /// Follow-up to #330: at the largest text size on an iPhone SE, Subscribe's question (no link kept) shows its whole
    /// message at once and at the sheet's full width, and each word of its title fits on a line. As a confirmation
    /// dialog it was a narrow popover that cut the message off and broke "subscribe" in two.
    func test_the_new_link_question_shows_its_whole_message_at_the_largest_text_size() async throws {
        try await assertQuestionShowsWhole(.newLink)
    }

    /// The same for Reset's question: as a confirmation dialog, its message stopped at "from the old" on an SE at AX5.
    func test_the_reset_question_shows_its_whole_message_at_the_largest_text_size() async throws {
        try await assertQuestionShowsWhole(.reset)
    }

    private func assertQuestionShowsWhole(_ kind: CalendarLinkQuestion.Kind) async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("trait overrides need iOS 17") }
        let center = makeCenter(FakeCalendar())
        await center.refresh(probeRoom: "room-1")
        XCTAssertTrue(center.showsSubscribe)
        let window = try HostedSummary.host(Form {
            CalendarSettingsSection(context: CalendarSettingsContext(center: center, rooms: []))
        })
        defer { HostedSummary.close(window) }
        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        let row = HostedSummary.wait(for: kind == .newLink ? "settings.calendar.subscribe" : "settings.calendar.reset",
                                     in: window)
        XCTAssertNotNil(row, "the calendar rows were drawn")
        if kind == .newLink {
            await center.subscribe()
            XCTAssertTrue(center.confirmsNewLink, "no link kept: Subscribe asks first")
        } else {
            XCTAssertEqual(row?.accessibilityActivate(), true, "Reset was tapped")
        }
        let id = CalendarLinkQuestion.identifier(kind)
        let text = CalendarLinkQuestion.message(kind)
        let message = try XCTUnwrap(HostedSummary.wait(for: "\(id).message", in: window),
                                    "the question shows its message in a sheet of its own")
        HostedSummary.pump(1)
        XCTAssertEqual(message.accessibilityLabel, text)

        let ax5 = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: ax5)
        let frame = message.accessibilityFrame
        let needed = (text as NSString).boundingRect(
            with: CGSize(width: frame.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
            attributes: [.font: body], context: nil).height
        let sheet = try XCTUnwrap(window.rootViewController?.presentedViewController?.view, "the question is a sheet")
        let visible = sheet.convert(sheet.bounds, to: nil).intersection(window.bounds)
        print("CALAX5 \(id) message \(frame) needs \(needed) visible \(visible) window \(window.bounds)")
        XCTAssertGreaterThanOrEqual(frame.height, needed - body.lineHeight / 2, "every line of the message is drawn: none cut")
        XCTAssertLessThanOrEqual(frame.height, visible.height, "the whole message fits on the screen at once")
        XCTAssertGreaterThanOrEqual(frame.width, visible.width * 0.75, "the message runs at the sheet's full width")

        let title = try XCTUnwrap(HostedSummary.element("\(id).title", in: window))
        let titleFont = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .title3, compatibleWith: ax5).pointSize,
                                          weight: .semibold)
        let widest = CalendarLinkQuestion.title(kind).split(separator: " ")
            .map { (String($0) as NSString).size(withAttributes: [.font: titleFont]).width }.max() ?? 0
        XCTAssertLessThanOrEqual(widest, title.accessibilityFrame.width, "each word of the title fits on a line")
    }

    // MARK: - Asking the server again (review P3, #330)

    /// While the routes answer 503 (or nothing), a room switch or a Settings open does not ask again at once: the next
    /// ask waits 1, 2, 4, 8, then at most 10 minutes. "On" is final for the sign-in. Any answer starts the waits over
    /// (an "off" is asked again after 10 minutes). The clock is the test's, not sleeps.
    func test_unanswered_probes_back_off_from_one_to_ten_minutes() async {
        let probes = CountingProbes()
        let clock = TestNow()
        let center = makeCenter(client: probes, feed: probes, clock: clock)
        await center.checkDrafts(probeRoom: "room-1")
        XCTAssertEqual(probes.draftAsks, 1)
        var asks = 1
        for wait in [60, 120, 240, 480, 600, 600] {
            clock.advance(TimeInterval(wait - 1))
            await center.checkDrafts(probeRoom: "room-1") // a room switch
            await center.refresh(probeRoom: "room-1") // Settings opens
            XCTAssertEqual(probes.draftAsks, asks, "asked again before \(wait) s")
            clock.advance(1)
            await center.checkDrafts(probeRoom: "room-1")
            asks += 1
            XCTAssertEqual(probes.draftAsks, asks, "not asked again at \(wait) s")
        }
        probes.drafts = .on
        clock.advance(600)
        await center.checkDrafts(probeRoom: "room-1")
        XCTAssertTrue(center.showsCalendar)
        clock.advance(3_600)
        await center.checkDrafts(probeRoom: "room-1")
        await center.refresh(probeRoom: "room-1")
        XCTAssertEqual(probes.draftAsks, asks + 1, "on is not asked again")

        // The feed: two misses (1, then 2 minutes), an "off" (10 minutes), then a miss waits 1 minute again.
        let feedProbes = CountingProbes()
        let feedClock = TestNow()
        let other = makeCenter(client: feedProbes, feed: feedProbes, clock: feedClock)
        await other.refresh(probeRoom: nil)
        feedClock.advance(60)
        await other.refresh(probeRoom: nil)
        XCTAssertEqual(feedProbes.feedAsks, 2)
        feedProbes.feed = .off
        feedClock.advance(120)
        await other.refresh(probeRoom: nil)
        XCTAssertEqual(feedProbes.feedAsks, 3)
        XCTAssertEqual(other.feedOn, false)
        feedProbes.feed = .unanswered
        feedClock.advance(599)
        await other.refresh(probeRoom: nil)
        XCTAssertEqual(feedProbes.feedAsks, 3, "an off answer is asked again only after ten minutes")
        feedClock.advance(1)
        await other.refresh(probeRoom: nil)
        XCTAssertEqual(feedProbes.feedAsks, 4)
        feedClock.advance(60)
        await other.refresh(probeRoom: nil)
        XCTAssertEqual(feedProbes.feedAsks, 5, "after an answer the waits start over at one minute")
        XCTAssertEqual(feedProbes.draftAsks, 0, "no room, no drafts ask")
    }

    // MARK: - Across the clock changes (review P3, #330)

    /// America/New_York. On 2026-11-01 1:30 happens twice: an event from the first (EDT) to the second (EST) is an hour
    /// long, and keeps both offsets to the save. On 2027-03-14 2:30 never happens: 1:30 EST to 3:30 EDT is an hour. A
    /// draft with no time starts at 9 in that day's own offset, and events read on their New York day and time.
    func test_drafts_and_events_keep_the_right_offset_across_the_clock_changes() async throws {
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{2009}", with: " ")
        }
        let cases = [
            (now: "2026-11-01T00:30:00-04:00", day: CalendarDay(year: 2026, month: 11, day: 1),
             start: "2026-11-01T01:30:00-04:00", end: "2026-11-01T01:30:00-05:00", nine: "2026-11-01T09:00:00-05:00",
             event: ("2026-11-01T06:30:00Z", "2026-11-01T07:30:00Z", "1:30 – 2:30 AM")),
            (now: "2027-03-14T00:30:00-05:00", day: CalendarDay(year: 2027, month: 3, day: 14),
             start: "2027-03-14T01:30:00-05:00", end: "2027-03-14T03:30:00-04:00", nine: "2027-03-14T09:00:00-04:00",
             event: ("2027-03-14T06:30:00Z", "2027-03-14T07:30:00Z", "1:30 – 3:30 AM")),
        ]
        for edge in cases {
            let fake = FakeCalendar()
            fake.events = [CalendarEvent(id: "e", sessionId: "room-1", title: "Late show", startsAt: at(edge.event.0),
                                         endsAt: at(edge.event.1))]
            fake.draftAnswer = .success(lunchDraft(edge.start, edge.end))
            let board = makeBoard(fake, now: edge.now)
            await board.loadIfNeeded()
            XCTAssertEqual(board.selected, edge.day)
            let shown = try XCTUnwrap(board.events(on: edge.day).first, "the event reads on its New York day")
            XCTAssertEqual(plain(CalendarEventTime.text(shown, calendar: board.calendar)), edge.event.2)

            board.addText = "Late show"
            await board.draft()
            XCTAssertEqual(fake.draftRequests.last?.request,
                           .text(day: edge.day, text: "Late show", timeZone: "America/New_York"))
            let form = try XCTUnwrap(board.form)
            XCTAssertEqual(form.endsAt.timeIntervalSince(form.startsAt), 3_600, "\(edge.day.key): an hour")
            await board.save()
            let body = try XCTUnwrap(fake.saved.last?.event.body)
            XCTAssertEqual(body["startsAt"] as? String, edge.start, edge.day.key)
            XCTAssertEqual(body["endsAt"] as? String, edge.end, edge.day.key)

            fake.draftAnswer = .success(CalendarDraft(title: "Breakfast", startsAt: nil, endsAt: nil, link: nil,
                                                      notes: nil, confidence: 0.4, assumptions: []))
            board.select(edge.day)
            board.addText = "Breakfast"
            await board.draft()
            let untimed = try XCTUnwrap(board.form)
            XCTAssertEqual(CalendarInstant.format(untimed.startsAt, in: board.calendar.timeZone), edge.nine,
                           "a draft with no time starts at 9 on that day")
        }
    }

    // MARK: - The month and VoiceOver

    /// Review P3 (#330): VoiceOver reads an event with its notes. Its link is a button of its own after it (the device
    /// test `test_an_event_reads_its_notes_and_its_link_is_a_button_of_its_own` reaches it on its own).
    func test_voiceover_reads_an_event_with_its_notes() {
        let dinner = CalendarEvent(id: "e1", sessionId: "room-1", title: "Team dinner", startsAt: at("2026-11-13T00:00:00Z"),
                                   notes: "  Table for eight.\n")
        XCTAssertEqual(CalendarEventRowLabel.text(dinner, time: "7:00 PM", room: "Launch planning"),
                       "Team dinner, 7:00 PM, Launch planning, Table for eight.")
        let call = CalendarEvent(id: "e2", sessionId: "room-1", title: "Call", startsAt: at("2026-11-13T00:00:00Z"),
                                 notes: " ")
        XCTAssertEqual(CalendarEventRowLabel.text(call, time: "7:00 PM", room: nil), "Call, 7:00 PM")
    }

    /// Review P3 (#330): the rows hosted on the simulator and read the way VoiceOver reads them (UI automation on, the
    /// accessibility tree walked). A row is one element with its notes; its link is an element of its own, a button,
    /// after it. A row combined into one element again, as under review, folds the link into the row and fails here.
    func test_voiceover_reaches_an_events_link_on_its_own() throws {
        let rehearsal = CalendarEvent(id: "e-link", sessionId: "room-1", title: "Launch rehearsal",
                                      startsAt: at("2026-11-12T15:00:00Z"),
                                      link: URL(string: "https://docs.example.test/rehearsal"))
        let dinner = CalendarEvent(id: "e-notes", sessionId: "room-1", title: "Team dinner",
                                   startsAt: at("2026-11-13T00:00:00Z"), notes: "Table for eight.")
        let window = try HostedSummary.host(VStack(alignment: .leading, spacing: 12) {
            Text("Calendar rows").accessibilityIdentifier("calendar.rows.drawn")
            CalendarEventRow(event: rehearsal, time: "10:00 AM", room: "Launch planning")
            CalendarEventRow(event: dinner, time: "7:00 PM", room: nil)
        })
        defer { HostedSummary.close(window) }
        XCTAssertNotNil(HostedSummary.wait(for: "calendar.rows.drawn", in: window), "the rows were drawn")
        HostedSummary.pump(0.3)

        let elements = HostedSummary.elements(in: window).filter { $0.isAccessibilityElement }
        func element(_ identifier: String) -> [NSObject] {
            elements.filter { HostedSummary.identifier(of: $0) == identifier }
        }
        let links = element("pocket.calendar.event.e-link.link")
        XCTAssertEqual(links.count, 1, "the link is an element of its own")
        XCTAssertEqual(links.first?.accessibilityLabel, "Open link for Launch rehearsal")
        XCTAssertEqual(links.first.map { $0.accessibilityTraits.contains(.button) }, true, "the link is a button")
        XCTAssertEqual(element("pocket.calendar.event.e-link").first?.accessibilityLabel,
                       "Launch rehearsal, 10:00 AM, Launch planning", "the row reads without its link")
        XCTAssertEqual(element("pocket.calendar.event.e-notes").first?.accessibilityLabel,
                       "Team dinner, 7:00 PM, Table for eight.", "the row reads its notes")
    }

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
