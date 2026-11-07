import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import SwiftUI

// Direct messages (Carter's ask): a tap on someone's avatar messages them privately, and the direct message sits under
// the room it started from. The server half is behind DIRECT_MESSAGES_ENABLED: with it off every route answers 404, and
// the app shows nothing of direct messages. Whether they are on is read from `GET /me/dm-settings`.

/// What the room list knows of a direct message when it is opened: whom it is with, and the room it started from.
struct DirectRoomInfo: Hashable {
    let counterpart: SessionCounterpart
    let originRoomId: String?
    let originTitle: String?

    /// A direct message's row, with its room's title from the same list; nil for a room.
    init?(row: SessionRowPresentation?, rows: [SessionRowPresentation]) {
        guard let row, let counterpart = row.counterpart else { return nil }
        self.counterpart = counterpart
        self.originRoomId = row.originRoomId
        self.originTitle = row.originRoomId.flatMap { id in
            rows.first { UTF8ExactIdentity.matches($0.sessionId, id) && !$0.isDirect }?.title
        }
    }

    /// A direct message the server just opened.
    init(_ dm: DirectMessage) {
        counterpart = dm.counterpart
        originRoomId = dm.originRoom?.sessionId
        originTitle = dm.originRoom?.title
    }
}

/// Whether direct messages are on for this account, and who can message you. One per signed-in app.
@MainActor
final class DirectMessagesCenter: ObservableObject {
    /// On once the server answered its settings; off until then, and after a 404 (the feature is off).
    @Published private(set) var isAvailable = false
    /// Who can message you, as the server holds it; nil before it has said, or for a value this build does not know.
    @Published private(set) var allowance: DirectMessagesAllowance?
    @Published private(set) var isSavingAllowance = false
    @Published private(set) var allowanceNotice: String?

    let client: any DirectMessaging
    private let onReauthenticationRequired: @MainActor () -> Void
    private var reading: Task<Void, Never>?

    init(client: any DirectMessaging, onReauthenticationRequired: @escaping @MainActor () -> Void = {}) {
        self.client = client
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    /// When the server last answered a read of the settings, for the side panel's open. A failed read leaves it, so the
    /// next open asks again.
    private var readAt: Date?

    /// Reads again unless the settings were read less than `age` seconds ago.
    func refresh(ifOlderThan age: TimeInterval) async {
        if let readAt, Date().timeIntervalSince(readAt) < age { return }
        await refresh()
    }

    /// Asks the server whether direct messages are on (one read at a time). A 404 hides them; a failure that says
    /// nothing either way keeps what is shown.
    func refresh() async {
        if let reading { return await reading.value }
        let task = Task { await read() }
        reading = task
        await task.value
        reading = nil
    }

    /// A read that finds what is shown writes nothing, so the root and the side panel draw only for a change.
    private func read() async {
        do {
            let value = try await client.directMessageSettings()
            readAt = Date()
            if !isAvailable { isAvailable = true }
            if allowance != value { allowance = value }
        } catch DirectMessageError.unavailable {
            readAt = Date()
            if isAvailable { isAvailable = false }
            if allowance != nil { allowance = nil }
        } catch DirectMessageError.reauthenticationRequired {
            onReauthenticationRequired()
        } catch {
        }
    }

    /// "Who can message me". Shown at once; put back with a line if the server did not take it.
    func setAllowance(_ value: DirectMessagesAllowance) async {
        guard isAvailable, value != allowance, !isSavingAllowance else { return }
        let before = allowance
        allowance = value
        allowanceNotice = nil
        isSavingAllowance = true
        defer { isSavingAllowance = false }
        do {
            allowance = try await client.setDirectMessageSettings(value) ?? value
        } catch DirectMessageError.unavailable {
            isAvailable = false
            allowance = nil
        } catch DirectMessageError.reauthenticationRequired {
            allowance = before
            onReauthenticationRequired()
        } catch {
            allowance = before
            allowanceNotice = "Not saved. Check your connection and try again."
        }
    }

    /// What a room opened by its id is (from a push, a banner or a link): what the room list says, and when the list has
    /// not loaded it (a direct message that just arrived), what the server says, so a direct message opens as one,
    /// with its header, and never as a plain room whose avatars would offer Message from inside it. Nil is a room.
    func directInfo(for sessionId: String, row: SessionRowPresentation?,
                    rows: [SessionRowPresentation]) async -> DirectRoomInfo? {
        if let row { return DirectRoomInfo(row: row, rows: rows) }
        if !isAvailable { await refresh() }
        guard isAvailable, let dm = try? await client.directMessage(sessionId) else { return nil }
        return DirectRoomInfo(dm)
    }

    enum OpenOutcome: Equatable {
        case opened(DirectMessage)
        /// The server's one answer for blocked, off, not sharing a room and unknown.
        case refused
        case failed(String)
    }

    /// Opens (or finds) the direct message with `target`, from the room you are in.
    func open(_ target: RoomProfileTarget, from contextRoomId: String) async -> OpenOutcome {
        do {
            return .opened(try await client.openDirectMessage(with: target.senderId, from: contextRoomId))
        } catch DirectMessageError.unavailable {
            // Every refusal reads the same. If direct messages went off, reading the settings hides the rest of them.
            Task { await refresh() }
            return .refused
        } catch DirectMessageError.reauthenticationRequired {
            onReauthenticationRequired()
            return .failed("Sign in again to send messages.")
        } catch {
            return .failed("Couldn't open the conversation. Check your connection and try again.")
        }
    }
}

/// Which header a direct message shows: Carter's pick, one line to change. `.compact` is one line ("From <room> ›" and a
/// "Memory: Off" pill that opens the switch); `.expanded` is the full header with the switch always shown.
enum DirectRoomHeaderChoice {
    static let pick: DirectRoomHeaderStyle = .compact

    /// The pick, or in a DEBUG build the one a launch argument asks for (`-PocketDMHeaderExpanded`,
    /// `-PocketDMHeaderCompact`), so both can be shown from one build.
    static var current: DirectRoomHeaderStyle {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-PocketDMHeaderExpanded") { return .expanded }
        if arguments.contains("-PocketDMHeaderCompact") { return .compact }
        #endif
        return pick
    }
}

/// What a room screen needs for direct messages; nil where they are off.
struct RoomDirectContext {
    let center: DirectMessagesCenter
    /// The direct message you already have with a sender id, from the room list.
    let existing: @MainActor (String) -> String?
    /// Opens a direct message the server answered with, as the room on screen.
    let open: @MainActor (DirectMessage) -> Void

    /// The context for a room screen, or nil while direct messages are off (or not known to be on): then no avatar is a
    /// button, no card opens and no direct message shows its switch.
    @MainActor
    static func ifAvailable(_ center: DirectMessagesCenter, existing: @escaping @MainActor (String) -> String?,
                            open: @escaping @MainActor (DirectMessage) -> Void) -> RoomDirectContext? {
        center.isAvailable ? RoomDirectContext(center: center, existing: existing, open: open) : nil
    }
}

// MARK: - The profile card

@MainActor
final class RoomProfileModel: ObservableObject {
    @Published private(set) var state: RoomProfileCardState
    private let canMessage: Bool
    private let canBlock: Bool

    init(target: RoomProfileTarget, sharedRoom: String?, canMessage: Bool, canBlock: Bool) {
        self.canMessage = canMessage
        self.canBlock = canBlock
        state = RoomProfileCardState(target: target, sharedRooms: sharedRoom.map { [$0] } ?? [], canMessage: canMessage,
                                     canBlock: canBlock)
    }

    /// The rooms you share with them, from the server (`GET /me/shared-rooms`): the newest few by name, newest first,
    /// and how many in all. Whether it answered. Until it does, and when it cannot (an API without the read answers 404,
    /// a 503 while the server does not answer it yet, or the read fails), the card keeps the room you are in, with no count.
    /// Nothing is asked for a public room's stand-in name, which names no account.
    @discardableResult
    func loadSharedRooms(_ reader: any SharedRoomsReading) async -> Bool {
        guard !RoomAuthor.isPublicAlias(state.target.senderId),
              let page = try? await reader.sharedRooms(with: state.target.senderId, cursor: nil,
                                                       limit: RoomProfileCardState.roomsShown),
              !page.rooms.isEmpty else { return false }
        state = state.with(sharedRooms: page.rooms.map(\.title), total: page.total, from: .server)
        return true
    }

    /// With a direct message already open with them, the rooms you share are the server's list.
    func loadSharedRooms(_ context: RoomDirectContext) async {
        guard let existing = context.existing(state.target.senderId),
              let dm = try? await context.center.client.directMessage(existing), !dm.mutualRooms.isEmpty else { return }
        state = state.with(sharedRooms: dm.mutualRooms.map(\.title), total: nil, from: .directMessage)
    }

    /// Message: opens the direct message from `roomId`; returns it, or says why not on the card.
    func message(_ context: RoomDirectContext, from roomId: String) async -> DirectMessage? {
        guard state.phase != .opening else { return nil }
        set(.opening)
        switch await context.center.open(state.target, from: roomId) {
        case .opened(let dm):
            set(.idle)
            return dm
        case .refused:
            set(.notice(RoomProfileCardState.refusal(name: state.target.name)))
        case .failed(let text):
            set(.notice(text))
        }
        return nil
    }

    private func set(_ phase: RoomProfileCardState.Phase) {
        state = RoomProfileCardState(target: state.target, sharedRooms: state.sharedRooms,
                                     sharedRoomsTotal: state.sharedRoomsTotal,
                                     sharedRoomsSource: state.sharedRoomsSource, canMessage: canMessage,
                                     canBlock: canBlock, phase: phase)
    }
}

/// The profile a tapped avatar or name opens, over the room (Carter, 11-04): the card on top (Message where direct
/// messages are on and reach them, Block where the app has it), how their posts come in, a box's live steps and its
/// Flight record, and their messages, paged, each one a jump back into the room.
struct RoomProfileSheet: View {
    let roomId: String
    /// Direct messages, where they are on; nil offers no Message.
    let context: RoomDirectContext?
    /// Block, where the app has a block flow (#312) and `RoomMemberBlock.offers` allows it, with the message it names
    /// (the newest of theirs in the list, never their id alone); nil shows no Block.
    let onBlock: ((Int64) -> Void)?
    /// A box's flight record entry, while it runs: its live steps.
    let box: FlightRecordState.Box?
    /// A message tapped in the list: the sheet closes and the room brings it into view.
    let onOpenMessage: (Int64) -> Void
    /// The room's Flight record, for a box.
    let onOpenFlight: (() -> Void)?
    let onClose: () -> Void
    /// The rooms you share, from the server; nil keeps the room you are in.
    let sharedRoomsReader: (any SharedRoomsReading)?
    /// The lab the server reports for an agent here, for the logo on its card, as after its name in the room.
    let reportedLab: String?
    @StateObject private var model: RoomProfileModel
    @StateObject private var messages: RoomMemberMessagesModel
    @State private var showsAllRooms = false

    init(target: RoomProfileTarget, roomId: String, sharedRoom: String?, canMessage: Bool, context: RoomDirectContext?,
         sharedRooms sharedRoomsReader: (any SharedRoomsReading)? = nil,
         messages reader: (any RoomAuthorMessagesReading)? = nil, box: FlightRecordState.Box? = nil,
         reportedLab: String? = nil,
         isBlocked: Bool = false, onBlock: ((Int64) -> Void)? = nil, onOpenMessage: @escaping (Int64) -> Void = { _ in },
         onOpenFlight: (() -> Void)? = nil, onReauthenticationRequired: @escaping @MainActor () -> Void = {},
         onClose: @escaping () -> Void) {
        self.roomId = roomId
        self.context = context
        self.onBlock = onBlock
        self.box = box
        self.reportedLab = reportedLab
        self.onOpenMessage = onOpenMessage
        self.onOpenFlight = onOpenFlight
        self.onClose = onClose
        self.sharedRoomsReader = sharedRoomsReader
        _model = StateObject(wrappedValue: RoomProfileModel(target: target, sharedRoom: sharedRoom,
                                                            canMessage: canMessage && context != nil,
                                                            canBlock: onBlock != nil))
        // Someone you blocked: their messages are not listed (or read).
        _messages = StateObject(wrappedValue: RoomMemberMessagesModel(
            sessionId: roomId, authorId: target.senderId, reader: reader, isBlocked: isBlocked,
            onReauthenticationRequired: onReauthenticationRequired
        ))
    }

    var body: some View {
        RoomMemberSheetView(
            card: model.state,
            messages: messages.state,
            box: box,
            // A box's model, as the room knows it.
            roomModel: box?.model,
            reportedLab: reportedLab,
            onMessage: {
                guard let context else { return }
                Task {
                    guard let dm = await model.message(context, from: roomId) else { return }
                    CrashReporter.shared.note("direct message opened")
                    onClose()
                    // After the card has gone, so the room it sat on can be replaced.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { context.open(dm) }
                }
            },
            onBlock: onBlock,
            onClose: onClose,
            onOpenMessage: { sequence in
                CrashReporter.shared.note("profile message opened")
                onOpenMessage(sequence)
            },
            onLoadMore: { Task { await messages.loadMore() } },
            onRetry: { Task { await messages.loadMore() } },
            onOpenFlight: onOpenFlight,
            onSeeAllRooms: sharedRoomsReader == nil ? nil : { showsAllRooms = true }
        )
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showsAllRooms) {
            if let sharedRoomsReader {
                RoomSharedRoomsSheet(principal: model.state.target.senderId, name: model.state.target.name,
                                     reader: sharedRoomsReader, onClose: { showsAllRooms = false })
            }
        }
        .task {
            // The server's list of the rooms you share; a direct message's, where one is open and that read is not.
            if let sharedRoomsReader, await model.loadSharedRooms(sharedRoomsReader) { return }
            if let context { await model.loadSharedRooms(context) }
        }
        // The first page as the sheet opens; the rest as the list scrolls.
        .task { await messages.loadMore() }
    }
}

// MARK: - See all: the rooms you share

/// Every room you share with someone, newest first by their latest activity, a page at a time as the list scrolls.
/// Never reads two pages at once; stops on the last page (no next cursor) or a cursor that does not move.
@MainActor
final class RoomSharedRoomsModel: ObservableObject {
    @Published private(set) var state: RoomSharedRoomsState
    let principal: String
    private let reader: any SharedRoomsReading
    private var rooms: [SharedRoom] = []
    private var cursor: String?
    private var total: Int?
    private var reachedEnd = false
    private var isLoading = false
    private var failure: String?

    static let pageSize = 20

    init(principal: String, name: String, reader: any SharedRoomsReading) {
        self.principal = principal
        self.reader = reader
        state = RoomSharedRoomsState(name: name)
    }

    func loadMore() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        failure = nil
        publish()
        defer {
            isLoading = false
            publish()
        }
        do {
            let asked = cursor
            let page = try await reader.sharedRooms(with: principal, cursor: asked, limit: Self.pageSize)
            let known = Set(rooms.map(\.sessionId))
            rooms += page.rooms.filter { !known.contains($0.sessionId) }
            total = page.total
            guard let next = page.nextCursor, next != asked else {
                reachedEnd = true
                return
            }
            cursor = next
        } catch SessionTransportError.cancelled {
            // Closed while reading: nothing to say.
        } catch {
            failure = "The rooms couldn't load."
        }
    }

    private func publish() {
        state = RoomSharedRoomsState(
            name: state.name,
            rows: rooms.map { RoomSharedRoomsState.Row(id: $0.sessionId, title: $0.title,
                                                       lastActive: $0.lastActiveAt.flatMap { ParsedSessionTimestamp($0).date }) },
            total: total,
            phase: isLoading ? .loading : (failure.map { .failed($0) } ?? .idle),
            canLoadMore: !reachedEnd
        )
    }
}

/// The See all sheet's host: its own model, the first page as it opens, the rest as the list scrolls.
struct RoomSharedRoomsSheet: View {
    @StateObject private var model: RoomSharedRoomsModel
    let onClose: () -> Void

    init(principal: String, name: String, reader: any SharedRoomsReading, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: RoomSharedRoomsModel(principal: principal, name: name, reader: reader))
        self.onClose = onClose
    }

    var body: some View {
        RoomSharedRoomsView(
            state: model.state,
            onLoadMore: { Task { await model.loadMore() } },
            onRetry: { Task { await model.loadMore() } },
            onClose: onClose
        )
        .task { await model.loadMore() }
    }
}

// MARK: - The direct message's header

@MainActor
final class DirectRoomModel: ObservableObject {
    @Published private(set) var dm: DirectMessage?
    @Published private(set) var isSaving = false
    @Published var notice: String?
    let sessionId: String

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func load(_ client: any DirectMessaging) async {
        do {
            dm = try await client.directMessage(sessionId)
        } catch DirectMessageError.unavailable {
            // Off, or no longer yours: no switch (and nothing assumed about it).
            dm = nil
        } catch {
        }
    }

    /// Turns the agent's use of this chat in `roomId` on or off. The switch keeps the server's value until the server
    /// answers with its new one.
    func setMemory(_ enabled: Bool, roomId: String, client: any DirectMessaging) async {
        guard let dm, !isSaving else { return }
        isSaving = true
        notice = nil
        defer { isSaving = false }
        do {
            let shares = try await client.setMemoryShare(sessionId, roomId: roomId, enabled: enabled)
            self.dm = dm.with(memoryShare: shares)
        } catch DirectMessageError.unavailable {
            notice = "This can't be changed right now."
            await load(client)
        } catch {
            notice = "Not saved. Check your connection and try again."
        }
    }
}

/// Whom a direct message is with, the room you share, and for an agent the memory switch and "notified".
struct DirectRoomHeaderHost: View {
    let info: DirectRoomInfo
    let sessionId: String
    let center: DirectMessagesCenter?
    let openRoom: @MainActor (String) -> Void
    let style: DirectRoomHeaderStyle
    /// The compact header's switch starts open (DEBUG previews only).
    let memoryOpen: Bool
    @StateObject private var model: DirectRoomModel

    init(info: DirectRoomInfo, sessionId: String, center: DirectMessagesCenter?,
         style: DirectRoomHeaderStyle = DirectRoomHeaderChoice.current, memoryOpen: Bool = false,
         openRoom: @escaping @MainActor (String) -> Void) {
        self.info = info
        self.sessionId = sessionId
        self.center = center
        self.style = style
        self.memoryOpen = memoryOpen
        self.openRoom = openRoom
        _model = StateObject(wrappedValue: DirectRoomModel(sessionId: sessionId))
    }

    var state: DirectRoomHeaderState {
        let dm = model.dm
        // The server's word on where it started wins, a null included; before it answers, the room list's.
        let origin: (id: String, title: String)?
        if let dm {
            origin = dm.originRoom.map { (id: $0.sessionId, title: $0.title) }
        } else {
            origin = info.originRoomId.flatMap { id in info.originTitle.map { (id: id, title: $0) } }
        }
        return DirectRoomHeaderState.make(
            name: info.counterpart.displayName,
            isAgent: info.counterpart.isAgent,
            origin: origin,
            mutual: (dm?.mutualRooms ?? []).map { (id: $0.sessionId, title: $0.title) },
            memoryShare: dm.map { Dictionary($0.memoryShare.map { ($0.roomId, $0.enabled) }, uniquingKeysWith: { $1 }) },
            isSaving: model.isSaving,
            notice: model.notice
        )
    }

    var body: some View {
        DirectRoomHeaderView(
            state: state,
            style: style,
            memoryOpen: memoryOpen,
            onOpenSharedRoom: { openRoom($0) },
            onSetMemory: { enabled in
                guard let center, let roomId = state.memory?.roomId else { return }
                Task { await model.setMemory(enabled, roomId: roomId, client: center.client) }
            },
            onDismissNotice: { model.notice = nil }
        )
        .task(id: center == nil) {
            if let center { await model.load(center.client) }
        }
    }
}

// MARK: - Settings

/// "Who can message me", where direct messages are on.
struct DirectMessagesSettingsSection: View {
    @ObservedObject var center: DirectMessagesCenter

    var body: some View {
        if center.isAvailable {
            Section {
                Picker("Who can message me", selection: Binding(
                    get: { center.allowance },
                    set: { value in if let value { Task { await center.setAllowance(value) } } }
                )) {
                    Text("People in rooms you share").tag(Optional(DirectMessagesAllowance.sharedRooms))
                    Text("Nobody").tag(Optional(DirectMessagesAllowance.nobody))
                }
                .disabled(center.isSavingAllowance)
                .accessibilityIdentifier("settings.dms.allow")
            } header: {
                Text("Direct messages")
            } footer: {
                Text(center.allowanceNotice
                     ?? "People and agents in a room you share can message you directly, from their card. Choose Nobody to turn that off.")
            }
        }
    }
}
