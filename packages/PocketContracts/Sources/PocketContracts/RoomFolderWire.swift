import Foundation

/// A folder name as the room-folders API takes it (`/api/v1/me/room-folders`, sentinelayer-api #1125): trimmed,
/// 1 to 60 characters, no control characters. Counted in Unicode code points, as the API counts with Python's len.
public enum RoomFolderName {
    public static let maximumLength = 60
    /// The most folders one person can have (the API answers 409 `ROOM_FOLDER_LIMIT` past it).
    public static let maximumFolders = 100
    /// How deep folders go: a top-level folder is level 1 (the API answers 409 `ROOM_FOLDER_DEPTH` past it).
    public static let maximumDepth = 3

    /// What the sheet says at the cap, whether the phone counted it or the server refused it.
    public static let limitMessage = "You've reached \(maximumFolders) folders."
    /// 409 `ROOM_FOLDER_DEPTH`.
    public static let depthMessage = "Folders go \(maximumDepth) levels deep at most."
    /// 409 `ROOM_FOLDER_CYCLE`.
    public static let cycleMessage = "A folder can't go inside itself."
    /// 409 `ROOM_FOLDER_NAME_TAKEN` on a create, a rename or a move.
    public static let nameTakenMessage = "There's already a folder with that name here."
    /// 409 `ROOM_FOLDER_NAME_TAKEN` on a delete: a folder inside it, moving up, has the name of one already there.
    public static let deleteNameTakenMessage =
        "A folder inside has the same name as one at that level. Rename one of them first."
    /// The delete confirmation: what happens to what is in the folder.
    public static let deleteMessage = "Its folders and rooms move up one level. No rooms are deleted."

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
        // Control characters (Cc) and the line and paragraph separators, as the API refuses them. Format characters
        // such as the zero-width joiner that builds "👩‍💻" are part of a name.
        let refused: Set<Unicode.GeneralCategory> = [.control, .lineSeparator, .paragraphSeparator]
        if name.unicodeScalars.contains(where: { refused.contains($0.properties.generalCategory) }) {
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
