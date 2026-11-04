import Foundation
import PocketSyncClient
import SwiftUI

// The calendar's screens: the month with its days, the day's events and the Add field, the draft form, the room's
// ⋯ entry and the Settings rows. Each shows only while the server's flag for it is on (`CalendarCenter`).

/// The room's ⋯ menu gets "Calendar" while drafting is on; it opens the room's calendar.
struct RoomCalendarEntry: ViewModifier {
    @ObservedObject var center: CalendarCenter
    let sessionId: String
    let roomTitle: String
    let canAdd: Bool
    /// Rooms only: a direct message has no calendar entry.
    let isOffered: Bool
    let onReauthenticationRequired: @MainActor () -> Void
    @State private var opens = false

    init(center: CalendarCenter, sessionId: String, roomTitle: String, canAdd: Bool, isOffered: Bool,
         onReauthenticationRequired: @escaping @MainActor () -> Void = {}) {
        _center = ObservedObject(wrappedValue: center)
        self.sessionId = sessionId
        self.roomTitle = roomTitle
        self.canAdd = canAdd
        self.isOffered = isOffered
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                if isOffered, center.showsCalendar {
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            opens = true
                        } label: {
                            Label("Calendar", systemImage: "calendar")
                        }
                        .accessibilityIdentifier("pocket.room.calendar")
                    }
                }
            }
            .sheet(isPresented: $opens) {
                CalendarSheet(center: center,
                              scope: .room(sessionId: sessionId, title: roomTitle, canAdd: canAdd),
                              onReauthenticationRequired: onReauthenticationRequired)
            }
            .task(id: sessionId) {
                if isOffered { await center.checkDrafts(probeRoom: sessionId) }
            }
            .onChange(of: center.showsCalendar) { shown in
                if !shown { opens = false }
            }
    }
}

/// A calendar in its own sheet, with Done.
struct CalendarSheet: View {
    @ObservedObject var center: CalendarCenter
    @StateObject private var board: CalendarBoard
    @Environment(\.dismiss) private var dismiss

    init(center: CalendarCenter, scope: CalendarScope, onReauthenticationRequired: @escaping @MainActor () -> Void) {
        _center = ObservedObject(wrappedValue: center)
        _board = StateObject(wrappedValue: CalendarBoard(
            scope: scope,
            client: center.client,
            onUnavailable: { center.calendarWentAway() },
            onReauthenticationRequired: onReauthenticationRequired
        ))
    }

    /// For previews and tests: a board made elsewhere.
    init(center: CalendarCenter, board: CalendarBoard) {
        _center = ObservedObject(wrappedValue: center)
        _board = StateObject(wrappedValue: board)
    }

    var body: some View {
        NavigationStack {
            CalendarScreen(board: board)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// The month, the day picked, its events, and the Add field.
struct CalendarScreen: View {
    @ObservedObject var board: CalendarBoard
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                monthHeader
                CalendarMonthGridView(grid: board.grid, selected: board.selected) { board.select($0) }
                    // A sideways swipe moves a month; scrolling up and down still scrolls.
                    .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                        let sideways = value.translation.width
                        guard abs(sideways) > 60, abs(sideways) > abs(value.translation.height) * 1.5 else { return }
                        board.showMonth(sideways < 0 ? 1 : -1)
                    })
                if board.load == .failed {
                    failure
                }
                if let day = board.selected {
                    dayDetail(day)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .task { await board.loadIfNeeded() }
        .sheet(item: $board.form) { _ in
            if let form = Binding($board.form) {
                NavigationStack {
                    CalendarDraftFormView(
                        form: form,
                        isSaving: board.isSaving,
                        problem: board.saveProblem,
                        onSave: { Task { await board.save() } },
                        onCancel: { board.cancelDraft() }
                    )
                }
                .interactiveDismissDisabled(board.isSaving)
            }
        }
    }

    private var monthHeader: some View {
        HStack(spacing: 8) {
            Button {
                board.showMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous month")
            .accessibilityIdentifier("pocket.calendar.previousMonth")
            Spacer(minLength: 0)
            Text(board.grid.title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("pocket.calendar.month")
            Spacer(minLength: 0)
            Button {
                board.showMonth(1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Next month")
            .accessibilityIdentifier("pocket.calendar.nextMonth")
        }
        // The month's name stays on one line between its arrows, as the grid under it does.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Couldn't read the calendar.")
                .font(.subheadline)
            Button("Try again") { Task { await board.loadIfNeeded() } }
        }
        .accessibilityElement(children: .contain)
    }

    private func dayDetail(_ day: CalendarDay) -> some View {
        let events = board.events(on: day)
        let labels = CalendarDayLabel(calendar: board.calendar)
        return VStack(alignment: .leading, spacing: 12) {
            Text(labels.day(day))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if board.load == .loading {
                ProgressView()
                    .accessibilityLabel("Reading the calendar")
            } else if events.isEmpty, board.load == .loaded {
                Text("Nothing on this day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(events) { event in
                eventRow(event)
            }
            if board.canAdd {
                addField(day)
            }
        }
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        let time = CalendarEventTime.text(event, calendar: board.calendar)
        let room = board.roomTitle(event.sessionId)
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(time)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let room {
                    Text(room)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let notes = event.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let link = event.link {
                    Button {
                        openURL(link)
                    } label: {
                        Label("Open link", systemImage: "link")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open link for \(event.title)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel([event.title, time, room].compactMap { $0 }.joined(separator: ", "))
    }

    private func addField(_ day: CalendarDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if !board.rooms.isEmpty {
                Picker("Room", selection: $board.addRoomId) {
                    ForEach(board.rooms) { room in
                        Text(room.title).tag(Optional(room.id))
                    }
                }
                .accessibilityIdentifier("pocket.calendar.addRoom")
            }
            TextField("Lunch with Sam at 1, link in the doc", text: $board.addText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .accessibilityLabel("Describe the event")
                .accessibilityHint("Then tap Draft. Nothing is saved until you check it and tap Save.")
                .accessibilityIdentifier("pocket.calendar.addText")
            HStack(spacing: 12) {
                Button {
                    Task { await board.draft() }
                } label: {
                    if board.isDrafting {
                        ProgressView()
                    } else {
                        Text("Draft")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(board.isDrafting || board.addText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(board.isDrafting ? "Drafting" : "Draft")
                .accessibilityIdentifier("pocket.calendar.draft")
                Spacer(minLength: 0)
            }
            if let problem = board.draftProblem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pocket.calendar.draftProblem")
            }
        }
        .padding(.top, 6)
    }
}

/// The month: weekday initials, then each day with a dot per event (three at most). VoiceOver reads each day as
/// "Wednesday, November 4, 2 events".
struct CalendarMonthGridView: View {
    let grid: CalendarMonthGrid
    let selected: CalendarDay?
    let onSelect: (CalendarDay) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Array(grid.weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(grid.cells) { cell in
                    if let day = cell.day {
                        CalendarDayCell(cell: cell, day: day, isSelected: day == selected) { onSelect(day) }
                    } else {
                        Color.clear
                            .frame(height: 1)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        // The grid keeps seven columns on a small phone: its numbers stop growing at the largest standard size, and
        // VoiceOver reads every day in full.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

struct CalendarDayCell: View {
    let cell: CalendarMonthGrid.Cell
    let day: CalendarDay
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Text("\(day.day)")
                    .font(.body.monospacedDigit().weight(cell.isToday || isSelected ? .bold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(isSelected ? Color.white : (cell.isToday ? Color.accentColor : Color.primary))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(isSelected ? Color.accentColor : Color.clear))
                    .overlay(Circle().stroke(cell.isToday && !isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
                HStack(spacing: 3) {
                    ForEach(0..<min(cell.eventCount, 3), id: \.self) { _ in
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cell.accessibilityLabel)
        .accessibilityValue(cell.isToday ? "Today" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("pocket.calendar.day.\(day.key)")
    }
}

/// The draft, to check and change before saving: title, start, end, link, notes, what the model assumed, and a word
/// when it was unsure. Save is the only way it is saved; Cancel (or a swipe down) drops it.
struct CalendarDraftFormView: View {
    @Binding var form: CalendarDraftForm
    let isSaving: Bool
    let problem: String?
    let onSave: () -> Void
    let onCancel: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Form {
            if form.isLowConfidence {
                Section {
                    Label("I'm not sure about this one. Check each field before you save.",
                          systemImage: "questionmark.circle")
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("pocket.calendar.lowConfidence")
                }
            }
            Section {
                TextField("Title", text: $form.title, axis: .vertical)
                    .accessibilityIdentifier("pocket.calendar.form.title")
                dateRow("Starts", selection: $form.startsAt, from: nil)
                Toggle("Has an end time", isOn: $form.hasEnd)
                if form.hasEnd {
                    dateRow("Ends", selection: $form.endsAt, from: form.startsAt)
                }
                TextField("Link (https://…)", text: $form.link, axis: .vertical)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("pocket.calendar.form.link")
                TextField("Notes", text: $form.notes, axis: .vertical)
                    .lineLimit(1...8)
                    .accessibilityIdentifier("pocket.calendar.form.notes")
            } footer: {
                Text(zoneLine)
            }
            if !form.assumptions.isEmpty {
                Section("What I assumed") {
                    ForEach(Array(form.assumptions.enumerated()), id: \.offset) { _, assumption in
                        Text(assumption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("pocket.calendar.assumptions")
            }
            if let room = form.roomTitle {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Room")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(room)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let problem {
                Section {
                    Text(problem)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("pocket.calendar.saveProblem")
                }
            }
        }
        .environment(\.timeZone, form.timeZone)
        .navigationTitle("New event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
                    .accessibilityIdentifier("pocket.calendar.form.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: onSave) {
                    if isSaving { ProgressView() } else { Text("Save").bold() }
                }
                .disabled(isSaving || form.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(isSaving ? "Saving" : "Save")
                .accessibilityIdentifier("pocket.calendar.form.save")
            }
        }
    }

    /// "Times are in Eastern Time."
    private var zoneLine: String {
        let name = form.timeZone.localizedName(for: .generic, locale: .current) ?? form.timeZone.identifier
        return "Times are in \(name)."
    }

    /// A date and time. At the accessibility sizes the label sits above, and the date and the time each get a line,
    /// so nothing is cut off.
    @ViewBuilder
    private func dateRow(_ label: String, selection: Binding<Date>, from: Date?) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                picker(label, selection: selection, from: from, parts: .date)
                picker(label, selection: selection, from: from, parts: .hourAndMinute)
            }
        } else {
            picker(label, selection: selection, from: from, parts: [.date, .hourAndMinute])
        }
    }

    @ViewBuilder
    private func picker(_ label: String, selection: Binding<Date>, from: Date?,
                        parts: DatePickerComponents) -> some View {
        if let from {
            DatePicker(label, selection: selection, in: from..., displayedComponents: parts)
                .hidesLabels(typeSize.isAccessibilitySize)
        } else {
            DatePicker(label, selection: selection, displayedComponents: parts)
                .hidesLabels(typeSize.isAccessibilitySize)
        }
    }
}

private extension View {
    @ViewBuilder
    func hidesLabels(_ hidden: Bool) -> some View {
        if hidden { labelsHidden() } else { self }
    }
}

/// What Settings needs for the calendar rows: the center, and the rooms an event can be added to.
struct CalendarSettingsContext {
    let center: CalendarCenter
    let rooms: [CalendarRoomChoice]
    var onReauthenticationRequired: @MainActor () -> Void = {}
}

/// Settings → Calendar: the calendar across your rooms, and the Apple Calendar link, each while its flag is on.
struct CalendarSettingsSection: View {
    let context: CalendarSettingsContext
    @ObservedObject private var center: CalendarCenter
    @State private var confirmsReset = false
    @Environment(\.dynamicTypeSize) private var typeSize

    init(context: CalendarSettingsContext) {
        self.context = context
        _center = ObservedObject(wrappedValue: context.center)
    }

    var body: some View {
        Group {
            if center.showsCalendar || center.showsSubscribe {
                Section {
                    if center.showsCalendar {
                        NavigationLink {
                            CalendarAgendaScreen(center: center, rooms: context.rooms,
                                                 onReauthenticationRequired: context.onReauthenticationRequired)
                        } label: {
                            Label("Calendar", systemImage: "calendar")
                        }
                        .accessibilityIdentifier("settings.calendar.open")
                    }
                    if center.showsSubscribe {
                        Button {
                            Task { await center.subscribe() }
                        } label: {
                            Label("Subscribe in Apple Calendar", systemImage: "calendar.badge.plus")
                        }
                        .disabled(center.isWorkingOnFeed)
                        .accessibilityIdentifier("settings.calendar.subscribe")
                        Button(role: .destructive) {
                            confirmsReset = true
                        } label: {
                            Label("Reset link", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(center.isWorkingOnFeed)
                        .accessibilityIdentifier("settings.calendar.reset")
                    }
                } header: {
                    Text("Calendar")
                } footer: {
                    Text(center.feedNotice ?? footer)
                        .accessibilityIdentifier("settings.calendar.footer")
                }
                // At the accessibility sizes the rows drop their icons, so "Calendar" is not broken across lines.
                .labelStyle(CalendarRowLabelStyle(showsIcon: !typeSize.isAccessibilitySize))
                .confirmationDialog("Reset your calendar link?", isPresented: $confirmsReset, titleVisibility: .visible) {
                    Button("Reset link", role: .destructive) { Task { await center.resetLink() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(CalendarCenter.resetWarning)
                }
            }
        }
    }

    private var footer: String {
        center.showsSubscribe
            ? "Apple Calendar shows the events from your rooms and keeps them up to date."
            : "Events from your rooms, by day."
    }
}

/// A row's icon and title, or the title alone.
private struct CalendarRowLabelStyle: LabelStyle {
    let showsIcon: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if showsIcon {
            Label(configuration)
        } else {
            configuration.title
        }
    }
}

/// The calendar across your rooms, pushed from Settings.
struct CalendarAgendaScreen: View {
    @ObservedObject var center: CalendarCenter
    @StateObject private var board: CalendarBoard

    init(center: CalendarCenter, rooms: [CalendarRoomChoice], onReauthenticationRequired: @escaping @MainActor () -> Void) {
        _center = ObservedObject(wrappedValue: center)
        _board = StateObject(wrappedValue: CalendarBoard(
            scope: .agenda(rooms: rooms),
            client: center.client,
            onUnavailable: { center.calendarWentAway() },
            onReauthenticationRequired: onReauthenticationRequired
        ))
    }

    var body: some View {
        CalendarScreen(board: board)
    }
}
