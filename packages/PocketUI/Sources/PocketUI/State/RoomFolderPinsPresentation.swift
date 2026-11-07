import Foundation

/// Capability and order for the separate pinned shortcuts; ordinary folders and rooms keep their places.
public enum RoomFolderPinsPresentation {
    public static let limit = 10
    public static let limitMessage = "You can pin up to 10 folders."

    public static func isAvailable(_ folders: [RoomFolderItem]) -> Bool {
        !folders.isEmpty && folders.allSatisfy(\.supportsPinning)
    }

    public static func ordered(_ folders: [RoomFolderItem]) -> [RoomFolderItem] {
        guard isAvailable(folders) else { return [] }
        return Array(folders.filter { $0.pinnedPosition.map { (0..<limit).contains($0) } == true }
            .sorted {
                if $0.pinnedPosition != $1.pinnedPosition { return ($0.pinnedPosition ?? limit) < ($1.pinnedPosition ?? limit) }
                return $0.id < $1.id
            }.prefix(limit))
    }

    public static func reordered(_ ids: [String], moving source: String, to target: String) -> [String] {
        guard let from = ids.firstIndex(of: source), let to = ids.firstIndex(of: target), from != to else { return ids }
        var next = ids
        next.remove(at: from)
        next.insert(source, at: to)
        return next
    }
}
