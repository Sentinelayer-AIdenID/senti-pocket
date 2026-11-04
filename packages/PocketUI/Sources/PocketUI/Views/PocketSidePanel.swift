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
        /// Who is in the room now and your unread messages.
        public let activity: RoomListActivity
        /// A direct message: whom it is with and the room it was opened from. Nil for a room.
        public let direct: Direct?
        /// Your folder for the room, as the room list says; nil in none.
        public let folderId: String?

        public init(id: String, title: String, subtitle: String?, lastActivity: Date?, kind: String? = nil,
                    activity: RoomListActivity = .none, direct: Direct? = nil, folderId: String? = nil) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.lastActivity = lastActivity
            self.kind = kind
            self.activity = activity
            self.direct = direct
            self.folderId = direct == nil ? folderId : nil
        }
    }

    /// Whom a direct message is with, and where it lives in the panel.
    public struct Direct: Equatable, Sendable {
        public let name: String
        public let isAgent: Bool
        /// The room it was opened from, which it sits under; nil when that room is gone or no longer visible.
        public let originRoomId: String?

        public init(name: String, isAgent: Bool, originRoomId: String?) {
            self.name = name
            self.isAgent = isAgent
            self.originRoomId = originRoomId
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
    /// Your folders, or nil where folders are off: then nothing about folders shows.
    private let folders: [RoomFolderItem]?
    /// Something the folders have to say once (a folder that is gone, a change that did not save).
    private let folderNotice: String?
    private let onFolder: ((RoomFolderIntent) -> Void)?
    @State private var query = ""
    /// Folders you folded, by id, kept between launches.
    @AppStorage("pocket.drawer.foldedFolders") private var foldedRaw = ""
    /// At the largest text sizes a room's age and who is online go under its name, so the name keeps its line.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        folders: [RoomFolderItem]? = nil,
        folderNotice: String? = nil,
        onFolder: ((RoomFolderIntent) -> Void)? = nil
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
        // Folders show only where they are on and can be changed: both or neither.
        let foldersOn = folders != nil && onFolder != nil
        self.folders = foldersOn ? folders : nil
        self.folderNotice = foldersOn ? folderNotice : nil
        self.onFolder = foldersOn ? onFolder : nil
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

    /// What VoiceOver says for a room's row: "Design review, open now", or with who is online and what is unread,
    /// "Weekly sync, 3 people and 2 agents online, 5 unread".
    static func accessibilityLabel(title: String, isCurrent: Bool, activity: RoomListActivity) -> String {
        [title, isCurrent ? "open now" : nil, activity.accessibilityDescription].compactMap { $0 }.joined(separator: ", ")
    }

    /// The room you are in shows no badge: what it shows is being read, and its count was made before you opened it.
    static func shownActivity(of room: Room, currentRoomId: String?) -> RoomListActivity {
        room.id == currentRoomId ? room.activity.whileReading : room.activity
    }

    /// What VoiceOver says for a direct message's row: "Direct message with Ada, 2 unread".
    static func directAccessibilityLabel(name: String, isAgent: Bool, isCurrent: Bool, unread: Int) -> String {
        ["Direct message with \(name)\(isAgent ? ", an agent" : "")", isCurrent ? "open now" : nil,
         unread > 0 ? "\(unread) unread" : nil].compactMap { $0 }.joined(separator: ", ")
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
                // Decisions first: what is waiting on you, across every room.
                if let waitingOnYou {
                    shortcut("Waiting on you", icon: "hand.raised", badge: waitingOnYou, id: "waiting", action: onWaitingOnYou)
                }
                shortcut("Notifications", icon: "bell", badge: unreadNotifications, id: "notifications", action: onNotifications)
                shortcut("Calls & briefings", icon: "phone", id: "calls", action: onCalls)
                shortcut("Activity", icon: "waveform.path.ecg", id: "activity", action: onActivity)
            }
            .padding(.top, 10)

            Divider().padding(.vertical, 8)

            HStack(spacing: 8) {
                // With folders, the rooms in none have their own "Rooms" under the folders; this heads them all.
                Text(folders?.isEmpty == false ? "Your rooms" : "Rooms")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PocketPalette.textSecondary)
                Spacer()
                if let onFolder {
                    Button {
                        onFolder(.create(fileRoomId: nil))
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(PocketPalette.accentStrong)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New folder")
                    .accessibilityIdentifier("pocket.drawer.newFolder")
                }
                Button("See all", action: onAllRooms)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PocketPalette.accentStrong)
                    .accessibilityIdentifier("pocket.drawer.allRooms")
            }
            .padding(.leading, 18)
            .padding(.trailing, onFolder == nil ? 18 : 10)
            .padding(.bottom, onFolder == nil ? 4 : 0)

            if let folderNotice {
                HStack(spacing: 6) {
                    Text(folderNotice)
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textPrimary)
                    Spacer(minLength: 4)
                    Button {
                        onFolder?(.dismissNotice)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.leading, 18)
                .padding(.trailing, 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pocket.drawer.folderNotice")
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        placedRooms
                    } else {
                        // A search is one flat list of what matches, rooms and direct messages alike.
                        let shown = Self.filter(rooms, by: query)
                        if shown.isEmpty {
                            emptyLine("No rooms match")
                        }
                        ForEach(shown) { room in
                            if room.direct != nil { directRow(room, nested: false) } else { roomRow(room) }
                        }
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
                PocketCountBadge(count: badge)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) unread" : title)
        .accessibilityIdentifier("pocket.drawer.\(id)")
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(PocketPalette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
    }

    private var folded: Set<String> {
        Set(foldedRaw.split(separator: "\n").map(String.init))
    }

    private func toggleFolded(_ id: String) {
        var set = folded
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        foldedRaw = set.sorted().joined(separator: "\n")
    }

    /// Your folders, then Rooms, then Messages; each direct message under the room it was opened from, where Carter
    /// asked for it to live.
    @ViewBuilder
    private var placedRooms: some View {
        let layout = SidePanelLayout.make(rooms, folders: folders)
        if layout.isEmpty {
            emptyLine("No rooms yet")
        }
        ForEach(Array(layout.folders.enumerated()), id: \.element.id) { index, section in
            folderHeader(section, isFirst: index == 0, isLast: index == layout.folders.count - 1)
            if !folded.contains(section.id) {
                if section.entries.isEmpty {
                    Text("No rooms in this folder")
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 40)
                        .padding(.vertical, 4)
                }
                ForEach(section.entries) { entry in
                    entryRows(entry)
                }
            }
        }
        if !layout.folders.isEmpty, !layout.rooms.isEmpty {
            sectionLabel("Rooms", id: "unfiled")
        }
        ForEach(layout.rooms) { entry in
            entryRows(entry)
        }
        if !layout.messages.isEmpty {
            sectionLabel("Messages", id: "messages")
            ForEach(layout.messages) { room in
                directRow(room, nested: false)
            }
        }
    }

    @ViewBuilder
    private func entryRows(_ entry: SidePanelLayout.Entry) -> some View {
        roomRow(entry.room)
        ForEach(entry.directs) { direct in
            directRow(direct, nested: true)
        }
    }

    private func sectionLabel(_ title: String, id: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PocketPalette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("pocket.drawer.section.\(id)")
    }

    /// A folder's line: tap to fold or open it; its menu renames, moves and deletes it. Folded, it shows its unread.
    private func folderHeader(_ section: SidePanelLayout.FolderSection, isFirst: Bool, isLast: Bool) -> some View {
        let isFolded = folded.contains(section.id)
        return HStack(spacing: 8) {
            Button {
                toggleFolded(section.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isFolded ? 0 : 90))
                        .foregroundStyle(PocketPalette.textSecondary)
                        .frame(width: 12)
                    Image(systemName: "folder.fill")
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.accentStrong)
                    Text(section.folder.name)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isFolded { PocketCountBadge(count: section.unread) }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(["Folder \(section.folder.name)", isFolded ? "folded" : "open",
                                 isFolded && section.unread > 0 ? "\(section.unread) unread" : nil]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint(isFolded ? "Shows its rooms" : "Folds its rooms away")
            .accessibilityIdentifier("pocket.drawer.folder.\(section.id)")
            if let onFolder {
                Menu {
                    Button { onFolder(.rename(folderId: section.id)) } label: { Label("Rename", systemImage: "pencil") }
                    Button { onFolder(.move(folderId: section.id, up: true)) } label: {
                        Label("Move up", systemImage: "arrow.up")
                    }
                    .disabled(isFirst)
                    Button { onFolder(.move(folderId: section.id, up: false)) } label: {
                        Label("Move down", systemImage: "arrow.down")
                    }
                    .disabled(isLast)
                    Button(role: .destructive) { onFolder(.delete(folderId: section.id)) } label: {
                        Label("Delete folder", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(section.folder.name) folder menu")
                .accessibilityIdentifier("pocket.drawer.folder.\(section.id).menu")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 2)
        .padding(.top, 2)
    }

    /// A direct message: the other side's picture and name, and its unread badge; under its room, indented.
    private func directRow(_ room: Room, nested: Bool) -> some View {
        let isCurrent = room.id == currentRoomId
        let activity = Self.shownActivity(of: room, currentRoomId: currentRoomId)
        let name = room.direct?.name ?? room.title
        let isAgent = room.direct?.isAgent ?? false
        return Button {
            onSelectRoom(room.id)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isCurrent ? PocketPalette.accent : Color.clear)
                    .frame(width: 3, height: 22)
                RoomAvatar(name: name, isHuman: !isAgent, size: 22)
                Text(name)
                    .font(.subheadline.weight(isCurrent || activity.unread > 0 ? .semibold : .regular))
                    .foregroundStyle(PocketPalette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let date = room.lastActivity, !dynamicTypeSize.isAccessibilitySize {
                    Text(Self.compactAge(of: date))
                        .font(.caption2)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .fixedSize()
                }
                PocketCountBadge(count: activity.unread)
            }
            .padding(.leading, nested ? 34 : 12)
            .padding(.trailing, 16)
            .padding(.vertical, 6)
            .background(isCurrent ? PocketPalette.inset : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.directAccessibilityLabel(name: name, isAgent: isAgent, isCurrent: isCurrent,
                                                          unread: activity.unread))
        .accessibilityIdentifier("pocket.drawer.direct.\(room.id)")
    }

    private func roomRow(_ room: Room) -> some View {
        let isCurrent = room.id == currentRoomId
        let activity = Self.shownActivity(of: room, currentRoomId: currentRoomId)
        let largeText = dynamicTypeSize.isAccessibilitySize
        return Button {
            onSelectRoom(room.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isCurrent ? PocketPalette.accent : Color.clear)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    // The name, then how long ago and who is online, then the unread badge on the right, as Discord
                    // lists channels. A room with unread messages has its name in bold.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(room.title)
                            .font(.subheadline.weight(isCurrent || activity.unread > 0 ? .semibold : .regular))
                            .foregroundStyle(PocketPalette.textPrimary)
                            .lineLimit(largeText ? 2 : 1)
                        Spacer(minLength: 0)
                        if !largeText { roomMeta(room, activity) }
                        PocketCountBadge(count: activity.unread)
                    }
                    if largeText { roomMeta(room, activity) }
                    if let kind = room.kind {
                        Text(kind)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(PocketPalette.accentStrong)
                            .lineLimit(1)
                    }
                    if let subtitle = room.subtitle {
                        SummaryPreviewText(subtitle, title: room.title, identifier: "pocket.drawer.room.\(room.id).summary",
                                           moreInline: true)
                            .font(.caption)
                            .foregroundStyle(PocketPalette.textSecondary)
                            .lineLimit(1)
                    }
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
        // Long-press: file the room in a folder, or take it out of one.
        .modifier(RoomFolderContextMenu(roomId: room.id, folderId: room.folderId, folders: folders, send: onFolder))
        .accessibilityLabel(Self.accessibilityLabel(title: room.title, isCurrent: isCurrent, activity: activity))
        .accessibilityIdentifier("pocket.drawer.room.\(room.id)")
    }

    /// How long ago the room was active ("5m"), then who is in it now.
    private func roomMeta(_ room: Room, _ activity: RoomListActivity) -> some View {
        HStack(spacing: 6) {
            if let date = room.lastActivity {
                Text(Self.compactAge(of: date))
            }
            RoomOnlineCounts(activity: activity)
        }
        .font(.caption2)
        .foregroundStyle(PocketPalette.textSecondary)
        .lineLimit(1)
        .fixedSize()
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
