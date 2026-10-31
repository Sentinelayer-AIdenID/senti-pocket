import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Compression)
import Compression
#endif

/// A post that may carry part of a file sent as base64 text: a message or a threaded reply, in its thread.
public struct RoomFilePost: Equatable, Sendable {
    /// The thread: its root message's sequence id (a top-level message is its own root unless it replies to one).
    public let thread: Int64
    /// The post's own id (a message's or a reply's), so the room can fold the parts it finds.
    public let id: String
    public let body: String

    public init(thread: Int64, id: String, body: String) {
        self.thread = thread
        self.id = id
        self.body = body
    }
}

/// A file found in a thread's posts, and whether its bytes are the ones the poster declared.
public struct RoomBase64File: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case verified
        case partsMissing(found: Int, total: Int)
        case noDeclaredHash
        case conflictingCopies(part: Int)
        case totalsDisagree
        case notValidBase64
        case tooLarge
        /// The joined bytes hash to `decoded`, and, when they are gzip, the unzipped bytes to `gunzipped`: neither is
        /// the declared hash.
        case hashMismatch(decoded: String, gunzipped: String?)
        case sizeMismatch

        /// What the room shows for it.
        public var line: String {
            switch self {
            case .verified: return "verified"
            case .partsMissing(let found, let total): return "\(found) of \(total) parts"
            case .noDeclaredHash: return "no declared hash"
            case .conflictingCopies(let part): return "conflicting copies of part \(part)"
            case .totalsDisagree: return "parts disagree on the total"
            case .notValidBase64: return "not valid base64"
            case .tooLarge: return "too large"
            case .hashMismatch: return "hash mismatch"
            case .sizeMismatch: return "size mismatch"
            }
        }
    }

    public let thread: Int64
    /// The file's name, made safe: a basename with no control characters or leading dots, at most 128 characters.
    public let name: String
    /// The hash the poster declared, in lowercase hex, when there is one.
    public let declaredSHA256: String?
    /// The parts found (each index once) and how many the file has.
    public let partsFound: Int
    public let partsTotal: Int
    /// The posts that carry the parts, in the order they were given.
    public let partPostIds: [String]
    public let status: Status
    /// The file, only when its bytes hash to the declared hash (and have the declared size, if one was given).
    public let data: Data?

    public var isVerified: Bool { status == .verified }
}

/// Files that agents post as base64 text split over several messages or threaded replies, put back together and
/// offered only when their bytes match the hash the poster declared. Deterministic: the same posts always give the
/// same bytes and the same verdict, whatever order they come in. No model and no network.
///
/// A part is a post whose whole body is either a JSON envelope (`artifact`, `sha256`, `part`, `parts`, `data`, and
/// optionally `bytes` and `encoding`), or a text header line `<name> part <i>/<n>` followed by the base64 text. A
/// header's hash comes from a declaration elsewhere in the thread: a line naming the file, then `sha256` and 64 hex
/// characters (and optionally `<n> bytes`).
public enum RoomBase64Files {
    /// The largest file put back together, decoded or unzipped (a guard against a small post unzipping to a huge one).
    public static let maximumBytes = 50 * 1024 * 1024

    private struct Part {
        let name: String
        let sha256: String?
        let index: Int
        let total: Int
        let data: String
        let bytes: Int?
    }

    private struct Group {
        let thread: Int64
        let name: String
        let sha256: String?
        var bytes: Int?
        var totals: [Int] = []
        var parts: [Int: String] = [:]
        var conflict: Int?
        var postIds: [String] = []
    }

    /// Every file the posts hold, by thread and name.
    public static func reassemble(_ posts: [RoomFilePost]) -> [RoomBase64File] {
        var threadBodies: [Int64: [String]] = [:]
        for post in posts { threadBodies[post.thread, default: []].append(post.body) }
        var groups: [Group] = []
        var groupIndex: [String: Int] = [:]
        var declarations: [String: (sha256: String, bytes: Int?)?] = [:]
        for post in posts {
            guard let part = parsePart(post.body) else { continue }
            var sha256 = part.sha256
            var bytes = part.bytes
            if sha256 == nil {
                // Each thread and name is looked up once: a declaration is read from every line of the thread.
                let key = "\(post.thread)\u{0}\(part.name)"
                if declarations[key] == nil {
                    declarations[key] = .some(findDeclaration(of: part.name, in: threadBodies[post.thread] ?? []))
                }
                let declaration = declarations[key] ?? nil
                sha256 = declaration?.sha256
                bytes = declaration?.bytes
            }
            let key = "\(post.thread)\u{0}\(part.name)\u{0}\(sha256 ?? "-")"
            if groupIndex[key] == nil {
                groupIndex[key] = groups.count
                groups.append(Group(thread: post.thread, name: part.name, sha256: sha256, bytes: bytes))
            }
            guard let index = groupIndex[key] else { continue }
            if !groups[index].totals.contains(part.total) { groups[index].totals.append(part.total) }
            if let bytes { groups[index].bytes = bytes }
            groups[index].postIds.append(post.id)
            let data = withoutWhitespace(part.data)
            if let previous = groups[index].parts[part.index], previous != data {
                groups[index].conflict = part.index
            } else {
                groups[index].parts[part.index] = data
            }
        }
        return groups.map(verify).sorted { ($0.thread, $0.name) < ($1.thread, $1.name) }
    }

    /// The text without ASCII whitespace, read as bytes (a part can be megabytes of base64).
    private static func withoutWhitespace(_ text: String) -> String {
        String(decoding: text.utf8.filter { !(9...13).contains($0) && $0 != 32 }, as: UTF8.self)
    }

    private static func verify(_ group: Group) -> RoomBase64File {
        let total = group.totals.first ?? 0
        func file(_ status: RoomBase64File.Status, _ data: Data? = nil) -> RoomBase64File {
            RoomBase64File(thread: group.thread, name: sanitizedName(group.name), declaredSHA256: group.sha256,
                           partsFound: group.parts.count, partsTotal: total, partPostIds: group.postIds,
                           status: status, data: data)
        }
        if group.totals.count > 1 { return file(.totalsDisagree) }
        if let conflict = group.conflict { return file(.conflictingCopies(part: conflict)) }
        guard let declared = group.sha256 else { return file(.noDeclaredHash) }
        if group.parts.count < total { return file(.partsMissing(found: group.parts.count, total: total)) }
        let joined = (1...max(total, 1)).compactMap { group.parts[$0] }.joined()
        guard let raw = decodeBase64(joined) else { return file(.notValidBase64) }
        if raw.count > maximumBytes { return file(.tooLarge) }
        let rawHash = sha256Hex(raw)
        var verified: Data?
        var unzippedHash: String?
        if rawHash == declared {
            verified = raw
        } else if raw.count >= 2, raw[raw.startIndex] == 0x1f, raw[raw.startIndex + 1] == 0x8b,
                  let unzipped = gunzip(raw, limit: maximumBytes) {
            let hash = sha256Hex(unzipped)
            unzippedHash = hash
            if hash == declared { verified = unzipped }
        }
        guard let verified else { return file(.hashMismatch(decoded: rawHash, gunzipped: unzippedHash)) }
        if let bytes = group.bytes, bytes != verified.count { return file(.sizeMismatch) }
        return file(.verified, verified)
    }

    // MARK: - Parts

    /// Whether a post is shaped like a part, read cheaply (a JSON body naming an artifact, or a header line): the
    /// room asks this of every post, and puts a thread together only when one of its posts is.
    public static func mayBePart(_ body: String) -> Bool {
        let text = body.drop(while: { $0.isWhitespace })
        if text.hasPrefix("{") { return text.contains("\"artifact\"") && text.contains("\"data\"") }
        guard let newline = text.firstIndex(of: "\n"), let headerPattern else { return false }
        let first = text[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
        return headerPattern.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)) != nil
    }

    private static let headerPattern = try? NSRegularExpression(
        pattern: #"^([^\s/\\]{1,128}) part ([0-9]+)/([0-9]+)$"#, options: [.caseInsensitive]
    )

    private static func parsePart(_ body: String) -> Part? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") { return parseEnvelope(text) }
        guard let newline = text.firstIndex(of: "\n") else { return nil }
        let first = text[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(first.startIndex..., in: first)
        guard let headerPattern, let match = headerPattern.firstMatch(in: first, range: range),
              let nameRange = Range(match.range(at: 1), in: first),
              let indexRange = Range(match.range(at: 2), in: first),
              let totalRange = Range(match.range(at: 3), in: first),
              let index = Int(first[indexRange]), let total = Int(first[totalRange]),
              index >= 1, total >= 1, index <= total else { return nil }
        return Part(name: String(first[nameRange]), sha256: nil, index: index, total: total,
                    data: String(text[text.index(after: newline)...]), bytes: nil)
    }

    private static func parseEnvelope(_ text: String) -> Part? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let name = object["artifact"] as? String,
              let sha256 = object["sha256"] as? String, isHex64(sha256),
              let index = integer(object["part"]), let total = integer(object["parts"]),
              index >= 1, index <= total,
              let data = object["data"] as? String else { return nil }
        return Part(name: name, sha256: sha256.lowercased(), index: index, total: total, data: data,
                    bytes: integer(object["bytes"]))
    }

    /// A JSON integer: a number with no fraction, never a boolean.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 9_007_199_254_740_992 else { return nil }
        return Int(double)
    }

    private static func isHex64(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy(isHexDigit)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    // MARK: - Declarations

    /// The first line in the thread that names the file and then gives `sha256` and 64 hex characters; its
    /// `<n> bytes`, when it has one, is the declared size.
    private static func findDeclaration(of name: String, in bodies: [String]) -> (sha256: String, bytes: Int?)? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let declaration = try? NSRegularExpression(
            pattern: escaped + #".*?sha256[\s:=`]*([0-9a-f]{64})"#, options: [.caseInsensitive]
        ), let size = try? NSRegularExpression(pattern: #"([0-9][0-9,]*)\s*bytes"#, options: [.caseInsensitive]) else {
            return nil
        }
        for body in bodies {
            for line in body.components(separatedBy: "\n") {
                let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
                let range = NSRange(line.startIndex..., in: line)
                guard let match = declaration.firstMatch(in: line, range: range),
                      let hashRange = Range(match.range(at: 1), in: line) else { continue }
                let bytes = size.firstMatch(in: line, range: range)
                    .flatMap { Range($0.range(at: 1), in: line) }
                    .flatMap { Int(line[$0].replacingOccurrences(of: ",", with: "")) }
                return (line[hashRange].lowercased(), bytes)
            }
        }
        return nil
    }

    // MARK: - Bytes

    /// Base64 with the standard alphabet, also taking `-` and `_` for `+` and `/` and missing `=` padding, as
    /// `^[A-Za-z0-9+/]*={0,2}$` after whitespace is removed. Padding comes last, two at most: checked here, since
    /// Foundation's decoder takes more. Another character, or a length no base64 text has, it refuses itself.
    static func decodeBase64(_ text: String) -> Data? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var padding = 0
        for byte in text.utf8 {
            switch byte {
            case 9...13, 32:
                continue
            case UInt8(ascii: "="):
                padding += 1
                bytes.append(byte)
            default:
                guard padding == 0 else { return nil }
                switch byte {
                case UInt8(ascii: "-"): bytes.append(UInt8(ascii: "+"))
                case UInt8(ascii: "_"): bytes.append(UInt8(ascii: "/"))
                default: bytes.append(byte)
                }
            }
        }
        guard padding <= 2 else { return nil }
        if bytes.count % 4 != 0 { bytes += [UInt8](repeating: UInt8(ascii: "="), count: 4 - bytes.count % 4) }
        return Data(base64Encoded: Data(bytes))
    }

    /// The bytes of a gzip file (RFC 1952: its header read here, the DEFLATE data inflated by Compression), or nil
    /// when it is not one or would unzip past `limit`, checked as the bytes come out. The declared hash checks the
    /// result, so the gzip trailer's checksum is not read.
    static func gunzip(_ data: Data, limit: Int) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard bytes.count >= offset + 2 else { return nil }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            offset = end + 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { return nil }
        return inflate(Array(bytes[offset..<(bytes.count - 8)]), limit: limit)
    }

    private struct PastLimit: Error {}

    private static func inflate(_ deflated: [UInt8], limit: Int) -> Data? {
        #if canImport(Compression)
        var output = Data()
        do {
            let filter = try OutputFilter(.decompress, using: .zlib) { (chunk: Data?) in
                guard let chunk else { return }
                guard output.count + chunk.count <= limit else { throw PastLimit() }
                output.append(chunk)
            }
            try filter.write(deflated)
            try filter.finalize()
        } catch {
            return nil
        }
        return output
        #else
        return nil
        #endif
    }

    /// Lowercase hex SHA-256.
    public static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }

    // MARK: - Names

    /// A basename with no control characters or leading dots, at most 128 characters; `file.bin` if nothing is left.
    public static func sanitizedName(_ name: String) -> String {
        let last = name.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).last
            .map(String.init) ?? name
        var scalars = String.UnicodeScalarView(last.unicodeScalars.filter { $0.value > 0x1f && $0.value != 0x7f })
        while scalars.first == "." { scalars.removeFirst() }
        let cut = String(String(scalars).utf16.prefix(128)) ?? String(String(scalars).prefix(128))
        return cut.isEmpty ? "file.bin" : cut
    }

    /// The file's type by its extension only (the bytes are never sniffed).
    public static func mimeType(forName name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "zip": return "application/zip"
        case "json": return "application/json"
        case "jsonl": return "application/x-ndjson"
        case "txt", "md": return "text/plain"
        case "csv": return "text/csv"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }

    /// The text types the room previews, as plain text only.
    public static func isPreviewable(_ name: String) -> Bool {
        ["txt", "md", "json", "jsonl", "csv"].contains((name as NSString).pathExtension.lowercased())
    }
}
