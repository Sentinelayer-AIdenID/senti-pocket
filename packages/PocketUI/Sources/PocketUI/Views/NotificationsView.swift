#if canImport(SwiftUI)
import SwiftUI
import PocketContracts

/// The bell: unread notifications first, then earlier ones. Tapping one marks it read and opens the room at the
/// message it is about (web parity: opening the list is not reading it).
public struct NotificationsView: View {
    private let state: NotificationsPresentationState
    private let send: (NotificationsIntent) -> Void

    public init(state: NotificationsPresentationState, send: @escaping (NotificationsIntent) -> Void) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        NavigationStack {
            List {
                if let failure = state.failure {
                    Text(failure.detail).foregroundStyle(PocketPalette.warning)
                }
                if state.couldNotUpdate {
                    Label("Couldn't update. Pull down to try again.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.warning)
                        .accessibilityIdentifier("pocket.notifications.stale")
                }
                if !state.unread.isEmpty {
                    Section("New") {
                        ForEach(state.unread) { row in rowButton(row) }
                    }
                }
                if !state.earlier.isEmpty {
                    Section("Earlier") {
                        ForEach(state.earlier) { row in rowButton(row) }
                    }
                }
                if state.unread.isEmpty && state.earlier.isEmpty && !state.isLoading && state.failure == nil {
                    Text("Nothing yet. Mentions and invites will show here.")
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                if let updatedAt = state.updatedAt {
                    TimelineView(.periodic(from: updatedAt, by: 30)) { context in
                        Text(NotificationsPresentationState.freshness(updatedAt: updatedAt, now: context.date))
                            .font(.caption)
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("pocket.notifications.updated")
                }
            }
            .overlay {
                if state.isLoading && state.unread.isEmpty && state.earlier.isEmpty {
                    ProgressView("Loading notifications")
                }
            }
            .refreshable { send(.refresh) }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { send(.close) }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Mark all read") { send(.markAllRead) }
                        .disabled(state.unread.isEmpty)
                }
            }
        }
        .accessibilityIdentifier("pocket.notifications.screen")
    }

    private func rowButton(_ row: NotificationRow) -> some View {
        Button {
            send(row.canOpen ? .open(id: row.id) : .markRead(id: row.id))
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: row.symbol)
                    .foregroundStyle(row.isRead ? PocketPalette.textSecondary : PocketPalette.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(row.isRead ? .subheadline : .subheadline.weight(.semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                    if !row.body.isEmpty {
                        Text(row.body)
                            .font(.footnote)
                            .foregroundStyle(PocketPalette.textSecondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if let room = row.roomTitle {
                            Text(room).lineLimit(1)
                        }
                        if let date = row.date {
                            Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                }
                Spacer(minLength: 0)
                if !row.isRead {
                    Circle().fill(PocketPalette.accent).frame(width: 8, height: 8).padding(.top, 6)
                        .accessibilityLabel("Unread")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pocket.notifications.row.\(row.id)")
    }
}

private extension View {
    @ViewBuilder
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
#endif
