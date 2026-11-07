import Foundation
import PocketContracts

// Room folders (Carter, 10-25; Pocket ticket e454ab6d; folders inside folders, Carter 11-04): your own sections in the
// side panel, in your order, each with its rooms and the folders inside it, up to 3 levels. Which folder a room is in is
// the room list's `folderId`; nothing here keeps a second copy.

/// One of your folders, as the side panel and the room menus show it.
public struct RoomFolderItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// The folder it is in, as the server says; nil at the top level. `RoomFolderTree` decides where it is shown.
    public let parentId: String?
    public let position: Int
    public let pinnedPosition: Int?
    /// True even for an unpinned folder (explicit null); false when the server omitted the field.
    public let supportsPinning: Bool
    /// The rooms in it.
    public let roomCount: Int
    /// The rooms in it and in every folder inside it: what a folded folder shows.
    public let totalRoomCount: Int
    public let createdAt: Date?

    public init(id: String, name: String, parentId: String? = nil, position: Int, roomCount: Int = 0,
                totalRoomCount: Int? = nil, createdAt: Date? = nil,
                pinnedPosition: Int? = nil, supportsPinning: Bool = false) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.position = position
        self.pinnedPosition = pinnedPosition
        self.supportsPinning = supportsPinning
        self.roomCount = roomCount
        self.totalRoomCount = max(roomCount, totalRoomCount ?? roomCount)
        self.createdAt = createdAt
    }

    /// The order of folders side by side, as the server keeps it: by position, then when made, then id.
    public static func precedes(_ left: RoomFolderItem, _ right: RoomFolderItem) -> Bool {
        if left.position != right.position { return left.position < right.position }
        let l = left.createdAt ?? .distantFuture
        let r = right.createdAt ?? .distantFuture
        if l != r { return l < r }
        return left.id < right.id
    }

    /// Folders side by side, in your order.
    public static func ordered(_ folders: [RoomFolderItem]) -> [RoomFolderItem] {
        folders.sorted(by: precedes)
    }
}

/// Your folders as a tree, built from the server's flat list. Never fails: a parent that is not in the list puts the
/// folder at the top level, a loop is broken at its first folder in your order (which goes to the top level), and
/// anything deeper than 3 levels sits beside the level-3 folder it was under.
public struct RoomFolderTree: Equatable, Sendable {
    public static var maximumDepth: Int { RoomFolderName.maximumDepth }

    public struct Node: Identifiable, Equatable, Sendable {
        public let folder: RoomFolderItem
        /// 1 at the top level.
        public let depth: Int
        /// The folder it is shown in; nil at the top level.
        public let parentId: String?
        /// The folders shown inside it, in your order.
        public let childIds: [String]
        /// Levels from it to its deepest folder, itself counted: 1 with no folder inside it.
        public let height: Int
        /// Its place among the folders beside it, and how many there are.
        public let siblingIndex: Int
        public let siblingCount: Int

        public var id: String { folder.id }
    }

    /// Every folder, each followed by the folders inside it (depth first, in your order).
    public let nodes: [Node]
    private let indexById: [String: Int]

    public static let empty = RoomFolderTree(nodes: [])

    private init(nodes: [Node]) {
        self.nodes = nodes
        var index: [String: Int] = [:]
        for (offset, node) in nodes.enumerated() { index[node.id] = offset }
        indexById = index
    }

    public static func == (lhs: RoomFolderTree, rhs: RoomFolderTree) -> Bool { lhs.nodes == rhs.nodes }

    public var isEmpty: Bool { nodes.isEmpty }

    public func node(_ id: String) -> Node? {
        indexById[id].map { nodes[$0] }
    }

    /// The folders inside it, at every level.
    public func descendants(of id: String) -> Set<String> {
        guard let start = indexById[id] else { return [] }
        let depth = nodes[start].depth
        var found = Set<String>()
        var index = start + 1
        // Depth first: what follows it deeper than it is inside it, up to the next folder at its level or above.
        while index < nodes.count, nodes[index].depth > depth {
            found.insert(nodes[index].id)
            index += 1
        }
        return found
    }

    /// The folders beside it, itself included, in your order.
    public func siblings(of id: String) -> [Node] {
        guard let node = node(id) else { return [] }
        if let parent = node.parentId { return self.node(parent)?.childIds.compactMap { self.node($0) } ?? [] }
        return nodes.filter { $0.parentId == nil }
    }

    /// Whether a new folder can go inside it (it is above the deepest level).
    public func canHoldFolder(_ id: String) -> Bool {
        (node(id)?.depth ?? Self.maximumDepth) < Self.maximumDepth
    }

    /// Where a folder can move: the top level and every folder that is not it, not inside it, and leaves room for its
    /// own levels (its deepest folder stays at level 3 or above). Where it is now is marked, not hidden. The server
    /// still judges; this only leaves out what it would refuse.
    public func destinations(movingFolder id: String) -> [RoomFolderDestination] {
        guard let moving = node(id) else { return [] }
        let inside = descendants(of: id)
        var shown = [RoomFolderDestination(folderId: nil, name: RoomFolderDestination.topLevelName, depth: 0,
                                           isCurrent: moving.parentId == nil)]
        for node in nodes where node.id != id && !inside.contains(node.id)
            && node.depth + moving.height <= Self.maximumDepth {
            shown.append(RoomFolderDestination(folderId: node.id, name: node.folder.name, depth: node.depth,
                                               isCurrent: node.id == moving.parentId))
        }
        return shown
    }

    /// Where a room can go: any folder. The one it is in now is marked.
    public func destinations(movingRoomIn folderId: String?) -> [RoomFolderDestination] {
        nodes.map {
            RoomFolderDestination(folderId: $0.id, name: $0.folder.name, depth: $0.depth, isCurrent: $0.id == folderId)
        }
    }

    public static func build(_ folders: [RoomFolderItem]) -> RoomFolderTree {
        // One folder per id: the first the server listed.
        var byId: [String: RoomFolderItem] = [:]
        var unique: [RoomFolderItem] = []
        for folder in folders where byId[folder.id] == nil {
            byId[folder.id] = folder
            unique.append(folder)
        }
        // A parent that is not one of your folders (or is itself): the top level.
        var parent: [String: String] = [:]
        for folder in unique {
            if let id = folder.parentId, id != folder.id, byId[id] != nil { parent[folder.id] = id }
        }
        let inOrder = RoomFolderItem.ordered(unique)
        breakLoops(&parent, inOrder: inOrder)

        var children: [String: [RoomFolderItem]] = [:]
        var roots: [RoomFolderItem] = []
        for folder in inOrder {
            if let id = parent[folder.id] { children[id, default: []].append(folder) } else { roots.append(folder) }
        }

        // Depth first, in your order. Below level 3, a folder is placed beside the level-3 folder it was under (and so
        // is everything under it), so nothing is lost and no level goes past 3.
        struct Placed {
            let folder: RoomFolderItem
            let depth: Int
            let parentId: String?
        }
        var placed: [Placed] = []
        placed.reserveCapacity(inOrder.count)
        var stack: [(RoomFolderItem, Int, String?)] = roots.reversed().map { ($0, 1, nil) }
        while let next = stack.popLast() {
            let (folder, depth, shownIn) = next
            placed.append(Placed(folder: folder, depth: depth, parentId: shownIn))
            let inside = children[folder.id] ?? []
            if depth < maximumDepth {
                for child in inside.reversed() { stack.append((child, depth + 1, folder.id)) }
            } else {
                for child in inside.reversed() { stack.append((child, depth, shownIn)) }
            }
        }

        var childIds: [String: [String]] = [:]
        var rootIds: [String] = []
        for item in placed {
            if let id = item.parentId { childIds[id, default: []].append(item.folder.id) } else { rootIds.append(item.folder.id) }
        }
        // Heights from the deepest up: a folder after its parent in `placed`, so walking backwards sees children first.
        var height: [String: Int] = [:]
        for item in placed.reversed() {
            let own = height[item.folder.id] ?? 1
            height[item.folder.id] = own
            if let id = item.parentId { height[id] = max(height[id] ?? 1, own + 1) }
        }
        var siblingIndex: [String: (Int, Int)] = [:]
        for (offset, id) in rootIds.enumerated() { siblingIndex[id] = (offset, rootIds.count) }
        for (_, ids) in childIds {
            for (offset, id) in ids.enumerated() { siblingIndex[id] = (offset, ids.count) }
        }
        return RoomFolderTree(nodes: placed.map { item in
            let (index, count) = siblingIndex[item.folder.id] ?? (0, 1)
            return Node(folder: item.folder, depth: item.depth, parentId: item.parentId,
                        childIds: childIds[item.folder.id] ?? [], height: height[item.folder.id] ?? 1,
                        siblingIndex: index, siblingCount: count)
        })
    }

    /// Each loop of parents (A in B, B in A) is broken at its first folder in your order, which goes to the top level;
    /// the others stay inside it.
    private static func breakLoops(_ parent: inout [String: String], inOrder: [RoomFolderItem]) {
        var rank: [String: Int] = [:]
        for (offset, folder) in inOrder.enumerated() { rank[folder.id] = offset }
        // 1: on the path being walked; 2: walked, leads to the top.
        var state: [String: UInt8] = [:]
        for folder in inOrder {
            var path: [String] = []
            var current: String? = folder.id
            while let id = current, state[id] == nil {
                state[id] = 1
                path.append(id)
                current = parent[id]
            }
            if let id = current, state[id] == 1, let start = path.firstIndex(of: id) {
                let loop = path[start...]
                if let first = loop.min(by: { (rank[$0] ?? .max) < (rank[$1] ?? .max) }) {
                    parent[first] = nil
                }
            }
            for id in path { state[id] = 2 }
        }
    }
}

/// A place a folder or a room can move to: the top level (no folder id) or one of your folders.
public struct RoomFolderDestination: Identifiable, Equatable, Sendable {
    public static let topLevelName = "Top level"

    public let folderId: String?
    public let name: String
    /// 0 for the top level, else the folder's level.
    public let depth: Int
    /// Where it is now: shown, not offered.
    public let isCurrent: Bool

    public var id: String { folderId ?? "top" }

    public init(folderId: String?, name: String, depth: Int, isCurrent: Bool) {
        self.folderId = folderId
        self.name = name
        self.depth = depth
        self.isCurrent = isCurrent
    }
}

/// What the folder controls ask for. The app does it on the server, then reads the folders and the room list again.
public enum RoomFolderIntent: Equatable, Sendable {
    /// "New folder", and the room to file in it once it is made ("New folder…" in a room's picker).
    case create(fileRoomId: String?)
    /// "New folder inside" a folder.
    case createInside(folderId: String)
    case rename(folderId: String)
    case delete(folderId: String)
    /// One place up or down among the folders beside it.
    case move(folderId: String, up: Bool)
    /// "Move to…": a folder into another folder or to the top level.
    case pickParent(folderId: String)
    /// "Move to folder…": a room into one of your folders.
    case pickFolder(roomId: String, folderId: String?)
    case file(roomId: String, folderId: String)
    case unfile(roomId: String, folderId: String)
    case setPinned(folderId: String, pinned: Bool)
    case reorderPins(folderIds: [String])
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

/// The folders you folded in the side panel, by id, kept between launches (one id per line, as before folders nested).
public struct FoldedFolders: Equatable, Sendable {
    public static let storageKey = "pocket.drawer.foldedFolders"

    public private(set) var ids: Set<String>

    public init(_ ids: Set<String> = []) {
        self.ids = ids
    }

    public init(raw: String) {
        ids = Set(raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    public var raw: String { ids.sorted().joined(separator: "\n") }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    public mutating func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }
}

#if canImport(SwiftUI)
/// The side panel's rooms, placed: your folders in your order, each with its rooms and then the folders inside it; then
/// the rooms in no folder; then the direct messages whose room is gone. Each direct message sits under the room it was
/// opened from, wherever that room is, newest first. Made off the main thread (`SidePanelPlacement`).
public struct SidePanelLayout: Equatable, Sendable {
    /// A room and the direct messages opened from it.
    public struct Entry: Identifiable, Equatable, Sendable {
        public let room: PocketSidePanel.Room
        public let directs: [PocketSidePanel.Room]
        public var id: String { room.id }
    }

    public struct FolderSection: Identifiable, Equatable, Sendable {
        public let folder: RoomFolderItem
        /// 1 at the top level.
        public let depth: Int
        /// Its own rooms.
        public let entries: [Entry]
        /// Whether folders sit inside it.
        public let hasFolders: Bool
        /// Every unread message in it and in every folder inside it, direct messages included: what a folded folder
        /// shows.
        public let unread: Int
        /// Its place among the folders beside it, and how many there are (for Move up and Move down).
        public let siblingIndex: Int
        public let siblingCount: Int
        public var id: String { folder.id }
    }

    /// Each folder followed by the folders inside it.
    public let folders: [FolderSection]
    /// Rooms in no folder (or in one that is not in your list).
    public let rooms: [Entry]
    /// Direct messages whose room is gone or not in the list.
    public let messages: [PocketSidePanel.Room]
    public let tree: RoomFolderTree
    /// Pin capability and order are placed with the tree, never recalculated while the panel draws.
    public let pinsAvailable: Bool
    public let pinnedFolders: [RoomFolderItem]

    public static let empty = SidePanelLayout(folders: [], rooms: [], messages: [], tree: .empty,
                                              pinsAvailable: false, pinnedFolders: [])

    public var isEmpty: Bool { folders.isEmpty && rooms.isEmpty && messages.isEmpty }

    /// - Parameters:
    ///   - rooms: the room list's rows, rooms and direct messages, most recent activity first.
    ///   - folders: your folders, or nil where folders are off (every room is then in Your rooms).
    public static func make(_ rooms: [PocketSidePanel.Room], folders: [RoomFolderItem]?) -> SidePanelLayout {
        var plain: [PocketSidePanel.Room] = []
        var plainIds = Set<String>()
        for room in rooms where room.direct == nil {
            plain.append(room)
            plainIds.insert(room.id)
        }
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
        let tree = RoomFolderTree.build(folders ?? [])
        let placedFolders = tree.nodes.map(\.folder)
        let pinsAvailable = RoomFolderPinsPresentation.isAvailable(placedFolders)
        let pinnedFolders = RoomFolderPinsPresentation.ordered(placedFolders)
        var filed: [String: [Entry]] = [:]
        var unfiled: [Entry] = []
        for room in plain {
            if let id = room.folderId, tree.node(id) != nil {
                filed[id, default: []].append(entry(room))
            } else {
                unfiled.append(entry(room))
            }
        }
        // Each folder's own unread, then added into every folder it is in: walking the depth-first list backwards
        // reaches a folder's insides before the folder.
        var unread: [String: Int] = [:]
        for node in tree.nodes {
            unread[node.id] = (filed[node.id] ?? []).reduce(0) { total, entry in
                total + entry.room.activity.unread + entry.directs.reduce(0) { $0 + $1.activity.unread }
            }
        }
        for node in tree.nodes.reversed() {
            if let parent = node.parentId { unread[parent, default: 0] += unread[node.id] ?? 0 }
        }
        let sections = tree.nodes.map { node in
            FolderSection(folder: node.folder, depth: node.depth, entries: filed[node.id] ?? [],
                          hasFolders: !node.childIds.isEmpty, unread: unread[node.id] ?? 0,
                          siblingIndex: node.siblingIndex, siblingCount: node.siblingCount)
        }
        return SidePanelLayout(folders: sections, rooms: unfiled, messages: newestFirst(orphans), tree: tree,
                               pinsAvailable: pinsAvailable, pinnedFolders: pinnedFolders)
    }

    /// One line of the side panel's list, in order, with what it shows. Ids are stable across reads.
    public enum Row: Identifiable, Equatable, Sendable {
        case folder(FolderLine)
        /// "No rooms in this folder", under an open folder with nothing in it.
        case emptyFolder(folderId: String, depth: Int)
        /// A room, in a folder at `depth` (0: in none).
        case room(PocketSidePanel.Room, depth: Int)
        /// A direct message under its room.
        case direct(PocketSidePanel.Room, depth: Int)
        /// A direct message whose room is gone.
        case message(PocketSidePanel.Room)
        case label(id: String, title: String)

        public var id: String {
            switch self {
            case .folder(let line): return "folder:" + line.id
            case .emptyFolder(let id, _): return "empty:" + id
            case .room(let room, _): return "room:" + room.id
            case .direct(let room, _): return "direct:" + room.id
            case .message(let room): return "message:" + room.id
            case .label(let id, _): return "label:" + id
            }
        }
    }

    /// A folder's line: what its row shows and what its menu offers.
    public struct FolderLine: Identifiable, Equatable, Sendable {
        public let folder: RoomFolderItem
        public let depth: Int
        public let folded: Bool
        /// Unread in it and in every folder inside it.
        public let unread: Int
        public let isFirst: Bool
        public let isLast: Bool
        /// Whether a new folder can go inside it.
        public let canHoldFolder: Bool
        public var id: String { folder.id }
    }

    /// The lines to show with these folders folded: a folded folder hides its rooms and every folder inside it.
    public func rows(folded: FoldedFolders) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(folders.count + rooms.count * 2 + messages.count + 2)
        // While inside a folded folder, its level: everything deeper is hidden.
        var hiddenBelow: Int?
        for section in folders {
            if let level = hiddenBelow {
                if section.depth > level { continue }
                hiddenBelow = nil
            }
            let isFolded = folded.contains(section.id)
            rows.append(.folder(FolderLine(folder: section.folder, depth: section.depth, folded: isFolded,
                                           unread: section.unread, isFirst: section.siblingIndex == 0,
                                           isLast: section.siblingIndex == section.siblingCount - 1,
                                           canHoldFolder: section.depth < RoomFolderTree.maximumDepth)))
            if isFolded {
                hiddenBelow = section.depth
                continue
            }
            if section.entries.isEmpty, !section.hasFolders {
                rows.append(.emptyFolder(folderId: section.id, depth: section.depth))
            }
            for entry in section.entries {
                rows.append(.room(entry.room, depth: section.depth))
                for direct in entry.directs { rows.append(.direct(direct, depth: section.depth)) }
            }
        }
        if !folders.isEmpty, !rooms.isEmpty {
            rows.append(.label(id: "unfiled", title: "Your chats"))
        }
        for entry in rooms {
            rows.append(.room(entry.room, depth: 0))
            for direct in entry.directs { rows.append(.direct(direct, depth: 0)) }
        }
        if !messages.isEmpty {
            rows.append(.label(id: "messages", title: "Messages"))
            for message in messages { rows.append(.message(message)) }
        }
        return rows
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

/// The side panel's placed rooms, kept ready: the tree, pin order and lines are made off the main thread when the rooms
/// or folders change, and written only when what shows changed, so opening the panel or a poll that finds nothing new
/// lays nothing out on the main thread. The folded folders are kept here too, in the same place and form as before.
@MainActor
public final class SidePanelPlacement: ObservableObject {
    public struct Shown: Equatable, Sendable {
        public let layout: SidePanelLayout
        public let rows: [SidePanelLayout.Row]
        /// The rooms as given, for the search.
        public let rooms: [PocketSidePanel.Room]

        public static let empty = Shown(layout: .empty, rows: [], rooms: [])
    }

    @Published public private(set) var shown: Shown
    public private(set) var folded: FoldedFolders
    /// How many times the rooms were placed (tests and the scale measurement read it).
    public private(set) var builds = 0

    private struct Input: Equatable, Sendable {
        let rooms: [PocketSidePanel.Room]
        let folders: [RoomFolderItem]?
    }

    private var input: Input?
    private var work: Task<Void, Never>?
    private let defaults: UserDefaults?

    /// - Parameter defaults: where the folded folders are kept; nil keeps them only while it lives.
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        folded = FoldedFolders(raw: defaults?.string(forKey: FoldedFolders.storageKey) ?? "")
        shown = .empty
    }

    /// Placed at once, for previews and tests of fixed content.
    public convenience init(rooms: [PocketSidePanel.Room], folders: [RoomFolderItem]?, folded: FoldedFolders = FoldedFolders()) {
        self.init(defaults: nil)
        self.folded = folded
        input = Input(rooms: rooms, folders: folders)
        let layout = SidePanelLayout.make(rooms, folders: folders)
        builds = 1
        shown = Shown(layout: layout, rows: layout.rows(folded: folded), rooms: rooms)
    }

    /// The room list's rows, made into the panel's rooms off the main thread.
    public func update(rows: [SessionRowPresentation], folders: [RoomFolderItem]?) {
        place(folders: folders) { rows.map(PocketSidePanel.Room.init(row:)) }
    }

    public func update(rooms: [PocketSidePanel.Room], folders: [RoomFolderItem]?) {
        place(folders: folders) { rooms }
    }

    /// Placed, for a test or a measurement that needs it done before it goes on.
    public func settle() async {
        await work?.value
    }

    public func toggleFolded(_ id: String) {
        folded.toggle(id)
        defaults?.set(folded.raw, forKey: FoldedFolders.storageKey)
        // One tap, one walk of the lines already placed: no placing again.
        let rows = shown.layout.rows(folded: folded)
        if rows != shown.rows { shown = Shown(layout: shown.layout, rows: rows, rooms: shown.rooms) }
    }

    /// Places the rooms off the main thread. A read that finds what is placed already places nothing and writes nothing;
    /// a newer read replaces one still being placed.
    private func place(folders: [RoomFolderItem]?, rooms: @escaping @Sendable () -> [PocketSidePanel.Room]) {
        work?.cancel()
        let last = input
        let folded = self.folded
        work = Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) { () -> Placed? in
                let next = Input(rooms: rooms(), folders: folders)
                guard next != last else { return nil }
                let layout = SidePanelLayout.make(next.rooms, folders: next.folders)
                return Placed(input: next, layout: layout, rows: layout.rows(folded: folded))
            }.value
            guard let self, !Task.isCancelled, let made else { return }
            self.input = made.input
            self.builds += 1
            // A folder folded or opened while this was placed: its lines again, for what is folded now.
            let rows = self.folded == folded ? made.rows : made.layout.rows(folded: self.folded)
            self.shown = Shown(layout: made.layout, rows: rows, rooms: made.input.rooms)
        }
    }

    private struct Placed: Sendable {
        let input: Input
        let layout: SidePanelLayout
        let rows: [SidePanelLayout.Row]
    }
}
#endif
