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

    @MainActor
    private static let center = CalendarCenter(client: PreviewCalendar(), feed: PreviewCalendar(), openURL: { _ in })

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
        guard let link = CalendarSubscriptionLink.make(apiBaseURL: URL(string: "https://api.example.com"),
                                                       token: "preview") else { throw CalendarError.invalidData }
        return link
    }
}
#endif
