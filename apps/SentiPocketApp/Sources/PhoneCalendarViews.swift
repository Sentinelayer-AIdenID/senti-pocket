import PocketSyncClient
import SwiftUI
import UIKit

// Connect my calendar (ticket 9583d41e): the phone's events in Pocket's own calendar, and Settings' switch that lets
// the person's agents see the calendars they pick. See `PhoneCalendarCenter`.

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

/// "Your calendars", over the month in every calendar screen, so they are found where the calendar is (Carter looked
/// there, not in Settings): Connect my calendar until Pocket may read the phone's calendars (Apple's, and Google's or
/// Outlook's once their account is on the phone), the plain line when it may not, and then the switch that lets the
/// person's agents see the calendars they pick; and Sync to my other calendars, which puts Pocket's events in Apple
/// Calendar (Carter: "it doesn't give me a sync with others button"). Each part only while its server flag is on.
struct PhoneCalendarCard: View {
    @ObservedObject var phone: PhoneCalendarCenter
    @ObservedObject var center: CalendarCenter
    /// Pocket's own calendar shows the phone's events; a room's calendar only offers the switches, and says where the
    /// events show.
    let showsEventsHere: Bool

    static let connectWords = "Apple, Google, Outlook: every calendar on this phone shows here, read-only. Nothing is "
        + "sent anywhere unless you turn on Let my agents see my calendar."
    static let accountsWords = "A Google or Outlook calendar shows once its account is on this phone, in Settings, "
        + "Calendar, Accounts."
    static let elsewhereWords = "Your phone's events show in your own calendar, in Settings, Calendar."
    static let syncWords = "Adds Pocket's events to Apple Calendar; Google Calendar can subscribe to the same link."

    var body: some View {
        if phone.available == true || center.showsSubscribe {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your calendars")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if phone.available == true {
                    phoneRows
                }
                if center.showsSubscribe {
                    CalendarSubscribeButton(center: center, title: "Sync to my other calendars",
                                            identifier: "pocket.calendar.sync")
                        .font(.subheadline.weight(.semibold))
                    note(center.feedNotice ?? Self.syncWords)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pocket.calendar.yourCalendars")
        }
    }

    @ViewBuilder
    private var phoneRows: some View {
        if phone.showsConnect {
            Button {
                Task { await phone.connect() }
            } label: {
                Label("Connect my calendar", systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("pocket.calendar.connect")
            note(Self.connectWords)
        } else {
            if phone.access == .granted {
                Label(showsEventsHere ? "Your phone's calendars show here" : Self.elsewhereWords,
                      systemImage: "iphone")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } else if phone.access.isRefused {
                PhoneCalendarRefusedLine()
            }
            // The switch stays in sight while sharing is on or being forgotten, whatever iOS lets Pocket read: the way
            // to stop sharing never hides.
            if phone.showsSharing {
                Toggle(isOn: Binding(get: { phone.sharesWithAgents },
                                     set: { on in Task { await phone.setSharing(on) } })) {
                    Text("Let my agents see my calendar")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityIdentifier("pocket.calendar.share")
                if phone.sharesWithAgents {
                    NavigationLink {
                        PhoneCalendarPicker(phone: phone)
                    } label: {
                        LabeledContent("Calendars to share",
                                       value: PhoneCalendarSettingsSection.picked(phone.pickedCount))
                            .font(.subheadline)
                    }
                    .accessibilityIdentifier("pocket.calendar.calendars")
                }
                note(words)
            }
        }
    }

    private var words: String {
        var words: [String] = []
        if let notice = phone.notice { words.append(notice) }
        words.append(PhoneCalendarSettingsSection.sharingWords(phone))
        if phone.sharesWithAgents, phone.pickedCount == 0 { words.append(PhoneCalendarSettingsSection.pickWords) }
        words.append(Self.accountsWords)
        return words.joined(separator: " ")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings → Your phone's calendar: connect it, and the switch that lets your agents see the calendars you pick.
struct PhoneCalendarSettingsSection: View {
    @ObservedObject var phone: PhoneCalendarCenter

    static let agentsWords = "Your agents can see the titles and times of your shared calendars. Turn this off any time."
    static let pickWords = "Pick the calendars to share."
    static let noAccessWords = "Pocket can't see your calendar right now. Nothing is shared."
    static let turnOnWords = "Turn this on to let your agents see the calendars you pick."

    /// What the switch says: nothing is shared while Pocket can't see the calendar; off, how to share; on, what the
    /// agents see.
    @MainActor
    static func sharingWords(_ phone: PhoneCalendarCenter) -> String {
        if phone.access != .granted { return noAccessWords }
        return phone.sharesWithAgents ? agentsWords : turnOnWords
    }
    static let connectWords = "Your phone's events show in your calendar here. Nothing is sent unless you turn on "
        + "Let my agents see my calendar."

    var body: some View {
        if phone.available == true {
            Section {
                if phone.showsConnect {
                    Button {
                        Task { await phone.connect() }
                    } label: {
                        Label("Connect my calendar", systemImage: "calendar.badge.plus")
                    }
                    .accessibilityIdentifier("settings.phoneCalendar.connect")
                } else {
                    if phone.access.isRefused {
                        PhoneCalendarRefusedLine()
                    }
                    // In sight while sharing is on or being forgotten, whatever iOS lets Pocket read.
                    if phone.showsSharing {
                        Toggle(isOn: Binding(get: { phone.sharesWithAgents },
                                             set: { on in Task { await phone.setSharing(on) } })) {
                            Text("Let my agents see my calendar")
                        }
                        .accessibilityIdentifier("settings.phoneCalendar.share")
                        if phone.sharesWithAgents {
                            NavigationLink {
                                PhoneCalendarPicker(phone: phone)
                            } label: {
                                LabeledContent("Calendars to share", value: Self.picked(phone.pickedCount))
                            }
                            .accessibilityIdentifier("settings.phoneCalendar.calendars")
                        }
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
            words.append(Self.sharingWords(phone))
            if phone.sharesWithAgents, phone.pickedCount == 0 { words.append(Self.pickWords) }
        default:
            if phone.showsSharing { words.append(Self.noAccessWords) }
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
