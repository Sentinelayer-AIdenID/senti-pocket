import Combine
import Foundation
import PocketSyncClient
import SwiftUI

// The calendar (Carter, 11-04; ticket 49119fff): tap a day, say what is happening, a cheap model drafts the event, you
// edit it and save it; and subscribe to it from Apple Calendar. The server half is behind CALENDAR_DRAFTS_ENABLED and
// CALENDAR_FEED_ENABLED: until a flag answers something other than 404 nothing of what it does shows, and a 404 later
// hides it again. The calendar reads when it opens and never on a timer; nothing saves without the person tapping Save.
// The subscribe link is kept for the signed-in person in the Keychain (`CalendarLinkVault`) and opened again, never
// made again without asking.

/// Whether the calendar is on, and the Apple Calendar link. One per signed-in app.
@MainActor
final class CalendarCenter: ObservableObject {
    /// Drafting (and so the calendar itself): nil until the server has answered, false where the flag is off.
    @Published private(set) var draftsOn: Bool?
    /// The subscribe link: nil until the server has answered, false where the flag is off.
    @Published private(set) var feedOn: Bool?
    /// What the subscribe rows last did, in words. Never the link: the link goes only to the system to open and to the
    /// person's own Keychain item.
    @Published private(set) var feedNotice: String?
    @Published private(set) var isWorkingOnFeed = false
    /// Subscribe found no kept link: making one replaces any link made before (another phone, before a sign-out), so
    /// it asks first, as Reset does.
    @Published var confirmsNewLink = false

    let client: any RoomCalendarServing
    /// The phone's own calendar in Pocket's (connect my calendar); nil where the app has none to offer.
    let phone: PhoneCalendarCenter?
    private let feed: any CalendarFeedServing
    private let vault: any CalendarLinkKeeping
    /// Who is signed in (the account id): the kept link is theirs alone.
    private let person: @MainActor () async -> String?
    /// Opens the link in the system; true only if it opened.
    private let openURL: @MainActor (URL) async -> Bool
    private let now: () -> Date
    private let onReauthenticationRequired: @MainActor () -> Void
    private var checkingDrafts = false
    private var checkingFeed = false
    private(set) var draftsSchedule = CalendarProbeSchedule()
    private(set) var feedSchedule = CalendarProbeSchedule()
    private var personKey: String?

    init(client: any RoomCalendarServing, feed: any CalendarFeedServing, vault: any CalendarLinkKeeping,
         person: @escaping @MainActor () async -> String?, openURL: @escaping @MainActor (URL) async -> Bool,
         phone: PhoneCalendarCenter? = nil, now: @escaping () -> Date = { Date() },
         onReauthenticationRequired: @escaping @MainActor () -> Void = {}) {
        self.client = client
        self.phone = phone
        self.feed = feed
        self.vault = vault
        self.person = person
        self.openURL = openURL
        self.now = now
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    var showsCalendar: Bool { draftsOn == true }
    var showsSubscribe: Bool { feedOn == true }

    /// The room Settings asks the drafts route with: any room you are in, whatever your role (the flag answers before
    /// any role check, so a viewer's room tells as much as an owner's), a room before a direct message. Nil only with
    /// no rooms at all.
    static func probeRoom(in rooms: [(id: String, role: String, isDirect: Bool)]) -> String? {
        rooms.first { !$0.isDirect }?.id ?? rooms.first?.id
    }

    /// Whether a member with this role may add events (the server decides in the end: a 403 says so).
    static func canAdd(role: String) -> Bool {
        let role = role.lowercased()
        return role.isEmpty || ["owner", "admin", "contributor"].contains(role)
    }

    /// Asks whether drafting is on, with a room the person is in (the route is per room), unless the server has
    /// answered or was asked too recently (see `CalendarProbeSchedule`).
    func checkDrafts(probeRoom: String?) async {
        guard draftsOn == nil, !checkingDrafts, let probeRoom, draftsSchedule.allows(now()) else { return }
        await probeDrafts(probeRoom)
    }

    /// Settings asks again when it opens, so a flag turned on shows without a new sign-in; the schedule spaces the
    /// asks out while the answer is "off" or no answer comes.
    func refresh(probeRoom: String?) async {
        if draftsOn != true, !checkingDrafts, let probeRoom, draftsSchedule.allows(now()) {
            await probeDrafts(probeRoom)
        }
        guard feedOn != true, !checkingFeed, feedSchedule.allows(now()) else { return }
        checkingFeed = true
        defer { checkingFeed = false }
        do {
            let on = try await feed.feedAvailable()
            feedOn = on
            feedSchedule.answered(on: on, at: now())
        } catch CalendarError.reauthenticationRequired {
            onReauthenticationRequired()
        } catch {
            feedSchedule.unanswered(at: now())
        }
    }

    private func probeDrafts(_ room: String) async {
        checkingDrafts = true
        defer { checkingDrafts = false }
        do {
            let on = try await client.draftsAvailable(inRoom: room)
            draftsOn = on
            draftsSchedule.answered(on: on, at: now())
        } catch CalendarError.reauthenticationRequired {
            onReauthenticationRequired()
        } catch {
            draftsSchedule.unanswered(at: now())
        }
    }

    /// A calendar route answered 404: the flag went off. Every calendar entry hides.
    func calendarWentAway() {
        draftsOn = false
        draftsSchedule.answered(on: false, at: now())
    }

    /// Opens Apple Calendar's subscribe sheet on the link kept for this person, without making a new one. With no
    /// kept link it asks first (`confirmsNewLink`): a new link stops any older one.
    func subscribe() async {
        guard showsSubscribe, !isWorkingOnFeed else { return }
        isWorkingOnFeed = true
        feedNotice = nil
        defer { isWorkingOnFeed = false }
        guard let key = await signedInPerson() else {
            feedNotice = Self.noPerson
            return
        }
        if let kept = vault.link(for: key).flatMap({ feed.keptLink($0) }) {
            await open(kept.url)
        } else {
            confirmsNewLink = true
        }
    }

    /// The person confirmed: a new link is made, kept for them, and opened.
    func confirmNewLink() async {
        confirmsNewLink = false
        await makeLink(opening: true)
    }

    /// Reset, once confirmed: a new link replaces the kept one. The old one stops working, so a calendar subscribed to
    /// it stops updating.
    func resetLink() async {
        await makeLink(opening: false)
    }

    private func makeLink(opening: Bool) async {
        guard showsSubscribe, !isWorkingOnFeed else { return }
        isWorkingOnFeed = true
        feedNotice = nil
        defer { isWorkingOnFeed = false }
        guard let key = await signedInPerson() else {
            feedNotice = Self.noPerson
            return
        }
        do {
            let link = try await feed.newSubscriptionLink()
            vault.keep(link.url, for: key)
            if opening {
                await open(link.url)
            } else {
                feedNotice = Self.reset
            }
        } catch {
            handleFeed(error)
        }
    }

    /// Says Apple Calendar opened only if the system opened the link.
    private func open(_ url: URL) async {
        feedNotice = await openURL(url) ? Self.opened : Self.notOpened
    }

    /// Who is signed in, asked once per sign-in: the kept link is theirs alone.
    private func signedInPerson() async -> String? {
        if let personKey { return personKey }
        personKey = await person()
        return personKey
    }

    private func handleFeed(_ error: Error) {
        switch error as? CalendarError {
        case .unavailable?:
            feedOn = false
            feedSchedule.answered(on: false, at: now())
        case .reauthenticationRequired?:
            onReauthenticationRequired()
        case .forbidden?:
            feedNotice = "This account can't make a calendar link right now."
        case .rateLimited?, .dailyLimit?:
            feedNotice = "Too many tries just now. Try again later."
        default:
            feedNotice = "Couldn't get your calendar link. Check your connection and try again."
        }
    }

    static let opened = "Apple Calendar opened. Choose Subscribe there to add your Senti events."
    static let notOpened = "Couldn't open Apple Calendar on this phone."
    static let reset = "Link reset. The old link no longer updates. Tap Subscribe to add the new one."
    static let noPerson = "Couldn't check who's signed in. Check your connection and try again."
    static let newLinkWarning = "This makes a new subscribe link. "
        + "A calendar already using an older link stops updating."
    /// Short enough to show whole on an iPhone SE at the largest text size (the longer one ran past its screen).
    static let resetWarning = "Calendars on the old link stop updating, on every device. "
        + "You can subscribe again with the new one."
}

/// When to ask a flag again. An answer of "on" is final for the sign-in (a later 404 turns it off); "off" is asked
/// again after 10 minutes; no answer (the edge's 503, no network) after 1 minute, doubling each time up to 10, and
/// back to 1 after any answer. As the web asks, so a room switch or a Settings open while the paths answer 503 does
/// not ask again.
struct CalendarProbeSchedule: Equatable {
    static let first: TimeInterval = 60
    static let longest: TimeInterval = 600

    private(set) var next: Date?
    private(set) var misses = 0

    func allows(_ now: Date) -> Bool {
        guard let next else { return true }
        return now >= next
    }

    mutating func answered(on: Bool, at now: Date) {
        misses = 0
        next = on ? nil : now.addingTimeInterval(Self.longest)
    }

    mutating func unanswered(at now: Date) {
        misses += 1
        let wait = min(Self.first * pow(2, Double(misses - 1)), Self.longest)
        next = now.addingTimeInterval(wait)
    }
}

/// The calendar's network session: the app's personal-call settings (no cache, no cookies, the bearer per request),
/// but a draft waits on a model, which the server allows about 35 s, so a request may wait 45 s.
enum CalendarHTTP {
    static let session: URLSession = {
        let configuration = SentiHTTPTransportPolicy.makeProtectedReadConfiguration()
        configuration.timeoutIntervalForRequest = 45
        return URLSession(configuration: configuration)
    }()
}

/// No calendar: every route answers as a flag that is off. For a root without one (the DEBUG root preview).
struct CalendarOff: RoomCalendarServing, CalendarFeedServing {
    func draftsAvailable(inRoom sessionId: String) async throws -> Bool { false }
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

/// A room the person can add events to, for the calendar opened from Settings.
struct CalendarRoomChoice: Equatable, Hashable, Identifiable {
    let id: String
    let title: String
}

/// Where a calendar reads and where it adds.
enum CalendarScope: Equatable {
    /// One room: its events, and events added to it.
    case room(sessionId: String, title: String, canAdd: Bool)
    /// Your events across your rooms; an event is added to the room picked.
    case agenda(rooms: [CalendarRoomChoice])
}

/// One open calendar: the month on screen, the day picked, its events, and the event being drafted.
@MainActor
final class CalendarBoard: ObservableObject {
    enum Load: Equatable {
        case loading
        case loaded
        case failed
    }

    /// The first day of the month on screen.
    @Published private(set) var month: CalendarDay
    /// The month as drawn; built again only when the month or the events change.
    @Published private(set) var grid: CalendarMonthGrid
    @Published private(set) var selected: CalendarDay?
    @Published private(set) var load: Load = .loading
    /// What the person typed to draft from. A failed draft leaves it as it was.
    @Published var addText = ""
    /// For the calendar opened from Settings: the room an event is added to.
    @Published var addRoomId: String?
    @Published private(set) var isDrafting = false
    @Published private(set) var draftProblem: String?
    /// The draft being edited. Saved only by `save()`; cancelling drops it.
    @Published var form: CalendarDraftForm?
    @Published private(set) var isSaving = false
    @Published private(set) var saveProblem: String?

    let scope: CalendarScope
    let calendar: Calendar
    /// How many times the calendar has been read from the server (once per open, unless the read failed).
    private(set) var reads = 0
    /// How many times the month has been laid out (once per month change or new events).
    private(set) var gridBuilds = 0

    private let client: any RoomCalendarServing
    private let now: () -> Date
    private let onUnavailable: @MainActor () -> Void
    private let onReauthenticationRequired: @MainActor () -> Void
    private var allEvents: [CalendarEvent] = []
    private var eventsByDay: [CalendarDay: [CalendarEvent]] = [:]
    /// Pocket's own calendar shows the phone's events too, read-only (connect my calendar); a room's never does.
    private let phone: PhoneCalendarCenter?
    /// The phone's events in the month on screen, by the day they start, soonest first.
    @Published private(set) var phoneByDay: [CalendarDay: [PhoneCalendarItem]] = [:]
    private var phoneWatch: AnyCancellable?

    init(scope: CalendarScope, client: any RoomCalendarServing, calendar: Calendar = CalendarBoard.personsCalendar(),
         now: @escaping () -> Date = { Date() }, onUnavailable: @escaping @MainActor () -> Void = {},
         onReauthenticationRequired: @escaping @MainActor () -> Void = {}, phone: PhoneCalendarCenter? = nil) {
        self.scope = scope
        self.client = client
        self.phone = phone
        self.calendar = calendar
        self.now = now
        self.onUnavailable = onUnavailable
        self.onReauthenticationRequired = onReauthenticationRequired
        let today = CalendarDay(now(), in: calendar)
        let first = CalendarDay(year: today.year, month: today.month, day: 1)
        month = first
        selected = today
        grid = CalendarMonthGrid(month: first, eventsByDay: [:], today: today, calendar: calendar)
        gridBuilds = 1
        if case .agenda(let rooms) = scope { addRoomId = rooms.first?.id }
        // The phone's events are read for the month on screen, and again whenever the phone's part changes (its
        // calendar changed, it was connected, the flag answered).
        if let phone {
            layOutPhone()
            phoneWatch = phone.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.layOutPhone() }
            }
        }
    }

    /// The Gregorian calendar in the person's zone and language, whatever calendar the phone shows: the API's days
    /// are Gregorian.
    nonisolated static func personsCalendar(timeZone: TimeZone = .current, locale: Locale = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }

    var timeZone: TimeZone { calendar.timeZone }

    var canAdd: Bool {
        switch scope {
        case .room(_, _, let canAdd): return canAdd
        case .agenda(let rooms): return !rooms.isEmpty
        }
    }

    var rooms: [CalendarRoomChoice] {
        if case .agenda(let rooms) = scope { return rooms }
        return []
    }

    func events(on day: CalendarDay) -> [CalendarEvent] {
        eventsByDay[day] ?? []
    }

    /// Pocket's own calendar shows the phone's events; a room's never does.
    var showsPhoneEvents: Bool { phone != nil }

    /// The phone's own events that day, read-only.
    func phoneItems(on day: CalendarDay) -> [PhoneCalendarItem] {
        phoneByDay[day] ?? []
    }

    /// Reads the phone's events for the month on screen and lays the month out again.
    func layOutPhone() {
        readPhone()
        buildGrid()
    }

    /// A day before today takes no new event.
    func isPast(_ day: CalendarDay) -> Bool {
        day < CalendarDay(now(), in: calendar)
    }

    func roomTitle(_ sessionId: String) -> String? {
        rooms.first { $0.id == sessionId }?.title
    }

    /// Reads the calendar when it opens: once, and again only after a read that failed. A 404 without a calendar code
    /// is the calendar turned off (it hides); with one it is a read that failed.
    func loadIfNeeded() async {
        guard reads == 0 || load == .failed else { return }
        reads += 1
        load = .loading
        do {
            let read: [CalendarEvent]
            switch scope {
            case .room(let sessionId, _, _): read = try await client.events(inRoom: sessionId)
            case .agenda: read = try await client.agenda()
            }
            setEvents(read)
            load = .loaded
        } catch CalendarError.unavailable {
            load = .failed
            onUnavailable()
        } catch CalendarError.reauthenticationRequired {
            load = .failed
            onReauthenticationRequired()
        } catch {
            load = .failed
        }
    }

    /// The month before (-1) or after (+1). The new month is laid out once.
    func showMonth(_ delta: Int) {
        guard delta != 0, let start = month.start(in: calendar),
              let moved = calendar.date(byAdding: .month, value: delta, to: start) else { return }
        let next = CalendarDay(moved, in: calendar)
        month = CalendarDay(year: next.year, month: next.month, day: 1)
        let today = CalendarDay(now(), in: calendar)
        selected = (today.year, today.month) == (month.year, month.month) ? today : nil
        readPhone()
        buildGrid()
    }

    func select(_ day: CalendarDay) {
        selected = day
        draftProblem = nil
    }

    /// Asks for a draft of what was typed, for the day picked, in the person's zone. Nothing is saved: the draft
    /// opens as a form. A 404 here is the drafts flag off: the calendar hides everywhere.
    func draft() async {
        let text = addText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAdd, !isDrafting, form == nil, let day = selected, !isPast(day), !text.isEmpty,
              let room = targetRoom else { return }
        guard text.count <= CalendarDraftRequest.maxTextLength else {
            draftProblem = "That's too long to draft. Keep it under \(CalendarDraftRequest.maxTextLength) characters."
            return
        }
        isDrafting = true
        draftProblem = nil
        defer { isDrafting = false }
        do {
            let draft = try await client.draft(inRoom: room.id, .text(day: day, text: text, timeZone: timeZone.identifier))
            saveProblem = nil
            form = CalendarDraftForm(draft: draft, day: day, roomId: room.id, roomTitle: room.title, calendar: calendar)
        } catch CalendarError.unavailable {
            onUnavailable()
        } catch CalendarError.notFound {
            draftProblem = "That room isn't there anymore."
        } catch CalendarError.reauthenticationRequired {
            onReauthenticationRequired()
        } catch CalendarError.forbidden {
            draftProblem = "You can't add events in this room."
        } catch CalendarError.rejected {
            // The server refused the words or the day (a day with no future time left in it, say): not the network.
            draftProblem = "Senti couldn't draft that for this day. Try saying it another way."
        } catch CalendarError.rateLimited {
            draftProblem = "Too many tries just now. Wait a moment and try again."
        } catch CalendarError.dailyLimit {
            draftProblem = "You've used today's drafts. Try again tomorrow."
        } catch {
            draftProblem = "Couldn't draft that. Check your connection and try again."
        }
    }

    /// Saves the form as it stands, to the room it was drafted for. The only way an event is saved.
    func save() async {
        guard let form, !isSaving else { return }
        let event: CalendarEventCreate
        switch form.validated(now: now()) {
        case .failure(let problem):
            saveProblem = problem.message
            return
        case .success(let valid):
            event = valid
        }
        isSaving = true
        saveProblem = nil
        defer { isSaving = false }
        do {
            let saved = try await client.save(event, inRoom: form.roomId)
            self.form = nil
            addText = ""
            setEvents(allEvents.filter { $0.id != saved.id } + [saved])
            let day = CalendarDay(saved.startsAt, in: calendar)
            if (day.year, day.month) != (month.year, month.month) {
                month = CalendarDay(year: day.year, month: day.month, day: 1)
                readPhone()
                buildGrid()
            }
            selected = day
        } catch CalendarError.unavailable {
            self.form = nil
            onUnavailable()
        } catch CalendarError.notFound {
            saveProblem = "Not saved: that room isn't there anymore."
        } catch CalendarError.reauthenticationRequired {
            onReauthenticationRequired()
        } catch CalendarError.forbidden {
            saveProblem = "You can't add events in this room."
        } catch CalendarError.rejected {
            saveProblem = "Senti didn't take that. Check the times and the link."
        } catch CalendarError.rateLimited {
            saveProblem = "Too many tries just now. Wait a moment and try again."
        } catch CalendarError.dailyLimit {
            saveProblem = "This room or your account has reached today's limit of new events."
        } catch {
            saveProblem = "Not saved. Check your connection and try again."
        }
    }

    /// Drops the draft. Nothing was saved; what was typed stays, to draft again. While a save is out it does nothing:
    /// the event may already exist, so the form stays until the server answers.
    func cancelDraft() {
        guard !isSaving else { return }
        form = nil
        saveProblem = nil
    }

    private var targetRoom: CalendarRoomChoice? {
        switch scope {
        case .room(let sessionId, let title, _):
            return CalendarRoomChoice(id: sessionId, title: title)
        case .agenda(let rooms):
            return rooms.first { $0.id == addRoomId } ?? rooms.first
        }
    }

    private func setEvents(_ list: [CalendarEvent]) {
        allEvents = list.sorted { ($0.startsAt, $0.id) < ($1.startsAt, $1.id) }
        eventsByDay = Dictionary(grouping: allEvents) { CalendarDay($0.startsAt, in: calendar) }
        buildGrid()
    }

    private func readPhone() {
        guard let phone, let start = month.start(in: calendar),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return }
        let items = phone.items(from: start, to: end).sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        phoneByDay = Dictionary(grouping: items) { CalendarDay($0.start, in: calendar) }
    }

    private func buildGrid() {
        grid = CalendarMonthGrid(month: month, eventsByDay: eventsByDay, phoneCounts: phoneByDay.mapValues(\.count),
                                 today: CalendarDay(now(), in: calendar), calendar: calendar)
        gridBuilds += 1
    }
}

/// A month laid out for the grid: blank cells before the 1st, then each day with its count of events and what
/// VoiceOver reads for it.
struct CalendarMonthGrid: Equatable {
    struct Cell: Equatable, Identifiable {
        let id: Int
        /// Nil for the blanks before the month's first day.
        let day: CalendarDay?
        let eventCount: Int
        let isToday: Bool
        /// "Wednesday, November 4, 2 events".
        let accessibilityLabel: String
    }

    let month: CalendarDay
    /// "November 2026".
    let title: String
    /// The weekday initials, from the person's first day of the week.
    let weekdays: [String]
    let cells: [Cell]

    /// `phoneCounts`: the phone's own events by day, counted with the rooms' (Pocket's own calendar).
    init(month: CalendarDay, eventsByDay: [CalendarDay: [CalendarEvent]], phoneCounts: [CalendarDay: Int] = [:],
         today: CalendarDay, calendar: Calendar) {
        self.month = month
        let titleFormatter = DateFormatter()
        titleFormatter.calendar = calendar
        titleFormatter.timeZone = calendar.timeZone
        titleFormatter.locale = calendar.locale
        titleFormatter.setLocalizedDateFormatFromTemplate("MMMMy")
        let first = month.start(in: calendar) ?? Date()
        title = titleFormatter.string(from: first)
        let symbols = titleFormatter.veryShortStandaloneWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        let shift = max(0, calendar.firstWeekday - 1) % 7
        weekdays = Array(symbols[shift...] + symbols[..<shift])
        let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let length = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let labels = CalendarDayLabel(calendar: calendar)
        var cells = (0..<leading).map { Cell(id: $0, day: nil, eventCount: 0, isToday: false, accessibilityLabel: "") }
        for number in 1...length {
            let day = CalendarDay(year: month.year, month: month.month, day: number)
            let count = (eventsByDay[day]?.count ?? 0) + (phoneCounts[day] ?? 0)
            cells.append(Cell(id: leading + number - 1, day: day, eventCount: count, isToday: day == today,
                              accessibilityLabel: labels.text(for: day, eventCount: count)))
        }
        self.cells = cells
    }
}

/// What VoiceOver reads for a day: "Wednesday, November 4, 2 events".
struct CalendarDayLabel {
    private let calendar: Calendar
    private let formatter: DateFormatter

    init(calendar: Calendar) {
        self.calendar = calendar
        formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
    }

    func day(_ day: CalendarDay) -> String {
        day.start(in: calendar).map(formatter.string(from:)) ?? day.key
    }

    func text(for day: CalendarDay, eventCount: Int) -> String {
        "\(self.day(day)), \(Self.count(eventCount))"
    }

    static func count(_ events: Int) -> String {
        switch events {
        case 0: return "no events"
        case 1: return "1 event"
        default: return "\(events) events"
        }
    }
}

/// An event's time as the person reads it, in their zone: "1:00 – 2:00 PM".
enum CalendarEventTime {
    static func text(_ event: CalendarEvent, calendar: Calendar) -> String {
        guard let end = event.endsAt else { return time(event.startsAt, calendar: calendar) }
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: event.startsAt, to: end)
    }

    static func time(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// The form a draft opens as: every field the person can change before saving, what the model assumed, and whether
/// it was unsure.
struct CalendarDraftForm: Identifiable, Equatable {
    enum Problem: Error, Equatable {
        case noTitle
        case titleTooLong
        case startPassed
        case endBeforeStart
        case badLink
        case notesTooLong

        var message: String {
            switch self {
            case .noTitle: return "Give it a title."
            case .titleTooLong: return "Keep the title under 200 characters."
            case .startPassed: return "That start time has passed. Pick a later one."
            case .endBeforeStart: return "The end is before the start."
            case .badLink: return "Links need to start with https://"
            case .notesTooLong: return "Keep the notes under 2,000 characters."
            }
        }
    }

    /// Below this, the form says the model was unsure.
    static let confidentFrom = 0.6

    let id = UUID()
    let roomId: String
    let roomTitle: String?
    let timeZone: TimeZone
    var title: String
    var startsAt: Date
    var hasEnd: Bool
    var endsAt: Date
    var link: String
    var notes: String
    /// What the model assumed, as it said it.
    let assumptions: [String]
    /// The model was unsure (confidence under 0.6, none given, or no start time).
    let isLowConfidence: Bool

    init(draft: CalendarDraft, day: CalendarDay, roomId: String, roomTitle: String?, calendar: Calendar) {
        let midnight = day.start(in: calendar) ?? Date()
        let fallback = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: midnight) ?? midnight
        let start = draft.startsAt ?? fallback
        self.roomId = roomId
        self.roomTitle = roomTitle
        timeZone = calendar.timeZone
        title = draft.title
        startsAt = start
        hasEnd = draft.endsAt != nil
        endsAt = draft.endsAt ?? start.addingTimeInterval(3_600)
        link = draft.link ?? ""
        notes = draft.notes ?? ""
        assumptions = draft.assumptions
        isLowConfidence = draft.startsAt == nil || (draft.confidence ?? 0) < Self.confidentFrom
    }

    /// The event to save, or what to fix first.
    func validated(now: Date) -> Result<CalendarEventCreate, Problem> {
        let title = self.title.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return .failure(.noTitle) }
        guard title.count <= 200 else { return .failure(.titleTooLong) }
        guard startsAt > now else { return .failure(.startPassed) }
        if hasEnd, endsAt <= startsAt { return .failure(.endBeforeStart) }
        let linkText = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = CalendarLink.https(linkText)
        if !linkText.isEmpty, url == nil { return .failure(.badLink) }
        let notes = self.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard notes.count <= 2_000 else { return .failure(.notesTooLong) }
        return .success(CalendarEventCreate(title: title, startsAt: startsAt, endsAt: hasEnd ? endsAt : nil, link: url,
                                            notes: notes.isEmpty ? nil : notes, timeZone: timeZone))
    }

    static func == (lhs: CalendarDraftForm, rhs: CalendarDraftForm) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.startsAt == rhs.startsAt && lhs.hasEnd == rhs.hasEnd
            && lhs.endsAt == rhs.endsAt && lhs.link == rhs.link && lhs.notes == rhs.notes
    }
}
