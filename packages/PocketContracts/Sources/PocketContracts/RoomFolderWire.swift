import Foundation

/// A folder name as the room-folders API takes it (`/api/v1/me/room-folders`, pinned contract 2026-11-04): trimmed,
/// 1 to 60 characters, no control characters. Counted in Unicode code points, as the API counts with Python's len.
public enum RoomFolderName {
    public static let maximumLength = 60
    /// The most folders one person can have.
    public static let maximumFolders = 100

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
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
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
