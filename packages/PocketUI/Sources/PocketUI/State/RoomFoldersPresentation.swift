import Foundation
import PocketContracts

// Room folders (Carter, 10-25; Pocket ticket e454ab6d): your own sections in the side panel, in your order, each with
// its rooms. Which folder a room is in is the room list's `folderId`; nothing here keeps a second copy.

/// One of your folders, as the side panel and the room menus show it.
public struct RoomFolderItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let position: Int
    public let roomCount: Int

    public init(id: String, name: String, position: Int, roomCount: Int = 0) {
        self.id = id
        self.name = name
        self.position = position
        self.roomCount = roomCount
    }

    /// Your order: by position, then name, then id.
    public static func ordered(_ folders: [RoomFolderItem]) -> [RoomFolderItem] {
        folders.sorted { ($0.position, $0.name.lowercased(), $0.id) < ($1.position, $1.name.lowercased(), $1.id) }
    }
}

/// What the folder controls ask for. The app does it on the server, then reads the folders and the room list again.
public enum RoomFolderIntent: Equatable, Sendable {
    /// "New folder", and the room to file in it once it is made ("New folder…" in a room's menu).
    case create(fileRoomId: String?)
    case rename(folderId: String)
    case delete(folderId: String)
    /// One place up or down in your order.
    case move(folderId: String, up: Bool)
    case file(roomId: String, folderId: String)
    case unfile(roomId: String, folderId: String)
    case dismissNotice
}

/// What the folder name sheet says about the name as typed, before anything is sent.
public enum RoomFolderSheetCheck: Equatable, Sendable {
    case ok(String)
    case problem(String)

    /// - Parameter isNew: a new folder also counts against the most a person can have.
    public static func check(_ name: String, isNew: Bool, folderCount: Int) -> RoomFolderSheetCheck {
        if isNew, folderCount >= RoomFolderName.maximumFolders {
            return .problem(RoomFolderName.limitMessage)
        }
        switch RoomFolderName.validate(name) {
        case .success(let cleaned): return .ok(cleaned)
        case .failure(let problem): return .problem(problem.message)
        }
    }
}

#if canImport(SwiftUI)
/// The side panel's rooms, placed: your folders in your order with their rooms, then the rooms in no folder, then the
/// direct messages whose room is gone. Each direct message sits under the room it was opened from, wherever that room
/// is, newest first.
public struct SidePanelLayout: Equatable, Sendable {
    /// A room and the direct messages opened from it.
    public struct Entry: Identifiable, Equatable, Sendable {
        public let room: PocketSidePanel.Room
        public let directs: [PocketSidePanel.Room]
        public var id: String { room.id }
    }

    public struct FolderSection: Identifiable, Equatable, Sendable {
        public let folder: RoomFolderItem
        public let entries: [Entry]
        public var id: String { folder.id }
        /// Every unread message in it, its direct messages included: what a folded folder shows.
        public var unread: Int { entries.reduce(0) { $0 + $1.room.activity.unread + $1.directs.reduce(0) { $0 + $1.activity.unread } } }
    }

    public let folders: [FolderSection]
    /// Rooms in no folder (or in one that is not in your list).
    public let rooms: [Entry]
    /// Direct messages whose room is gone or not in the list.
    public let messages: [PocketSidePanel.Room]

    public var isEmpty: Bool { folders.isEmpty && rooms.isEmpty && messages.isEmpty }

    /// - Parameters:
    ///   - rooms: the room list's rows, rooms and direct messages, most recent activity first.
    ///   - folders: your folders, or nil where folders are off (every room is then under Rooms).
    public static func make(_ rooms: [PocketSidePanel.Room], folders: [RoomFolderItem]?) -> SidePanelLayout {
        let plain = rooms.filter { $0.direct == nil }
        let plainIds = Set(plain.map(\.id))
        var nested: [String: [(Int, PocketSidePanel.Room)]] = [:]
        var orphans: [(Int, PocketSidePanel.Room)] = []
        for (index, room) in rooms.enumerated() {
            guard let direct = room.direct else { continue }
            if let origin = direct.originRoomId, plainIds.contains(origin) {
                nested[origin, default: []].append((index, room))
            } else {
                orphans.append((index, room))
            }
        }
        func entry(_ room: PocketSidePanel.Room) -> Entry {
            Entry(room: room, directs: newestFirst(nested[room.id] ?? []))
        }
        let ordered = RoomFolderItem.ordered(folders ?? [])
        let folderIds = Set(ordered.map(\.id))
        let sections = ordered.map { folder in
            FolderSection(folder: folder, entries: plain.filter { $0.folderId == folder.id }.map(entry))
        }
        let unfiled = plain.filter { room in room.folderId.map { !folderIds.contains($0) } ?? true }.map(entry)
        return SidePanelLayout(folders: sections, rooms: unfiled, messages: newestFirst(orphans))
    }

    /// Most recent activity first; no activity last; otherwise in the room list's order.
    private static func newestFirst(_ rooms: [(Int, PocketSidePanel.Room)]) -> [PocketSidePanel.Room] {
        rooms.sorted { left, right in
            let l = left.1.lastActivity?.timeIntervalSince1970 ?? -.infinity
            let r = right.1.lastActivity?.timeIntervalSince1970 ?? -.infinity
            return l == r ? left.0 < right.0 : l > r
        }.map(\.1)
    }
}
#endif
