import Foundation

/// A verified file as a card keeps it: its size and what it is made from (its decoded parts, which are the file
/// itself or its gzip), never the unzipped bytes. The bytes are made again only when they are wanted: the whole
/// file, checked again, when it is saved; its first bytes when its preview is opened. Held by reference: the room's
/// state is compared each time it changes, and this compares by identity.
public final class RoomChatFileContent: Equatable, @unchecked Sendable {
    /// The file's size.
    public let size: Int
    /// What the card keeps of the file: its decoded parts.
    public let kept: Data
    private let make: @Sendable (Data) -> Data?
    private let head: @Sendable (Data) -> Data

    /// - Parameters:
    ///   - make: the file's bytes from `kept`, checked again (unzipped again under the cap when it is gzip, then
    ///     its size and hash); nil when they don't check out.
    ///   - head: the file's first bytes from `kept` (at least `RoomChatFileCard.previewBytes` of them when the
    ///     file has that many), for its preview; by default `kept` itself, for a file that isn't gzip.
    public init(size: Int, kept: Data, make: @escaping @Sendable (Data) -> Data?,
                head: @escaping @Sendable (Data) -> Data = { $0 }) {
        self.size = size
        self.kept = kept
        self.make = make
        self.head = head
    }

    /// The file's bytes, made again and checked again: nil when they no longer check out, and then nothing is saved.
    public func bytes() -> Data? { make(kept) }

    /// The file's first bytes, made again for its preview.
    public func firstBytes() -> Data { head(kept) }

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
    /// Whether the file is verified and of a text type, which has a preview.
    public let previewable: Bool
    /// The posts folded behind the card's toggle.
    public let partCount: Int

    public var isVerified: Bool { content != nil }

    /// The lines a text preview shows, the longest line it shows whole, and how far into the file it reads.
    public static let previewLines = 40
    public static let previewLineLength = 200
    public static let previewBytes = 64 * 1024

    /// - Parameters:
    ///   - id: the file among the room's (its thread, author, name and hash); by default made from those shown.
    ///   - author: who posted the parts, as the room names them.
    ///   - sha256: the declared hash, lowercase hex.
    ///   - verified: what is kept of the file, only when its bytes hash to the declared hash (and have the declared
    ///     size).
    ///   - status: why it is not a file, worded for the room; nil when verified.
    ///   - partsTotal: how many parts the file has.
    ///   - partPosts: the posts that carry them (folded behind the card).
    ///   - computedHashes: for a hash mismatch, what the bytes hash to (decoded, then unzipped).
    ///   - previewable: a text type the room previews as plain text.
    public init(id: String? = nil, thread: Int64, name: String, author: String, sha256: String?,
                verified: RoomChatFileContent?, status: String?, partsTotal: Int, partPosts: Int,
                computedHashes: [String] = [], previewable: Bool) {
        self.id = id ?? "\(thread)/\(author)/\(name)/\(sha256 ?? "-")"
        self.thread = thread
        self.name = name
        self.author = author
        self.content = verified
        let parts = partsTotal == 1 ? "1 part" : "\(partsTotal) parts"
        if let verified, let sha256 {
            let size = ByteCountFormatter.string(fromByteCount: Int64(verified.size), countStyle: .file)
            self.detail = "\(size) · sha256 ✓ \(sha256.prefix(12)) · \(parts)"
        } else {
            self.detail = status ?? "not verified"
        }
        self.mismatch = computedHashes.isEmpty ? nil : computedHashes.enumerated().map { index, hash in
            "\(index == 0 ? "decoded" : "unzipped") \(hash.prefix(12))"
        }.joined(separator: " · ")
        self.previewable = verified != nil && previewable
        self.partCount = partPosts
    }

    /// The first lines of a verified text file, shown as plain text only, made when the preview is opened; nil for
    /// any other file.
    public func preview() -> String? {
        guard previewable, let content else { return nil }
        return Self.preview(of: content.firstBytes())
    }

    /// The first `previewLines` lines, each cut at `previewLineLength` characters: plain text, never markup.
    static func preview(of data: Data) -> String {
        let text = String(decoding: data.prefix(previewBytes), as: UTF8.self)
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

    /// Saves a verified file: its bytes made again and checked again, then written as `write(_:named:in:now:)`
    /// writes them. Bytes that no longer check out are never written.
    public static func write(_ content: RoomChatFileContent, named name: String,
                             in folder: URL = RoomFileExports.folder, now: Date = Date()) throws -> URL {
        guard let data = content.bytes() else { throw NotVerified() }
        return try write(data, named: name, in: folder, now: now)
    }

    /// The file's bytes didn't check out again when it was saved, so nothing was written.
    public struct NotVerified: Error, Equatable {}

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
