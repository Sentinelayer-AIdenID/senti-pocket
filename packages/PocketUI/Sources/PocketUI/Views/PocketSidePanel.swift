#if canImport(SwiftUI)
import SwiftUI

/// How the app looks: the phone's setting, or always light or dark.
public enum PocketThemePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "Match the phone"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The side panel the top-left button opens, as in the big assistant apps: your rooms (searchable), the bell, calls
/// and briefings, activity, and you with Settings pinned at the bottom.
public struct PocketSidePanel: View {
    public struct Room: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let subtitle: String?
        public let lastActivity: Date?
        /// The room's kind when it isn't general ("Study together", "Research", "Meetings").
        public let kind: String?

        public init(id: String, title: String, subtitle: String?, lastActivity: Date?, kind: String? = nil) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.lastActivity = lastActivity
            self.kind = kind
        }
    }

    private let rooms: [Room]
    private let currentRoomId: String?
    private let unreadNotifications: Int
    /// How many asks wait on your decision; nil where the server has no such list yet.
    private let waitingOnYou: Int?
    private let accountName: String?
    @Binding private var theme: PocketThemePreference
    private let onSelectRoom: (String) -> Void
    private let onAllRooms: () -> Void
    private let onNotifications: () -> Void
    private let onWaitingOnYou: () -> Void
    private let onCalls: () -> Void
    private let onActivity: () -> Void
    private let onSettings: () -> Void
    /// Start a new room of a type (Carter, #55287); nil where rooms cannot be made.
    private let onNewRoom: (() -> Void)?
    /// Plan & billing (Carter, 10-31); nil where it isn't offered.
    private let onBilling: (() -> Void)?
    @State private var query = ""

    public init(
        rooms: [Room],
        currentRoomId: String?,
        unreadNotifications: Int,
        waitingOnYou: Int? = nil,
        accountName: String?,
        theme: Binding<PocketThemePreference>,
        onSelectRoom: @escaping (String) -> Void,
        onAllRooms: @escaping () -> Void,
        onNotifications: @escaping () -> Void,
        onWaitingOnYou: @escaping () -> Void = {},
        onCalls: @escaping () -> Void,
        onActivity: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onNewRoom: (() -> Void)? = nil,
        onBilling: (() -> Void)? = nil
    ) {
        self.rooms = rooms
        self.currentRoomId = currentRoomId
        self.unreadNotifications = unreadNotifications
        self.waitingOnYou = waitingOnYou
        self.accountName = accountName
        _theme = theme
        self.onSelectRoom = onSelectRoom
        self.onAllRooms = onAllRooms
        self.onNotifications = onNotifications
        self.onWaitingOnYou = onWaitingOnYou
        self.onCalls = onCalls
        self.onActivity = onActivity
        self.onSettings = onSettings
        self.onNewRoom = onNewRoom
        self.onBilling = onBilling
    }

    /// How long ago, in the fewest characters: "now", "12m", "7h", "3d", "5w".
    static func compactAge(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (7 * 86_400)))w"
        }
    }

    /// Rooms whose title or summary contains the search, in the order given (most recent activity first).
    static func filter(_ rooms: [Room], by query: String) -> [Room] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rooms }
        return rooms.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || ($0.subtitle?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Senti")
                .font(.title2.bold())
                .foregroundStyle(PocketPalette.textPrimary)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(PocketPalette.textSecondary)
                    .accessibilityHidden(true)
                TextField("Search rooms", text: $query)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel("Search rooms")
                    .accessibilityIdentifier("pocket.drawer.search")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 14)

            VStack(spacing: 2) {
                if let onNewRoom {
                    shortcut("New room", icon: "plus.bubble", id: "newRoom", action: onNewRoom)
                }
                // Decisions first: what is waiting on you, across every room (Carter, 10-30).
                if let waitingOnYou {
                    shortcut("Waiting on you", icon: "hand.raised", badge: waitingOnYou, id: "waiting", action: onWaitingOnYou)
                }
                shortcut("Notifications", icon: "bell", badge: unreadNotifications, id: "notifications", action: onNotifications)
                shortcut("Calls & briefings", icon: "phone", id: "calls", action: onCalls)
                shortcut("Activity", icon: "waveform.path.ecg", id: "activity", action: onActivity)
                if let onBilling {
                    shortcut("Plan & billing", icon: "creditcard", id: "billing", action: onBilling)
                }
            }
            .padding(.top, 10)

            Divider().padding(.vertical, 8)

            HStack {
                Text("Rooms")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PocketPalette.textSecondary)
                Spacer()
                Button("See all", action: onAllRooms)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PocketPalette.accentStrong)
                    .accessibilityIdentifier("pocket.drawer.allRooms")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 2) {
                    let shown = Self.filter(rooms, by: query)
                    if shown.isEmpty {
                        Text(query.isEmpty ? "No rooms yet" : "No rooms match")
                            .font(.footnote)
                            .foregroundStyle(PocketPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                    }
                    ForEach(shown) { room in
                        roomRow(room)
                    }
                }
                .padding(.bottom, 8)
            }

            Divider()
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PocketPalette.canvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.drawer")
    }

    private func shortcut(_ title: String, icon: String, badge: Int = 0, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .frame(width: 24)
                Text(title)
                    .font(.body)
                    .foregroundStyle(PocketPalette.textPrimary)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(PocketPalette.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) unread" : title)
        .accessibilityIdentifier("pocket.drawer.\(id)")
    }

    private func roomRow(_ room: Room) -> some View {
        let isCurrent = room.id == currentRoomId
        return Button {
            onSelectRoom(room.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isCurrent ? PocketPalette.accent : Color.clear)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.title)
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(PocketPalette.textPrimary)
                        .lineLimit(1)
                    if let kind = room.kind {
                        Text(kind)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PocketPalette.accentStrong)
                            .lineLimit(1)
                    }
                    if let subtitle = room.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(PocketPalette.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let date = room.lastActivity {
                    Text(Self.compactAge(of: date))
                        .font(.caption2)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .background(isCurrent ? PocketPalette.inset : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCurrent ? "\(room.title), open now" : room.title)
        .accessibilityIdentifier("pocket.drawer.room.\(room.id)")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: onSettings) {
                HStack(spacing: 10) {
                    Text(initials)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(PocketPalette.accent, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(accountName ?? "You")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PocketPalette.textPrimary)
                            .lineLimit(1)
                        Text("Settings")
                            .font(.caption)
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings and account")
            .accessibilityIdentifier("pocket.drawer.settings")
            Spacer(minLength: 0)
            Menu {
                Picker("Appearance", selection: $theme) {
                    ForEach(PocketThemePreference.allCases) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
            } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.title3)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Appearance, \(theme.label)")
            .accessibilityIdentifier("pocket.drawer.appearance")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var initials: String {
        let name = (accountName ?? "You").trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
#endif
