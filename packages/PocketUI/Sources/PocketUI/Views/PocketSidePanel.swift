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

        /// The room list's row as the panel shows it.
        public init(row: SessionRowPresentation) {
            self.init(
                id: row.sessionId,
                title: row.title,
                subtitle: row.summary,
                lastActivity: row.lastActivity?.date,
                kind: row.roomTypeLabel,
                activity: row.activity,
                direct: row.counterpart.map {
                    Direct(name: $0.displayName, isAgent: $0.isAgent, originRoomId: row.originRoomId)
                },
                folderId: row.folderId
            )
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

    /// The rooms and folders, placed off the main thread; the panel only reads what is placed.
    @ObservedObject private var placement: SidePanelPlacement
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
    /// Something the folders have to say once (a folder that is gone, a change that did not save).
    private let folderNotice: String?
    /// What the folder controls ask for; nil where folders are off: then nothing about folders shows.
    private let onFolder: ((RoomFolderIntent) -> Void)?
    @State private var query = ""
    /// At the largest text sizes a room's age and who is online go under its name, so the name keeps its line.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// - Parameters:
    ///   - placement: the rooms and your folders, placed (`SidePanelPlacement.update`).
    ///   - onFolder: nil where folders are off.
    public init(
        placement: SidePanelPlacement,
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
        folderNotice: String? = nil,
        onFolder: ((RoomFolderIntent) -> Void)? = nil
    ) {
        _placement = ObservedObject(wrappedValue: placement)
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
        self.folderNotice = onFolder == nil ? nil : folderNotice
        self.onFolder = onFolder
    }

    /// How far each level of folders steps in.
    static let levelIndent: CGFloat = 12

    /// What VoiceOver says for a folder's row: "Studio, folder, level 2, 3 rooms, 1 unread, collapsed".
    static func folderAccessibilityLabel(name: String, depth: Int, rooms: Int, unread: Int, folded: Bool) -> String {
        "\(name), folder, level \(depth), \(rooms) \(rooms == 1 ? "room" : "rooms"), \(unread) unread, "
            + (folded ? "collapsed" : "expanded")
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
        // At the largest text sizes the title, search, shortcuts and Rooms line scroll with the rooms: held above them
        // they took most of the screen, and your folders had a sliver under them.
        let controlsScroll = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 0) {
            if !controlsScroll { controls }

            ScrollView {
                LazyVStack(spacing: 2) {
                    if controlsScroll {
                        controls
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        placedRooms
                    } else {
                        // A search is one flat list of what matches, rooms and direct messages alike.
                        let shown = Self.filter(placement.shown.rooms, by: query)
                        if shown.isEmpty {
                            emptyLine("No rooms match")
                        }
                        // One view per item (the wrapper), so the lazy list builds only the lines it shows.
                        ForEach(shown) { room in
                            VStack(alignment: .leading, spacing: 0) {
                                if room.direct != nil { directRow(room, depth: nil) } else { roomRow(room, depth: 0) }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .accessibilityIdentifier("pocket.drawer.list")

            Divider()
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PocketPalette.canvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.drawer")
    }

    /// The title, the search, the shortcuts, and the Rooms line with New folder and See all.
    private var controls: some View {
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

            // With folders, the rooms in none have their own "Your rooms" after the folders; this heads them all. At the
            // largest text sizes New folder and See all go under it, so no word is cut.
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 0) {
                        roomsTitle
                        HStack(spacing: 8) {
                            newFolderButton
                            Spacer(minLength: 0)
                            seeAllButton
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        roomsTitle
                        Spacer(minLength: 0)
                        newFolderButton
                        seeAllButton
                    }
                }
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
        }
    }

    private var roomsTitle: some View {
        Text("Rooms")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(PocketPalette.textSecondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var newFolderButton: some View {
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
    }

    private var seeAllButton: some View {
        Button("See all", action: onAllRooms)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(PocketPalette.accentStrong)
            .lineLimit(1)
            .accessibilityIdentifier("pocket.drawer.allRooms")
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

    /// Your folders, each with its rooms and the folders inside it, then Your rooms, then Messages; each direct message
    /// under the room it was opened from, where Carter asked for it to live. The lines were placed off the main thread.
    @ViewBuilder
    private var placedRooms: some View {
        let rows = placement.shown.rows
        if rows.isEmpty {
            emptyLine("No rooms yet")
        }
        // One view per row (the wrapper around the switch), so the lazy list builds only the rows it shows. An item that
        // can make a varying number of views makes a lazy list build every item at every layout pass to count them:
        // Carter's phone froze inside that walk with the panel open (11-04).
        ForEach(rows) { row in
            VStack(alignment: .leading, spacing: 0) {
                switch row {
                case .folder(let line):
                    folderHeader(line)
                case .emptyFolder(_, let depth):
                    Text("No rooms in this folder")
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 40 + Self.indent(depth))
                        .padding(.vertical, 4)
                case .room(let room, let depth):
                    roomRow(room, depth: depth)
                case .direct(let room, let depth):
                    directRow(room, depth: depth)
                case .message(let room):
                    directRow(room, depth: nil)
                case .label(let id, let title):
                    sectionLabel(title, id: id)
                }
            }
        }
    }

    /// How far a folder at `depth` steps in from the top level (level 1 does not).
    static func indent(_ depth: Int) -> CGFloat {
        CGFloat(max(0, depth - 1)) * levelIndent
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

    /// A folder's line: tap to fold or open it; its menu renames it, makes a folder inside it, moves it and deletes it.
    /// Folded, it shows how many rooms are in it (inside its folders too) and their unread.
    private func folderHeader(_ line: SidePanelLayout.FolderLine) -> some View {
        // At the largest text sizes the name keeps the line (two if it needs them) and the counts go under it.
        let largeText = dynamicTypeSize.isAccessibilitySize
        return HStack(spacing: 8) {
            Button {
                placement.toggleFolded(line.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(line.folded ? 0 : 90))
                        .foregroundStyle(PocketPalette.textSecondary)
                        .frame(width: 12)
                    Image(systemName: line.depth == 1 ? "folder.fill" : "folder")
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.accentStrong)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.folder.name)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(PocketPalette.textPrimary)
                            .lineLimit(largeText ? 2 : 1)
                        if largeText, line.folded { folderCounts(line) }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                    if !largeText, line.folded { folderCounts(line) }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.folderAccessibilityLabel(name: line.folder.name, depth: line.depth,
                                                              rooms: line.folder.totalRoomCount, unread: line.unread,
                                                              folded: line.folded))
            .accessibilityHint(line.folded ? "Shows what is in it" : "Folds it away")
            .accessibilityIdentifier("pocket.drawer.folder.\(line.id)")
            if let onFolder {
                Menu {
                    Button { onFolder(.rename(folderId: line.id)) } label: { Label("Rename", systemImage: "pencil") }
                    if line.canHoldFolder {
                        Button { onFolder(.createInside(folderId: line.id)) } label: {
                            Label("New folder inside", systemImage: "folder.badge.plus")
                        }
                    }
                    Button { onFolder(.pickParent(folderId: line.id)) } label: {
                        Label("Move to…", systemImage: "folder")
                    }
                    Button { onFolder(.move(folderId: line.id, up: true)) } label: {
                        Label("Move up", systemImage: "arrow.up")
                    }
                    .disabled(line.isFirst)
                    Button { onFolder(.move(folderId: line.id, up: false)) } label: {
                        Label("Move down", systemImage: "arrow.down")
                    }
                    .disabled(line.isLast)
                    Button(role: .destructive) { onFolder(.delete(folderId: line.id)) } label: {
                        Label("Delete folder", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(line.folder.name) folder menu")
                .accessibilityIdentifier("pocket.drawer.folder.\(line.id).menu")
            }
        }
        .padding(.leading, 14 + Self.indent(line.depth))
        .padding(.trailing, 2)
        .padding(.top, 2)
    }

    /// A folded folder's rooms (inside its folders too, as the server counts them) and their unread.
    private func folderCounts(_ line: SidePanelLayout.FolderLine) -> some View {
        HStack(spacing: 6) {
            Text("\(line.folder.totalRoomCount)")
                .font(.caption2)
                .foregroundStyle(PocketPalette.textSecondary)
                .fixedSize()
            PocketCountBadge(count: line.unread)
        }
    }

    /// A direct message: the other side's picture and name, and its unread badge; under its room, indented as far as
    /// the room is (`depth`), or on its own line when its room is gone (nil).
    private func directRow(_ room: Room, depth: Int?) -> some View {
        RenderTrace.built(.sidePanel)
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
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Spacer(minLength: 0)
                if let date = room.lastActivity, !dynamicTypeSize.isAccessibilitySize {
                    Text(Self.compactAge(of: date))
                        .font(.caption2)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .fixedSize()
                }
                PocketCountBadge(count: activity.unread)
            }
            .padding(.leading, depth.map { 34 + Self.roomIndent($0) } ?? 12)
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

    /// How far a room steps in: none in no folder, else one level past its folder's line.
    static func roomIndent(_ depth: Int) -> CGFloat {
        CGFloat(max(0, depth)) * levelIndent
    }

    /// A room, in a folder at `depth` (0: in none).
    private func roomRow(_ room: Room, depth: Int) -> some View {
        RenderTrace.built(.sidePanel)
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
            .padding(.leading, 12 + Self.roomIndent(depth))
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .background(isCurrent ? PocketPalette.inset : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Long-press: file the room in a folder, or take it out of one.
        .modifier(RoomFolderContextMenu(roomId: room.id,
                                        filedIn: room.folderId.flatMap { placement.shown.layout.tree.node($0)?.id },
                                        send: onFolder))
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
