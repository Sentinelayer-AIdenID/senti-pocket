import EventKit
import Foundation
import PocketSyncClient
import SwiftUI
import UIKit

// Connect my calendar (ticket 9583d41e; Carter, 2026-11-06: "Add the connect my calendar feature to calendar so all
// your calendar items can appear here and agents can have access to it"). Two separate things:
// - Connect my calendar: with the person's leave (iOS calendar access), the phone's own events show in Pocket's own
//   calendar (the one in Settings, never a room's), marked as from the phone, read-only. Showing sends nothing.
// - Let my agents see my calendar: a switch, off until she turns it on, for the calendars she picks. On, the phone
//   sends 7 days back to 30 ahead (title, start, end, all-day, place, calendar name; never notes, attendees or links)
//   when the app opens and when the phone's calendar changes, at most once a minute. Off sends a DELETE and the server
//   forgets them; a DELETE that did not go is sent again before anything else, and nothing is sent until it has gone.
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
    /// The events between `start` and `end` in the calendars with these ids, or in every calendar for nil.
    func items(from start: Date, to end: Date, calendars ids: Set<String>?) -> [PhoneCalendarItem]
    /// `changed` runs whenever the phone's calendar changes.
    func onChange(_ changed: @escaping @MainActor () -> Void)
}

/// The phone's calendar through EventKit.
@MainActor
final class EventKitPhoneCalendar: PhoneCalendarStore {
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

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

    func items(from start: Date, to end: Date, calendars ids: Set<String>?) -> [PhoneCalendarItem] {
        guard access == .granted, end > start else { return [] }
        var chosen: [EKCalendar]?
        if let ids {
            let picked = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
            guard !picked.isEmpty else { return [] }
            chosen = picked
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: chosen)
        return store.events(matching: predicate).compactMap(PhoneCalendarItem.init(event:))
    }

    func onChange(_ changed: @escaping @MainActor () -> Void) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                          queue: .main) { _ in
            Task { @MainActor in changed() }
        }
    }
}

/// The phone's calendar in Pocket: whether it may show, the events it shows, and what is sent to the person's agents.
@MainActor
final class PhoneCalendarCenter: ObservableObject {
    /// The server's flag: nil until it answers, false while it answers 404, and then nothing of this shows.
    @Published private(set) var available: Bool?
    @Published private(set) var access: PhoneCalendarAccess
    /// The phone's calendars, once Pocket may read them.
    @Published private(set) var calendars: [PhoneCalendarSource] = []
    /// "Let my agents see my calendar": off until she turns it on.
    @Published private(set) var sharesWithAgents = false
    /// The calendars she picked to share; none until she picks.
    @Published private(set) var sharedCalendarIds: Set<String> = []
    /// What the last send or forget could not do, in words.
    @Published private(set) var notice: String?
    /// Moves on whenever the phone's calendar changes or is connected, so an open calendar reads it again.
    @Published private(set) var revision = 0

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
    private var lastSend: Date?
    private var sendWaiting = false
    /// Sends and forgets run one after another, in the order asked: a forget never lands before a send asked first.
    private var queue: Task<Void, Never>?
    /// A forget that has not gone yet: sent again first, and nothing is sent until it has gone.
    private(set) var forgetPending = false

    init(store: any PhoneCalendarStore, client: any DeviceCalendarServing, defaults: UserDefaults = .standard,
         person: @escaping @MainActor () async -> String?, calendar: Calendar = .current,
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
        store.onChange { [weak self] in self?.phoneChanged() }
    }

    static func runLater(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            work()
        }
    }

    /// Showing the phone's events in Pocket's calendar: the flag is on and Pocket may read them.
    var shows: Bool { available == true && access == .granted }

    /// The app came to the front: ask the flag when due, send a forget that did not go, and send when sharing.
    func appOpened() async {
        access = store.access
        guard await loadPerson() else { return }
        await checkAvailable()
        guard available == true else { return }
        if access == .granted { calendars = store.calendars() }
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
        access = await store.requestAccess()
        if access == .granted {
            calendars = store.calendars()
            revision += 1
        }
    }

    /// The phone's events between `start` and `end`, in every calendar on the phone, to show. Nothing is sent.
    func items(from start: Date, to end: Date) -> [PhoneCalendarItem] {
        guard shows else { return [] }
        return store.items(from: start, to: end, calendars: nil)
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

    /// Picks a calendar to share, or takes it out: the next send carries only the picked ones.
    func setShared(_ calendarId: String, _ shared: Bool) {
        guard personKey != nil else { return }
        if shared { sharedCalendarIds.insert(calendarId) } else { sharedCalendarIds.remove(calendarId) }
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

    // MARK: - Sending

    private var canSend: Bool {
        available == true && access == .granted && sharesWithAgents && !sharedCalendarIds.isEmpty && personKey != nil
    }

    private func phoneChanged() {
        access = store.access
        if access == .granted { calendars = store.calendars() }
        revision += 1
        requestSend()
    }

    /// Waits until every send and forget asked so far has run.
    func idle() async {
        while let current = queue {
            await current.value
            if queue == current { return }
        }
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
        let upload = Self.upload(store.items(from: window.start, to: window.end, calendars: sharedCalendarIds),
                                 shared: sharedCalendarIds, window: window, calendar: calendar)
        do {
            _ = try await client.putDeviceEvents(upload, idempotencyKey: UUID().uuidString)
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
        lastSend = nil
        return true
    }

    private func save() {
        guard let shares = key("shares"), let picks = key("calendars"), let forget = key("forget") else { return }
        defaults.set(sharesWithAgents, forKey: shares)
        defaults.set(sharedCalendarIds.sorted(), forKey: picks)
        defaults.set(forgetPending, forKey: forget)
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
