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

/// A file an agent posted as base64 parts, shown at the root of its thread: what it is, whether its bytes are the
/// ones the poster declared, and, only then, the way to save it.
public struct RoomChatFileCard: Equatable, Identifiable, Sendable {
    public let id: String
    public let thread: Int64
    /// The file's name, already made safe (a basename, at most 128 characters).
    public let name: String
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
    ///   - sha256: the declared hash, lowercase hex.
    ///   - verified: the file, only when its bytes hash to the declared hash (and have the declared size).
    ///   - status: why it is not a file, worded for the room; nil when verified.
    ///   - partsTotal: how many parts the file has.
    ///   - partPosts: the posts that carry them (folded behind the card).
    ///   - computedHashes: for a hash mismatch, what the bytes hash to (decoded, then unzipped).
    ///   - previewable: a text type the room previews as plain text.
    public init(thread: Int64, name: String, sha256: String?, verified: Data?, status: String?, partsTotal: Int,
                partPosts: Int, computedHashes: [String] = [], previewable: Bool) {
        self.id = "\(thread)/\(name)/\(sha256 ?? "-")"
        self.thread = thread
        self.name = name
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

    /// "3 data parts": the toggle that shows the posts the file came from.
    public var partsToggleTitle: String { partCount == 1 ? "1 data part" : "\(partCount) data parts" }
}
