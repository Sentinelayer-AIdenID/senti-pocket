import Foundation

/// A verified file's bytes, held by reference: the room's state is compared each time it changes, and a file of many
/// megabytes compares by identity, not byte by byte.
public final class RoomChatFileContent: Equatable, @unchecked Sendable {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public static func == (lhs: RoomChatFileContent, rhs: RoomChatFileContent) -> Bool { lhs === rhs }
}

/// A file an agent posted as base64 parts, shown at the root of its thread: what it is, who posted it, whether its
/// bytes are the ones they declared, and, only then, the way to save it.
public struct RoomChatFileCard: Equatable, Identifiable, Sendable {
    public let id: String
    /// Where the card goes: its thread's root message, or, for parts posted at the top level, the newest of them.
    public let thread: Int64
    /// The file's name, already made safe (a basename, at most 128 bytes).
    public let name: String
    /// Who posted the parts, as the room names them: the file is theirs, not the thread's.
    public let author: String
    /// The verified file; nil when the bytes are not the declared ones, so nothing can be saved.
    public let content: RoomChatFileContent?
    /// "3 KB · sha256 ✓ 9b1f5b6cba4a · 3 parts" for a verified file; otherwise why it is not one ("2 of 3 parts",
    /// "hash mismatch", "no declared hash").
    public let detail: String
    /// For a hash mismatch: what the bytes hash to instead, 12 hex characters each.
    public let mismatch: String?
    /// The first lines of a verified text file, shown as plain text only; nil for any other file.
    public let preview: String?
    /// The posts folded behind the card's toggle.
    public let partCount: Int

    public var isVerified: Bool { content != nil }

    /// The lines a text preview shows, and the longest line it shows whole.
    public static let previewLines = 40
    public static let previewLineLength = 200

    /// - Parameters:
    ///   - id: the file among the room's (its thread, author, name and hash); by default made from those shown.
    ///   - author: who posted the parts, as the room names them.
    ///   - sha256: the declared hash, lowercase hex.
    ///   - verified: the file, only when its bytes hash to the declared hash (and have the declared size).
    ///   - status: why it is not a file, worded for the room; nil when verified.
    ///   - partsTotal: how many parts the file has.
    ///   - partPosts: the posts that carry them (folded behind the card).
    ///   - computedHashes: for a hash mismatch, what the bytes hash to (decoded, then unzipped).
    ///   - previewable: a text type the room previews as plain text.
    public init(id: String? = nil, thread: Int64, name: String, author: String, sha256: String?, verified: Data?,
                status: String?, partsTotal: Int, partPosts: Int, computedHashes: [String] = [], previewable: Bool) {
        self.id = id ?? "\(thread)/\(author)/\(name)/\(sha256 ?? "-")"
        self.thread = thread
        self.name = name
        self.author = author
        self.content = verified.map(RoomChatFileContent.init)
        let parts = partsTotal == 1 ? "1 part" : "\(partsTotal) parts"
        if let verified, let sha256 {
            let size = ByteCountFormatter.string(fromByteCount: Int64(verified.count), countStyle: .file)
            self.detail = "\(size) · sha256 ✓ \(sha256.prefix(12)) · \(parts)"
        } else {
            self.detail = status ?? "not verified"
        }
        self.mismatch = computedHashes.isEmpty ? nil : computedHashes.enumerated().map { index, hash in
            "\(index == 0 ? "decoded" : "unzipped") \(hash.prefix(12))"
        }.joined(separator: " · ")
        self.preview = verified.flatMap { previewable ? Self.preview(of: $0) : nil }
        self.partCount = partPosts
    }

    /// The first `previewLines` lines, each cut at `previewLineLength` characters: plain text, never markup.
    static func preview(of data: Data) -> String {
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(previewLines)
            .map { line in
                let line = line.hasSuffix("\r") ? line.dropLast() : line
                return line.count > previewLineLength ? String(line.prefix(previewLineLength)) + "…" : String(line)
            }
            .joined(separator: "\n")
    }

    /// "posted by ada-agent": whose file it is, under its name.
    public var postedBy: String { "posted by \(author.isEmpty ? "an unknown member" : author)" }

    /// "3 data parts": the toggle that shows the posts the file came from.
    public var partsToggleTitle: String { partCount == 1 ? "1 data part" : "\(partCount) data parts" }
}

/// Where verified files are written on their way out (to the share sheet), and their clean-up: each export is written
/// into its own folder when the person picks a destination, and exports older than an hour are removed before the
/// next one and whenever a room opens, since the share sheet says nothing when it is done with a file.
public enum RoomFileExports {
    /// How long an export stays for the share sheet to finish with it.
    public static let lifetime: TimeInterval = 60 * 60

    public static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("room-files", isDirectory: true)
    }

    /// Writes the file under its (already safe) name in a new folder of its own, after removing old exports.
    public static func write(_ data: Data, named name: String, in folder: URL = RoomFileExports.folder,
                             now: Date = Date()) throws -> URL {
        removeExports(olderThan: lifetime, in: folder, now: now)
        let export = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        let url = export.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Removes the exports last changed more than `age` ago; returns how many went.
    @discardableResult
    public static func removeExports(olderThan age: TimeInterval = RoomFileExports.lifetime,
                                     in folder: URL = RoomFileExports.folder, now: Date = Date()) -> Int {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else {
            return 0
        }
        var removed = 0
        for entry in entries {
            let changed = (try? entry.resourceValues(forKeys: Set(keys)))?.contentModificationDate
            guard now.timeIntervalSince(changed ?? .distantPast) > age else { continue }
            if (try? manager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}
