import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Compression)
import Compression
#endif

/// A post that may carry part of a file sent as base64 text: who posted it, and in which thread.
public struct RoomFilePost: Equatable, Sendable {
    /// The thread: the root message's sequence for a reply, and for the root message itself when its file is in its
    /// thread; nil for a top-level post, whose parts group with the same author's other top-level posts.
    public let thread: Int64?
    /// Who posted it. A file's parts, and the declaration that gives a header part its hash, count only from the
    /// same author in the same thread: another member's posts never join or break someone else's file.
    public let author: String
    /// The post's own id (a message's or a reply's), so the room can fold the parts it finds.
    public let id: String
    public let body: String

    public init(thread: Int64?, author: String, id: String, body: String) {
        self.thread = thread
        self.author = author
        self.id = id
        self.body = body
    }
}

/// A file found in one author's posts in a thread, and whether its bytes are the ones that author declared.
public struct RoomBase64File: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case verified
        case partsMissing(found: Int, total: Int)
        case noDeclaredHash
        /// The author declared more than one hash for the name, and the parts don't say which is theirs.
        case ambiguousDeclarations
        case conflictingCopies(part: Int)
        /// The parts or declarations give the file more than one size.
        case conflictingSizes
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
            case .ambiguousDeclarations: return "ambiguous declarations"
            case .conflictingCopies(let part): return "conflicting copies of part \(part)"
            case .conflictingSizes: return "conflicting sizes"
            case .totalsDisagree: return "parts disagree on the total"
            case .notValidBase64: return "not valid base64"
            case .tooLarge: return "too large"
            case .hashMismatch: return "hash mismatch"
            case .sizeMismatch: return "size mismatch"
            }
        }
    }

    /// The file among the posts given: its thread, author, name as posted and declared hash, one to a line.
    public let id: String
    public let thread: Int64?
    /// Who posted the parts: the file is theirs.
    public let author: String
    /// The file's name, made safe: a basename with no control, direction or zero-width characters and no leading dots,
    /// at most 128 bytes of UTF-8.
    public let name: String
    /// The hash the poster declared, in lowercase hex, when there is one.
    public let declaredSHA256: String?
    /// The parts found (each index once) and how many the file has.
    public let partsFound: Int
    public let partsTotal: Int
    /// The posts that carry the parts, by id.
    public let partPostIds: [String]
    public let status: Status
    /// The file, only when its bytes hash to the declared hash (and have the declared size, if one was given).
    public let data: Data?

    public var isVerified: Bool { status == .verified }
}

/// Files that agents post as base64 text split over several messages or threaded replies, put back together and
/// offered only when their bytes match the hash their author declared. Deterministic and order-independent: the same
/// posts give the same bytes and the same verdicts in any order. No model and no network.
///
/// A part is a post whose whole body is either a JSON envelope (`artifact`, `sha256`, `part`, `parts`, `data`, and
/// optionally `bytes` and `encoding`), or a text header line `<name> part <i>/<n>` followed by nothing but base64 text.
/// A header's hash comes from the header line itself, when it ends with a parenthetical holding `sha256` and 64 hex
/// characters (`(2264 bytes, SHA256 <hex>, gzip plus base64)`, its `<n> bytes` the size); otherwise from a declaration
/// by the same author in the same thread: a line naming the file, then `sha256` and 64 hex characters (and optionally
/// `<n> bytes`) before the next file named on the line.
///
/// Parts group by thread, author, name and declared hash, so a file is only ever its own author's.
public enum RoomBase64Files {
    /// The largest file put back together, decoded or unzipped (a guard against a small post unzipping to a huge one).
    public static let maximumBytes = 50 * 1024 * 1024
    /// What one author's files in one thread may decode and unzip together in one call: a guard against many small
    /// posts that each unzip to almost the cap. Each author has their own, so no one can use up another's.
    public static let authorBudgetBytes = 200 * 1024 * 1024

    private struct Part {
        let name: [Unicode.Scalar]
        let sha256: String?
        let index: Int
        let total: Int
        let data: [UInt8]
        let bytes: Int?
    }

    /// One author's posts in one thread. The author is compared as bytes, never as canonically equivalent text.
    private struct Poster: Hashable {
        let thread: Int64?
        let author: [UInt8]
    }

    private struct GroupKey: Hashable {
        let poster: Poster
        let name: [Unicode.Scalar]
        /// The declared hash; "?" when the declarations are ambiguous, "-" when there is none.
        let hash: String
    }

    private struct Group {
        let poster: Poster
        let author: String
        let name: [Unicode.Scalar]
        let sha256: String?
        let ambiguous: Bool
        var totals: Set<Int> = []
        var sizes: Set<Int> = []
        var parts: [Int: Set<[UInt8]>] = [:]
        var postIds: [String] = []

        var threadText: String { poster.thread.map(String.init) ?? "top" }
        var nameText: String { String(String.UnicodeScalarView(name)) }
        var id: String { [threadText, author, nameText, sha256 ?? (ambiguous ? "?" : "-")].joined(separator: "\n") }
        /// The fixed order files are checked in (and returned in): thread, author, name and hash.
        var order: [UInt32] {
            "\(threadText)/\(author)/\(nameText)/\(sha256 ?? "null")".unicodeScalars.map(\.value)
        }
    }

    /// Every file the posts hold, by thread, author and name. `maximumBytes` caps each file and `authorBudget` what one
    /// author's files in one thread may decode and unzip together; both are lowered only by tests. A cancelled task
    /// gets nothing back.
    public static func reassemble(_ posts: [RoomFilePost], maximumBytes: Int = RoomBase64Files.maximumBytes,
                                  authorBudget: Int = RoomBase64Files.authorBudgetBytes) -> [RoomBase64File] {
        var bodies: [Poster: [String]] = [:]
        for post in posts {
            bodies[Poster(thread: post.thread, author: Array(post.author.utf8)), default: []].append(post.body)
        }
        var declarations: [Poster: DeclarationIndex] = [:]
        var groups: [GroupKey: Group] = [:]
        for post in posts {
            if Task.isCancelled { return [] }
            guard let part = parsePart(post.body) else { continue }
            let poster = Poster(thread: post.thread, author: Array(post.author.utf8))
            var sha256 = part.sha256
            var sizes: Set<Int> = part.bytes.map { [$0] } ?? []
            var ambiguous = false
            if sha256 == nil {
                // Only the part's own author, in the same thread, can declare its hash.
                let index = declarations[poster] ?? DeclarationIndex(bodies[poster] ?? [])
                declarations[poster] = index
                let found = index.declarations(of: part.name)
                let hashes = Set(found.map(\.sha256))
                if hashes.count > 1 {
                    ambiguous = true
                } else if let only = hashes.first {
                    sha256 = only
                    sizes.formUnion(found.compactMap(\.bytes))
                }
            }
            let key = GroupKey(poster: poster, name: part.name, hash: sha256 ?? (ambiguous ? "?" : "-"))
            var group = groups[key] ?? Group(poster: poster, author: post.author, name: part.name, sha256: sha256,
                                             ambiguous: ambiguous)
            group.totals.insert(part.total)
            group.sizes.formUnion(sizes)
            group.parts[part.index, default: []].insert(part.data)
            group.postIds.append(post.id)
            groups[key] = group
        }
        var budgets: [Poster: Int] = [:]
        var files: [RoomBase64File] = []
        let ordered = groups.values.map { (order: $0.order, group: $0) }
            .sorted { $0.order.lexicographicallyPrecedes($1.order) }
            .map(\.group)
        for group in ordered {
            if Task.isCancelled { return [] }
            var budget = budgets[group.poster] ?? authorBudget
            files.append(verify(group, maximumBytes: maximumBytes, budget: &budget))
            budgets[group.poster] = budget
        }
        return Task.isCancelled ? [] : files
    }

    /// A group's verdict. The order of the checks is the spec's, so every implementation reports the same reason.
    private static func verify(_ group: Group, maximumBytes: Int, budget: inout Int) -> RoomBase64File {
        let total = group.totals.min() ?? 0
        func file(_ status: RoomBase64File.Status, _ data: Data? = nil) -> RoomBase64File {
            RoomBase64File(id: group.id, thread: group.poster.thread, author: group.author,
                           name: sanitizedName(group.nameText), declaredSHA256: group.sha256,
                           partsFound: group.parts.count, partsTotal: total, partPostIds: group.postIds.sorted(),
                           status: status, data: data)
        }
        if group.totals.count > 1 { return file(.totalsDisagree) }
        // The lowest index with differing copies, whatever order they came in.
        if let conflict = group.parts.filter({ $0.value.count > 1 }).keys.min() {
            return file(.conflictingCopies(part: conflict))
        }
        if group.ambiguous { return file(.ambiguousDeclarations) }
        guard let declared = group.sha256 else { return file(.noDeclaredHash) }
        if group.sizes.count > 1 { return file(.conflictingSizes) }
        if group.parts.count < total || group.parts.keys.contains(where: { $0 > total }) {
            return file(.partsMissing(found: min(group.parts.count, total), total: total))
        }
        var joined: [UInt8] = []
        for index in 1...max(total, 1) { joined += group.parts[index]?.first ?? [] }
        // The size is known from the text before anything is decoded.
        let estimate = decodedLength(joined)
        if estimate > maximumBytes || estimate > budget { return file(.tooLarge) }
        guard let raw = decodeBase64(joined) else { return file(.notValidBase64) }
        budget -= raw.count
        let rawHash = sha256Hex(raw)
        var verified: Data?
        var unzippedHash: String?
        if rawHash == declared {
            verified = raw
        } else if raw.count >= 2, raw[raw.startIndex] == 0x1f, raw[raw.startIndex + 1] == 0x8b, budget > 0,
                  let unzipped = gunzip(raw, limit: min(maximumBytes, budget)) {
            budget -= unzipped.count
            let hash = sha256Hex(unzipped)
            unzippedHash = hash
            if hash == declared { verified = unzipped }
        }
        guard let verified else { return file(.hashMismatch(decoded: rawHash, gunzipped: unzippedHash)) }
        if let size = group.sizes.first, size != verified.count { return file(.sizeMismatch) }
        return file(.verified, verified)
    }

    // MARK: - Parts

    /// Whether a post is a part: the room asks this once per post and revision, and puts a thread together only when
    /// one of its posts is.
    public static func mayBePart(_ body: String) -> Bool {
        parsePart(body) != nil
    }

    private static func parsePart(_ body: String) -> Part? {
        let text = normalizedScalars(body)
        var start = 0
        var end = text.count
        while start < end, isSpace(text[start]) { start += 1 }
        while end > start, isSpace(text[end - 1]) { end -= 1 }
        guard start < end else { return nil }
        if text[start] == "{" { return parseEnvelope(String(String.UnicodeScalarView(text[start..<end]))) }
        guard let newline = text[start..<end].firstIndex(of: "\n") else { return nil }
        var headerEnd = newline
        while headerEnd > start, isSpace(text[headerEnd - 1]) { headerEnd -= 1 }
        guard let header = parseHeader(text[start..<headerEnd]),
              header.index >= 1, header.total >= 1, header.index <= header.total else { return nil }
        // Prose is not a part: everything after the header is base64 (spaces and line breaks aside), and some is there.
        var data: [UInt8] = []
        data.reserveCapacity(end - newline)
        for scalar in text[(newline + 1)..<end] where !isSpace(scalar) {
            guard isBase64Character(scalar) else { return nil }
            data.append(UInt8(scalar.value))
        }
        guard data.count >= 4 else { return nil }
        // A parenthetical on the header line that holds the hash declares it, and its size; without one, the thread
        // needs a declaration line from the same author.
        let hash = hashes(in: header.meta).first?.value
        let bytes = hash == nil ? nil : sizes(in: header.meta).first?.value
        return Part(name: header.name, sha256: hash, index: header.index, total: header.total, data: data, bytes: bytes)
    }

    /// `^([^\s/\\]{1,128}) part (\d{1,6})/(\d{1,6})(?:\s*\(([^)]{0,512})\))?$`, case-insensitive, read by hand: the
    /// lengths are UTF-16 code units, as the reference counts them.
    private static func parseHeader(
        _ line: ArraySlice<Unicode.Scalar>
    ) -> (name: [Unicode.Scalar], index: Int, total: Int, meta: [Unicode.Scalar])? {
        var at = line.startIndex
        let end = line.endIndex
        while at < end, !isSpace(line[at]), line[at] != "/", line[at] != "\\" { at += 1 }
        let name = Array(line[line.startIndex..<at])
        let word: [Unicode.Scalar] = ["p", "a", "r", "t"]
        guard (1...128).contains(utf16Length(name)), at + 6 <= end, line[at] == " ", line[at + 5] == " ",
              line[(at + 1)..<(at + 5)].map(lowercased) == word else { return nil }
        guard let index = number(in: line, from: at + 6), index.end < end, line[index.end] == "/",
              let total = number(in: line, from: index.end + 1) else { return nil }
        if total.end == end { return (name, index.value, total.value, []) }
        var open = total.end
        while open < end, isSpace(line[open]) { open += 1 }
        guard open < end, line[open] == "(", line[end - 1] == ")", open < end - 1 else { return nil }
        let meta = Array(line[(open + 1)..<(end - 1)])
        guard !meta.contains(")"), utf16Length(meta) <= 512 else { return nil }
        return (name, index.value, total.value, meta)
    }

    /// One to six ASCII digits from `start`, and where they end.
    private static func number(in line: ArraySlice<Unicode.Scalar>, from start: Int) -> (value: Int, end: Int)? {
        var end = start
        var value = 0
        while end < line.endIndex, isDigit(line[end]) {
            value = value * 10 + Int(line[end].value - 48)
            end += 1
            if end - start > 6 { return nil }
        }
        return end > start ? (value, end) : nil
    }

    private static func parseEnvelope(_ text: String) -> Part? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let name = object["artifact"] as? String,
              let sha256 = object["sha256"] as? String, isHex64(sha256),
              let index = integer(object["part"]), let total = integer(object["parts"]),
              index >= 1, index <= total,
              let text = object["data"] as? String else { return nil }
        var data: [UInt8] = []
        data.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars where !isSpace(scalar) {
            guard isBase64Character(scalar) else { return nil }
            data.append(UInt8(scalar.value))
        }
        guard !data.isEmpty else { return nil }
        return Part(name: Array(name.unicodeScalars), sha256: sha256.lowercased(), index: index, total: total,
                    data: data, bytes: declaredSize(object["bytes"]))
    }

    /// A JSON integer: a number with no fraction, never a boolean.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 9_007_199_254_740_992 else { return nil }
        return Int(double)
    }

    /// A declared size: any JSON integer; one too large for any file is kept as a size no file has.
    private static func declaredSize(_ value: Any?) -> Int? {
        if let size = integer(value) { return size }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue, number.doubleValue.isFinite else { return nil }
        return Int.max
    }

    private static func isHex64(_ text: String) -> Bool {
        text.utf8.count == 64 && text.unicodeScalars.allSatisfy(isHexDigit)
    }

    // MARK: - Declarations

    /// One author's lines in one thread that mention `sha256` (no other line can declare a hash), and what each file
    /// name finds in them, worked out once per name.
    private final class DeclarationIndex {
        private static let before: Set<Unicode.Scalar> = [" ", "\t", "`", "'", "\"", "(", "["]
        private static let after: Set<Unicode.Scalar> = [" ", "\t", "`", "'", "\"", ":", ",", ";", ")", "]"]
        private let lines: [[Unicode.Scalar]]
        private var scans: [Int: LineScan] = [:]
        private var found: [[Unicode.Scalar]: [(sha256: String, bytes: Int?)]] = [:]

        init(_ bodies: [String]) {
            var lines: [[Unicode.Scalar]] = []
            for body in bodies {
                for line in RoomBase64Files.lines(of: body) where RoomBase64Files.mentionsHash(line) {
                    lines.append(line)
                }
            }
            self.lines = lines
        }

        /// Every declaration of `name`: each place a line names it, at a name boundary, and then gives `sha256` and
        /// 64 hex characters before the next file the line names. Each line is scanned once, so a line that names the
        /// file many times is still read in linear time.
        func declarations(of name: [Unicode.Scalar]) -> [(sha256: String, bytes: Int?)] {
            if let known = found[name] { return known }
            var result: [(sha256: String, bytes: Int?)] = []
            for (number, line) in lines.enumerated() where line.count >= name.count {
                for at in 0...(line.count - name.count) where line[at] == name[0] {
                    guard line[at..<(at + name.count)].elementsEqual(name) else { continue }
                    let previous: Unicode.Scalar = at == 0 ? " " : line[at - 1]
                    let next: Unicode.Scalar = at + name.count < line.count ? line[at + name.count] : " "
                    guard Self.before.contains(previous), Self.after.contains(next) else { continue }
                    let scan = scans[number] ?? LineScan(line)
                    scans[number] = scan
                    if let declaration = scan.declaration(from: at + name.count) { result.append(declaration) }
                }
            }
            found[name] = result
            return result
        }
    }

    /// A line's file-like tokens, hashes and sizes, each found in one pass: then the segment after any place the line
    /// names a file, and the hash and size in it, are looked up rather than searched for.
    private struct LineScan {
        private struct Run {
            let start: Int
            let end: Int
            /// The run's last ".", or -1.
            let dot: Int
            /// `[^\s`'"(),;:]+\.[A-Za-z0-9]{1,8}` up to its end, then a space, or a quote and a space.
            let endsLikeFile: Bool
        }

        private let line: [Unicode.Scalar]
        private let runs: [Run]
        /// The run each position is in, or -1.
        private let runOf: [Int]
        /// The first run that starts after each position.
        private let runAfter: [Int]
        /// The first file-like run from each run on, or -1.
        private let fileFrom: [Int]
        private let hashes: [Found<String>]
        private let sizes: [Found<Int>]

        init(_ line: [Unicode.Scalar]) {
            let count = line.count
            var runs: [Run] = []
            var runOf = Array(repeating: -1, count: count)
            var at = 0
            while at < count {
                guard RoomBase64Files.isTokenCharacter(line[at]) else {
                    at += 1
                    continue
                }
                var end = at
                while end < count, RoomBase64Files.isTokenCharacter(line[end]) { end += 1 }
                let dot = line[at..<end].lastIndex(of: ".") ?? -1
                let extensionLength = dot >= 0 ? end - dot - 1 : 0
                // At least one character before the dot, 1 to 8 ASCII letters or digits after it to the run's end.
                let extensionLike = dot > at && (1...8).contains(extensionLength)
                    && line[(dot + 1)..<end].allSatisfy(RoomBase64Files.isAlphanumeric)
                let followed = end < count
                    && (RoomBase64Files.isSpace(line[end])
                        || (RoomBase64Files.isQuote(line[end]) && end + 1 < count
                            && RoomBase64Files.isSpace(line[end + 1])))
                for position in at..<end { runOf[position] = runs.count }
                runs.append(Run(start: at, end: end, dot: dot, endsLikeFile: extensionLike && followed))
                at = end
            }
            var runAfter = Array(repeating: runs.count, count: count + 1)
            var next = runs.count
            var candidate = runs.count - 1
            for position in stride(from: count, through: 0, by: -1) {
                while candidate >= 0, runs[candidate].start > position {
                    next = candidate
                    candidate -= 1
                }
                runAfter[position] = next
            }
            var fileFrom = Array(repeating: -1, count: runs.count + 1)
            for index in stride(from: runs.count - 1, through: 0, by: -1) {
                fileFrom[index] = runs[index].endsLikeFile ? index : fileFrom[index + 1]
            }
            self.line = line
            self.runs = runs
            self.runOf = runOf
            self.runAfter = runAfter
            self.fileFrom = fileFrom
            hashes = RoomBase64Files.hashes(in: line)
            sizes = RoomBase64Files.sizes(in: line)
        }

        /// Where a segment that begins at `start` ends: where the next file-like token begins, searching from `start`
        /// (`[`'"]?[^\s`'"(),;:]+\.[A-Za-z0-9]{1,8}[`'"]?\s`), or the end of the line.
        func segmentEnd(from start: Int) -> Int {
            let next: Int
            if start < line.count, runOf[start] >= 0 {
                // A search that begins inside a run sees only the rest of it: a token there needs its dot after
                // `start`.
                let run = runs[runOf[start]]
                if run.endsLikeFile, run.dot > start { return start }
                next = runOf[start] + 1
            } else {
                next = runAfter[start]
            }
            guard next < runs.count, fileFrom[next] >= 0 else { return line.count }
            let run = runs[fileFrom[next]]
            return run.start - 1 >= start && RoomBase64Files.isQuote(line[run.start - 1]) ? run.start - 1 : run.start
        }

        /// The declaration in the segment after a file name that ends at `start`: its first hash, and its first size.
        func declaration(from start: Int) -> (sha256: String, bytes: Int?)? {
            let end = segmentEnd(from: start)
            guard let hash = Self.first(hashes, from: start), hash.end <= end else { return nil }
            let size = Self.first(sizes, from: start).flatMap { $0.end <= end ? $0.value : nil }
            return (hash.value, size)
        }

        private static func first<Value>(_ found: [Found<Value>], from start: Int) -> Found<Value>? {
            var low = 0
            var high = found.count
            while low < high {
                let middle = (low + high) / 2
                if found[middle].at < start { low = middle + 1 } else { high = middle }
            }
            return low < found.count ? found[low] : nil
        }
    }

    private struct Found<Value> {
        let at: Int
        let end: Int
        let value: Value
    }

    /// Each `sha256` followed, after spaces, tabs, `:`, `=` and quotes, by exactly 64 hex characters: the hex,
    /// lowercased, with where the word starts and where the hex ends.
    private static func hashes(in text: [Unicode.Scalar]) -> [Found<String>] {
        var found: [Found<String>] = []
        guard text.count >= 6 else { return found }
        for at in 0...(text.count - 6) where matches(text, at: at, "sha256") {
            var start = at + 6
            while start < text.count, hashSeparators.contains(text[start]) { start += 1 }
            let end = start + 64
            guard end <= text.count, text[start..<end].allSatisfy(isHexDigit),
                  end == text.count || !isHexDigit(text[end]) else { continue }
            let hex = String(String.UnicodeScalarView(text[start..<end])).lowercased()
            found.append(Found(at: at, end: end, value: hex))
        }
        return found
    }

    /// Each `(\d[\d,]{0,15})\s?bytes\b` (case-insensitive), as the number without its commas.
    private static func sizes(in text: [Unicode.Scalar]) -> [Found<Int>] {
        var found: [Found<Int>] = []
        for at in text.indices where isDigit(text[at]) {
            var digits = at + 1
            while digits < text.count, digits - at - 1 <= 15, isDigit(text[digits]) || text[digits] == "," {
                digits += 1
            }
            guard digits - at - 1 <= 15 else { continue }
            let word = digits < text.count && isSpace(text[digits]) ? digits + 1 : digits
            guard word + 5 <= text.count, matches(text, at: word, "bytes"),
                  word + 5 == text.count || !isWordCharacter(text[word + 5]) else { continue }
            var value = 0
            for scalar in text[at..<digits] where scalar != "," { value = value * 10 + Int(scalar.value - 48) }
            found.append(Found(at: at, end: word + 5, value: value))
        }
        return found
    }

    private static let hashSeparators: Set<Unicode.Scalar> = [" ", "\t", ":", "=", "`", "'", "\""]

    /// A body's lines, with CRLF and a lone CR each a line break.
    private static func lines(of body: String) -> [[Unicode.Scalar]] {
        var lines: [[Unicode.Scalar]] = []
        var line: [Unicode.Scalar] = []
        var afterReturn = false
        for scalar in body.unicodeScalars {
            switch scalar {
            case "\r":
                lines.append(line)
                line.removeAll(keepingCapacity: true)
                afterReturn = true
            case "\n":
                if !afterReturn {
                    lines.append(line)
                    line.removeAll(keepingCapacity: true)
                }
                afterReturn = false
            default:
                line.append(scalar)
                afterReturn = false
            }
        }
        lines.append(line)
        return lines
    }

    /// The body's scalars with CRLF and a lone CR each turned into LF.
    private static func normalizedScalars(_ body: String) -> [Unicode.Scalar] {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(body.utf8.count)
        var afterReturn = false
        for scalar in body.unicodeScalars {
            switch scalar {
            case "\r":
                scalars.append("\n")
                afterReturn = true
            case "\n":
                if !afterReturn { scalars.append("\n") }
                afterReturn = false
            default:
                scalars.append(scalar)
                afterReturn = false
            }
        }
        return scalars
    }

    private static func mentionsHash(_ line: [Unicode.Scalar]) -> Bool {
        guard line.count >= 6 else { return false }
        return (0...(line.count - 6)).contains { matches(line, at: $0, "sha256") }
    }

    /// `word` (ASCII) at `at`, ignoring ASCII case only.
    private static func matches(_ text: [Unicode.Scalar], at: Int, _ word: StaticString) -> Bool {
        guard at + word.utf8CodeUnitCount <= text.count else { return false }
        return word.withUTF8Buffer { bytes in
            bytes.enumerated().allSatisfy { offset, byte in lowercased(text[at + offset]).value == UInt32(byte) }
        }
    }

    // MARK: - Characters

    /// JavaScript's `\s` (and what `trim` removes): the reference's notion of a space.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    private static func isTokenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        !isSpace(scalar) && !"`'\"(),;:".unicodeScalars.contains(scalar)
    }

    private static func isQuote(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "`" || scalar == "'" || scalar == "\""
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        isDigit(scalar) || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        isAlphanumeric(scalar) || scalar == "_"
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        isDigit(scalar) || (65...70).contains(scalar.value) || (97...102).contains(scalar.value)
    }

    private static func isBase64Character(_ scalar: Unicode.Scalar) -> Bool {
        isAlphanumeric(scalar) || "+/_=-".unicodeScalars.contains(scalar)
    }

    private static func lowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32) ?? scalar : scalar
    }

    private static func utf16Length(_ scalars: [Unicode.Scalar]) -> Int {
        scalars.reduce(0) { $0 + UTF16.width($1) }
    }

    // MARK: - Bytes

    /// The decoded size of base64 text, from its length alone (trailing padding aside).
    static func decodedLength(_ base64: [UInt8]) -> Int {
        var count = base64.count
        while count > 0, base64[count - 1] == UInt8(ascii: "=") { count -= 1 }
        return count * 3 / 4
    }

    /// Base64 with the standard alphabet, also taking `-` and `_` for `+` and `/` and missing `=` padding, as
    /// `^[A-Za-z0-9+/]*={0,2}$` after whitespace is removed. Padding comes last, two at most: checked here, since
    /// Foundation's decoder takes more. Another character, or a length no base64 text has, it refuses itself.
    static func decodeBase64(_ text: String) -> Data? {
        decodeBase64(Array(text.utf8))
    }

    static func decodeBase64(_ text: [UInt8]) -> Data? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count + 3)
        var padding = 0
        for byte in text {
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

    /// The bytes of a gzip file (RFC 1952: its header read here, including the optional extra field, name, comment and
    /// header checksum; the DEFLATE data inflated by Compression), or nil when it is not one or would unzip past
    /// `limit`, checked as the bytes come out. The declared hash checks the result, so the trailer's checksum is not
    /// read.
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

    private struct Stopped: Error {}

    private static func inflate(_ deflated: [UInt8], limit: Int) -> Data? {
        #if canImport(Compression)
        var output = Data()
        do {
            let filter = try OutputFilter(.decompress, using: .zlib) { (chunk: Data?) in
                guard let chunk else { return }
                // Past the cap, or no longer wanted: stop as the bytes come out.
                guard output.count + chunk.count <= limit, !Task.isCancelled else { throw Stopped() }
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

    /// A name that can be shown and saved as it reads: the control (C0 and C1), direction and zero-width characters
    /// are taken out first, then everything up to the last `/` or `\` and any leading dots; at most 128 bytes of
    /// UTF-8, cut between characters; `file.bin` if nothing is left.
    public static func sanitizedName(_ name: String) -> String {
        let visible: [Unicode.Scalar] = name.unicodeScalars.filter { !isHidden($0) }
        let base = visible.lastIndex(where: { $0 == "/" || $0 == "\\" }).map { visible[($0 + 1)...] } ?? visible[...]
        var kept = String.UnicodeScalarView()
        var bytes = 0
        for scalar in base.drop(while: { $0 == "." }) {
            bytes += UTF8.width(scalar)
            if bytes > 128 { break }
            kept.append(scalar)
        }
        return kept.isEmpty ? "file.bin" : String(kept)
    }

    /// C0 and C1 controls; the direction marks, embeddings, overrides and isolates; zero-width characters.
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF:
            return true
        default:
            return false
        }
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
