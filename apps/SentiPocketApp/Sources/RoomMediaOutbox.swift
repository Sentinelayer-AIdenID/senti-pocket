import Foundation
import PocketSyncClient

/// One file's record in the outbox, kept as `entry.json` beside its file. An upload survives the app being closed:
/// its room, its ids (the same on every retry), the message it belongs to, and how far it got. Only stripped copies
/// are kept here: a photo or video's original is deleted as soon as its copy without location exists.
struct RoomMediaOutboxEntry: Codable, Equatable {
    struct Prepared: Codable, Equatable {
        /// The stored copy's file name in the entry's folder.
        var file: String
        var filename: String
        var contentType: String
        var fileExtension: String
        var sizeBytes: Int64
        var sha256: String
        var preview: Preview?
    }

    struct Preview: Codable, Equatable {
        var file: String
        var filename: String
        var sizeBytes: Int64
        var sha256: String
    }

    struct Stored: Codable, Equatable {
        var attachmentId: String
        var filename: String
        var kind: String?
        var contentType: String?
        var sizeBytes: Int64?
        var sha256: String?
        var status: String?
    }

    struct Message: Codable, Equatable {
        /// The message's client id: a retry after a relaunch posts the same message.
        var clientId: String
        var text: String?
        /// Its place among the message's files.
        var position: Int
    }

    var version = 1
    var sessionId: String
    /// The client attachment id, which becomes the attachment's id.
    var itemId: String
    var filename: String
    /// image, video or file.
    var kind: String
    var sizeBytes: Int64?
    var createdAt: Date
    var prepared: Prepared?
    /// Init was called: the server has a row for it (deleted if the file is taken out before it is sent).
    var initiated: Bool
    var previewDone: Bool
    var stored: Stored?
    var message: Message?
    /// Taken back by the person: deleted on the server at the next open, never restored.
    var withdrawn: Bool?
}

enum RoomMediaOutbox {
    static let entryName = "entry.json"
    /// An outbox entry not finished within this long is dropped at launch (the server lets unfinished uploads expire).
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static func write(_ entry: RoomMediaOutboxEntry, in folder: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: folder.appendingPathComponent(entryName),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read(in folder: URL) -> RoomMediaOutboxEntry? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(entryName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RoomMediaOutboxEntry.self, from: data)
    }

    /// This room's entries, oldest first.
    static func entries(for sessionId: String, root: URL) -> [(folder: URL, entry: RoomMediaOutboxEntry)] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let entry = read(in: folder), entry.sessionId == sessionId else { return nil }
            return (folder, entry)
        }
        .sorted { $0.entry.createdAt < $1.entry.createdAt }
    }

    /// At launch: drops what should not stay on the phone. A folder with no entry (closed before it was written), an
    /// entry never prepared (it would still hold the original, location and all), and an entry older than a week.
    static func sweep(root: URL = RoomMediaFiles.outbox, now: Date = Date()) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let entry = read(in: folder), entry.prepared != nil,
                  now.timeIntervalSince(entry.createdAt) < maximumAge else {
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            // Anything beside the entry that it does not name (an original left by a crash mid-way) goes too.
            let kept: Set<String> = [entryName, entry.prepared?.file, entry.prepared?.preview?.file].reduce(into: []) {
                if let name = $1 { $0.insert(name) }
            }
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where !kept.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
