import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts

// Connect my calendar (ticket 9583d41e), the phone's half of the contract of 2026-11-06 (draft 2). With the person's
// switch on, the phone sends its own events in a window, 7 days back to 30 ahead, so their own agents can read them:
// - `PUT /me/calendar/device-events` replaces the window (an event no longer on the phone goes), with an
//   Idempotency-Key;
// - `DELETE /me/calendar/device-events` forgets every one of them (the switch turned off);
// - `GET /me/calendar/device-events?from=&to=` reads them back; with an empty window it is the flag's probe.
// An event is sent as exactly id, calendar, title, start, end, allDay and location: never its notes, attendees or links
// (they carry meeting passcodes), and the server refuses any other key. With its flag off, all three routes answer
// 404 with no code, and the app shows nothing of it.

/// The phone's events' route, window and limits.
public enum DeviceCalendarRoutes {
    public static let events = ["api", "v1", "me", "calendar", "device-events"]
    /// The window sent: from midnight this many days back, to midnight this many days after today.
    public static let daysBack = 7
    public static let daysAhead = 30
    /// The API's limits, kept on the phone so that one long field never has the whole window refused.
    public static let maxEvents = 2_000
    public static let maxTitle = 200
    public static let maxLocation = 200
    public static let maxCalendar = 100
}

/// One of the phone's events as it is sent: the contract's keys and nothing else.
public struct DeviceCalendarEvent: Equatable, Sendable {
    /// Lowercase hex sha256 of the phone's identifier for the event and its occurrence's start (`id(identifier:...)`).
    public let id: String
    /// The name of the calendar it is in.
    public let calendar: String
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let location: String?

    /// What an event with no title is sent as.
    public static let noTitle = "No title"
    /// What a calendar with no name is sent as.
    public static let noCalendarName = "Calendar"

    /// An event as the phone holds it. Its title, location and calendar's name are cut to the API's limits (counted as
    /// the API counts them, in Unicode scalars, never splitting a character); an end before the start is the start.
    public init(identifier: String, occurrenceStart: Date, calendar: String, title: String?, start: Date, end: Date,
                allDay: Bool, location: String?) {
        id = Self.id(identifier: identifier, occurrenceStart: occurrenceStart)
        self.calendar = Self.cut(calendar, to: DeviceCalendarRoutes.maxCalendar) ?? Self.noCalendarName
        self.title = Self.cut(title, to: DeviceCalendarRoutes.maxTitle) ?? Self.noTitle
        self.start = start
        self.end = max(end, start)
        self.allDay = allDay
        self.location = Self.cut(location, to: DeviceCalendarRoutes.maxLocation)
    }

    /// `sha256(identifier + "|" + the occurrence's start in UTC, ISO 8601)`, lowercase hex. The phone gives every
    /// occurrence of a repeating event the same identifier, so its start keeps each one apart.
    public static func id(identifier: String, occurrenceStart: Date) -> String {
        let text = identifier + "|" + CalendarInstant.format(occurrenceStart, in: .gmt)
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// An all-day event's bounds: from the local midnight of its first day to the local midnight after its last day,
    /// which is not part of it. The phone ends an all-day event a second before midnight.
    public static func allDayBounds(start: Date, end: Date, in calendar: Calendar) -> (start: Date, end: Date) {
        let first = calendar.startOfDay(for: start)
        let last = max(end, start)
        let lastDay = calendar.startOfDay(for: last)
        // Already a midnight after the first day: that midnight is the end.
        if lastDay == last, lastDay > first { return (first, lastDay) }
        return (first, calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay)
    }

    /// The event as sent, its times with `timeZone`'s offset: the contract's seven keys, location null when it has none.
    public func json(in timeZone: TimeZone) -> [String: Any] {
        [
            "id": id,
            "calendar": calendar,
            "title": title,
            "start": CalendarInstant.format(start, in: timeZone),
            "end": CalendarInstant.format(end, in: timeZone),
            "allDay": allDay,
            "location": location.map { $0 as Any } ?? NSNull()
        ]
    }

    /// `text` trimmed and cut to at most `limit` Unicode scalars, whole characters only; nil when nothing is left.
    static func cut(_ text: String?, to limit: Int) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        var kept = ""
        var scalars = 0
        for character in trimmed {
            let count = character.unicodeScalars.count
            guard scalars + count <= limit else { break }
            kept.append(character)
            scalars += count
        }
        return kept.isEmpty ? nil : kept
    }
}

/// What one send carries: the window, and the phone's events in it.
public struct DeviceCalendarUpload: Equatable, Sendable {
    public let windowStart: Date
    public let windowEnd: Date
    /// Soonest first, each once, at most `DeviceCalendarRoutes.maxEvents`.
    public let events: [DeviceCalendarEvent]
    /// The phone's zone: every time is written with its offset.
    public let timeZone: TimeZone

    public init(windowStart: Date, windowEnd: Date, events: [DeviceCalendarEvent], timeZone: TimeZone) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        var seen = Set<String>()
        let ordered = events.sorted { ($0.start, $0.id) < ($1.start, $1.id) }.filter { seen.insert($0.id).inserted }
        self.events = Array(ordered.prefix(DeviceCalendarRoutes.maxEvents))
        self.timeZone = timeZone
    }

    /// The window sent around `now`: from midnight `daysBack` days ago to midnight `daysAhead` days after today, in
    /// `calendar` (the phone's).
    public static func window(around now: Date, in calendar: Calendar) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -DeviceCalendarRoutes.daysBack, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: DeviceCalendarRoutes.daysAhead + 1, to: today) ?? today
        return (start, end)
    }

    /// The request's body: where the events come from, the window, and the events.
    public var body: [String: Any] {
        [
            "source": "ios",
            "windowStart": CalendarInstant.format(windowStart, in: timeZone),
            "windowEnd": CalendarInstant.format(windowEnd, in: timeZone),
            "events": events.map { $0.json(in: timeZone) }
        ]
    }
}

/// The phone's events with the server: the flag's probe, a send, and forgetting them. A protocol so the app's model
/// is testable without a network.
public protocol DeviceCalendarServing: Sendable {
    /// Whether connecting is on: an empty window's read answers anything but a 404 with no code.
    func deviceEventsAvailable(now: Date) async throws -> Bool
    /// Replaces the window with the upload's events; how many the server stored. A retry of one send passes its key
    /// again.
    func putDeviceEvents(_ upload: DeviceCalendarUpload, idempotencyKey: String) async throws -> Int
    /// Forgets every event this person sent, from their agents' memory too.
    func deleteDeviceEvents() async throws
}

extension HTTPRoomCalendarClient: DeviceCalendarServing {
    /// Reads an empty window (from and to both `now`): never a PUT, so asking stores nothing.
    public func deviceEventsAvailable(now: Date) async throws -> Bool {
        let instant = CalendarInstant.format(now, in: .gmt)
        return try await probe("GET", DeviceCalendarRoutes.events,
                               query: [URLQueryItem(name: "from", value: instant),
                                       URLQueryItem(name: "to", value: instant)],
                               body: nil)
    }

    public func putDeviceEvents(_ upload: DeviceCalendarUpload, idempotencyKey: String) async throws -> Int {
        let length = idempotencyKey.utf8.count
        guard (1...128).contains(length) else { throw CalendarError.rejected }
        let answer = try await send("PUT", DeviceCalendarRoutes.events, body: upload.body,
                                    headers: ["Idempotency-Key": idempotencyKey])
        guard let stored = answer?["stored"]?.intValue else { throw CalendarError.invalidData }
        return Int(clamping: stored)
    }

    public func deleteDeviceEvents() async throws {
        _ = try await send("DELETE", DeviceCalendarRoutes.events)
    }
}
