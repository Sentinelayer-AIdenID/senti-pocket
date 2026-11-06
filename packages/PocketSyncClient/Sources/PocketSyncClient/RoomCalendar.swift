import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts

// The calendar (ticket 49119fff), built against the contract of 2026-11-04, before its API change exists:
// - a room's events are the live `/sessions/{id}/calendar/events` (list: upcoming only, at most 90 days ahead; create:
//   `{title, startsAt, endsAt?, link?}` with explicit offsets);
// - a draft is `POST /sessions/{id}/calendar/drafts` (flag CALENDAR_DRAFTS_ENABLED) and is never saved by the server;
// - the subscribe link is `POST /me/calendar-feed-token` (every call makes a new token; the old link stops working)
//   and `GET /me/calendar.ics?token=` (flag CALENDAR_FEED_ENABLED).
// With a flag off its routes answer 404 with no code or the API's generic `HTTP_ERROR`, and the app shows nothing of
// what they do; a 404 with a calendar code (`CALENDAR_ERROR`: no such event or feed token) is a real not-found.
// Every path is in `CalendarRoutes`, so a route that lands differently changes there.

/// The calendar's routes under the API origin.
public enum CalendarRoutes {
    public static func events(_ sessionId: String) -> [String] {
        ["api", "v1", "sessions", sessionId, "calendar", "events"]
    }

    public static func drafts(_ sessionId: String) -> [String] {
        ["api", "v1", "sessions", sessionId, "calendar", "drafts"]
    }

    public static let agenda = ["api", "v1", "me", "agenda"]
    public static let feedToken = ["api", "v1", "me", "calendar-feed-token"]
    public static let feed = ["api", "v1", "me", "calendar.ics"]
    public static let feedTokenQuery = "token"
    /// How far ahead the lists read: the API's most.
    public static let daysAhead = 90
    static let pageSize = 200
    static let maxPages = 5
}

/// A day in someone's calendar, without a time: what a tap on the grid means, and the draft's `day`.
public struct CalendarDay: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `calendar` (its time zone decides).
    public init(_ date: Date, in calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// `YYYY-MM-DD`.
    public var key: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Midnight at the start of the day in `calendar`.
    public func start(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// ISO 8601 instants as the API writes and takes them: always with an offset.
public enum CalendarInstant {
    /// An instant with an explicit offset (`Z` or `±hh:mm`); fractional seconds are allowed and dropped. A time with
    /// no offset is refused: it means nothing without one.
    public static func parse(_ text: String?) -> Date? {
        guard var text = text?.trimmingCharacters(in: .whitespaces), text.count <= 64 else { return nil }
        if let dot = text.firstIndex(of: "."), let end = text[dot...].dropFirst().firstIndex(where: { !$0.isNumber }),
           text.distance(from: dot, to: end) > 1 {
            text.removeSubrange(dot..<end)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// `date` written in `timeZone`, with its offset, to the second (`2026-11-04T13:00:00-05:00`).
    public static func format(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}

/// One scheduled event, as the API returns it (its times are UTC instants; show them in the person's zone).
public struct CalendarEvent: Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let title: String
    public let startsAt: Date
    public let endsAt: Date?
    public let link: URL?
    public let notes: String?

    public init(id: String, sessionId: String, title: String, startsAt: Date, endsAt: Date? = nil, link: URL? = nil,
                notes: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.link = link
        self.notes = notes
    }

    /// An event needs an id, a title and a start with an offset. A cancelled one is not shown. A link is kept only if
    /// it is https.
    init?(json: JSONValue?, sessionId fallback: String? = nil) {
        guard let json, let id = json["id"]?.stringValue, !id.isEmpty, id.utf8.count <= 128,
              let title = json["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let startsAt = CalendarInstant.parse(json["startsAt"]?.stringValue),
              let sessionId = json["sessionId"]?.stringValue ?? fallback, PersonalRequest.isIdentifier(sessionId)
        else { return nil }
        if let cancelled = json["cancelledAt"], cancelled != .null { return nil }
        let endsAt = CalendarInstant.parse(json["endsAt"]?.stringValue).flatMap { $0 > startsAt ? $0 : nil }
        self.init(id: id, sessionId: sessionId, title: String(title.prefix(200)), startsAt: startsAt, endsAt: endsAt,
                  link: CalendarLink.https(json["link"]?.stringValue), notes: json["notes"]?.stringValue)
    }
}

/// Links the calendar keeps: https only, as the API takes them.
public enum CalendarLink {
    public static func https(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.utf8.count <= 2_048,
              let url = URL(string: text), url.scheme?.lowercased() == "https", url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

/// What a draft is asked from: words typed for a day, or a message in the room.
public enum CalendarDraftRequest: Equatable, Sendable {
    case text(day: CalendarDay, text: String, timeZone: String)
    case message(sourceSequenceId: Int64)

    /// The most a typed description may be.
    public static let maxTextLength = 3_500

    var body: [String: Any] {
        switch self {
        case .text(let day, let text, let timeZone):
            return ["day": day.key, "text": text, "timezone": timeZone]
        case .message(let sequence):
            return ["sourceSequenceId": sequence]
        }
    }
}

/// An unsaved event the model drafted. Nothing about it is saved until the person saves the form made from it.
public struct CalendarDraft: Equatable, Sendable {
    public let title: String
    /// Nil when the model gave no time it could stand behind.
    public let startsAt: Date?
    public let endsAt: Date?
    public let link: String?
    public let notes: String?
    /// 0...1; nil when the server gave none.
    public let confidence: Double?
    /// What the model assumed, in plain words ("I assumed 1 PM, Eastern").
    public let assumptions: [String]

    public init(title: String, startsAt: Date?, endsAt: Date? = nil, link: String? = nil, notes: String? = nil,
                confidence: Double? = nil, assumptions: [String] = []) {
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.link = link
        self.notes = notes
        self.confidence = confidence
        self.assumptions = assumptions
    }

    /// The draft at the top of the answer or under `draft`. It needs a title; the rest may be missing.
    init?(json: JSONValue?) {
        guard let json, let title = json["title"]?.stringValue else { return nil }
        let startsAt = CalendarInstant.parse(json["startsAt"]?.stringValue)
        var endsAt = CalendarInstant.parse(json["endsAt"]?.stringValue)
        if let start = startsAt, let end = endsAt, end <= start { endsAt = nil }
        let confidence = json["confidence"]?.doubleValue.flatMap { (0...1).contains($0) ? $0 : nil }
        let assumptions = (json["assumptions"]?.arrayValue ?? [])
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(12)
            .map { String($0.prefix(300)) }
        self.init(
            title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
            startsAt: startsAt,
            endsAt: endsAt,
            link: json["link"]?.stringValue,
            notes: json["notes"]?.stringValue,
            confidence: confidence,
            assumptions: Array(assumptions)
        )
    }
}

/// An event to save, as the person left the form. Its times are written in the person's zone, with the offset.
public struct CalendarEventCreate: Equatable, Sendable {
    public let title: String
    public let startsAt: Date
    public let endsAt: Date?
    public let link: URL?
    public let notes: String?
    public let timeZone: TimeZone

    public init(title: String, startsAt: Date, endsAt: Date?, link: URL?, notes: String?, timeZone: TimeZone) {
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.link = link
        self.notes = notes
        self.timeZone = timeZone
    }

    /// Whether a saved event keeps its notes. The create route takes no `notes` yet (its body refuses unknown fields),
    /// so sending them would refuse every save; the form says notes stay in the draft. On when the API stores them.
    public static let savesNotes = false

    /// The create body. Empty fields are left out, so an event without an end or a link saves as the API expects.
    public var body: [String: Any] {
        var body: [String: Any] = ["title": title, "startsAt": CalendarInstant.format(startsAt, in: timeZone)]
        if let endsAt { body["endsAt"] = CalendarInstant.format(endsAt, in: timeZone) }
        if let link { body["link"] = link.absoluteString }
        if Self.savesNotes, let notes, !notes.isEmpty { body["notes"] = notes }
        return body
    }
}

/// The link Apple Calendar subscribes to. It carries the person's feed token, so it never describes itself: the
/// only places it goes are the URL handed to the system to open and the person's own Keychain item.
public struct CalendarSubscriptionLink: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    /// `webcal://<api host>/api/v1/me/calendar.ics?token=…`, to open and nothing else.
    public let url: URL

    init(url: URL) {
        self.url = url
    }

    /// The webcal link for the feed URL the server gave (`url` in the token route's answer). It is a server value, so
    /// it is checked: https, on the API's own host and port, the feed's path, a token in the query, nothing else.
    public static func make(apiBaseURL: URL?, feedURL: String?) -> CalendarSubscriptionLink? {
        feed(feedURL, scheme: "https", apiBaseURL: apiBaseURL)
    }

    /// A link kept from before (the person's Keychain item), checked as when it was made, or nil.
    public static func kept(_ url: URL, apiBaseURL: URL?) -> CalendarSubscriptionLink? {
        feed(url.absoluteString, scheme: "webcal", apiBaseURL: apiBaseURL)
    }

    private static func feed(_ text: String?, scheme: String, apiBaseURL: URL?) -> CalendarSubscriptionLink? {
        guard let text, text.utf8.count <= 2_048,
              let origin = HTTPSessionTransport.validOrigin(apiBaseURL),
              let api = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              var feed = URLComponents(string: text),
              feed.scheme?.lowercased() == scheme,
              let host = feed.host?.lowercased(), host == api.host?.lowercased(),
              feed.port == api.port, feed.user == nil, feed.password == nil, feed.fragment == nil,
              feed.percentEncodedPath == "/" + CalendarRoutes.feed.joined(separator: "/"),
              let items = feed.queryItems, items.count == 1, items[0].name == CalendarRoutes.feedTokenQuery,
              let token = items[0].value, !token.isEmpty
        else { return nil }
        feed.scheme = "webcal"
        return feed.url.map(CalendarSubscriptionLink.init(url:))
    }

    public var description: String { "CalendarSubscriptionLink(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

public enum CalendarError: Error, Equatable, Sendable {
    /// 404 with no code or `HTTP_ERROR`: the flag is off (or the route is not there yet). Everything about it hides.
    case unavailable
    /// 404 with any other code (`CALENDAR_ERROR`): the route is there, the thing asked for is not.
    case notFound
    /// 403: not something this person may do in this room.
    case forbidden
    /// 400 or 422: the server refused what was sent.
    case rejected
    /// 429 `RATE_LIMITED` or with no code (an edge, a proxy): too many requests just now.
    case rateLimited
    /// 429 `CALENDAR_ERROR`: a daily cap (drafts, or new events per room or per person).
    case dailyLimit
    case reauthenticationRequired
    case notConfigured
    case retryable
    case invalidData
    case accountChanged
}

/// The calendar as the signed-in person. A protocol so the app's models are testable without a network, and so a route
/// that lands differently changes in one place.
public protocol RoomCalendarServing: Sendable {
    /// Whether drafting is on: the drafts route answers something other than 404.
    func draftsAvailable(inRoom sessionId: String) async throws -> Bool
    /// The room's upcoming events, soonest first.
    func events(inRoom sessionId: String) async throws -> [CalendarEvent]
    /// Your upcoming events across your rooms, soonest first.
    func agenda() async throws -> [CalendarEvent]
    /// A draft; nothing is saved.
    func draft(inRoom sessionId: String, _ request: CalendarDraftRequest) async throws -> CalendarDraft
    /// Saves the event in the room (the existing create route).
    func save(_ event: CalendarEventCreate, inRoom sessionId: String) async throws -> CalendarEvent
}

/// The subscribe link for Apple Calendar.
public protocol CalendarFeedServing: Sendable {
    /// Whether the feed is on: its route answers something other than 404.
    func feedAvailable() async throws -> Bool
    /// A link with a new feed token. Every call makes a new one, and a calendar subscribed to an older link stops
    /// updating: the app keeps the link it made and asks before making another.
    func newSubscriptionLink() async throws -> CalendarSubscriptionLink
    /// A link kept from before, checked again as a link this client makes (the feed on this API's host), or nil.
    func keptLink(_ url: URL) -> CalendarSubscriptionLink?
}

public final class HTTPRoomCalendarClient: RoomCalendarServing, CalendarFeedServing, @unchecked Sendable {
    private let request: PersonalRequest
    private let apiBaseURL: URL?
    private let urlSession: URLSession

    public init(apiBaseURL: URL?, urlSession: URLSession, tokenProvider: @escaping @Sendable () -> String?) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        request = PersonalRequest(apiBaseURL: apiBaseURL, urlSession: urlSession, tokenProvider: tokenProvider)
    }

    /// Asks the drafts route with an empty body. The flag is the route's first check (as the API's other flagged
    /// routes do it), so off answers 404 before anything else and on refuses the empty body: no model runs.
    public func draftsAvailable(inRoom sessionId: String) async throws -> Bool {
        guard PersonalRequest.isIdentifier(sessionId) else { throw CalendarError.rejected }
        return try await probe("POST", CalendarRoutes.drafts(sessionId), body: [:])
    }

    public func events(inRoom sessionId: String) async throws -> [CalendarEvent] {
        guard PersonalRequest.isIdentifier(sessionId) else { throw CalendarError.rejected }
        return try await list(CalendarRoutes.events(sessionId), room: sessionId)
    }

    public func agenda() async throws -> [CalendarEvent] {
        try await list(CalendarRoutes.agenda, room: nil)
    }

    public func draft(inRoom sessionId: String, _ draftRequest: CalendarDraftRequest) async throws -> CalendarDraft {
        guard PersonalRequest.isIdentifier(sessionId) else { throw CalendarError.rejected }
        if case .text(_, let text, let zone) = draftRequest {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= CalendarDraftRequest.maxTextLength, TimeZone(identifier: zone) != nil
            else { throw CalendarError.rejected }
        }
        let answer = try await send("POST", CalendarRoutes.drafts(sessionId), body: draftRequest.body)
        guard let draft = CalendarDraft(json: answer?["draft"] ?? answer) else { throw CalendarError.invalidData }
        return draft
    }

    public func save(_ event: CalendarEventCreate, inRoom sessionId: String) async throws -> CalendarEvent {
        guard PersonalRequest.isIdentifier(sessionId) else { throw CalendarError.rejected }
        let answer = try await send("POST", CalendarRoutes.events(sessionId), body: event.body)
        guard let saved = CalendarEvent(json: answer?["event"] ?? answer, sessionId: sessionId) else {
            throw CalendarError.invalidData
        }
        return saved
    }

    /// Asks the feed with no token and no credential (the route takes only its own token, as calendar apps send it):
    /// off answers 404, on refuses the missing token (422, or a 401). No answer, or a 5xx, says neither.
    public func feedAvailable() async throws -> Bool {
        guard let origin = HTTPSessionTransport.validOrigin(apiBaseURL) else { throw CalendarError.notConfigured }
        let url: URL
        do {
            url = try HTTPSessionTransport.makeURL(baseURL: origin, path: CalendarRoutes.feed, query: [])
        } catch {
            throw CalendarError.notConfigured
        }
        var probe = URLRequest(url: url)
        probe.httpMethod = "GET"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: probe)
        } catch {
            throw CalendarError.retryable
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw CalendarError.retryable }
        switch status {
        case 404:
            let json = data.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: data)
            return !Self.isFlagOff(json)
        case 408, 425, 500..<600: throw CalendarError.retryable
        default: return true
        }
    }

    public func newSubscriptionLink() async throws -> CalendarSubscriptionLink {
        let answer = try await send("POST", CalendarRoutes.feedToken)
        guard let link = CalendarSubscriptionLink.make(apiBaseURL: apiBaseURL, feedURL: answer?["url"]?.stringValue)
        else { throw CalendarError.invalidData }
        return link
    }

    public func keptLink(_ url: URL) -> CalendarSubscriptionLink? {
        CalendarSubscriptionLink.kept(url, apiBaseURL: apiBaseURL)
    }

    /// A 404 is the flag off (or no such route) when it carries no code or the API's generic `HTTP_ERROR` (what its
    /// handler writes for `HTTPException(404, "Not found")` and for an unknown path); any other code means the route
    /// answered.
    static func isFlagOff(_ json: JSONValue?) -> Bool {
        let code = errorCode(json)
        return code == nil || code == "HTTP_ERROR"
    }

    /// A 429 is a daily cap only with the API's calendar code.
    static func isDailyCap(_ json: JSONValue?) -> Bool {
        errorCode(json) == "CALENDAR_ERROR"
    }

    /// The error's code, at the top (`{"error": {"code": ...}}`) or under FastAPI's `detail`.
    static func errorCode(_ json: JSONValue?) -> String? {
        json?["error"]?["code"]?.stringValue
            ?? json?["detail"]?["error"]?["code"]?.stringValue
            ?? json?["detail"]?["code"]?.stringValue
    }

    private func list(_ path: [String], room: String?) async throws -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        var seen = Set<String>()
        var offset = 0
        for _ in 0..<CalendarRoutes.maxPages {
            let query = [URLQueryItem(name: "days", value: String(CalendarRoutes.daysAhead)),
                         URLQueryItem(name: "limit", value: String(CalendarRoutes.pageSize)),
                         URLQueryItem(name: "offset", value: String(offset))]
            let answer = try await send("GET", path, query: query)
            guard let rows = answer?["events"]?.arrayValue else { throw CalendarError.invalidData }
            for event in rows.compactMap({ CalendarEvent(json: $0, sessionId: room) })
            where seen.insert(event.id).inserted {
                events.append(event)
            }
            guard let next = answer?["nextOffset"]?.intValue.map({ Int(clamping: $0) }), next > offset, next <= 10_000
            else { break }
            offset = next
        }
        return events.sorted { ($0.startsAt, $0.id) < ($1.startsAt, $1.id) }
    }

    /// Whether a flagged route is there: anything but a 404 with no code (`unavailable`) says it is.
    func probe(_ method: String, _ path: [String], query: [URLQueryItem] = [],
               body: [String: Any]?) async throws -> Bool {
        do {
            _ = try await send(method, path, query: query, body: body)
            return true
        } catch CalendarError.unavailable {
            return false
        } catch CalendarError.notFound, CalendarError.forbidden, CalendarError.rejected, CalendarError.rateLimited,
                CalendarError.dailyLimit {
            return true
        }
    }

    func send(_ method: String, _ path: [String], query: [URLQueryItem] = [], body: [String: Any]? = nil,
              headers: [String: String] = [:]) async throws -> JSONValue? {
        let answer: PersonalRequest.Answer
        do {
            answer = try await request.send(method, path, query: query, body: body, headers: headers)
        } catch PersonalRequest.Failure.notConfigured {
            throw CalendarError.notConfigured
        } catch PersonalRequest.Failure.notLoggedIn {
            throw CalendarError.reauthenticationRequired
        } catch PersonalRequest.Failure.accountChanged {
            throw CalendarError.accountChanged
        } catch PersonalRequest.Failure.invalidRequest {
            throw CalendarError.rejected
        } catch {
            throw CalendarError.retryable
        }
        switch answer.status {
        case 200..<300: return answer.json
        case 401: throw CalendarError.reauthenticationRequired
        case 403: throw CalendarError.forbidden
        case 404: throw Self.isFlagOff(answer.json) ? CalendarError.unavailable : CalendarError.notFound
        // Only the API's own calendar code is a daily cap; `RATE_LIMITED`, or no code at all (an edge or a proxy),
        // is "too many just now".
        case 429: throw Self.isDailyCap(answer.json) ? CalendarError.dailyLimit : CalendarError.rateLimited
        case 408, 425, 500..<600: throw CalendarError.retryable
        default: throw CalendarError.rejected
        }
    }
}
