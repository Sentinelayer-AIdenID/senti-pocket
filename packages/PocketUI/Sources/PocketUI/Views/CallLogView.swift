#if canImport(SwiftUI)
import SwiftUI

/// "Calls & briefings": every call you made or got, newest first, by day. A call opens to what was decided (the
/// agents' summaries), its timings, and the way back to it in its room. Calls scheduled in your rooms' calendars will
/// show above them once the calendar is live.
public struct CallLogView: View {
    private let state: CallLogState
    private let readingId: String?
    private let send: (CallLogIntent) -> Void

    /// `readingId` is the call whose summary is being read aloud, if any.
    public init(state: CallLogState, readingId: String? = nil, send: @escaping (CallLogIntent) -> Void) {
        self.state = state
        self.readingId = readingId
        self.send = send
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { send(.openBriefing) } label: {
                        Label("Briefing and Ask Senti", systemImage: "person.wave.2")
                    }
                    .accessibilityIdentifier("pocket.calls.briefing")
                }
                .listRowBackground(PocketPalette.raised)

                Section("Coming up") {
                    Text("Calls scheduled in your rooms will show here once room calendars are live.")
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                .listRowBackground(PocketPalette.raised)

                if !state.isAvailable {
                    Text("Your calls will show here once the server has the call log.")
                        .foregroundStyle(PocketPalette.textSecondary)
                        .listRowBackground(PocketPalette.raised)
                        .accessibilityIdentifier("pocket.calls.unavailable")
                } else if state.rows.isEmpty {
                    Text(state.isLoading ? "Looking…" : "No calls yet. Start one from a room's waveform button.")
                        .foregroundStyle(PocketPalette.textSecondary)
                        .listRowBackground(PocketPalette.raised)
                        .accessibilityIdentifier("pocket.calls.empty")
                }
                if let notice = state.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.warning)
                        .listRowBackground(PocketPalette.raised)
                }
                ForEach(Self.days(state.rows), id: \.title) { day in
                    Section(day.title) {
                        ForEach(day.rows) { row in
                            NavigationLink {
                                CallLogDetail(row: row, isReading: readingId == row.id, send: send)
                            } label: {
                                CallLogRowView(row: row)
                            }
                            .accessibilityIdentifier("pocket.calls.row.\(row.id)")
                        }
                    }
                    .listRowBackground(PocketPalette.raised)
                }
                if state.canLoadMore {
                    Button("Earlier calls") { send(.loadMore) }
                        .listRowBackground(PocketPalette.raised)
                }
            }
            .scrollContentBackground(.hidden)
            .pocketCanvas()
            .refreshable { send(.refresh) }
            .navigationTitle("Calls & briefings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { send(.close) }
                }
            }
        }
    }

    struct Day: Equatable {
        let title: String
        let rows: [CallLogRow]
    }

    /// The calls by day, newest first: "Today", "Yesterday", then the date.
    static func days(_ rows: [CallLogRow], now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        var order: [String] = []
        var grouped: [String: [CallLogRow]] = [:]
        for row in rows {
            let title: String
            if let date = row.startedAt {
                if calendar.isDate(date, inSameDayAs: now) {
                    title = "Today"
                } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                          calendar.isDate(date, inSameDayAs: yesterday) {
                    title = "Yesterday"
                } else {
                    title = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
                }
            } else {
                title = "Earlier"
            }
            if grouped[title] == nil { order.append(title) }
            grouped[title, default: []].append(row)
        }
        return order.map { Day(title: $0, rows: grouped[$0] ?? []) }
    }
}

private struct CallLogRowView: View {
    let row: CallLogRow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.direction == .outgoing ? "phone.arrow.up.right.fill" : "phone.arrow.down.left.fill")
                .foregroundStyle(row.isMissed ? PocketPalette.danger : PocketPalette.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(row.isMissed ? PocketPalette.danger : PocketPalette.textPrimary)
                    .lineLimit(1)
                Text([row.roomTitle, row.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let startedAt = row.startedAt {
                Text(startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(PocketPalette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CallLogDetail: View {
    let row: CallLogRow
    let isReading: Bool
    let send: (CallLogIntent) -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title).font(.title3.weight(.semibold))
                    Text([row.roomTitle, row.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(PocketPalette.textSecondary)
                    if let startedAt = row.startedAt {
                        Text(startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.footnote)
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                    if let reason = row.reason {
                        Text(reason).font(.subheadline)
                    }
                }
                if row.canOpen {
                    Button {
                        send(.open(id: row.id))
                    } label: {
                        Label(row.hasTranscript ? "Open it in the room, with its transcript" : "Open it in the room",
                              systemImage: "arrow.up.forward.square")
                    }
                    .accessibilityIdentifier("pocket.calls.open")
                }
            }
            .listRowBackground(PocketPalette.raised)

            Section("What was decided") {
                if row.summaries.isEmpty {
                    Text(row.isOngoing ? "The call is still going." : "No summary was posted for this call.")
                        .foregroundStyle(PocketPalette.textSecondary)
                } else {
                    Button {
                        send(.listen(id: row.id))
                    } label: {
                        Label(isReading ? "Stop" : "Listen", systemImage: isReading ? "stop.fill" : "speaker.wave.2.fill")
                    }
                    .accessibilityIdentifier("pocket.calls.listen")
                    ForEach(Array(row.summaries.enumerated()), id: \.offset) { _, summary in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.author).font(.footnote.weight(.semibold))
                            ChatMarkdownView(text: summary.text, ownHandles: [])
                        }
                    }
                }
            }
            .listRowBackground(PocketPalette.raised)

            if let timings = row.timings {
                Section("How fast it was") {
                    Text(timings).font(.footnote)
                }
                .listRowBackground(PocketPalette.raised)
            }
        }
        .scrollContentBackground(.hidden)
        .pocketCanvas()
        .navigationTitle("Call")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
#endif
