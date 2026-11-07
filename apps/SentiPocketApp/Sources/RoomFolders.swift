import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import SwiftUI

// Room folders (Carter, 10-25; Pocket ticket e454ab6d; folders inside folders, Carter 11-04). The server half is
// sentinelayer-api #1125, behind ROOM_FOLDERS_ENABLED: with it off the routes answer 404 and the app shows nothing of
// folders. Which folder a room is in is the room list's `folderId`: after every change the folders and the room list are
// read again, and nothing here keeps a copy that could drift.

/// Your folders, and the sheets that make, rename, move and delete them. One per signed-in app.
@MainActor
final class RoomFoldersCenter: ObservableObject {
    /// The open sheet: naming a new folder (at the top level, with the room to file in it once made, or inside a
    /// folder), renaming one, or picking where a folder or a room goes.
    enum Sheet: Identifiable, Equatable {
        case create(fileRoomId: String?)
        case createInside(RoomFolder)
        case rename(RoomFolder)
        case moveFolder(RoomFolder)
        case moveRoom(roomId: String, folderId: String?)

        var id: String {
            switch self {
            case .create(let room): return "create:" + (room ?? "")
            case .createInside(let folder): return "createInside:" + folder.id
            case .rename(let folder): return "rename:" + folder.id
            case .moveFolder(let folder): return "moveFolder:" + folder.id
            case .moveRoom(let room, _): return "moveRoom:" + room
            }
        }
    }

    /// Your folders as the server lists them; nil where folders are off (or before the server has answered).
    @Published private(set) var folders: [RoomFolder]? {
        didSet { items = folders?.map(Self.item) }
    }
    /// The side panel's folders, or nil where folders are off.
    private(set) var items: [RoomFolderItem]?
    @Published var notice: String?
    @Published var sheet: Sheet?
    /// What the server said about the name in the open sheet (a name already used, a change that did not save).
    @Published private(set) var sheetProblem: String?
    @Published private(set) var isSaving = false
    let pinControls = RoomFolderPinControls()
    var isPinSaving: Bool {
        get { pinControls.isSaving }
        set { pinControls.setSaving(newValue) }
    }
    /// The folder whose delete waits on your confirmation.
    @Published var deleting: RoomFolder?
    /// Which read of the folders is the newest, and whether a move is on its way.
    private var readRevision = 0
    private var moving = false

    let client: any RoomFoldersServing
    let pinClient: (any RoomFolderPinsServing)?
    private(set) var pinAccountId: String?
    var canChangePins: Bool { pinClient != nil && pinAccountId != nil }
    /// Reads the room list again: where each room is filed is its `folderId` there.
    private let onRoomsChanged: @MainActor () -> Void
    let onReauthenticationRequired: @MainActor () -> Void

    init(client: any RoomFoldersServing, onRoomsChanged: @escaping @MainActor () -> Void,
         onReauthenticationRequired: @escaping @MainActor () -> Void = {},
         pinClient: (any RoomFolderPinsServing)? = nil) {
        self.client = client
        self.pinClient = pinClient
        self.onRoomsChanged = onRoomsChanged
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    func setPinAccountId(_ value: String?) {
        guard pinAccountId != value else { return }
        // The first identity belongs to this already signed-in root: keep its ordinary folder read and freshness.
        // Replacing or clearing a known account still invalidates every older ordinary or pin list response.
        if pinAccountId != nil { readRevision += 1 }
        pinAccountId = value
        pinControls.setAvailable(canChangePins)
    }

    /// The tree of your folders, for the pickers and the menus: made when one opens.
    var tree: RoomFolderTree { RoomFolderTree.build(items ?? []) }

    /// One create's Idempotency-Key, for every try of the same name in the same place: a retry after a lost answer gets
    /// the folder that was made, not "that name is taken". Another name or place is another create, with a new key.
    private var createAttempt: (name: String, parent: String?, key: String)?

    static func item(_ folder: RoomFolder) -> RoomFolderItem {
        RoomFolderItem(id: folder.id, name: folder.name, parentId: folder.parentFolderId, position: folder.position,
                       roomCount: folder.roomCount, totalRoomCount: folder.totalRoomCount,
                       createdAt: ParsedSessionTimestamp(folder.createdAt)?.date,
                       pinnedPosition: folder.pinnedPosition, supportsPinning: folder.supportsPinning)
    }

    /// What a refusal says, in plain words; nil for one that is not about where folders go or what they are called.
    /// - Parameter deleting: a taken name on a delete is a folder inside it that would move up beside one of its name.
    static func line(for error: RoomFolderError, deleting: Bool = false) -> String? {
        switch error {
        case .duplicateName: return deleting ? RoomFolderName.deleteNameTakenMessage : RoomFolderName.nameTakenMessage
        case .limitReached: return RoomFolderName.limitMessage
        case .tooDeep: return RoomFolderName.depthMessage
        case .cycle: return RoomFolderName.cycleMessage
        default: return nil
        }
    }

    /// When the server last answered a read of the folders, for the side panel's open. A failed read leaves it, so the
    /// next open asks again.
    private var readAt: Date?

    /// Reads again unless the folders were read less than `age` seconds ago.
    func refresh(ifOlderThan age: TimeInterval) async {
        if let readAt, Date().timeIntervalSince(readAt) < age { return }
        await refresh()
    }

    /// Reads your folders. A 404 (or 403) means folders are off: everything about them hides. A failure that says
    /// nothing either way keeps what is shown. A read that finds what is shown writes nothing, so the root and the side
    /// panel draw only for a change.
    @discardableResult
    func refresh() async -> Bool {
        // Only the newest read is shown: an older one that lands late (a slow link) never puts back what it saw.
        readRevision += 1
        let revision = readRevision
        do {
            let read = try await client.folders()
            guard revision == readRevision else { return false }
            readAt = Date()
            if read != folders { folders = read }
            return true
        } catch RoomFolderError.unavailable {
            readAt = Date()
            if folders != nil { folders = nil }
            if sheet != nil { sheet = nil }
            if deleting != nil { deleting = nil }
            if notice != nil { notice = nil }
        } catch RoomFolderError.reauthenticationRequired {
            onReauthenticationRequired()
        } catch {
        }
        return false
    }

    /// A pin write and its authoritative read belong to the same person. The pin transport checks that account
    /// before sending a read, so a sign-in change between the write and this reload never starts a new-account GET.
    func refreshPins(accountId: String) async throws -> Bool {
        guard let pinClient, pinAccountId == accountId else { throw RoomFolderError.accountChanged }
        readRevision += 1
        let revision = readRevision
        do {
            let read = try await pinClient.folders(accountId: accountId)
            guard pinAccountId == accountId else { throw RoomFolderError.accountChanged }
            guard revision == readRevision else { return false }
            readAt = Date()
            if read != folders { folders = read }
            return true
        } catch RoomFolderError.unavailable {
            guard pinAccountId == accountId else { throw RoomFolderError.accountChanged }
            guard revision == readRevision else { return false }
            readAt = Date()
            if folders != nil { folders = nil }
            if sheet != nil { sheet = nil }
            if deleting != nil { deleting = nil }
            if notice != nil { notice = nil }
            return false
        }
    }

    func send(_ intent: RoomFolderIntent) {
        switch intent {
        case .create(let room):
            open(.create(fileRoomId: room))
        case .createInside(let id):
            guard let folder = folder(id), tree.canHoldFolder(id) else { return }
            open(.createInside(folder))
        case .rename(let id):
            guard let folder = folder(id) else { return }
            open(.rename(folder))
        case .pickParent(let id):
            guard let folder = folder(id) else { return }
            open(.moveFolder(folder))
        case .pickFolder(let room, let folderId):
            open(.moveRoom(roomId: room, folderId: folderId))
        case .delete(let id):
            deleting = folder(id)
        case .move(let id, let up):
            Task { await move(id, up: up) }
        case .file(let room, let folder):
            Task { await change { try await self.client.file(room: room, in: folder) } }
        case .unfile(let room, let folder):
            Task { await change { try await self.client.unfile(room: room, from: folder) } }
        case .setPinned(let id, let pinned):
            Task { await setPinned(id, pinned: pinned) }
        case .reorderPins(let ids):
            Task { await reorderPins(ids) }
        case .dismissNotice:
            notice = nil
        }
    }

    private func open(_ next: Sheet) {
        sheetProblem = nil
        switch next {
        case .create, .createInside: createAttempt = nil
        default: break
        }
        sheet = next
    }

    /// Where the open picker offers to move to: for a folder, the places that keep it 3 levels deep at most and are not
    /// it or inside it; for a room, every folder.
    var destinations: [RoomFolderDestination] {
        switch sheet {
        case .moveFolder(let folder): return tree.destinations(movingFolder: folder.id)
        case .moveRoom(_, let folderId): return tree.destinations(movingRoomIn: folderId)
        default: return []
        }
    }

    /// Saves the name in the open sheet: makes the folder (at the top level, filing the room it was made for, or inside
    /// a folder), or renames it.
    func save(name: String) async {
        guard let sheet, !isSaving else { return }
        guard let cleaned = RoomFolderName.cleaned(name) else {
            sheetProblem = RoomFolderName.validate(name).problemMessage
            return
        }
        isSaving = true
        sheetProblem = nil
        defer { isSaving = false }
        do {
            switch sheet {
            case .create(let room):
                let folder = try await client.createFolder(named: cleaned, in: nil,
                                                           idempotencyKey: createKey(name: cleaned, parent: nil))
                self.sheet = nil
                if let room {
                    await change { try await self.client.file(room: room, in: folder.id) }
                } else {
                    await reread()
                }
            case .createInside(let parent):
                _ = try await client.createFolder(named: cleaned, in: parent.id,
                                                  idempotencyKey: createKey(name: cleaned, parent: parent.id))
                self.sheet = nil
                await reread()
            case .rename(let folder):
                _ = try await client.renameFolder(folder.id, to: cleaned)
                self.sheet = nil
                await reread()
            case .moveFolder, .moveRoom:
                return
            }
        } catch let error as RoomFolderError where Self.line(for: error) != nil {
            // A taken name, the cap, a level too deep: the sheet stays with the reason, and the folders are read again
            // so the phone counts and places what the server has (another device may have changed them).
            sheetProblem = Self.line(for: error)
            await refresh()
        } catch RoomFolderError.gone {
            self.sheet = nil
            notice = Self.gone
            await reread()
        } catch RoomFolderError.unavailable {
            self.sheet = nil
            await reread()
        } catch RoomFolderError.reauthenticationRequired {
            self.sheet = nil
            onReauthenticationRequired()
        } catch RoomFolderError.rejected {
            sheetProblem = "Senti didn't take that name. Try another."
        } catch {
            sheetProblem = "Not saved. Check your connection and try again."
        }
    }

    /// The key for a create of `name` in `parent`: the last one again for the same name and place.
    private func createKey(name: String, parent: String?) -> String {
        if let attempt = createAttempt, attempt.name == name, attempt.parent == parent { return attempt.key }
        let key = UUID().uuidString
        createAttempt = (name, parent, key)
        return key
    }

    /// The place picked in the open picker: the folder moves there (nil: the top level), or the room is filed there.
    /// A refusal keeps the picker open with the reason, and the folders are read again.
    func pick(_ destination: String?) async {
        guard let sheet, !isSaving else { return }
        isSaving = true
        sheetProblem = nil
        defer { isSaving = false }
        do {
            switch sheet {
            case .moveFolder(let folder):
                guard destination != folder.parentFolderId else {
                    self.sheet = nil
                    return
                }
                _ = try await client.moveFolder(folder.id, into: destination)
            case .moveRoom(let room, let current):
                guard let destination, destination != current else {
                    self.sheet = nil
                    return
                }
                try await client.file(room: room, in: destination)
            default:
                return
            }
            self.sheet = nil
            await reread()
        } catch let error as RoomFolderError where Self.line(for: error) != nil {
            sheetProblem = Self.line(for: error)
            await refresh()
        } catch RoomFolderError.gone {
            self.sheet = nil
            notice = Self.gone
            await reread()
        } catch RoomFolderError.unavailable {
            self.sheet = nil
            await reread()
        } catch RoomFolderError.reauthenticationRequired {
            self.sheet = nil
            onReauthenticationRequired()
        } catch {
            sheetProblem = "Not moved. Check your connection and try again."
        }
    }

    /// "New folder…" in a room's picker: the name sheet, and the room filed in the folder once it is made.
    func newFolderForPickedRoom() {
        guard case .moveRoom(let room, _) = sheet else { return }
        open(.create(fileRoomId: room))
    }

    /// Deletes the folder you confirmed: its folders take its place and its rooms move up one level. A folder inside
    /// it with the name of one already at that level keeps it from being deleted, and says so.
    func confirmDelete() async {
        guard let folder = deleting else { return }
        await delete(folder)
    }

    /// The alert's "Delete folder": the folder is taken at the tap. The alert clears `deleting` as it closes, before a
    /// task started by the tap runs, so a task that read `deleting` itself found nothing and deleted nothing.
    @discardableResult
    func deleteFromAlert() -> Task<Void, Never>? {
        guard let folder = deleting else { return nil }
        return Task { await delete(folder) }
    }

    private func delete(_ folder: RoomFolder) async {
        deleting = nil
        await change(deleting: true) { try await self.client.deleteFolder(folder.id) }
    }

    /// One place up or down among the folders beside it: its new place, counted from 0, is its position. One move at a
    /// time: a second tap while the first is on its way would count from the old order and move the folder twice.
    private func move(_ id: String, up: Bool) async {
        guard !moving else { return }
        moving = true
        defer { moving = false }
        let beside = tree.siblings(of: id)
        guard let index = beside.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard beside.indices.contains(target) else { return }
        await change { _ = try await self.client.moveFolder(id, to: target) }
    }

    /// A change, then the folders and the room list read again, whatever happened: a folder that is gone says so, and
    /// a refusal says why in plain words.
    private func change(deleting: Bool = false, _ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
        } catch RoomFolderError.gone {
            notice = Self.gone
        } catch RoomFolderError.reauthenticationRequired {
            onReauthenticationRequired()
            return
        } catch RoomFolderError.unavailable {
        } catch let error as RoomFolderError where Self.line(for: error, deleting: deleting) != nil {
            notice = Self.line(for: error, deleting: deleting)
        } catch {
            notice = "That didn't save. Check your connection and try again."
        }
        await reread()
    }

    private func reread() async {
        await refresh()
        onRoomsChanged()
    }

    private func folder(_ id: String) -> RoomFolder? {
        folders?.first { $0.id == id }
    }

    static let gone = "That folder is no longer there. Your folders were read again."
}

private extension Result where Success == String, Failure == RoomFolderName.Problem {
    var problemMessage: String? {
        if case .failure(let problem) = self { return problem.message }
        return nil
    }
}

/// The folder sheets over the app: naming one, picking where one goes (or a room), and confirming a delete.
struct RoomFolderSheets: ViewModifier {
    @ObservedObject var center: RoomFoldersCenter

    func body(content: Content) -> some View {
        content
            .sheet(item: $center.sheet) { sheet in
                switch sheet {
                case .create, .createInside, .rename:
                    RoomFolderNameSheet(
                        title: Self.nameTitle(sheet),
                        place: Self.place(sheet),
                        initialName: { if case .rename(let folder) = sheet { return folder.name } else { return "" } }(),
                        isNew: { if case .rename = sheet { return false } else { return true } }(),
                        folderCount: center.folders?.count ?? 0,
                        serverProblem: center.sheetProblem,
                        isSaving: center.isSaving,
                        onSave: { name in Task { await center.save(name: name) } },
                        onCancel: { center.sheet = nil }
                    )
                    .presentationDetents([.medium])
                case .moveFolder(let folder):
                    RoomFolderPickerSheet(
                        title: "Move “\(folder.name)”",
                        destinations: center.destinations,
                        problem: center.sheetProblem,
                        isSaving: center.isSaving,
                        onPick: { destination in Task { await center.pick(destination) } },
                        onCancel: { center.sheet = nil }
                    )
                    .presentationDetents([.medium, .large])
                case .moveRoom:
                    RoomFolderPickerSheet(
                        title: "Move to folder",
                        destinations: center.destinations,
                        problem: center.sheetProblem,
                        isSaving: center.isSaving,
                        onPick: { destination in Task { await center.pick(destination) } },
                        onNewFolder: { center.newFolderForPickedRoom() },
                        onCancel: { center.sheet = nil }
                    )
                    .presentationDetents([.medium, .large])
                }
            }
            // An alert, not an action sheet: at the largest text sizes the action sheet's narrow card cut the line
            // about what moves up.
            .alert(
                center.deleting.map { "Delete “\($0.name)”?" } ?? "Delete folder?",
                isPresented: Binding(get: { center.deleting != nil }, set: { if !$0 { center.deleting = nil } })
            ) {
                Button("Delete folder", role: .destructive) { center.deleteFromAlert() }
                Button("Cancel", role: .cancel) { center.deleting = nil }
            } message: {
                Text(RoomFolderName.deleteMessage)
            }
    }

    static func nameTitle(_ sheet: RoomFoldersCenter.Sheet) -> String {
        if case .rename = sheet { return "Rename folder" }
        return "New folder"
    }

    /// Where a new folder goes, when it is inside another.
    static func place(_ sheet: RoomFoldersCenter.Sheet) -> String? {
        if case .createInside(let folder) = sheet { return "Inside “\(folder.name)”" }
        return nil
    }
}
