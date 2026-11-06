import EventKit
import Foundation
import PocketSyncClient
import SwiftUI
import UIKit

// Connect my calendar (ticket 9583d41e; Carter, 2026-11-06: "Add the connect my calendar feature to calendar so all
// your calendar items can appear here and agents can have access to it"). Two separate things:
// - Connect my calendar: with the person's leave (iOS calendar access), the phone's own events show in Pocket's own
//   calendar (the one in Settings, never a room's), marked as from the phone, read-only. Showing sends nothing.
// - Let my agents see my calendar: a switch, off until the person turns it on, for the calendars they pick. On, the
//   phone sends 7 days back to 30 ahead (title, start, end, all-day, place, calendar name; never notes, attendees or
//   links) when the app opens and when the phone's calendar changes, at most once a minute, and never the same body
//   twice. The server forgets everything (DELETE) whenever sharing stops: the switch turned off, the last calendar
//   unticked, or calendar access turned off in iOS Settings (then once, with the switch left as the person set it, in
//   sight, and sharing starts again by itself when access comes back). A DELETE that did not go is sent again before
//   anything else, and nothing is sent until it has gone.
// Both hide while the server's flag answers 404 (`DeviceCalendarServing`). The switch and the picks are the signed-in
// account's own: another sign-in on the phone starts with the switch off.

/// Whether Pocket may read the phone's calendar.
enum PhoneCalendarAccess: Equatable, Sendable {
    /// Not asked yet: "Connect my calendar" asks.
    case notAsked
    case granted
    /// Turned off for Pocket in Settings.
    case denied
    /// Not allowed on this phone (a management profile, Screen Time).
    case restricted
    /// iOS 17's add-only access: Pocket could add events, never read them.
    case addOnly

    /// Asked, and Pocket cannot read the calendar: a plain line, and the way to Settings.
    var isRefused: Bool { self == .denied || self == .restricted || self == .addOnly }
}

/// One of the phone's calendars.
struct PhoneCalendarSource: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    /// The account it is in ("iCloud", "Gmail"); empty when the phone does not say.
    let account: String
}

/// One of the phone's events as Pocket holds it: what its calendar shows, and all that is ever sent. Its notes,
/// attendees and links are never read into it.
struct PhoneCalendarItem: Equatable, Identifiable, Sendable {
    /// The id it is sent with (`DeviceCalendarEvent.id`): each occurrence of a repeating event is its own.
    let id: String
    /// The phone's identifier for the event; every occurrence of a repeating event shares it.
    let identifier: String
    /// When this occurrence was first scheduled to start.
    let occurrenceStart: Date
    let calendarId: String
    let calendarTitle: String
    /// "No title" for an event without one.
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String?

    init(identifier: String, occurrenceStart: Date, calendarId: String, calendarTitle: String, title: String?,
         start: Date, end: Date, allDay: Bool, location: String?) {
        id = DeviceCalendarEvent.id(identifier: identifier, occurrenceStart: occurrenceStart)
        self.identifier = identifier
        self.occurrenceStart = occurrenceStart
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = trimmed.isEmpty ? DeviceCalendarEvent.noTitle : trimmed
        self.start = start
        self.end = max(end, start)
        self.allDay = allDay
        let place = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.location = place.isEmpty ? nil : place
    }

    /// An EventKit event with times: its title, times, place and calendar. Never its notes, attendees or link.
    init?(event: EKEvent) {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        self.init(identifier: event.eventIdentifier ?? event.calendarItemIdentifier,
                  occurrenceStart: event.occurrenceDate ?? start,
                  calendarId: event.calendar?.calendarIdentifier ?? "",
                  calendarTitle: event.calendar?.title ?? "",
                  title: event.title, start: start, end: end, allDay: event.isAllDay, location: event.location)
    }
}

/// The phone's calendar, as Pocket reads it: a protocol, so tests and previews use a stand-in with made-up events.
@MainActor
protocol PhoneCalendarStore: AnyObject {
    var access: PhoneCalendarAccess { get }
    /// Asks iOS for full access to read events (the system asks the person once); the access after.
    func requestAccess() async -> PhoneCalendarAccess
    func calendars() -> [PhoneCalendarSource]
    /// The events between `start` and `end` in the calendars with these ids, or in every calendar for nil. Read off
    /// the main thread.
    func items(from start: Date, to end: Date, calendars ids: Set<String>?) async -> [PhoneCalendarItem]
    /// `changed` runs whenever the phone's calendar changes, in place of any given before.
    func onChange(_ changed: @escaping @MainActor () -> Void)
}

/// The phone's calendar through EventKit: one store for the whole app (`shared`). The app's root view is built again
/// on every pass of the App's body, and each pass made a new store and a change observer that was never removed.
@MainActor
final class EventKitPhoneCalendar: PhoneCalendarStore {
    static let shared = EventKitPhoneCalendar()
    /// How many were ever made: one.
    private(set) static var made = 0

    /// Watches EventKit's change notification for as long as it lives, and stops when it goes.
    private final class ChangeWatch {
        private let token: NSObjectProtocol

        init(store: EKEventStore, onChange: @escaping @Sendable () -> Void) {
            token = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                           queue: .main) { _ in onChange() }
        }

        deinit { NotificationCenter.default.removeObserver(token) }
    }

    private let store = EKEventStore()
    private var watch: ChangeWatch?
    private var changed: (@MainActor () -> Void)?

    private init() {
        Self.made += 1
        watch = ChangeWatch(store: store) { [weak self] in
            Task { @MainActor in self?.changed?() }
        }
    }

    var access: PhoneCalendarAccess {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined: return .notAsked
        case .restricted: return .restricted
        case .denied: return .denied
        default: break
        }
        if #available(iOS 17.0, *) {
            switch status {
            case .fullAccess: return .granted
            case .writeOnly: return .addOnly
            default: return .denied
            }
        }
        return status == .authorized ? .granted : .denied
    }

    func requestAccess() async -> PhoneCalendarAccess {
        if #available(iOS 17.0, *) {
            _ = try? await store.requestFullAccessToEvents()
        } else {
            _ = try? await store.requestAccess(to: .event)
        }
        return access
    }

    func calendars() -> [PhoneCalendarSource] {
        guard access == .granted else { return [] }
        return store.calendars(for: .event)
            .map { PhoneCalendarSource(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "") }
            .sorted { ($0.account, $0.title, $0.id) < ($1.account, $1.title, $1.id) }
    }

    func items(from start: Date, to end: Date, calendars ids: Set<String>?) async -> [PhoneCalendarItem] {
        guard access == .granted, end > start else { return [] }
        let store = self.store
        return await Task.detached(priority: .userInitiated) { () -> [PhoneCalendarItem] in
            var chosen: [EKCalendar]?
            if let ids {
                let picked = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
                guard !picked.isEmpty else { return [] }
                chosen = picked
            }
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: chosen)
            return store.events(matching: predicate).compactMap(PhoneCalendarItem.init(event:))
        }.value
    }

    func onChange(_ changed: @escaping @MainActor () -> Void) {
        self.changed = changed
    }

    #if DEBUG
    /// The calendar preview's made-up event (`-PocketCalendarSeedEvent`), with notes and a link that must never leave
    /// the phone. Any left by an earlier run is removed first. Needs calendar access; nil without it.
    static let seedTitle = "Site visit (made up)"
    private var seedIdentifier: String?
    /// The calendar the made-up event is in, for the device test to tick.
    private(set) var seedCalendarId: String?
    private var seedRenames = 0

    func seedForPreview(now: Date) {
        guard access == .granted, let calendar = store.defaultCalendarForNewEvents else { return }
        let window = store.predicateForEvents(withStart: now.addingTimeInterval(-86_400 * 8),
                                              end: now.addingTimeInterval(86_400 * 32), calendars: [calendar])
        for old in store.events(matching: window) where old.title?.hasPrefix(Self.seedTitle) == true {
            try? store.remove(old, span: .thisEvent, commit: true)
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = Self.seedTitle
        event.startDate = now.addingTimeInterval(3_600)
        event.endDate = now.addingTimeInterval(7_200)
        event.notes = "Bring the blue folder"
        event.url = URL(string: "https://meet.example.test/room-7")
        try? store.save(event, span: .thisEvent, commit: true)
        seedIdentifier = event.eventIdentifier
        seedCalendarId = calendar.calendarIdentifier
    }

    /// Renames the made-up event, as an edit on the phone would: the phone's calendar changes.
    func renameSeedForPreview() {
        guard let seedIdentifier, let event = store.event(withIdentifier: seedIdentifier) else { return }
        seedRenames += 1
        event.title = "\(Self.seedTitle) \(seedRenames)"
        try? store.save(event, span: .thisEvent, commit: true)
    }
    #endif
}

/// The phone's calendar in Pocket: whether it may show, the events it shows, and what is sent to the person's agents.
@MainActor
final class PhoneCalendarCenter: ObservableObject {
    /// The server's flag: nil until it answers, false while it answers 404, and then nothing of this shows.
    @Published private(set) var available: Bool?
    @Published private(set) var access: PhoneCalendarAccess
    /// The phone's calendars, once Pocket may read them.
    @Published private(set) var calendars: [PhoneCalendarSource] = []
    /// "Let my agents see my calendar": off until the person turns it on.
    @Published private(set) var sharesWithAgents = false
    /// The calendars picked to share; none until some are picked.
    @Published private(set) var sharedCalendarIds: Set<String> = []
    /// What the last send or forget could not do, in words.
    @Published private(set) var notice: String?
    /// Moves on whenever the phone's calendar changes or is connected, so an open calendar reads it again.
    @Published private(set) var revision = 0
    /// A forget that has not gone yet: sent again first, and nothing is sent until it has gone. While it waits, the
    /// switch stays in sight, whatever iOS lets Pocket read.
    @Published private(set) var forgetPending = false
    /// The server holds nothing of this person's: the last word it had was a DELETE (none sent since). With calendar
    /// access gone, the server is told to forget once, not at every app open.
    private(set) var serverForgot = false

    /// The least time between two sends.
    static let spacing: TimeInterval = 60
    static let sendFailed = "Couldn't send your calendar to your agents just now. It goes again when the app opens."
    static let forgetFailed = "Couldn't turn sharing off on the server just now. It's tried again when the app opens, "
        + "and nothing is sent until it has gone."

    private let store: any PhoneCalendarStore
    private let client: any DeviceCalendarServing
    private let defaults: UserDefaults
    /// Who is signed in (the account id): the switch and the picks are theirs alone.
    private let person: @MainActor () async -> String?
    private let calendar: Calendar
    private let now: () -> Date
    /// Runs `work` after a delay: the minute between two sends.
    private let later: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var personKey: String?
    private(set) var schedule = CalendarProbeSchedule()
    private var checking = false
    private var listening = false
    private var lastSend: Date?
    private var sendWaiting = false
    /// The body of the last send the server took: the same body is not sent again.
    private var lastSentBody: Data?
    /// Sends and forgets run one after another, in the order asked: a forget never lands before a send asked first.
    private var queue: Task<Void, Never>?

    /// `calendar` is the phone's own, following a change of time zone.
    init(store: any PhoneCalendarStore, client: any DeviceCalendarServing, defaults: UserDefaults = .standard,
         person: @escaping @MainActor () async -> String?, calendar: Calendar = .autoupdatingCurrent,
         now: @escaping () -> Date = { Date() },
         later: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = PhoneCalendarCenter.runLater) {
        self.store = store
        self.client = client
        self.defaults = defaults
        self.person = person
        self.calendar = calendar
        self.now = now
        self.later = later
        access = store.access
    }

    /// The app's own: on the one EventKit store. Making it again (each pass of the App's body does) makes no new
    /// store, and only the center the app keeps listens to it (`appOpened`).
    static func live(client: any DeviceCalendarServing,
                     person: @escaping @MainActor () async -> String?) -> PhoneCalendarCenter {
        PhoneCalendarCenter(store: EventKitPhoneCalendar.shared, client: client, person: person)
    }

    static func runLater(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            work()
        }
    }

    /// Showing the phone's events in Pocket's calendar: the flag is on and Pocket may read them.
    var shows: Bool { available == true && access == .granted }

    /// The switch and the picks are in sight: Pocket may read the calendar, or sharing is on or still being forgotten
    /// (calendar access turned off in iOS Settings must never hide the way to stop sharing).
    var showsSharing: Bool { access == .granted || sharesWithAgents || forgetPending }

    /// How many picked calendars are on the phone now: a pick whose calendar has gone is not counted.
    var pickedCount: Int {
        calendars.isEmpty ? sharedCalendarIds.count : sharedCalendarIds.intersection(calendars.map(\.id)).count
    }

    /// The app came to the front: ask the flag when due, stop sharing if calendar access went, send a forget that did
    /// not go, and send when sharing.
    func appOpened() async {
        listen()
        access = store.access
        guard await loadPerson() else { return }
        await checkAvailable()
        guard available == true else { return }
        if access == .granted {
            calendars = store.calendars()
        } else {
            accessWent()
        }
        if forgetPending { enqueue { await self.forget() } }
        requestSend()
    }

    /// Asks the server whether connecting is on, unless it has said so or was asked too recently.
    func checkAvailable() async {
        guard available != true, !checking, schedule.allows(now()) else { return }
        checking = true
        defer { checking = false }
        do {
            let on = try await client.deviceEventsAvailable(now: now())
            available = on
            schedule.answered(on: on, at: now())
        } catch {
            schedule.unanswered(at: now())
        }
    }

    /// "Connect my calendar": asks iOS for access. The phone's events then show in Pocket's calendar; nothing is sent.
    func connect() async {
        guard available == true else { return }
        listen()
        access = await store.requestAccess()
        if access == .granted {
            calendars = store.calendars()
            revision += 1
        }
    }

    /// The phone's events between `start` and `end`, in every calendar on the phone, to show. Nothing is sent.
    func items(from start: Date, to end: Date) async -> [PhoneCalendarItem] {
        guard shows else { return [] }
        return await store.items(from: start, to: end, calendars: nil)
    }

    /// "Let my agents see my calendar". On sends the picked calendars (once picked); off sends the DELETE.
    func setSharing(_ on: Bool) async {
        guard available == true, await loadPerson() else { return }
        if on {
            guard access == .granted, !sharesWithAgents else { return }
            sharesWithAgents = true
            save()
            requestSend()
        } else {
            guard sharesWithAgents || forgetPending else { return }
            sharesWithAgents = false
            forgetPending = true
            save()
            enqueue { await self.forget() }
            await queue?.value
        }
    }

    /// Picks a calendar to share, or takes it out: the next send carries only the picked ones. Unticking the last one
    /// while sharing leaves nothing shared, so the server forgets what it has.
    func setShared(_ calendarId: String, _ shared: Bool) {
        guard personKey != nil else { return }
        let hadPicks = !sharedCalendarIds.isEmpty
        if shared { sharedCalendarIds.insert(calendarId) } else { sharedCalendarIds.remove(calendarId) }
        if hadPicks, sharedCalendarIds.isEmpty, sharesWithAgents {
            forgetPending = true
            save()
            enqueue { await self.forget() }
            return
        }
        save()
        requestSend()
    }

    /// Sends now, or a minute after the last send: a change inside the minute is folded into that one.
    func requestSend() {
        guard canSend else { return }
        let wait = lastSend.map { Self.spacing - now().timeIntervalSince($0) } ?? 0
        if wait <= 0 {
            lastSend = now()
            enqueue { await self.send() }
        } else if !sendWaiting {
            sendWaiting = true
            later(wait) { [weak self] in
                guard let self else { return }
                self.sendWaiting = false
                self.requestSend()
            }
        }
    }

    /// What one send carries: the events of the picked calendars only (whatever the phone gave), each with the
    /// contract's seven keys, an all-day one from midnight to the midnight after its last day.
    static func upload(_ items: [PhoneCalendarItem], shared: Set<String>, window: (start: Date, end: Date),
                       calendar: Calendar) -> DeviceCalendarUpload {
        let events = items.filter { shared.contains($0.calendarId) }.map { item -> DeviceCalendarEvent in
            let bounds = item.allDay
                ? DeviceCalendarEvent.allDayBounds(start: item.start, end: item.end, in: calendar)
                : (start: item.start, end: item.end)
            return DeviceCalendarEvent(identifier: item.identifier, occurrenceStart: item.occurrenceStart,
                                       calendar: item.calendarTitle, title: item.title, start: bounds.start,
                                       end: bounds.end, allDay: item.allDay, location: item.location)
        }
        return DeviceCalendarUpload(windowStart: window.start, windowEnd: window.end, events: events,
                                    timeZone: calendar.timeZone)
    }

    /// Waits until every send and forget asked so far has run.
    func idle() async {
        while let current = queue {
            await current.value
            if queue == current { return }
        }
    }

    // MARK: - Sending

    private var canSend: Bool {
        available == true && access == .granted && sharesWithAgents && !sharedCalendarIds.isEmpty && personKey != nil
    }

    /// Only the center the app keeps listens to the phone's calendar.
    private func listen() {
        guard !listening else { return }
        listening = true
        store.onChange { [weak self] in self?.phoneChanged() }
    }

    private func phoneChanged() {
        access = store.access
        if access == .granted {
            calendars = store.calendars()
        } else if personKey != nil {
            accessWent()
            if forgetPending { enqueue { await self.forget() } }
        }
        revision += 1
        requestSend()
    }

    /// Calendar access went (turned off in iOS Settings, or reset) while sharing: the server is to forget what it has,
    /// once. The switch stays as the person set it, in sight, so it can be turned off, and sharing starts again by
    /// itself when access comes back.
    private func accessWent() {
        guard sharesWithAgents, !serverForgot, !forgetPending else { return }
        forgetPending = true
        save()
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func send() async {
        guard canSend else { return }
        if forgetPending {
            await forget()
            guard !forgetPending else { return }
        }
        let window = DeviceCalendarUpload.window(around: now(), in: calendar)
        let picked = sharedCalendarIds
        let upload = Self.upload(await store.items(from: window.start, to: window.end, calendars: picked),
                                 shared: picked, window: window, calendar: calendar)
        let body = try? JSONSerialization.data(withJSONObject: upload.body, options: [.sortedKeys])
        if let body, body == lastSentBody { return }
        do {
            _ = try await client.putDeviceEvents(upload, idempotencyKey: UUID().uuidString)
            lastSentBody = body
            serverForgot = false
            save()
            notice = nil
        } catch CalendarError.unavailable {
            wentAway()
        } catch {
            notice = Self.sendFailed
        }
    }

    private func forget() async {
        guard forgetPending else { return }
        do {
            try await client.deleteDeviceEvents()
            forgetPending = false
            serverForgot = true
            lastSentBody = nil
            notice = nil
        } catch CalendarError.unavailable {
            // The flag is off: everything hides, and the forget goes once it is back.
            wentAway()
        } catch {
            notice = Self.forgetFailed
        }
        save()
    }

    private func wentAway() {
        available = false
        schedule.answered(on: false, at: now())
    }

    // MARK: - The person's own switch and picks

    private func key(_ name: String) -> String? {
        personKey.map { "pocket.phoneCalendar.\($0).\(name)" }
    }

    /// Reads the signed-in person's switch, picks and any forget not gone yet; false with no one signed in.
    private func loadPerson() async -> Bool {
        guard let signedIn = await person(), !signedIn.isEmpty else { return false }
        guard signedIn != personKey else { return true }
        personKey = signedIn
        sharesWithAgents = key("shares").map(defaults.bool(forKey:)) ?? false
        sharedCalendarIds = Set(key("calendars").flatMap(defaults.stringArray(forKey:)) ?? [])
        forgetPending = key("forget").map(defaults.bool(forKey:)) ?? false
        serverForgot = key("forgot").map(defaults.bool(forKey:)) ?? false
        lastSend = nil
        lastSentBody = nil
        return true
    }

    private func save() {
        guard let shares = key("shares"), let picks = key("calendars"), let forget = key("forget"),
              let forgot = key("forgot") else { return }
        defaults.set(sharesWithAgents, forKey: shares)
        defaults.set(sharedCalendarIds.sorted(), forKey: picks)
        defaults.set(forgetPending, forKey: forget)
        defaults.set(serverForgot, forKey: forgot)
    }
}

/// With no calendar service (a build without one): connecting is off, so nothing of it shows.
extension CalendarOff: DeviceCalendarServing {
    func deviceEventsAvailable(now: Date) async throws -> Bool { false }
    func putDeviceEvents(_ upload: DeviceCalendarUpload, idempotencyKey: String) async throws -> Int {
        throw CalendarError.unavailable
    }
    func deleteDeviceEvents() async throws { throw CalendarError.unavailable }
}
