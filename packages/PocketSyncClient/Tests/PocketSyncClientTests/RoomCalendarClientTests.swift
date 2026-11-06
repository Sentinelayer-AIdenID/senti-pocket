import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts
import XCTest
@testable import PocketSyncClient

/// Answers the calendar's routes from a handler and records what was asked, query included.
final class CalendarRoutesURLProtocol: URLProtocol {
    struct Seen {
        let method: String
        let path: String
        let query: [String: String]
        let authorization: String?
        let accept: String?
        let idempotencyKey: String?
        let body: JSONValue?
        let rawBody: Data?
    }

    private static let lock = NSLock()
    private static var handler: ((Seen) -> (Int, String))?
    private static var seen: [Seen] = []

    static func reset(handler: @escaping (Seen) -> (Int, String)) {
        lock.lock()
        self.handler = handler
        seen = []
        lock.unlock()
    }

    static var requests: [Seen] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CalendarRoutesURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                bytes.append(buffer, count: read)
            }
            stream.close()
            data = bytes
        }
        var query: [String: String] = [:]
        for item in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let item = Seen(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            query: query,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            accept: request.value(forHTTPHeaderField: "Accept"),
            idempotencyKey: request.value(forHTTPHeaderField: "Idempotency-Key"),
            body: data.flatMap { $0.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: $0) },
            rawBody: data
        )
        Self.lock.lock()
        Self.seen.append(item)
        let handler = Self.handler
        Self.lock.unlock()
        let (status, text) = handler?(item) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The calendar against the contract of 2026-11-04 (brief for ticket 49119fff; the existing create route of API #1057).
/// Titles and links are made up.
final class RoomCalendarClientTests: XCTestCase {
    private let room = "room-1"

    private func client(_ handler: @escaping (CalendarRoutesURLProtocol.Seen) -> (Int, String)) -> HTTPRoomCalendarClient {
        CalendarRoutesURLProtocol.reset(handler: handler)
        return HTTPRoomCalendarClient(apiBaseURL: URL(string: "https://api.example.test"),
                                      urlSession: CalendarRoutesURLProtocol.session(), tokenProvider: { "person-token" })
    }

    private func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }

    // MARK: - One personal request

    /// #330 and #331 merged: one `send` takes a query (the calendar's reads) and extra headers (an idempotency key on
    /// folder writes) together, and an extra header never replaces the Accept or the bearer every call carries.
    func test_one_personal_request_carries_a_query_and_extra_headers_and_keeps_its_own() async throws {
        CalendarRoutesURLProtocol.reset { _ in (200, "{}") }
        let request = PersonalRequest(apiBaseURL: URL(string: "https://api.example.test"),
                                      urlSession: CalendarRoutesURLProtocol.session(), tokenProvider: { "person-token" })
        let answer = try await request.send("POST", ["api", "v1", "me", "room-folders"],
                                            query: [URLQueryItem(name: "days", value: "90")], body: ["name": "Studio"],
                                            headers: ["Idempotency-Key": "key-1", "Authorization": "Bearer someone-else",
                                                      "Accept": "text/plain"])
        XCTAssertEqual(answer.status, 200)
        let seen = try XCTUnwrap(CalendarRoutesURLProtocol.requests.first)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.path, "/api/v1/me/room-folders")
        XCTAssertEqual(seen.query, ["days": "90"], "the query is sent")
        XCTAssertEqual(seen.idempotencyKey, "key-1", "the extra header is sent")
        XCTAssertEqual(seen.authorization, "Bearer person-token", "an extra header never replaces the bearer")
        XCTAssertEqual(seen.accept, "application/json", "an extra header never replaces the Accept")
        XCTAssertEqual(seen.body, .object(["name": .string("Studio")]))
    }

    // MARK: - Reading

    func test_a_rooms_events_read_90_days_ahead_soonest_first_and_skip_what_cannot_be_shown() async throws {
        let calendar = client { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.path, "/api/v1/sessions/room-1/calendar/events")
            XCTAssertEqual(request.query["days"], "90")
            XCTAssertEqual(request.authorization, "Bearer person-token")
            return (200, """
            {"events": [
              {"id": "e2", "sessionId": "room-1", "title": "Design review", "startsAt": "2026-11-06T15:00:00+00:00",
               "endsAt": "2026-11-06T16:00:00+00:00", "link": "https://meet.example.test/x", "urgent": false},
              {"id": "e1", "sessionId": "room-1", "title": "Lunch", "startsAt": "2026-11-05T17:00:00.123456+00:00",
               "endsAt": null, "link": "http://not-https.example.test"},
              {"id": "e3", "sessionId": "room-1", "title": "Cancelled", "startsAt": "2026-11-07T15:00:00+00:00",
               "cancelledAt": "2026-11-04T10:00:00+00:00"},
              {"id": "e4", "sessionId": "room-1", "title": "No offset", "startsAt": "2026-11-07T15:00:00"},
              {"id": "e5", "sessionId": "room-1", "title": "  ", "startsAt": "2026-11-07T15:00:00Z"},
              {"id": "e2", "sessionId": "room-1", "title": "Twice", "startsAt": "2026-11-06T15:00:00+00:00"}
            ], "nextOffset": null}
            """)
        }
        let events = try await calendar.events(inRoom: room)
        XCTAssertEqual(events.map(\.id), ["e1", "e2"], "soonest first; cancelled, offset-less, untitled and repeated left out")
        XCTAssertEqual(events[0].startsAt, CalendarInstant.parse("2026-11-05T17:00:00Z"), "fractional seconds are dropped")
        XCTAssertNil(events[0].link, "only https links are kept")
        XCTAssertEqual(events[1].link?.absoluteString, "https://meet.example.test/x")
        XCTAssertEqual(events[1].endsAt, CalendarInstant.parse("2026-11-06T16:00:00Z"))
    }

    func test_the_list_follows_next_offset_and_stops_at_its_bound() async throws {
        let calendar = client { request in
            let offset = Int(request.query["offset"] ?? "0") ?? 0
            let id = "e\(offset)"
            return (200, #"{"events": [{"id": "\#(id)", "sessionId": "room-1", "title": "T", "#
                + #""startsAt": "2026-11-06T15:00:00Z"}], "nextOffset": \#(offset + 200)}"#)
        }
        let events = try await calendar.events(inRoom: room)
        XCTAssertEqual(CalendarRoutesURLProtocol.requests.map { $0.query["offset"] }, ["0", "200", "400", "600", "800"])
        XCTAssertEqual(events.count, 5)
    }

    func test_the_agenda_is_yours_across_rooms() async throws {
        let calendar = client { request in
            XCTAssertEqual(request.path, "/api/v1/me/agenda")
            return (200, #"{"events": [{"id": "e1", "sessionId": "room-2", "title": "Standup", "#
                + #""startsAt": "2026-11-05T14:00:00Z"}, {"id": "e2", "title": "No room", "startsAt": "2026-11-05T14:00:00Z"}]}"#)
        }
        let events = try await calendar.agenda()
        XCTAssertEqual(events.map(\.sessionId), ["room-2"], "an agenda event names its room, or it cannot be shown")
    }

    // MARK: - Drafting

    func test_a_draft_is_asked_for_a_day_in_the_persons_zone_and_maps_back() async throws {
        let calendar = client { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/api/v1/sessions/room-1/calendar/drafts")
            XCTAssertEqual(request.body, .object(["day": .string("2026-11-04"), "text": .string("Lunch with Sam at 1"),
                                                  "timezone": .string("America/New_York")]))
            return (200, """
            {"title": "Lunch with Sam", "startsAt": "2026-11-04T13:00:00-05:00", "endsAt": "2026-11-04T14:00:00-05:00",
             "link": "https://docs.example.test/plan", "notes": "Bring the plan", "confidence": 0.82,
             "assumptions": ["I assumed 1 PM, Eastern", "  ", "I assumed an hour"]}
            """)
        }
        let draft = try await calendar.draft(inRoom: room, .text(day: CalendarDay(year: 2026, month: 11, day: 4),
                                                                 text: "Lunch with Sam at 1", timeZone: "America/New_York"))
        XCTAssertEqual(draft.title, "Lunch with Sam")
        XCTAssertEqual(draft.startsAt, CalendarInstant.parse("2026-11-04T18:00:00Z"))
        XCTAssertEqual(draft.endsAt, CalendarInstant.parse("2026-11-04T19:00:00Z"))
        XCTAssertEqual(draft.link, "https://docs.example.test/plan")
        XCTAssertEqual(draft.notes, "Bring the plan")
        XCTAssertEqual(draft.confidence, 0.82)
        XCTAssertEqual(draft.assumptions, ["I assumed 1 PM, Eastern", "I assumed an hour"])
    }

    func test_a_draft_from_a_message_sends_its_sequence_and_reads_a_wrapped_answer() async throws {
        let calendar = client { request in
            XCTAssertEqual(request.body, .object(["sourceSequenceId": .int(42)]))
            return (200, #"{"draft": {"title": "Call", "startsAt": null, "confidence": 7, "assumptions": "no"}}"#)
        }
        let draft = try await calendar.draft(inRoom: room, .message(sourceSequenceId: 42))
        XCTAssertEqual(draft.title, "Call")
        XCTAssertNil(draft.startsAt, "no time is left empty, never guessed")
        XCTAssertNil(draft.confidence, "a confidence outside 0...1 is no confidence")
        XCTAssertEqual(draft.assumptions, [])
    }

    func test_a_draft_refuses_empty_or_overlong_text_and_an_unknown_zone_without_asking() async {
        let calendar = client { _ in XCTFail("nothing should be sent"); return (500, "") }
        let day = CalendarDay(year: 2026, month: 11, day: 4)
        for request in [CalendarDraftRequest.text(day: day, text: "  \n", timeZone: "America/New_York"),
                        .text(day: day, text: String(repeating: "a", count: 3_501), timeZone: "America/New_York"),
                        .text(day: day, text: "Lunch", timeZone: "Not/AZone")] {
            do {
                _ = try await calendar.draft(inRoom: room, request)
                XCTFail("sent \(request)")
            } catch {
                XCTAssertEqual(error as? CalendarError, .rejected)
            }
        }
        XCTAssertTrue(CalendarRoutesURLProtocol.requests.isEmpty)
    }

    /// Review P3 (#330): the API and the web take 3,500 characters; so does Pocket.
    func test_a_draft_takes_text_up_to_3500_characters_as_the_api_does() async throws {
        let text = String(repeating: "a", count: 3_500)
        let calendar = client { request in
            XCTAssertEqual(request.body?["text"]?.stringValue?.count, 3_500)
            return (200, #"{"title": "Long plan", "startsAt": null, "confidence": 0.5, "assumptions": []}"#)
        }
        let draft = try await calendar.draft(inRoom: room, .text(day: CalendarDay(year: 2026, month: 11, day: 4),
                                                                 text: text, timeZone: "America/New_York"))
        XCTAssertEqual(draft.title, "Long plan")
        XCTAssertEqual(CalendarRoutesURLProtocol.requests.count, 1, "3,500 characters are sent, not refused here")
        XCTAssertEqual(CalendarDraftRequest.maxTextLength, 3_500)
    }

    // MARK: - Saving

    /// The existing create route refuses unknown fields and has no `notes` yet: notes are not sent.
    func test_save_posts_the_existing_create_body_with_offsets_in_the_persons_zone() async throws {
        let calendar = client { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/api/v1/sessions/room-1/calendar/events")
            XCTAssertEqual(request.body, .object([
                "title": .string("Lunch with Sam"),
                "startsAt": .string("2026-11-04T13:00:00-05:00"),
                "endsAt": .string("2026-11-04T14:00:00-05:00"),
                "link": .string("https://docs.example.test/plan")
            ]))
            return (201, """
            {"id": "e9", "sessionId": "room-1", "title": "Lunch with Sam", "startsAt": "2026-11-04T18:00:00+00:00",
             "endsAt": "2026-11-04T19:00:00+00:00", "link": "https://docs.example.test/plan", "urgent": false,
             "revision": 1, "cancelledAt": null}
            """)
        }
        let saved = try await calendar.save(CalendarEventCreate(
            title: "Lunch with Sam",
            startsAt: CalendarInstant.parse("2026-11-04T18:00:00Z")!,
            endsAt: CalendarInstant.parse("2026-11-04T19:00:00Z")!,
            link: URL(string: "https://docs.example.test/plan"),
            notes: "Bring the plan",
            timeZone: zone("America/New_York")
        ), inRoom: room)
        XCTAssertEqual(saved.id, "e9")
        XCTAssertEqual(saved.startsAt, CalendarInstant.parse("2026-11-04T13:00:00-05:00"))
    }

    func test_save_leaves_out_what_is_empty() {
        let body = CalendarEventCreate(title: "Dentist", startsAt: Date(timeIntervalSince1970: 1_800_000_000), endsAt: nil,
                                       link: nil, notes: "Bring the card", timeZone: zone("Asia/Kolkata")).body
        XCTAssertEqual(Set(body.keys), ["title", "startsAt"])
        XCTAssertEqual(body["startsAt"] as? String, "2027-01-15T13:30:00+05:30")
    }

    // MARK: - Status codes

    func test_statuses_map_to_what_the_app_does() async {
        let cases: [(Int, String, CalendarError)] = [
            (404, "HTTP_ERROR", .unavailable), (404, "CALENDAR_ERROR", .notFound),
            (403, "CALENDAR_ERROR", .forbidden), (400, "CALENDAR_ERROR", .rejected),
            (422, "CALENDAR_ERROR", .rejected), (429, "RATE_LIMITED", .rateLimited), (429, "CALENDAR_ERROR", .dailyLimit),
            (401, "CALENDAR_ERROR", .reauthenticationRequired), (503, "CALENDAR_ERROR", .retryable)
        ]
        for (status, code, expected) in cases {
            let calendar = client { _ in (status, #"{"detail": {"error": {"code": "\#(code)"}}}"#) }
            do {
                _ = try await calendar.events(inRoom: room)
                XCTFail("\(status) answered events")
            } catch {
                XCTAssertEqual(error as? CalendarError, expected, "\(status)")
            }
        }
    }

    /// A draft answered 429 with `body`, and the error it read as.
    private func draftError(on429 body: String) async -> CalendarError? {
        let calendar = client { _ in (429, body) }
        do {
            _ = try await calendar.draft(inRoom: room, .text(day: CalendarDay(year: 2026, month: 11, day: 6),
                                                             text: "Lunch", timeZone: "America/New_York"))
            XCTFail("a draft from a 429")
            return nil
        } catch {
            return error as? CalendarError
        }
    }

    /// Review P2 (#330): the API's own rate limit is "too many just now", not today's cap.
    func test_a_429_rate_limited_is_too_many_just_now() async {
        let error = await draftError(on429: #"{"error": {"code": "RATE_LIMITED", "message": "Slow down."}}"#)
        XCTAssertEqual(error, .rateLimited, "RATE_LIMITED is not the daily cap")
    }

    /// Review P2 (#330): a 429 from an edge or a proxy carries no calendar code (no body, or not the API's envelope):
    /// it must not tell the person they have used today's drafts.
    func test_a_429_with_no_code_is_too_many_just_now() async {
        for body in ["", #"{"detail": "Too Many Requests"}"#, "<html>429</html>"] {
            let error = await draftError(on429: body)
            XCTAssertEqual(error, .rateLimited, "a 429 with no code read as the daily cap: \(body.isEmpty ? "no body" : body)")
        }
    }

    /// Review P2 (#330): only the API's calendar code on a 429 is a daily cap.
    func test_a_429_calendar_error_is_the_daily_cap() async {
        for body in [#"{"error": {"code": "CALENDAR_ERROR", "message": "Calendar draft daily limit exceeded"}}"#,
                     #"{"detail": {"error": {"code": "CALENDAR_ERROR"}}}"#] {
            let error = await draftError(on429: body)
            XCTAssertEqual(error, .dailyLimit, "CALENDAR_ERROR on a 429 is today's cap: \(body)")
        }
    }

    func test_error_codes_are_read_at_the_top_and_under_detail() {
        func code(_ text: String) -> String? {
            HTTPRoomCalendarClient.errorCode(try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
        }
        XCTAssertEqual(code(#"{"error": {"code": "A"}}"#), "A")
        XCTAssertEqual(code(#"{"detail": {"error": {"code": "B"}}}"#), "B")
        XCTAssertEqual(code(#"{"detail": {"code": "C"}}"#), "C")
        XCTAssertNil(code(#"{"detail": "Not Found"}"#))
    }

    // MARK: - Flags

    /// Web review of the same API (#746), checked against the API's handler (#1150 at 7484c8c,
    /// `http_exception_handler`): a flag off raises `HTTPException(404, "Not found")`, which the handler writes as
    /// `{"error": {"code": "HTTP_ERROR"}}`; an unknown path is Starlette's `{"detail": "Not Found"}`; a real calendar
    /// not-found is `{"error": {"code": "CALENDAR_ERROR"}}`. Only the first two are "off". The exact bodies:
    func test_a_404_is_off_only_without_a_calendar_code() async throws {
        let off = [
            #"{"error": {"code": "HTTP_ERROR", "message": "Not found", "request_id": "req-1"}}"#,
            #"{"detail": "Not Found"}"#,
            "",
            #"{"detail": {"error": {"code": "HTTP_ERROR", "message": "Not found"}}}"#,
        ]
        let found = [
            #"{"error": {"code": "CALENDAR_ERROR", "message": "Calendar feed not found", "request_id": "req-2"}}"#,
            #"{"detail": {"error": {"code": "CALENDAR_ERROR", "message": "Calendar event not found"}}}"#,
        ]
        for body in off {
            var calendar = client { _ in (404, body) }
            let drafts = try await calendar.draftsAvailable(inRoom: room)
            XCTAssertFalse(drafts, "drafting reads as off for \(body)")
            calendar = client { _ in (404, body) }
            let feed = try await calendar.feedAvailable()
            XCTAssertFalse(feed, "the feed reads as off for \(body)")
            calendar = client { _ in (404, body) }
            do {
                _ = try await calendar.events(inRoom: room)
                XCTFail("events read from a 404")
            } catch {
                XCTAssertEqual(error as? CalendarError, .unavailable, body)
            }
        }
        for body in found {
            var calendar = client { _ in (404, body) }
            let drafts = try await calendar.draftsAvailable(inRoom: room)
            XCTAssertTrue(drafts, "a calendar not-found means the route is there: \(body)")
            calendar = client { _ in (404, body) }
            let feed = try await calendar.feedAvailable()
            XCTAssertTrue(feed, "a calendar not-found means the route is there: \(body)")
            calendar = client { _ in (404, body) }
            do {
                _ = try await calendar.newSubscriptionLink()
                XCTFail("a link from a 404")
            } catch {
                XCTAssertEqual(error as? CalendarError, .notFound, body)
            }
        }
    }

    func test_drafting_is_off_only_on_a_404_and_the_probe_sends_an_empty_body() async throws {
        for (status, on) in [(404, false), (422, true), (400, true), (403, true), (429, true), (200, true)] {
            let calendar = client { request in
                XCTAssertEqual(request.method, "POST")
                XCTAssertEqual(request.path, "/api/v1/sessions/room-1/calendar/drafts")
                XCTAssertEqual(request.body, .object([:]), "an empty body: no model runs")
                return (status, #"{"detail":"Not Found"}"#)
            }
            let available = try await calendar.draftsAvailable(inRoom: room)
            XCTAssertEqual(available, on, "\(status)")
        }
    }

    /// The feed route takes only its own token, as calendar apps send it: the probe sends no token and no bearer
    /// (review P3, #330; the web sends none either). A 401 there is the missing token refused, not a signed-out
    /// person: it reads as on.
    func test_the_feed_is_off_only_on_a_404_and_the_probe_carries_no_token_and_no_credential() async throws {
        for (status, on) in [(404, false), (422, true), (403, true), (401, true)] {
            let calendar = client { request in
                XCTAssertEqual(request.method, "GET")
                XCTAssertEqual(request.path, "/api/v1/me/calendar.ics")
                XCTAssertTrue(request.query.isEmpty)
                XCTAssertNil(request.authorization, "the probe sends no Authorization header")
                return (status, "")
            }
            let available = try await calendar.feedAvailable()
            XCTAssertEqual(available, on, "\(status)")
        }
        let calendar = client { _ in (503, "") }
        do {
            _ = try await calendar.feedAvailable()
            XCTFail("a 503 decided the feed")
        } catch {
            XCTAssertEqual(error as? CalendarError, .retryable)
        }
    }

    func test_an_unknown_answer_on_a_probe_is_not_taken_as_off_or_on() async {
        let calendar = client { _ in (503, "") }
        do {
            _ = try await calendar.draftsAvailable(inRoom: room)
            XCTFail("a 503 decided the flag")
        } catch {
            XCTAssertEqual(error as? CalendarError, .retryable)
        }
    }

    // MARK: - Subscribe

    /// The link is the server's `url` (review P3, #330), opened as webcal: the API answers
    /// `{"token": ..., "url": "https://<api>/api/v1/me/calendar.ics?token=..."}`.
    func test_the_subscribe_link_is_the_servers_url_as_webcal() async throws {
        let calendar = client { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/api/v1/me/calendar-feed-token")
            XCTAssertNil(request.body, "a new link is a POST with no body")
            return (200, #"{"token": "made-up-value", "url": "https://api.example.test/api/v1/me/calendar.ics?token=made%2Bup%2Ffeed%3Dvalue"}"#)
        }
        let link = try await calendar.newSubscriptionLink()
        XCTAssertEqual(link.url.absoluteString, "webcal://api.example.test/api/v1/me/calendar.ics?token=made%2Bup%2Ffeed%3Dvalue",
                       "the server's url, not one built from the token field")
        let parsed = URLComponents(url: link.url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(parsed?.queryItems?.first { $0.name == "token" }?.value, "made+up/feed=value", "reads back exactly")
    }

    /// The `url` is a server value: anything but https on the API's own host, port and feed path, with one token in
    /// the query, is refused and no link is made.
    func test_a_server_url_that_is_not_the_feed_on_the_api_host_is_refused() async {
        let refused = [
            "http://api.example.test/api/v1/me/calendar.ics?token=abc",
            "https://elsewhere.example.test/api/v1/me/calendar.ics?token=abc",
            "https://api.example.test.elsewhere.test/api/v1/me/calendar.ics?token=abc",
            "https://api.example.test:8443/api/v1/me/calendar.ics?token=abc",
            "https://user@api.example.test/api/v1/me/calendar.ics?token=abc",
            "https://api.example.test/api/v1/me/other.ics?token=abc",
            "https://api.example.test/api/v1/me/calendar.ics",
            "https://api.example.test/api/v1/me/calendar.ics?token=",
            "https://api.example.test/api/v1/me/calendar.ics?token=abc&next=https://elsewhere.example.test",
            "https://api.example.test/api/v1/me/calendar.ics?token=abc#fragment",
            "javascript:alert(1)",
        ]
        for url in refused {
            XCTAssertNil(CalendarSubscriptionLink.make(apiBaseURL: URL(string: "https://api.example.test"), feedURL: url), url)
        }
        XCTAssertNil(CalendarSubscriptionLink.make(apiBaseURL: URL(string: "https://api.example.test"), feedURL: nil))
        XCTAssertNil(CalendarSubscriptionLink.make(apiBaseURL: nil,
                                                   feedURL: "https://api.example.test/api/v1/me/calendar.ics?token=abc"))
        XCTAssertNotNil(CalendarSubscriptionLink.make(apiBaseURL: URL(string: "https://API.example.test"),
                                                      feedURL: "https://api.example.test/api/v1/me/calendar.ics?token=abc"))
        for body in [#"{"token": "abc"}"#, #"{"token": "abc", "url": "https://elsewhere.example.test/feed"}"#] {
            let calendar = client { _ in (200, body) }
            let made = try? await calendar.newSubscriptionLink()
            XCTAssertNil(made, body)
        }
    }

    /// A link kept in the Keychain is checked again before it is opened: webcal, on the API host, the feed path.
    func test_a_kept_link_is_checked_before_it_is_opened() {
        let calendar = client { _ in XCTFail("checking a kept link asks nothing"); return (500, "") }
        let kept = "webcal://api.example.test/api/v1/me/calendar.ics?token=abc"
        XCTAssertEqual(calendar.keptLink(URL(string: kept)!)?.url.absoluteString, kept)
        for other in ["webcal://elsewhere.example.test/api/v1/me/calendar.ics?token=abc",
                      "https://api.example.test/api/v1/me/calendar.ics?token=abc",
                      "webcal://api.example.test/api/v1/me/other.ics?token=abc"] {
            XCTAssertNil(calendar.keptLink(URL(string: other)!), other)
        }
        XCTAssertTrue(CalendarRoutesURLProtocol.requests.isEmpty)
    }

    func test_the_link_never_describes_its_token() throws {
        let feedValue = "made-up-feed-value"
        let link = try XCTUnwrap(CalendarSubscriptionLink.make(
            apiBaseURL: URL(string: "https://api.example.test"),
            feedURL: "https://api.example.test/api/v1/me/calendar.ics?token=\(feedValue)"))
        var dumped = ""
        dump(link, to: &dumped)
        for text in [String(describing: link), String(reflecting: link), "\(link)", dumped] {
            XCTAssertFalse(text.contains(feedValue), text)
        }
    }

    // MARK: - Days and instants

    func test_a_day_is_the_day_in_the_persons_zone() {
        let instant = CalendarInstant.parse("2026-11-05T03:30:00Z")!
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = zone("America/New_York")
        var kolkata = Calendar(identifier: .gregorian)
        kolkata.timeZone = zone("Asia/Kolkata")
        XCTAssertEqual(CalendarDay(instant, in: newYork).key, "2026-11-04")
        XCTAssertEqual(CalendarDay(instant, in: kolkata).key, "2026-11-05")
    }

    /// America/New_York around the 2026-11-01 fall-back and the 2027-03-14 spring-forward (review P3, #330): the
    /// written offset follows the instant, and the day is New York's.
    func test_times_keep_the_right_offset_across_the_clock_changes() {
        let newYorkZone = zone("America/New_York")
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = newYorkZone
        // 1:30 happens twice on 2026-11-01: first in EDT (05:30Z), then in EST (06:30Z).
        XCTAssertEqual(CalendarInstant.format(CalendarInstant.parse("2026-11-01T05:30:00Z")!, in: newYorkZone),
                       "2026-11-01T01:30:00-04:00")
        XCTAssertEqual(CalendarInstant.format(CalendarInstant.parse("2026-11-01T06:30:00Z")!, in: newYorkZone),
                       "2026-11-01T01:30:00-05:00")
        XCTAssertEqual(CalendarInstant.parse("2026-11-01T01:30:00-05:00")!.timeIntervalSince(
            CalendarInstant.parse("2026-11-01T01:30:00-04:00")!), 3_600, "the two 1:30s are an hour apart")
        XCTAssertEqual(CalendarDay(CalendarInstant.parse("2026-11-01T06:30:00Z")!, in: newYork).key, "2026-11-01")
        // 2:30 does not exist on 2027-03-14: 07:30Z is 3:30 EDT.
        XCTAssertEqual(CalendarInstant.format(CalendarInstant.parse("2027-03-14T07:30:00Z")!, in: newYorkZone),
                       "2027-03-14T03:30:00-04:00")
        XCTAssertEqual(CalendarInstant.format(CalendarInstant.parse("2027-03-14T06:30:00Z")!, in: newYorkZone),
                       "2027-03-14T01:30:00-05:00")
        let body = CalendarEventCreate(title: "Late show", startsAt: CalendarInstant.parse("2026-11-01T05:30:00Z")!,
                                       endsAt: CalendarInstant.parse("2026-11-01T07:00:00Z")!, link: nil, notes: nil,
                                       timeZone: newYorkZone).body
        XCTAssertEqual(body["startsAt"] as? String, "2026-11-01T01:30:00-04:00")
        XCTAssertEqual(body["endsAt"] as? String, "2026-11-01T02:00:00-05:00", "the end is after the clocks went back")
    }

    func test_instants_need_an_offset() {
        XCTAssertNotNil(CalendarInstant.parse("2026-11-04T13:00:00-05:00"))
        XCTAssertNotNil(CalendarInstant.parse("2026-11-04T13:00:00Z"))
        XCTAssertNotNil(CalendarInstant.parse("2026-11-04T13:00:00.5+00:00"))
        XCTAssertNil(CalendarInstant.parse("2026-11-04T13:00:00"))
        XCTAssertNil(CalendarInstant.parse("tomorrow"))
        XCTAssertNil(CalendarInstant.parse(nil))
    }
}
