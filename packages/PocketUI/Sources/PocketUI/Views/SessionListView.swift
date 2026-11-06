#if canImport(SwiftUI)
import SwiftUI
import PocketContracts   // ParsedSessionTimestamp (SessionAtlasTypes): a row's last activity

public struct SessionListView: View {
    private let state: SessionListPresentationState
    private let send: (PocketProductIntent) -> Void
    /// Your folders, where folders are on: a room's long press moves it to one or out of it.
    private let folders: [RoomFolderItem]?
    private let onFolder: ((RoomFolderIntent) -> Void)?

    public init(state: SessionListPresentationState, folders: [RoomFolderItem]? = nil,
                onFolder: ((RoomFolderIntent) -> Void)? = nil, send: @escaping (PocketProductIntent) -> Void) {
        self.state = state
        self.send = send
        self.folders = onFolder == nil ? nil : folders
        self.onFolder = folders == nil ? nil : onFolder
    }

    public var body: some View {
        Group {
            if state.rows.isEmpty {
                emptyOrFailure
            } else {
                sessionList
            }
        }
        .navigationTitle(ChatListWords.title)
        .accessibilityIdentifier("pocket.sessions.screen")
        .pocketCanvas()
    }

    private var sessionList: some View {
        let yours = Set(folders?.map(\.id) ?? [])
        return List {
            Section {
                SessionProvenanceBanner(provenance: state.provenance)
            }
            .listRowBackground(PocketPalette.raised)

            if let failure = state.failure {
                Section {
                    failureRow(failure)
                }
                .listRowBackground(PocketPalette.raised)
            }

            Section(ChatListWords.section) {
                ForEach(state.rows) { row in
                    Button { send(.selectSession(sessionId: row.sessionId)) } label: {
                        SessionRow(row: row)
                    }
                    .buttonStyle(.plain)
                    // A room's long press files it in a folder; a direct message lives under its room, in none.
                    .modifier(RoomFolderContextMenu(roomId: row.sessionId,
                                                    filedIn: row.folderId.flatMap { yours.contains($0) ? $0 : nil },
                                                    send: row.isDirect ? nil : onFolder))
                    .accessibilityIdentifier("pocket.sessions.row.\(row.sessionId)")
                    .accessibilityHint(ChatListWords.rowHint)
                    .listRowBackground(PocketPalette.raised)
                }
            }

            if state.hasMore {
                Section {
                    Button(ChatListWords.loadMore) { send(.loadMoreSessions) }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("pocket.sessions.load-more")
                }
                .listRowBackground(PocketPalette.raised)
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { send(.refreshSessions) }
        .overlay {
            if state.isRefreshing {
                ProgressView(ChatListWords.loading)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("pocket.sessions.refreshing")
            }
        }
    }

    private var emptyOrFailure: some View {
        ScrollView {
            VStack(spacing: 16) {
                SessionProvenanceBanner(provenance: state.provenance)

                Image(systemName: state.failure == nil ? "rectangle.stack" : "exclamationmark.triangle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(state.failure == nil ? PocketPalette.accent : PocketPalette.warning)
                    .accessibilityHidden(true)

                Text(state.isRefreshing ? ChatListWords.loading : (state.failure?.title ?? ChatListWords.emptyTitle(state.provenance)))
                    .font(.title2.bold())
                Text(state.isRefreshing
                    ? ChatListWords.loadingDetail
                    : (state.failure?.detail ?? ChatListWords.emptyDetail(state.provenance)))
                    .foregroundStyle(PocketPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if state.isRefreshing {
                    ProgressView()
                        .accessibilityLabel(ChatListWords.loading)
                        .accessibilityIdentifier("pocket.sessions.refreshing")
                } else {
                    Button("Try again") { send(.refreshSessions) }
                        .buttonStyle(.borderedProminent)
                        .tint(PocketPalette.accent)
                        .accessibilityIdentifier("pocket.sessions.retry")
                }
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }


    private func failureRow(_ failure: SessionLoadFailure) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.title).font(.headline)
                Text(failure.detail)
                    .font(.subheadline)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PocketPalette.warning)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A chat's row says what a new person needs: its name, when it was last active, what is unread, and its summary.
/// Never its id, the server's status, its role, its kind or its counts (Carter, 2026-11-06, ticket 693f0cc5).
private struct SessionRow: View {
    let row: SessionRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // When it was last active and the unread badge sit on the right of the name's line, as Messages and
            // Discord show them; under the name when large text leaves no room.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: 10)
                    lastActive
                    PocketCountBadge(count: row.activity.unread)
                }
                VStack(alignment: .leading, spacing: 5) {
                    title
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        lastActive
                        PocketCountBadge(count: row.activity.unread)
                    }
                }
            }

            if let summary = row.summary {
                SummaryPreviewText(summary, title: row.title, identifier: "pocket.sessions.row.\(row.sessionId).summary")
                    .font(.subheadline)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var title: some View {
        Text(row.title)
            .font(.headline)
            .foregroundStyle(PocketPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "5m ago", or "just now" within the minute. A time the phone cannot read shows nothing rather than the
    /// server's text.
    @ViewBuilder
    private var lastActive: some View {
        if let date = row.lastActivity?.date {
            AgoText(date: date)
                .font(.caption)
                .foregroundStyle(PocketPalette.textSecondary)
                .fixedSize()
        } else if row.lastActivity == nil {
            Text(ChatListWords.noActivity)
                .font(.caption)
                .foregroundStyle(PocketPalette.textSecondary)
                .fixedSize()
        }
    }
}

struct SessionProvenanceBanner: View {
    let provenance: SessionPresentationProvenance

    var body: some View {
        Label {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pocket.sessions.provenance")
    }

    private var message: String {
        switch provenance {
        case .network(let lastUpdated):
            return ChatListWords.upToDate(updated: lastUpdated.formatted(.relative(presentation: .named)))
        case .cache(let cachedAt, let authenticationExpired):
            return ChatListWords.savedCopy(from: cachedAt.formatted(.relative(presentation: .named)),
                                           signInAgain: authenticationExpired)
        case .fixture:
            return "Preview data · not live"
        case .unavailable:
            return ChatListWords.notConnected
        }
    }

    private var icon: String {
        switch provenance {
        case .network: return "network"
        case .cache: return "arrow.down.circle"
        case .fixture: return "doc.text.magnifyingglass"
        case .unavailable: return "lock.slash"
        }
    }

    private var color: Color {
        switch provenance {
        case .network: return PocketPalette.accent
        case .cache: return PocketPalette.warning
        case .fixture, .unavailable: return PocketPalette.textSecondary
        }
    }
}

/// The words of the chat list, once "Sessions": the first screen a new person meets says chats (Carter, 2026-11-06).
enum ChatListWords {
    static let title = "Chats"
    static let section = "Your chats"
    static let rowHint = "Opens this chat"
    static let loadMore = "Load more chats"
    static let loading = "Loading chats"
    static let loadingDetail = "Getting your chats."
    static let notConnected = "Not connected"
    static let noActivity = "No activity yet"

    static func emptyTitle(_ provenance: SessionPresentationProvenance) -> String {
        switch provenance {
        case .network: return "No chats yet"
        case .cache: return "No saved chats"
        case .fixture: return "No preview chats"
        case .unavailable: return "Chats unavailable"
        }
    }

    static func emptyDetail(_ provenance: SessionPresentationProvenance) -> String {
        switch provenance {
        case .network: return "Chats you start or join show up here."
        case .cache: return "Reconnect to see your latest chats."
        case .fixture: return "This build has no live chats."
        case .unavailable: return "Sign in and connect to Senti to see your chats."
        }
    }

    /// The banner over a list read just now: "Up to date · updated now".
    static func upToDate(updated: String) -> String {
        "Up to date · updated \(updated)"
    }

    /// The banner over the copy kept on the phone: "Saved copy · from 5 minutes ago".
    static func savedCopy(from: String, signInAgain: Bool) -> String {
        "Saved copy · from \(from)" + (signInAgain ? " · sign in again to refresh" : "")
    }
}
#endif
