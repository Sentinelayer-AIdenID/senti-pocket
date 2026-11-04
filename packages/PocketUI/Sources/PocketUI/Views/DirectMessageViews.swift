#if canImport(SwiftUI)
import SwiftUI
import PocketContracts

/// A message's avatar: where profile cards open (direct messages on), a tap opens the author's card. Never on
/// yourself or the room's voice. A long press on the message is still its menu.
struct RoomProfileAvatar: View {
    let senderId: String
    let name: String
    let isHuman: Bool
    var size: CGFloat = 26
    @Environment(\.roomProfileOpener) private var opener

    var body: some View {
        if let opener, opener.opens(senderId) {
            Button {
                opener(RoomProfileTarget(senderId: senderId, name: name, isAgent: !isHuman))
            } label: {
                RoomAvatar(name: name, isHuman: isHuman, size: size)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name)'s profile")
            .accessibilityHint("Opens their card, to message them directly")
            .accessibilityIdentifier("pocket.room.avatar.\(senderId)")
        } else {
            RoomAvatar(name: name, isHuman: isHuman, size: size)
        }
    }
}

/// Someone's card, from their avatar: who they are, the rooms you share, Message, and Block where the app has it.
public struct RoomProfileCardView: View {
    private let state: RoomProfileCardState
    private let onMessage: () -> Void
    private let onBlock: (() -> Void)?
    private let onClose: () -> Void

    /// The most shared rooms listed by name; the rest are counted.
    static let roomsShown = 4

    public init(state: RoomProfileCardState, onMessage: @escaping () -> Void, onBlock: (() -> Void)? = nil,
                onClose: @escaping () -> Void) {
        self.state = state
        self.onMessage = onMessage
        self.onBlock = onBlock
        self.onClose = onClose
    }

    /// "Rooms you share" as listed: up to `roomsShown` names, then "and 3 more".
    static func sharedLines(_ rooms: [String]) -> [String] {
        let shown = Array(rooms.prefix(roomsShown))
        let more = rooms.count - shown.count
        return more > 0 ? shown + ["and \(more) more"] : shown
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                RoomAvatar(name: state.target.name, isHuman: !state.target.isAgent, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.target.name)
                        .font(.title3.bold())
                        .foregroundStyle(PocketPalette.textPrimary)
                        .lineLimit(2)
                        .accessibilityIdentifier("pocket.profile.name")
                    Text(state.target.isAgent ? "Agent" : "Person")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PocketPalette.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(PocketPalette.inset, in: Capsule())
                        .accessibilityIdentifier("pocket.profile.kind")
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(PocketPalette.inset, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("pocket.profile.close")
            }

            if !state.sharedRooms.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.sharedRooms.count == 1 ? "Room you share" : "Rooms you share")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(Self.sharedLines(state.sharedRooms).enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "bubble.left.and.bubble.right")
                            .font(.subheadline)
                            .foregroundStyle(PocketPalette.textPrimary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pocket.profile.sharedRooms")
            }

            VStack(spacing: 10) {
                if state.canMessage {
                    Button(action: onMessage) {
                        HStack(spacing: 8) {
                            if state.phase == .opening {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "bubble.left.fill")
                            }
                            Text(state.phase == .opening ? "Opening…" : "Message")
                                .font(.body.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(PocketPalette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(state.phase == .opening)
                    .accessibilityLabel("Message \(state.target.name)")
                    .accessibilityIdentifier("pocket.profile.message")
                }
                if state.canBlock, let onBlock {
                    Button(role: .destructive, action: onBlock) {
                        Text("Block \(state.target.name)")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(PocketPalette.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pocket.profile.block")
                }
            }

            if case .notice(let text) = state.phase {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pocket.profile.notice")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PocketPalette.canvas.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.profile.card")
        // VoiceOver says why Message did nothing ("You can't message Sam right now") as soon as it shows.
        .onChange(of: state.phase) { phase in
            if case .notice(let text) = phase { announceToVoiceOver(text) }
        }
    }
}

/// Says `text` to VoiceOver now, where there is one.
func announceToVoiceOver(_ text: String) {
    #if os(iOS)
    UIAccessibility.post(notification: .announcement, argument: text)
    #endif
}

/// The top of a direct message, in either layout (`DirectRoomHeaderStyle`). Compact: one line, "From <room> ›" (opens
/// the room) and, for an agent, a "Memory: Off" pill that opens the switch, folded by default. Expanded: whom it is with,
/// the "Shared room" chip and the switch with its note. The switch shows only the server's value: off until you turn
/// it on. Nothing here says what the other side is doing.
public struct DirectRoomHeaderView: View {
    private let state: DirectRoomHeaderState
    private let style: DirectRoomHeaderStyle
    private let onOpenSharedRoom: (String) -> Void
    private let onSetMemory: (Bool) -> Void
    private let onDismissNotice: () -> Void
    /// The compact header's switch, opened from its pill.
    @State private var memoryOpen: Bool

    public init(state: DirectRoomHeaderState, style: DirectRoomHeaderStyle = .compact, memoryOpen: Bool = false,
                onOpenSharedRoom: @escaping (String) -> Void, onSetMemory: @escaping (Bool) -> Void,
                onDismissNotice: @escaping () -> Void = {}) {
        self.state = state
        self.style = style
        self.onOpenSharedRoom = onOpenSharedRoom
        self.onSetMemory = onSetMemory
        self.onDismissNotice = onDismissNotice
        _memoryOpen = State(initialValue: memoryOpen)
    }

    /// Nothing to show: no room to go back to, no switch, nothing to say.
    private var isEmpty: Bool {
        style == .compact && state.fromChip == nil && state.memoryPill == nil && state.notice == nil
    }

    public var body: some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                switch style {
                case .compact: compact
                case .expanded: expanded
                }
                if let notice = state.notice {
                    noticeRow(notice)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, style == .compact ? 2 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pocket.direct.header")
        }
    }

    // MARK: - Compact

    /// One line: the room it came from, and the switch's pill. When the two do not fit side by side (the largest text
    /// sizes) the pill goes under the chip, each whole.
    @ViewBuilder
    private var compact: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                fromRoomChip(whole: true)
                Spacer(minLength: 0)
                memoryPillButton
            }
            VStack(alignment: .leading, spacing: 0) {
                fromRoomChip(whole: false)
                memoryPillButton
            }
        }
        if memoryOpen {
            memorySwitch
                .padding(.bottom, 8)
                .transition(.opacity)
        }
    }

    /// `whole`: on the shared line, at its full width (the line is chosen only when it fits); on a line of its own, the
    /// room's name wraps instead of running off the screen.
    @ViewBuilder
    private func fromRoomChip(whole: Bool) -> some View {
        if let id = state.sharedRoomId, let chip = state.fromChip {
            Button {
                onOpenSharedRoom(id)
            } label: {
                HStack(spacing: 4) {
                    Text(chip).lineLimit(whole ? 1 : 3)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.accentStrong)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .fixedSize(horizontal: whole, vertical: true)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(chip)
            .accessibilityHint("Opens that room")
            .accessibilityIdentifier("pocket.direct.fromRoom")
        }
    }

    @ViewBuilder
    private var memoryPillButton: some View {
        if let pill = state.memoryPill, let memory = state.memory {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { memoryOpen.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: memory.isOn ? "brain.head.profile" : "lock")
                    Text(pill)
                    Image(systemName: memoryOpen ? "chevron.up" : "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(memory.isOn ? PocketPalette.accentStrong : PocketPalette.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(PocketPalette.inset, in: Capsule())
                .fixedSize()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pill)
            .accessibilityHint(memoryOpen ? "Hides the switch" : "Shows the switch")
            .accessibilityIdentifier("pocket.direct.memoryPill")
        }
    }

    // MARK: - Expanded

    @ViewBuilder
    private var expanded: some View {
        HStack(spacing: 10) {
            RoomAvatar(name: state.name, isHuman: !state.isAgent, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PocketPalette.textPrimary)
                    .lineLimit(1)
                Text(state.subtitle)
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        // On a line of its own, so the room's name is read whole.
        if let id = state.sharedRoomId, let chip = state.sharedRoomChip {
            Button {
                onOpenSharedRoom(id)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text(chip).lineLimit(3)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.accentStrong)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(PocketPalette.inset, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens that room")
            .accessibilityIdentifier("pocket.direct.sharedRoom")
        }
        if state.memory != nil {
            memorySwitch
        }
    }

    // MARK: - Shared parts

    /// "Let <agent> use this chat in <room>", the server's value, and what that value means.
    @ViewBuilder
    private var memorySwitch: some View {
        if let memory = state.memory, let label = state.memoryLabel, let note = state.memoryNote {
            VStack(alignment: .leading, spacing: 3) {
                Toggle(isOn: Binding(get: { memory.isOn }, set: { onSetMemory($0) })) {
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.footnote)
                            .foregroundStyle(PocketPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if memory.isSaving { ProgressView().controlSize(.small) }
                    }
                }
                .tint(PocketPalette.accent)
                .disabled(memory.isSaving)
                .accessibilityIdentifier("pocket.direct.memory")
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pocket.direct.memoryNote")
            }
        }
    }

    private func noticeRow(_ notice: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(PocketPalette.warning)
            Text(notice).font(.caption).foregroundStyle(PocketPalette.textPrimary)
            Spacer(minLength: 0)
            Button(action: onDismissNotice) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PocketPalette.textSecondary)
            .accessibilityLabel("Dismiss")
        }
        .accessibilityIdentifier("pocket.direct.notice")
        .onAppear { announceToVoiceOver(notice) }
    }
}

/// A room's folder choices, in its long-press menu (the side panel and All rooms): move it to a folder (or a new one),
/// or take it out of the one it is in.
public struct RoomFolderMenuItems: View {
    let roomId: String
    let folderId: String?
    let folders: [RoomFolderItem]
    let send: (RoomFolderIntent) -> Void

    public init(roomId: String, folderId: String?, folders: [RoomFolderItem], send: @escaping (RoomFolderIntent) -> Void) {
        self.roomId = roomId
        self.folderId = folderId
        self.folders = folders
        self.send = send
    }

    public var body: some View {
        let others = RoomFolderItem.ordered(folders).filter { $0.id != folderId }
        Menu {
            ForEach(others) { folder in
                Button {
                    send(.file(roomId: roomId, folderId: folder.id))
                } label: {
                    Label(folder.name, systemImage: "folder")
                }
            }
            if !others.isEmpty { Divider() }
            Button {
                send(.create(fileRoomId: roomId))
            } label: {
                Label("New folder…", systemImage: "folder.badge.plus")
            }
        } label: {
            Label("Move to folder", systemImage: "folder")
        }
        if let folderId, folders.contains(where: { $0.id == folderId }) {
            Button {
                send(.unfile(roomId: roomId, folderId: folderId))
            } label: {
                Label("Remove from folder", systemImage: "folder.badge.minus")
            }
        }
    }
}

/// A room's long press with its folder choices, only where folders are on: with them off the room has no long-press
/// menu at all, as before.
struct RoomFolderContextMenu: ViewModifier {
    let roomId: String
    let folderId: String?
    let folders: [RoomFolderItem]?
    let send: ((RoomFolderIntent) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let folders, let send {
            content.contextMenu {
                RoomFolderMenuItems(roomId: roomId, folderId: folderId, folders: folders, send: send)
            }
        } else {
            content
        }
    }
}

/// Naming a folder, new or renamed: the name is checked as it is typed (1 to 60 characters, at most 100 folders), and
/// what the server said about it (a name already used) shows under it.
public struct RoomFolderNameSheet: View {
    private let title: String
    private let isNew: Bool
    private let folderCount: Int
    private let serverProblem: String?
    private let isSaving: Bool
    private let onSave: (String) -> Void
    private let onCancel: () -> Void
    @State private var name: String
    @State private var edited = false

    public init(title: String, initialName: String = "", isNew: Bool, folderCount: Int, serverProblem: String?,
                isSaving: Bool, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.isNew = isNew
        self.folderCount = folderCount
        self.serverProblem = serverProblem
        self.isSaving = isSaving
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
    }

    private var check: RoomFolderSheetCheck {
        RoomFolderSheetCheck.check(name, isNew: isNew, folderCount: folderCount)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder name", text: $name)
                        .autocorrectionDisabled()
                        .onSubmit { save() }
                        .onChange(of: name) { _ in edited = true }
                        .accessibilityIdentifier("pocket.folder.name")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if case .problem(let text) = check, edited || isNew && folderCount >= RoomFolderName.maximumFolders {
                            Text(text).foregroundStyle(PocketPalette.danger)
                                .accessibilityIdentifier("pocket.folder.problem")
                        } else if let serverProblem {
                            Text(serverProblem).foregroundStyle(PocketPalette.danger)
                                .accessibilityIdentifier("pocket.folder.serverProblem")
                        } else {
                            Text("Only you see your folders. Up to \(RoomFolderName.maximumLength) characters.")
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", action: save)
                            .disabled(!canSave)
                            .accessibilityIdentifier("pocket.folder.save")
                    }
                }
            }
        }
    }

    private var canSave: Bool {
        if case .ok = check { return !isSaving }
        return false
    }

    private func save() {
        guard canSave, case .ok(let cleaned) = check else { return }
        onSave(cleaned)
    }
}
#endif
