import PocketSyncClient
import SwiftUI
import UIKit

// Connect my calendar (ticket 9583d41e): the phone's events in Pocket's own calendar, and Settings' switch that lets
// the person's agents see the calendars she picks. See `PhoneCalendarCenter`.

/// One of the phone's own events in Pocket's calendar: read-only, and marked as from the phone.
struct PhoneEventRow: View {
    let item: PhoneCalendarItem
    let time: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary)
                .frame(width: 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(time)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let location = item.location {
                    Text(location)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(Self.source(item), systemImage: "iphone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(item, time: time))
        .accessibilityIdentifier("pocket.calendar.phoneEvent.\(item.id)")
    }

    /// "From your phone · Work".
    static func source(_ item: PhoneCalendarItem) -> String {
        item.calendarTitle.isEmpty ? "From your phone" : "From your phone · \(item.calendarTitle)"
    }

    /// What VoiceOver reads: "Dentist, 9:00 – 10:00 AM, Main Street, from your phone, Home".
    static func label(_ item: PhoneCalendarItem, time: String) -> String {
        [item.title, time, item.location, "from your phone", item.calendarTitle.isEmpty ? nil : item.calendarTitle]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// Its time as the person reads it: "All day", or "9:00 – 10:00 AM".
    static func time(_ item: PhoneCalendarItem, calendar: Calendar) -> String {
        if item.allDay { return "All day" }
        guard item.end > item.start else { return CalendarEventTime.time(item.start, calendar: calendar) }
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: item.start, to: item.end)
    }
}

/// When Pocket may not read the phone's calendar: one plain line, and the way to Settings.
struct PhoneCalendarRefusedLine: View {
    static let text = "Pocket can't see your calendar. Turn on Calendars for Senti Pocket in Settings."
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(.footnote.weight(.semibold))
            .accessibilityIdentifier("pocket.calendar.openSettings")
        }
        .accessibilityElement(children: .contain)
    }
}

/// Over Pocket's own calendar: "Connect my calendar" until the phone's events show here, or the plain line when
/// Pocket may not read them. Nothing while the server's flag is off.
struct PhoneCalendarConnectBanner: View {
    @ObservedObject var phone: PhoneCalendarCenter

    var body: some View {
        if phone.available == true {
            if phone.access == .notAsked {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        Task { await phone.connect() }
                    } label: {
                        Label("Connect my calendar", systemImage: "calendar.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pocket.calendar.connect")
                    Text("Your phone's events show here, on this phone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if phone.access.isRefused {
                PhoneCalendarRefusedLine()
            }
        }
    }
}

/// Settings → Your phone's calendar: connect it, and the switch that lets your agents see the calendars you pick.
struct PhoneCalendarSettingsSection: View {
    @ObservedObject var phone: PhoneCalendarCenter

    static let agentsWords = "Your agents can see the titles and times of your shared calendars. Turn this off any time."
    static let pickWords = "Pick the calendars to share."
    static let connectWords = "Your phone's events show in your calendar here. Nothing is sent unless you turn on "
        + "Let my agents see my calendar."

    var body: some View {
        if phone.available == true {
            Section {
                if phone.access == .notAsked {
                    Button {
                        Task { await phone.connect() }
                    } label: {
                        Label("Connect my calendar", systemImage: "calendar.badge.plus")
                    }
                    .accessibilityIdentifier("settings.phoneCalendar.connect")
                } else if phone.access.isRefused {
                    PhoneCalendarRefusedLine()
                } else {
                    Toggle(isOn: Binding(get: { phone.sharesWithAgents },
                                         set: { on in Task { await phone.setSharing(on) } })) {
                        Text("Let my agents see my calendar")
                    }
                    .accessibilityIdentifier("settings.phoneCalendar.share")
                    if phone.sharesWithAgents {
                        NavigationLink {
                            PhoneCalendarPicker(phone: phone)
                        } label: {
                            LabeledContent("Calendars to share", value: Self.picked(phone.sharedCalendarIds.count))
                        }
                        .accessibilityIdentifier("settings.phoneCalendar.calendars")
                    }
                }
            } header: {
                Text("Your phone's calendar")
            } footer: {
                Text(footer)
                    .accessibilityIdentifier("settings.phoneCalendar.footer")
            }
        }
    }

    static func picked(_ count: Int) -> String {
        count == 0 ? "None" : String(count)
    }

    private var footer: String {
        var words: [String] = []
        if let notice = phone.notice { words.append(notice) }
        switch phone.access {
        case .notAsked:
            words.append(Self.connectWords)
        case .granted:
            words.append(Self.agentsWords)
            if phone.sharesWithAgents, phone.sharedCalendarIds.isEmpty { words.append(Self.pickWords) }
        default:
            break
        }
        return words.joined(separator: " ")
    }
}

/// The calendars to share with your agents: only the ticked ones are ever sent.
struct PhoneCalendarPicker: View {
    @ObservedObject var phone: PhoneCalendarCenter

    var body: some View {
        List {
            Section {
                ForEach(phone.calendars) { source in
                    let shared = phone.sharedCalendarIds.contains(source.id)
                    Button {
                        phone.setShared(source.id, !shared)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title)
                                    .foregroundStyle(.primary)
                                if !source.account.isEmpty {
                                    Text(source.account)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if shared {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(shared ? .isSelected : [])
                    .accessibilityIdentifier("settings.phoneCalendar.calendar.\(source.id)")
                }
            } footer: {
                Text("Only the calendars you tick are shared: their events' titles, times and places, never notes, "
                     + "people or links.")
            }
        }
        .navigationTitle("Calendars to share")
        .navigationBarTitleDisplayMode(.inline)
    }
}
