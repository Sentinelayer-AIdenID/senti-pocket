#if DEBUG
import Foundation
import PocketSyncClient
import SwiftUI

/// DEBUG-only calendar preview: `-PocketCalendarPreview` opens the calendar on made-up events, so it can be built, run
/// and screenshotted on a simulator without signing in. `-PocketCalendarStage` picks the screen: `month` (default),
/// `day` (a day with three events), `form` (a draft with what the model assumed) or `subscribe` (Settings' calendar
/// rows). Never compiled into Release.
enum RoomCalendarPreview {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketCalendarPreview")
    }

    static var stage: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-PocketCalendarStage"), index + 1 < arguments.count else {
            return "month"
        }
        return arguments[index + 1]
    }

    /// A fixed morning, so every screenshot shows the same month: Wednesday, November 4, 2026, 10 AM in New York.
    static let zone = TimeZone(identifier: "America/New_York")!
    static let now = CalendarInstant.parse("2026-11-04T10:00:00-05:00")!
    static let roomId = "preview-room"

    /// `-ShotsDark` for screenshots taken from a UI test, which does not follow the simulator's appearance.
    @MainActor
    static var rootView: some View {
        stageView
            .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-ShotsDark") ? .dark : nil)
    }

    @MainActor
    @ViewBuilder
    private static var stageView: some View {
        if stage == "subscribe" {
            PreviewSettings()
        } else if stage == "connect" {
            ConnectPreview()
        } else {
            CalendarSheet(center: center, board: board(for: stage))
        }
    }

    /// `-PocketCalendarInRoom` gives the preview room (`-PocketRoomPreview`) the calendar's ⋯ entry; without it the
    /// room has none, as before.
    @MainActor
    static var roomEntry: RoomCalendarEntry {
        RoomCalendarEntry(center: center, sessionId: roomId, roomTitle: "Design review", canAdd: true,
                          isOffered: ProcessInfo.processInfo.arguments.contains("-PocketCalendarInRoom"))
    }

    /// No link kept yet, so Subscribe asks before it makes one; the preview opens nothing.
    @MainActor
    private static let center = CalendarCenter(client: PreviewCalendar(), feed: PreviewCalendar(),
                                               vault: PreviewLinks(), person: { "preview-person" },
                                               openURL: { _ in false })

    @MainActor
    private static func board(for stage: String) -> CalendarBoard {
        let calendar = CalendarBoard.personsCalendar(timeZone: zone, locale: Locale(identifier: "en_US"))
        let board = CalendarBoard(scope: .room(sessionId: roomId, title: "Launch planning", canAdd: true),
                                  client: PreviewCalendar(), calendar: calendar, now: { now })
        switch stage {
        case "day":
            board.select(CalendarDay(year: 2026, month: 11, day: 12))
        case "form":
            board.addText = "Lunch with Sam at 1, link in the doc"
            board.form = CalendarDraftForm(draft: PreviewCalendar.draft, day: CalendarDay(year: 2026, month: 11, day: 4),
                                           roomId: roomId, roomTitle: "Launch planning", calendar: calendar)
        default:
            break
        }
        return board
    }

    /// `-PocketCalendarStage connect`: Pocket's own calendar on the simulator's real calendar, through the app's one
    /// EventKit store and the real device-events client. Its requests go to a stand-in server inside the app
    /// (`DeviceCalendarRecorder`), which answers as the API does and writes each request to `CAL_CAPTURE_FILE`.
    /// `-PocketCalendarSeedEvent` first adds a made-up event with notes and a link; "Edit the made-up event" renames
    /// it. The switch and the picks start afresh with `-PocketCalendarFresh`, and are kept from the launch before
    /// without it.
    private struct ConnectPreview: View {
        @MainActor static let phone: PhoneCalendarCenter = {
            let defaults = UserDefaults(suiteName: "phone-calendar-preview") ?? .standard
            if ProcessInfo.processInfo.arguments.contains("-PocketCalendarFresh") {
                defaults.removePersistentDomain(forName: "phone-calendar-preview")
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DeviceCalendarRecorder.self]
            let client = HTTPRoomCalendarClient(apiBaseURL: URL(string: "https://api.preview.invalid"),
                                                urlSession: URLSession(configuration: configuration),
                                                tokenProvider: { "preview-person-token" })
            return PhoneCalendarCenter(store: EventKitPhoneCalendar.shared, client: client, defaults: defaults,
                                       person: { "preview-person" })
        }()
        @MainActor static let center = CalendarCenter(client: PreviewCalendar(), feed: PreviewCalendar(),
                                                      vault: PreviewLinks(), person: { "preview-person" },
                                                      openURL: { _ in false }, phone: phone)

        @State private var seedCalendar = "none"

        var body: some View {
            NavigationStack {
                CalendarAgendaScreen(center: Self.center, rooms: [], onReauthenticationRequired: {})
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Edit the made-up event") { EventKitPhoneCalendar.shared.renameSeedForPreview() }
                        .accessibilityIdentifier("pocket.debug.editSeed")
                    Spacer()
                    Text("EventKit stores: \(EventKitPhoneCalendar.made)")
                        .accessibilityIdentifier("pocket.debug.stores")
                    Text(seedCalendar)
                        .accessibilityIdentifier("pocket.debug.seedCalendar")
                }
                .font(.caption)
                .padding(8)
                .background(.bar)
            }
            .task {
                if ProcessInfo.processInfo.arguments.contains("-PocketCalendarSeedEvent") {
                    EventKitPhoneCalendar.shared.seedForPreview(now: Date())
                    seedCalendar = EventKitPhoneCalendar.shared.seedCalendarId ?? "none"
                }
                await Self.phone.appOpened()
            }
        }
    }

    /// The real Settings screen with the calendar rows on.
    private struct PreviewSettings: View {
        @StateObject private var whisper = WhisperModelProvisioningCoordinator()

        var body: some View {
            WhisperModelSettingsView(
                coordinator: whisper,
                calendar: CalendarSettingsContext(
                    center: RoomCalendarPreview.center,
                    rooms: [CalendarRoomChoice(id: RoomCalendarPreview.roomId, title: "Launch planning")]
                ),
                onSignOut: {}
            )
            .task { await RoomCalendarPreview.center.refresh(probeRoom: RoomCalendarPreview.roomId) }
        }
    }
}

/// Made-up events in November 2026, a draft, and a feed that is on. Nothing leaves the phone.
private struct PreviewCalendar: RoomCalendarServing, CalendarFeedServing {
    static func at(_ text: String) -> Date { CalendarInstant.parse(text)! }

    static let events: [CalendarEvent] = [
        event("p1", "Design review", "2026-11-04T11:00:00-05:00", "2026-11-04T12:00:00-05:00"),
        event("p2", "Lunch with Sam", "2026-11-04T13:00:00-05:00", "2026-11-04T14:00:00-05:00",
              link: "https://example.com/lunch-plan"),
        event("p3", "Dentist", "2026-11-06T09:30:00-05:00", nil),
        event("p4", "Launch rehearsal", "2026-11-12T10:00:00-05:00", "2026-11-12T11:30:00-05:00",
              link: "https://example.com/rehearsal"),
        event("p5", "Investor call", "2026-11-12T14:00:00-05:00", "2026-11-12T14:30:00-05:00"),
        event("p6", "Team dinner", "2026-11-12T19:00:00-05:00", nil, notes: "Table for eight."),
        event("p7", "Quarterly planning", "2026-11-19T09:00:00-05:00", "2026-11-19T12:00:00-05:00"),
        event("p8", "Flight to Boston", "2026-11-25T07:15:00-05:00", "2026-11-25T08:40:00-05:00"),
    ]

    static let draft = CalendarDraft(
        title: "Lunch with Sam",
        startsAt: at("2026-11-04T13:00:00-05:00"),
        endsAt: at("2026-11-04T14:00:00-05:00"),
        link: "https://example.com/lunch-plan",
        notes: "Bring the launch checklist.",
        confidence: 0.55,
        assumptions: ["I assumed 1 PM, Eastern.", "I assumed it lasts an hour.",
                      "I took the link from the doc you mentioned."]
    )

    private static func event(_ id: String, _ title: String, _ start: String, _ end: String?, link: String? = nil,
                              notes: String? = nil) -> CalendarEvent {
        CalendarEvent(id: id, sessionId: RoomCalendarPreview.roomId, title: title, startsAt: at(start),
                      endsAt: end.map(at), link: link.flatMap(URL.init(string:)), notes: notes)
    }

    func draftsAvailable(inRoom sessionId: String) async throws -> Bool { true }
    func events(inRoom sessionId: String) async throws -> [CalendarEvent] { Self.events }
    func agenda() async throws -> [CalendarEvent] { Self.events }
    func draft(inRoom sessionId: String, _ request: CalendarDraftRequest) async throws -> CalendarDraft { Self.draft }

    func save(_ event: CalendarEventCreate, inRoom sessionId: String) async throws -> CalendarEvent {
        CalendarEvent(id: UUID().uuidString, sessionId: sessionId, title: event.title, startsAt: event.startsAt,
                      endsAt: event.endsAt, link: event.link, notes: event.notes)
    }

    func feedAvailable() async throws -> Bool { true }

    func newSubscriptionLink() async throws -> CalendarSubscriptionLink {
        let feedURL = "https://api.example.com/api/v1/me/calendar.ics?token=preview"
        guard let link = CalendarSubscriptionLink.make(apiBaseURL: Self.api, feedURL: feedURL) else {
            throw CalendarError.invalidData
        }
        return link
    }

    func keptLink(_ url: URL) -> CalendarSubscriptionLink? { CalendarSubscriptionLink.kept(url, apiBaseURL: Self.api) }

    private static let api = URL(string: "https://api.example.com")
}

/// The preview's kept link: in memory for the run, never the Keychain.
private final class PreviewLinks: CalendarLinkKeeping, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: (person: String, link: URL)?

    func link(for person: String) -> URL? { lock.withLock { kept?.person == person ? kept?.link : nil } }
    func keep(_ link: URL, for person: String) { lock.withLock { kept = (person, link) } }
    func forgetAll() { lock.withLock { kept = nil } }
}
#endif
