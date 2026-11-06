import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts
import XCTest
@testable import PocketSyncClient

/// Connect my calendar against the contract of 2026-11-06 (draft 2), ticket 9583d41e. Every event here is made up.
final class DeviceCalendarClientTests: XCTestCase {
    private func client(_ handler: @escaping (CalendarRoutesURLProtocol.Seen) -> (Int, String)) -> HTTPRoomCalendarClient {
        CalendarRoutesURLProtocol.reset(handler: handler)
        return HTTPRoomCalendarClient(apiBaseURL: URL(string: "https://api.example.test"),
                                      urlSession: CalendarRoutesURLProtocol.session(), tokenProvider: { "person-token" })
    }

    private let newYork = TimeZone(identifier: "America/New_York")!

    private func instant(_ text: String) -> Date { CalendarInstant.parse(text)! }

    private var newYorkCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        return calendar
    }

    private func upload() -> DeviceCalendarUpload {
        DeviceCalendarUpload(
            windowStart: instant("2026-10-30T00:00:00-04:00"),
            windowEnd: instant("2026-12-07T00:00:00-05:00"),
            events: [
                DeviceCalendarEvent(identifier: "example-event", occurrenceStart: instant("2026-11-06T15:00:00Z"),
                                    calendar: "Work", title: "Design review", start: instant("2026-11-06T15:00:00Z"),
                                    end: instant("2026-11-06T16:00:00Z"), allDay: false, location: "Studio 2"),
                DeviceCalendarEvent(identifier: "example-day", occurrenceStart: instant("2026-11-08T05:00:00Z"),
                                    calendar: "Home", title: "Moving day", start: instant("2026-11-08T05:00:00Z"),
                                    end: instant("2026-11-09T05:00:00Z"), allDay: true, location: nil)
            ],
            timeZone: newYork
        )
    }

    // MARK: - What leaves the phone

    /// The server refuses any key outside the contract (notes, attendees, url, organizer) with 422, so each event is
    /// sent as exactly id, calendar, title, start, end, allDay and location, and the body as where it comes from, the
    /// window and the events.
    func test_each_event_is_sent_as_exactly_the_contracts_keys() async throws {
        let calendar = client { _ in (200, #"{"stored": 2}"#) }
        _ = try await calendar.putDeviceEvents(upload(), idempotencyKey: "send-1")
        let body = try XCTUnwrap(CalendarRoutesURLProtocol.requests.first?.body?.objectValue)
        XCTAssertEqual(Set(body.keys), ["source", "windowStart", "windowEnd", "events"])
        let events = try XCTUnwrap(body["events"]?.arrayValue)
        XCTAssertEqual(events.count, 2)
        for event in events {
            XCTAssertEqual(Set(try XCTUnwrap(event.objectValue).keys),
                           ["id", "calendar", "title", "start", "end", "allDay", "location"],
                           "exactly the contract's keys")
        }
        XCTAssertEqual(body["source"], .string("ios"))
        XCTAssertEqual(body["windowStart"], .string("2026-10-30T00:00:00-04:00"))
        XCTAssertEqual(body["windowEnd"], .string("2026-12-07T00:00:00-05:00"))
        XCTAssertEqual(events[0]["calendar"], .string("Work"))
        XCTAssertEqual(events[0]["title"], .string("Design review"))
        XCTAssertEqual(events[0]["start"], .string("2026-11-06T10:00:00-05:00"), "times carry the phone's offset")
        XCTAssertEqual(events[0]["end"], .string("2026-11-06T11:00:00-05:00"))
        XCTAssertEqual(events[0]["allDay"], .bool(false))
        XCTAssertEqual(events[0]["location"], .string("Studio 2"))
        XCTAssertEqual(events[1]["allDay"], .bool(true))
        XCTAssertEqual(events[1]["location"], .null, "no place is null, never left out")
    }

    /// An event's id is the lowercase hex sha256 of the phone's identifier for it and its occurrence's start in UTC, so
    /// each occurrence of a repeating event (one identifier on the phone) has its own.
    func test_an_events_id_is_the_sha256_of_its_identifier_and_its_occurrence() {
        let first = DeviceCalendarEvent.id(identifier: "example-event",
                                           occurrenceStart: instant("2026-11-06T10:00:00-05:00"))
        XCTAssertEqual(first, "679486840367784d0ce8cbbcdb1412c96c5f5a022687f3a7eacfdd19ce37d1aa")
        let nextWeek = DeviceCalendarEvent.id(identifier: "example-event",
                                              occurrenceStart: instant("2026-11-13T15:00:00Z"))
        XCTAssertEqual(nextWeek, "bad6a83831720e154925ccd0dbc30a9741f2f49418c8c912f42ae864726662f1")
        XCTAssertNotEqual(first, nextWeek, "each occurrence is its own")
    }

    /// Within the API's limits on the phone, so that one long field never has the whole window refused: titles and
    /// places at most 200 Unicode scalars and calendar names 100, whole characters only. No title is "No title".
    func test_titles_places_and_calendar_names_are_cut_to_the_apis_limits() {
        let long = String(repeating: "a", count: 250)
        // One person at a laptop, with a skin tone: one character of four Unicode scalars.
        let points: [UInt32] = [0x1F469, 0x1F3FD, 0x200D, 0x1F4BB]
        let coder = String(String.UnicodeScalarView(points.compactMap { Unicode.Scalar($0) }))
        XCTAssertEqual(coder.count, 1)
        let start = instant("2026-11-06T15:00:00Z")
        let event = DeviceCalendarEvent(identifier: "example-event", occurrenceStart: start, calendar: long,
                                        title: String(repeating: coder, count: 60), start: start,
                                        end: start.addingTimeInterval(-60), allDay: false, location: long)
        XCTAssertEqual(event.calendar.unicodeScalars.count, 100)
        XCTAssertEqual(event.location?.unicodeScalars.count, 200)
        XCTAssertEqual(event.title.unicodeScalars.count, 200)
        XCTAssertEqual(event.title.count, 50, "whole characters only")
        XCTAssertEqual(event.end, event.start, "an end before the start is the start")

        let bare = DeviceCalendarEvent(identifier: "example-event", occurrenceStart: start, calendar: " ", title: "  ",
                                       start: start, end: start, allDay: false, location: " ")
        XCTAssertEqual(bare.title, "No title")
        XCTAssertEqual(bare.calendar, "Calendar")
        XCTAssertNil(bare.location)
    }

    /// An all-day event runs from the local midnight of its first day to the local midnight after its last, which is
    /// not part of it; the phone ends one a second before midnight.
    func test_an_all_day_event_runs_from_midnight_to_the_midnight_after_its_last_day() {
        let one = DeviceCalendarEvent.allDayBounds(start: instant("2026-11-08T00:00:00-05:00"),
                                                   end: instant("2026-11-08T23:59:59-05:00"), in: newYorkCalendar)
        XCTAssertEqual(one.start, instant("2026-11-08T00:00:00-05:00"))
        XCTAssertEqual(one.end, instant("2026-11-09T00:00:00-05:00"))
        let three = DeviceCalendarEvent.allDayBounds(start: instant("2026-11-08T00:00:00-05:00"),
                                                     end: instant("2026-11-10T23:59:59-05:00"), in: newYorkCalendar)
        XCTAssertEqual(three.end, instant("2026-11-11T00:00:00-05:00"))
        let atMidnight = DeviceCalendarEvent.allDayBounds(start: instant("2026-11-08T00:00:00-05:00"),
                                                          end: instant("2026-11-09T00:00:00-05:00"), in: newYorkCalendar)
        XCTAssertEqual(atMidnight.end, instant("2026-11-09T00:00:00-05:00"), "an end at midnight stays")
        // The day the clocks go back in New York: still midnight to midnight, 25 hours.
        let longDay = DeviceCalendarEvent.allDayBounds(start: instant("2026-11-01T00:00:00-04:00"),
                                                       end: instant("2026-11-01T23:59:59-05:00"), in: newYorkCalendar)
        XCTAssertEqual(longDay.start, instant("2026-11-01T00:00:00-04:00"))
        XCTAssertEqual(longDay.end, instant("2026-11-02T00:00:00-05:00"))
    }

    /// The window is 7 days back to 30 ahead, from the phone's midnights, within the API's 60 days.
    func test_the_window_runs_from_7_days_back_to_30_days_ahead() {
        let window = DeviceCalendarUpload.window(around: instant("2026-11-06T08:40:00-05:00"), in: newYorkCalendar)
        XCTAssertEqual(window.start, instant("2026-10-30T00:00:00-04:00"))
        XCTAssertEqual(window.end, instant("2026-12-07T00:00:00-05:00"))
        XCTAssertLessThanOrEqual(window.end.timeIntervalSince(window.start), 60 * 86_400)
    }

    /// One send holds each event once, soonest first, and at most 2000 (the API's most).
    func test_a_send_holds_each_event_once_soonest_first_and_at_most_2000() {
        let base = instant("2026-11-06T00:00:00Z")
        var events = (0..<2_100).map { index -> DeviceCalendarEvent in
            let start = base.addingTimeInterval(Double(2_100 - index) * 60)
            return DeviceCalendarEvent(identifier: "event-\(index)", occurrenceStart: start, calendar: "Work",
                                       title: "Event \(index)", start: start, end: start.addingTimeInterval(1_800),
                                       allDay: false, location: nil)
        }
        events.append(events[0])
        let upload = DeviceCalendarUpload(windowStart: base, windowEnd: base.addingTimeInterval(30 * 86_400),
                                          events: events, timeZone: .gmt)
        XCTAssertEqual(upload.events.count, 2_000)
        XCTAssertEqual(Set(upload.events.map(\.id)).count, 2_000, "each once")
        XCTAssertEqual(upload.events.map(\.start), upload.events.map(\.start).sorted())
        XCTAssertEqual(upload.events.first?.start, base.addingTimeInterval(60), "the soonest first")
    }

    // MARK: - The routes

    /// A send is a PUT with its idempotency key, as the signed-in person; the server says how many it stored.
    func test_a_send_is_a_put_with_its_idempotency_key() async throws {
        let calendar = client { request in
            XCTAssertEqual(request.method, "PUT")
            XCTAssertEqual(request.path, "/api/v1/me/calendar/device-events")
            XCTAssertEqual(request.idempotencyKey, "send-7")
            XCTAssertEqual(request.authorization, "Bearer person-token")
            return (200, #"{"stored": 2, "windowStart": "2026-10-30T04:00:00Z", "windowEnd": "2026-12-07T05:00:00Z"}"#)
        }
        let stored = try await calendar.putDeviceEvents(upload(), idempotencyKey: "send-7")
        XCTAssertEqual(stored, 2)
        XCTAssertEqual(CalendarRoutesURLProtocol.requests.count, 1)
    }

    /// Forgetting is one DELETE, with no body.
    func test_forgetting_is_one_delete() async throws {
        let calendar = client { request in
            XCTAssertEqual(request.method, "DELETE")
            XCTAssertEqual(request.path, "/api/v1/me/calendar/device-events")
            return (204, "")
        }
        try await calendar.deleteDeviceEvents()
        XCTAssertEqual(CalendarRoutesURLProtocol.requests.count, 1)
        XCTAssertNil(CalendarRoutesURLProtocol.requests.first?.rawBody.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The flag's probe reads an empty window (from and to both now) and never sends a PUT: 200 is on, a 404 with no
    /// code (or the API's generic one) is off, and a 503 says neither.
    func test_the_probe_reads_an_empty_window_and_a_404_with_no_code_is_off() async throws {
        let now = instant("2026-11-06T08:40:00Z")
        var calendar = client { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.path, "/api/v1/me/calendar/device-events")
            XCTAssertEqual(request.query, ["from": "2026-11-06T08:40:00Z", "to": "2026-11-06T08:40:00Z"])
            return (200, #"{"events": []}"#)
        }
        let on = try await calendar.deviceEventsAvailable(now: now)
        XCTAssertTrue(on)

        calendar = client { request in
            XCTAssertEqual(request.method, "GET")
            return (404, "")
        }
        let off = try await calendar.deviceEventsAvailable(now: now)
        XCTAssertFalse(off, "a 404 with no code is the flag off")

        calendar = client { _ in (404, #"{"error": {"code": "HTTP_ERROR", "message": "Not found"}}"#) }
        let offGeneric = try await calendar.deviceEventsAvailable(now: now)
        XCTAssertFalse(offGeneric)

        calendar = client { _ in (503, "") }
        do {
            _ = try await calendar.deviceEventsAvailable(now: now)
            XCTFail("a 503 says neither on nor off")
        } catch {
            XCTAssertEqual(error as? CalendarError, .retryable)
        }
    }
}
