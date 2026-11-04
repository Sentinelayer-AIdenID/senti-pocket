import Foundation

/// A folder name as the room-folders API takes it (`/api/v1/me/room-folders`, pinned contract 2026-11-04): trimmed,
/// 1 to 60 characters, no control characters. Counted in Unicode code points, as the API counts with Python's len.
public enum RoomFolderName {
    public static let maximumLength = 60
    /// The most folders one person can have (the API answers 409 `ROOM_FOLDER_LIMIT` past it).
    public static let maximumFolders = 100

    /// What the sheet says at the cap, whether the phone counted it or the server refused it.
    public static let limitMessage = "You have \(maximumFolders) folders, the most there can be. Delete one first."

    /// Why a name cannot be sent.
    public enum Problem: Error, Equatable, Sendable {
        case empty
        case tooLong
        case controlCharacters

        public var message: String {
            switch self {
            case .empty: return "Give the folder a name."
            case .tooLong: return "A folder name is at most \(RoomFolderName.maximumLength) characters."
            case .controlCharacters: return "That name has characters a folder name cannot have."
            }
        }
    }

    /// The name to send, or why it cannot be.
    public static func validate(_ raw: String) -> Result<String, Problem> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .failure(.empty) }
        // True control characters only (Cc). Format characters such as the zero-width joiner that builds "👩‍💻" are
        // part of a name.
        if name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return .failure(.controlCharacters)
        }
        if name.unicodeScalars.count > maximumLength { return .failure(.tooLong) }
        return .success(name)
    }

    /// The name to send, or nil when the API would refuse it.
    public static func cleaned(_ raw: String) -> String? {
        if case .success(let name) = validate(raw) { return name }
        return nil
    }
}
