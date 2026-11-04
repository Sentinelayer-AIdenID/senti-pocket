import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import SwiftUI

// Room folders (Carter, 10-25; Pocket ticket e454ab6d). The server half is behind ROOM_FOLDERS_ENABLED: with it off the
// routes answer 404 and the app shows nothing of folders. Which folder a room is in is the room list's `folderId`:
// after every change the folders and the room list are read again, and nothing here keeps a copy that could drift.

/// Your folders, and the sheets that make, rename and delete them. One per signed-in app.
@MainActor
final class RoomFoldersCenter: ObservableObject {
    /// The name sheet: a new folder (and the room to file in it once made), or a folder to rename.
    enum Sheet: Identifiable, Equatable {
        case create(fileRoomId: String?)
        case rename(RoomFolder)

        var id: String {
            switch self {
            case .create(let room): return "create:" + (room ?? "")
            case .rename(let folder): return "rename:" + folder.id
            }
        }
    }

    /// Your folders in your order; nil where folders are off (or before the server has answered).
    @Published private(set) var folders: [RoomFolder]?
    @Published var notice: String?
    @Published var sheet: Sheet?
    /// What the server said about the name in the open sheet (a name already used, a change that did not save).
    @Published private(set) var sheetProblem: String?
    @Published private(set) var isSaving = false
    /// The folder whose delete waits on your confirmation.
    @Published var deleting: RoomFolder?

    let client: any RoomFoldersServing
    /// Reads the room list again: where each room is filed is its `folderId` there.
    private let onRoomsChanged: @MainActor () -> Void
    private let onReauthenticationRequired: @MainActor () -> Void

    init(client: any RoomFoldersServing, onRoomsChanged: @escaping @MainActor () -> Void,
         onReauthenticationRequired: @escaping @MainActor () -> Void = {}) {
        self.client = client
        self.onRoomsChanged = onRoomsChanged
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    /// The side panel's folders, or nil where folders are off.
    var items: [RoomFolderItem]? {
        folders?.map { RoomFolderItem(id: $0.id, name: $0.name, position: $0.position, roomCount: $0.roomCount) }
    }

    /// Reads your folders. A 404 (or 403) means folders are off: everything about them hides. A failure that says
    /// nothing either way keeps what is shown.
    func refresh() async {
        do {
            folders = try await client.folders()
        } catch RoomFolderError.unavailable {
            folders = nil
            sheet = nil
            deleting = nil
            notice = nil
        } catch RoomFolderError.reauthenticationRequired {
            onReauthenticationRequired()
        } catch {
        }
    }

    func send(_ intent: RoomFolderIntent) {
        switch intent {
        case .create(let room):
            sheetProblem = nil
            sheet = .create(fileRoomId: room)
        case .rename(let id):
            guard let folder = folder(id) else { return }
            sheetProblem = nil
            sheet = .rename(folder)
        case .delete(let id):
            deleting = folder(id)
        case .move(let id, let up):
            Task { await move(id, up: up) }
        case .file(let room, let folder):
            Task { await change { try await self.client.file(room: room, in: folder) } }
        case .unfile(let room, let folder):
            Task { await change { try await self.client.unfile(room: room, from: folder) } }
        case .dismissNotice:
            notice = nil
        }
    }

    /// Saves the name in the open sheet: makes the folder (and files the room it was made for), or renames it.
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
                let folder = try await client.createFolder(named: cleaned)
                self.sheet = nil
                if let room {
                    await change { try await self.client.file(room: room, in: folder.id) }
                } else {
                    await reread()
                }
            case .rename(let folder):
                _ = try await client.renameFolder(folder.id, to: cleaned)
                self.sheet = nil
                await reread()
            }
        } catch RoomFolderError.duplicateName {
            sheetProblem = "You already have a folder named “\(cleaned)”."
        } catch RoomFolderError.limitReached {
            // The server counted 100 where the phone counted fewer: say so, and read the folders again so the sheet
            // counts what the server has.
            sheetProblem = RoomFolderName.limitMessage
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

    /// Deletes the folder you confirmed; its rooms become unfiled.
    func confirmDelete() async {
        guard let folder = deleting else { return }
        deleting = nil
        await change { try await self.client.deleteFolder(folder.id) }
    }

    /// One place up or down in your order: the folder's new place, counted from 0, is its position.
    private func move(_ id: String, up: Bool) async {
        guard let ordered = folders, let index = ordered.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard ordered.indices.contains(target) else { return }
        await change { _ = try await self.client.moveFolder(id, to: target) }
    }

    /// A change, then the folders and the room list read again, whatever happened: a folder that is gone says so.
    private func change(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
        } catch RoomFolderError.gone {
            notice = Self.gone
        } catch RoomFolderError.reauthenticationRequired {
            onReauthenticationRequired()
            return
        } catch RoomFolderError.unavailable {
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

/// The folder sheets over the app: naming one, and confirming a delete.
struct RoomFolderSheets: ViewModifier {
    @ObservedObject var center: RoomFoldersCenter

    func body(content: Content) -> some View {
        content
            .sheet(item: $center.sheet) { sheet in
                RoomFolderNameSheet(
                    title: { if case .rename = sheet { return "Rename folder" } else { return "New folder" } }(),
                    initialName: { if case .rename(let folder) = sheet { return folder.name } else { return "" } }(),
                    isNew: { if case .create = sheet { return true } else { return false } }(),
                    folderCount: center.folders?.count ?? 0,
                    serverProblem: center.sheetProblem,
                    isSaving: center.isSaving,
                    onSave: { name in Task { await center.save(name: name) } },
                    onCancel: { center.sheet = nil }
                )
                .presentationDetents([.medium])
            }
            .confirmationDialog(
                center.deleting.map { "Delete “\($0.name)”?" } ?? "Delete folder?",
                isPresented: Binding(get: { center.deleting != nil }, set: { if !$0 { center.deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete folder", role: .destructive) { Task { await center.confirmDelete() } }
                Button("Cancel", role: .cancel) { center.deleting = nil }
            } message: {
                Text(Self.deleteMessage(roomCount: center.deleting?.roomCount ?? 0))
            }
    }

    /// The delete confirmation says where the folder's rooms go.
    static func deleteMessage(roomCount: Int) -> String {
        switch roomCount {
        case 0: return "The folder is empty. Deleting it changes no room."
        case 1: return "Its room moves back to Rooms. The room itself is not deleted."
        default: return "Its \(roomCount) rooms move back to Rooms. The rooms themselves are not deleted."
        }
    }
}
