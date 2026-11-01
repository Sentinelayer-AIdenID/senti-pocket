import Compression
import Foundation
import XCTest
@testable import PocketSyncClient

/// Files sent as base64 parts. `Fixtures/room-base64-files.json` holds synthetic posts whose outcomes are known by
/// construction (made by encoding known bytes, not by running a parser), so every case here is checked against bytes
/// and hashes that existed before any parser ran.
final class RoomBase64FilesTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Case: Decodable {
            struct Post: Decodable {
                let thread: Int64?
                let author: String
                let body: String
            }
            struct Expect: Decodable, Equatable {
                let status: String
                let author: String
                let name: String
                let bytes: Int?
                let sha256: String?
            }
            let id: String
            let posts: [Post]
            let expect: [Expect]
        }
        let spec: String
        let cases: [Case]
    }

    private func vectors() throws -> Vectors {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "room-base64-files", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private func posts(_ testCase: Vectors.Case) -> [RoomFilePost] {
        testCase.posts.enumerated().map {
            RoomFilePost(thread: $0.element.thread, author: $0.element.author, id: "\(testCase.id)-\($0.offset)",
                         body: $0.element.body)
        }
    }

    /// As the reference checks them: a verified file by its status, author, name, size and the hash of its bytes; any
    /// other outcome by its status line, author and name.
    private func outcome(_ file: RoomBase64File) -> Vectors.Case.Expect {
        guard file.isVerified, let data = file.data else {
            return .init(status: file.status.line, author: file.author, name: file.name, bytes: nil, sha256: nil)
        }
        return .init(status: "verified", author: file.author, name: file.name, bytes: data.count,
                     sha256: RoomBase64Files.sha256Hex(data))
    }

    private func vector(_ id: String) throws -> Vectors.Case {
        try XCTUnwrap(try vectors().cases.first { $0.id == id }, id)
    }

    /// `count` bytes that are no text and no gzip.
    private func bytes(_ count: Int, seed: Int = 7) -> Data {
        Data((0..<count).map { UInt8(($0 * 37 + seed) % 251) })
    }

    /// The file as JSON envelopes, its base64 split over `total` parts.
    private func envelopes(_ file: Data, name: String, total: Int, bytes: Int? = nil) -> [String] {
        let encoded = file.base64EncodedString()
        let size = (encoded.count + total - 1) / total
        return (0..<total).map { index in
            var object: [String: Any] = [
                "artifact": name, "sha256": RoomBase64Files.sha256Hex(file), "part": index + 1, "parts": total,
                "data": String(encoded.dropFirst(index * size).prefix(size))
            ]
            object["bytes"] = bytes ?? file.count
            let json = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: json, as: UTF8.self)
        }
    }

    private func post(_ body: String, by author: String = "ada-agent", in thread: Int64? = 7,
                      id: String? = nil) -> RoomFilePost {
        RoomFilePost(thread: thread, author: author, id: id ?? "\(author)-\(body.hashValue)", body: body)
    }

    private func text(_ scalars: UInt32...) -> String {
        String(String.UnicodeScalarView(scalars.compactMap(Unicode.Scalar.init)))
    }

    // MARK: - The vectors

    func test_every_vector_gives_its_expected_outcome() throws {
        let all = try vectors()
        XCTAssertEqual(all.spec, "room-base64-files/2")
        XCTAssertEqual(all.cases.count, 32)
        for testCase in all.cases {
            XCTAssertEqual(RoomBase64Files.reassemble(posts(testCase)).map(outcome), testCase.expect, testCase.id)
        }
    }

    /// Only the bodies, their authors, their threads and the part indexes count: the same posts in any order give the
    /// same files (reversed, and started from each post in turn).
    func test_the_outcome_never_depends_on_the_order_of_the_posts() throws {
        for testCase in try vectors().cases {
            let given = RoomBase64Files.reassemble(posts(testCase))
            var orders = [Array(posts(testCase).reversed())]
            for start in posts(testCase).indices {
                orders.append(Array(posts(testCase)[start...] + posts(testCase)[..<start]))
            }
            for order in orders {
                let other = RoomBase64Files.reassemble(order)
                XCTAssertEqual(given.map(outcome), other.map(outcome), testCase.id)
                XCTAssertEqual(given.map(\.data), other.map(\.data), testCase.id)
                XCTAssertEqual(given.map(\.partPostIds), other.map(\.partPostIds), testCase.id)
            }
        }
    }

    func test_the_parts_of_a_file_are_named_for_folding() throws {
        let file = try XCTUnwrap(RoomBase64Files.reassemble(posts(try vector("missing-part"))).first)
        XCTAssertEqual(file.partPostIds, ["missing-part-0", "missing-part-1"])
        XCTAssertEqual(file.partsFound, 2)
        XCTAssertEqual(file.partsTotal, 3)
        XCTAssertEqual(file.author, "alice-agent")
        XCTAssertNil(file.data, "no file without every part")
    }

    func test_a_hash_mismatch_shows_what_the_bytes_hash_to() throws {
        let file = try XCTUnwrap(RoomBase64Files.reassemble(posts(try vector("corrupted-part"))).first)
        guard case .hashMismatch(let decoded, let gunzipped) = file.status else {
            return XCTFail("\(file.status)")
        }
        XCTAssertEqual(decoded.count, 64)
        XCTAssertNotEqual(decoded, file.declaredSHA256)
        XCTAssertNil(gunzipped, "not gzip")
        XCTAssertNil(file.data)
    }

    // MARK: - Authors

    /// A file is only ever its own author's. Another member's same-name parts in the thread are their own file,
    /// credited to them, and their copy of a part never breaks or joins the first author's file.
    func test_another_members_parts_are_their_own_file_and_break_nothing() throws {
        let pack = bytes(3_000)
        let mine = envelopes(pack, name: "pack.zip", total: 3)
        let theirs = envelopes(bytes(1_500, seed: 3), name: "pack.zip", total: 2)
        // The second member also posts their own copy of the first author's part 2, under that author's hash.
        let forged = envelopes(bytes(3_000, seed: 11), name: "pack.zip", total: 3)[1]
            .replacingOccurrences(of: RoomBase64Files.sha256Hex(bytes(3_000, seed: 11)),
                                  with: RoomBase64Files.sha256Hex(pack))
        let posts = mine.enumerated().map { post($0.element, by: "ada-agent", id: "ada-\($0.offset)") }
            + theirs.enumerated().map { post($0.element, by: "lin-agent", id: "lin-\($0.offset)") }
            + [post(forged, by: "lin-agent", id: "lin-forged")]
        let files = RoomBase64Files.reassemble(posts)
        let ada = try XCTUnwrap(files.first { $0.author == "ada-agent" })
        XCTAssertEqual(ada.status, .verified)
        XCTAssertEqual(ada.data, pack)
        XCTAssertEqual(ada.partPostIds, ["ada-0", "ada-1", "ada-2"], "only the author's own posts fold under it")
        let lin = files.filter { $0.author == "lin-agent" }
        XCTAssertEqual(lin.map(\.status.line).sorted(), ["1 of 3 parts", "verified"])
        XCTAssertFalse(lin.contains { $0.partPostIds.contains { $0.hasPrefix("ada-") } })
        XCTAssertEqual(Set(files.map(\.id)).count, files.count, "each file has its own id")
    }

    /// A header part's hash comes only from a declaration by the same author in the same thread.
    func test_a_declaration_counts_only_from_the_parts_author_in_the_same_thread() throws {
        let notes = Data("first line\nsecond line\n".utf8)
        let hash = RoomBase64Files.sha256Hex(notes)
        let part = post("notes.txt part 1/1\n\(notes.base64EncodedString())", by: "ada-agent", id: "part")
        let declaration = "`notes.txt`: \(notes.count) bytes, SHA256 \(hash)"
        let byOther = post(declaration, by: "lin-agent", id: "other")
        let elsewhere = post(declaration, by: "ada-agent", in: 8, id: "elsewhere")
        XCTAssertEqual(RoomBase64Files.reassemble([byOther, part, elsewhere]).map(\.status), [.noDeclaredHash])
        let own = post(declaration, by: "ada-agent", id: "own")
        let file = try XCTUnwrap(RoomBase64Files.reassemble([byOther, part, own]).first)
        XCTAssertEqual(file.status, .verified)
        XCTAssertEqual(file.partPostIds, ["part"], "a declaration is not a part")
    }

    /// Top-level posts (not replies) group per author across the room's top level.
    func test_top_level_parts_group_per_author() throws {
        let one = envelopes(bytes(900), name: "a.bin", total: 3)
        let two = envelopes(bytes(600, seed: 5), name: "a.bin", total: 2)
        let posts = one.enumerated().map { post($0.element, by: "ada-agent", in: nil, id: "a\($0.offset)") }
            + two.enumerated().map { post($0.element, by: "lin-agent", in: nil, id: "l\($0.offset)") }
        let files = RoomBase64Files.reassemble(posts)
        XCTAssertEqual(files.map(\.status), [.verified, .verified])
        XCTAssertEqual(files.map(\.author), ["ada-agent", "lin-agent"])
        XCTAssertEqual(files.map(\.thread), [nil, nil])
    }

    // MARK: - Order

    /// Differing copies of more than one part report the lowest such index, in every order.
    func test_conflicting_copies_report_the_lowest_index_in_any_order() {
        let file = bytes(1_200)
        let good = envelopes(file, name: "c.bin", total: 4)
        let bad = envelopes(bytes(1_200, seed: 9), name: "c.bin", total: 4)
            .map { $0.replacingOccurrences(of: RoomBase64Files.sha256Hex(bytes(1_200, seed: 9)),
                                           with: RoomBase64Files.sha256Hex(file)) }
        let posts = (good + [bad[3], bad[1]]).enumerated().map { post($0.element, id: "p\($0.offset)") }
        for order in [posts, Array(posts.reversed()), Array(posts[2...] + posts[..<2])] {
            XCTAssertEqual(RoomBase64Files.reassemble(order).first?.status, .conflictingCopies(part: 2))
        }
    }

    // MARK: - Parsing

    /// A part's index is between 1 and its total, in a header or an envelope; otherwise the post is no part at all.
    func test_a_part_numbered_outside_its_total_is_not_a_part() {
        let data = "SGVsbG8h"
        let envelope = #"{"artifact":"x.txt","sha256":"\#(String(repeating: "a", count: 64))","part":3,"parts":2,"#
            + #""data":"\#(data)"}"#
        for body in ["x.txt part 3/2\n\(data)", "x.txt part 0/2\n\(data)", envelope] {
            XCTAssertFalse(RoomBase64Files.mayBePart(body), body)
            XCTAssertEqual(RoomBase64Files.reassemble([post(body)]), [], body)
        }
        XCTAssertTrue(RoomBase64Files.mayBePart("x.txt part 2/2\n\(data)"))
    }

    /// Prose after a header line is an ordinary message, shown as it is: a part is a header and then base64 only.
    func test_prose_after_a_header_is_not_a_part() {
        XCTAssertFalse(RoomBase64Files.mayBePart("Review part 1/2 (see the notes below)\nThis is prose, not data."))
        XCTAssertFalse(RoomBase64Files.mayBePart("notes.txt part 1/2\nSGk"), "too short to be data")
        XCTAssertFalse(RoomBase64Files.mayBePart("notes.txt part 1/2"), "nothing after the header")
        XCTAssertFalse(RoomBase64Files.mayBePart("notes.txt part 1/1234567\nSGVsbG8h"), "seven digits")
        XCTAssertFalse(RoomBase64Files.mayBePart("a/b.txt part 1/2\nSGVsbG8h"), "a path is no name")
        XCTAssertTrue(RoomBase64Files.mayBePart("notes.txt PART 1/2\n  SGVs\n  bG8h\n"))
        let hash = String(repeating: "a", count: 64)
        let envelope = #"{"artifact":"x.txt","sha256":"\#(hash)","part":1,"parts":1,"data":"SGk*"}"#
        XCTAssertFalse(RoomBase64Files.mayBePart(envelope), "an envelope's data is base64 only")
    }

    /// Header lines that end in CRLF, or a lone CR, are header lines.
    func test_a_header_line_may_end_in_crlf() throws {
        let text = Data("Hi".utf8)
        for breakText in ["\r\n", "\r"] {
            let body = "notes.txt part 1/1 (2 bytes, SHA256 \(RoomBase64Files.sha256Hex(text)))\(breakText)SGk="
            XCTAssertTrue(RoomBase64Files.mayBePart(body))
            XCTAssertEqual(RoomBase64Files.reassemble([post(body)]).first?.data, text)
        }
    }

    /// A header may declare its hash, and its size, in a parenthetical on its own line: then no declaration is
    /// needed. A parenthetical without a hash changes nothing.
    func test_a_header_can_declare_its_hash_inline() throws {
        let text = Data((1...40).map { "line \($0)" }.joined(separator: "\n").utf8)
        let hash = RoomBase64Files.sha256Hex(text)
        let encoded = text.base64EncodedString()
        let halves = [String(encoded.prefix(encoded.count / 2)), String(encoded.dropFirst(encoded.count / 2))]
        func posts(_ meta: String) -> [RoomFilePost] {
            halves.enumerated().map { index, data in
                RoomFilePost(thread: 7, author: "ada-agent", id: "p\(index)",
                             body: "notes.txt part \(index + 1)/2\(meta)\n\(data)")
            }
        }
        let inline = " (\(text.count) bytes, SHA256 \(hash.uppercased()), base64)"
        let verified = try XCTUnwrap(RoomBase64Files.reassemble(posts(inline)).first)
        XCTAssertEqual(verified.status, .verified)
        XCTAssertEqual(verified.declaredSHA256, hash)
        XCTAssertEqual(verified.data, text)
        XCTAssertTrue(RoomBase64Files.mayBePart(posts(inline)[0].body))

        let wrongSize = " (\(text.count + 1) bytes, sha256: \(hash))"
        XCTAssertEqual(RoomBase64Files.reassemble(posts(wrongSize)).first?.status, .sizeMismatch,
                       "the size is declared")
        XCTAssertEqual(RoomBase64Files.reassemble(posts(" (base64)")).first?.status, .noDeclaredHash,
                       "no hash in the parenthetical: a declaration is still needed")
    }

    /// Each part keeps the hash its own header declares: a corrected file posted again under the same name in the
    /// same thread is a second file, not conflicting copies of the first (the reference gives the same two files).
    func test_each_part_keeps_the_hash_its_own_header_declares() {
        func parts(_ file: Data) -> [String] {
            let encoded = file.base64EncodedString()
            let hash = RoomBase64Files.sha256Hex(file)
            return [String(encoded.prefix(encoded.count / 2)), String(encoded.dropFirst(encoded.count / 2))]
                .enumerated().map { index, data in
                    "notes.txt part \(index + 1)/2 (\(file.count) bytes, SHA256 \(hash))\n\(data)"
                }
        }
        let first = Data(String(repeating: "first version\n", count: 20).utf8)
        let second = Data(String(repeating: "second version, corrected\n", count: 20).utf8)
        let posts = (parts(first) + parts(second)).enumerated().map {
            RoomFilePost(thread: 9, author: "ada-agent", id: "p\($0.offset)", body: $0.element)
        }
        let files = RoomBase64Files.reassemble(posts)
        XCTAssertEqual(files.map(\.status), [.verified, .verified])
        XCTAssertEqual(Set(files.compactMap(\.data)), [first, second])
    }

    // MARK: - Declarations

    /// A declaration names the file at a name boundary: `data.csv` is not declared by a line about `metadata.csv`,
    /// and is by one that quotes or brackets it.
    func test_a_declaration_names_the_file_at_a_name_boundary() {
        let data = Data("a,b\n1,2\n".utf8)
        let hash = RoomBase64Files.sha256Hex(data)
        let part = post("data.csv part 1/1\n\(data.base64EncodedString())", id: "part")
        for (line, declares) in [("`metadata.csv`: SHA256 \(hash)", false), ("mydata.csv sha256 \(hash)", false),
                                 ("data.csvx sha256 \(hash)", false), ("`diff.csv` sha256 \(hash)", false),
                                 ("data.csv sha256 \(hash)0", false), ("data.csv sha256 \(hash)", true),
                                 ("(data.csv) sha256=\(hash)", true), ("Files: [data.csv]: sha256 `\(hash)`", true)] {
            let status = RoomBase64Files.reassemble([post(line, id: "line"), part]).first?.status
            XCTAssertEqual(status, declares ? .verified : .noDeclaredHash, line)
        }
    }

    /// A line may declare several files: each takes the hash and size between its name and the next file named, so
    /// a file with no size of its own doesn't take the next one's, and one with no hash of its own has none.
    func test_one_line_can_declare_several_files() throws {
        let files = [("a.txt", Data("alpha\n".utf8)), ("b.txt", Data("bravo!\n".utf8)), ("c.txt", Data("c\n".utf8))]
        let line = "Files: " + files.enumerated().map { index, file in
            let size = index == 0 ? "" : "\(file.1.count) bytes, "
            return "`\(file.0)` \(size)SHA256 \(RoomBase64Files.sha256Hex(file.1))"
        }.joined(separator: "; ")
        let parts = files.map { post("\($0.0) part 1/1\n\($0.1.base64EncodedString())", id: $0.0) }
        let found = RoomBase64Files.reassemble([post(line, id: "line")] + parts)
        XCTAssertEqual(found.map(\.status), [.verified, .verified, .verified])
        XCTAssertEqual(found.compactMap(\.data), files.map(\.1))

        let echo = Data("echo\n".utf8)
        let both = "`d.txt`, `e.txt` sha256 \(RoomBase64Files.sha256Hex(echo))"
        let declared = RoomBase64Files.reassemble([post(both, id: "both"), post("d.txt part 1/1\nZGVsdGEK", id: "d"),
                                                   post("e.txt part 1/1\n\(echo.base64EncodedString())", id: "e")])
        XCTAssertEqual(declared.map(\.status), [.noDeclaredHash, .verified], "d.txt declares no hash of its own")
    }

    /// The same author declaring two hashes for one name, with no hash on the part: "ambiguous declarations", in
    /// either order, never the first or the last. Two sizes for one file: "conflicting sizes", in either order.
    func test_conflicting_declarations_and_sizes_are_never_resolved_by_order() {
        let hi = Data("Hi".utf8)
        let lines = ["`notes.txt`: 2 bytes, SHA256 \(RoomBase64Files.sha256Hex(hi))",
                     "`notes.txt`: 3 bytes, SHA256 \(RoomBase64Files.sha256Hex(Data("Hi!".utf8)))"]
        let part = post("notes.txt part 1/1\nSGk=", id: "part")
        for order in [lines, Array(lines.reversed())] {
            let posts = order.enumerated().map { post($0.element, id: "d\($0.offset)") } + [part]
            XCTAssertEqual(RoomBase64Files.reassemble(posts).first?.status, .ambiguousDeclarations)
        }
        let sizes = [envelopes(hi, name: "notes.txt", total: 1, bytes: 999)[0],
                     envelopes(hi, name: "notes.txt", total: 1, bytes: 2)[0]]
        for order in [sizes, Array(sizes.reversed())] {
            let posts = order.enumerated().map { post($0.element, id: "s\($0.offset)") }
            XCTAssertEqual(RoomBase64Files.reassemble(posts).first?.status, .conflictingSizes)
        }
        let twice = ["`notes.txt` 2 bytes, SHA256 \(RoomBase64Files.sha256Hex(hi))",
                     "notes.txt (9 bytes) sha256 \(RoomBase64Files.sha256Hex(hi))"]
        let declared = twice.enumerated().map { post($0.element, id: "t\($0.offset)") } + [part]
        XCTAssertEqual(RoomBase64Files.reassemble(declared).first?.status, .conflictingSizes)
    }

    /// A line that names a file thousands of times is still read in linear time (the old pattern took seconds).
    func test_a_long_line_naming_a_file_many_times_is_read_quickly() throws {
        let data = Data("Hello!".utf8)
        let line = String(repeating: "x ", count: 30_000) + "sha256 " + RoomBase64Files.sha256Hex(data)
        let posts = [post(line, id: "line"), post("x part 1/1\n\(data.base64EncodedString())", id: "part")]
        let started = Date()
        let file = try XCTUnwrap(RoomBase64Files.reassemble(posts).first)
        XCTAssertEqual(file.status, .verified)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "linear, not quadratic")
    }

    // MARK: - Resources

    /// The cap is checked from the base64 length before anything is decoded: a file one byte over a lowered cap is
    /// too large, and one at it is a file.
    func test_the_size_cap_is_checked_before_decoding() throws {
        let file = bytes(3_004)
        let posts = envelopes(file, name: "pack.zip", total: 3).enumerated()
            .map { post($0.element, id: "p\($0.offset)") }
        XCTAssertEqual(RoomBase64Files.reassemble(posts, maximumBytes: 3_003).first?.status, .tooLarge)
        XCTAssertEqual(RoomBase64Files.reassemble(posts, maximumBytes: 3_004).first?.data, file)
    }

    /// Each author's files in a thread share one budget for what they decode and unzip; another author has their own.
    func test_each_author_has_their_own_budget_in_a_thread() throws {
        let first = bytes(1_000)
        let second = bytes(1_000, seed: 3)
        let theirs = bytes(1_000, seed: 5)
        let posts = [post(envelopes(first, name: "a.bin", total: 1)[0], by: "ada-agent", id: "a"),
                     post(envelopes(second, name: "b.bin", total: 1)[0], by: "ada-agent", id: "b"),
                     post(envelopes(theirs, name: "c.bin", total: 1)[0], by: "lin-agent", id: "c")]
        let files = RoomBase64Files.reassemble(posts, authorBudget: 1_500)
        XCTAssertEqual(files.map(\.name), ["a.bin", "b.bin", "c.bin"])
        XCTAssertEqual(files.map(\.status), [.verified, .tooLarge, .verified])
        XCTAssertEqual(RoomBase64Files.reassemble(posts, authorBudget: 2_000).map(\.status),
                       [.verified, .verified, .verified])
    }

    /// A rebuild that has been superseded (its task cancelled) stops and gives nothing back.
    func test_a_cancelled_rebuild_gives_nothing() async throws {
        let posts = envelopes(bytes(3_000), name: "pack.zip", total: 3).enumerated()
            .map { post($0.element, id: "p\($0.offset)") }
        let task = Task.detached { () -> [RoomBase64File] in
            while !Task.isCancelled { await Task.yield() }
            return RoomBase64Files.reassemble(posts)
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled, [])
        XCTAssertEqual(RoomBase64Files.reassemble(posts).map(\.status), [.verified])
    }

    // MARK: - Names

    func test_names_are_made_safe() {
        let bell = String(Character(Unicode.Scalar(7)))
        XCTAssertEqual(RoomBase64Files.sanitizedName("../../etc/fixture.zip"), "fixture.zip")
        XCTAssertEqual(RoomBase64Files.sanitizedName("C:\\notes\\..hidden.txt"), "hidden.txt")
        XCTAssertEqual(RoomBase64Files.sanitizedName("a" + bell + "b.csv"), "ab.csv")
        XCTAssertEqual(RoomBase64Files.sanitizedName("folder/"), "file.bin")
        XCTAssertEqual(RoomBase64Files.sanitizedName("..."), "file.bin")
        XCTAssertEqual(RoomBase64Files.sanitizedName(String(repeating: "n", count: 200) + ".md").count, 128)
    }

    /// Characters that change how a name reads without being seen are taken out before anything else: so a
    /// right-to-left override can't make "invoice[RLO]fdp.zip" read as a PDF, and a zero-width space can't keep a
    /// leading dot.
    func test_names_drop_control_direction_and_zero_width_characters() {
        XCTAssertEqual(RoomBase64Files.sanitizedName("invoice" + text(0x202E) + "fdp.zip"), "invoicefdp.zip")
        XCTAssertEqual(RoomBase64Files.sanitizedName(text(0x200B) + ".hidden.txt"), "hidden.txt")
        XCTAssertEqual(RoomBase64Files.sanitizedName("rep" + text(0x85) + "ort" + text(0x9F) + ".txt"), "report.txt")
        for hidden: UInt32 in [0x00, 0x1F, 0x7F, 0x80, 0x9F, 0x061C, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A,
                               0x202B, 0x202C, 0x202D, 0x202E, 0x2060, 0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF] {
            XCTAssertEqual(RoomBase64Files.sanitizedName("a" + text(hidden) + "b.txt"), "ab.txt",
                           String(hidden, radix: 16))
        }
        XCTAssertEqual(RoomBase64Files.sanitizedName("x/" + text(0x301) + "y.txt"), text(0x301) + "y.txt",
                       "a mark after a slash doesn't hide the slash")
        XCTAssertEqual(RoomBase64Files.sanitizedName("a" + text(0x00E9) + ".txt"), "a" + text(0x00E9) + ".txt")
    }

    /// At most 128 bytes of UTF-8, cut between characters: 42 three-byte characters (126 bytes), never a broken one.
    func test_names_are_capped_by_bytes_between_characters() {
        let kanji = text(0x6F22)
        let capped = RoomBase64Files.sanitizedName(String(repeating: kanji, count: 128) + ".txt")
        XCTAssertEqual(capped, String(repeating: kanji, count: 42))
        XCTAssertEqual(capped.utf8.count, 126)
        let emoji = text(0x1F600)
        XCTAssertEqual(RoomBase64Files.sanitizedName(String(repeating: emoji, count: 40)).utf8.count, 128,
                       "32 of 4 bytes")
        XCTAssertEqual(RoomBase64Files.sanitizedName("a" + String(repeating: emoji, count: 40)).utf8.count, 125)
    }

    func test_the_type_comes_from_the_extension_only() {
        XCTAssertEqual(RoomBase64Files.mimeType(forName: "pack.zip"), "application/zip")
        XCTAssertEqual(RoomBase64Files.mimeType(forName: "data.JSON"), "application/json")
        XCTAssertEqual(RoomBase64Files.mimeType(forName: "knowledge.jsonl"), "application/x-ndjson")
        XCTAssertEqual(RoomBase64Files.mimeType(forName: "notes.md"), "text/plain")
        XCTAssertEqual(RoomBase64Files.mimeType(forName: "notes.txt"), "text/plain")
        XCTAssertEqual(RoomBase64Files.mimeType(forName: "table.csv"), "text/csv")
        XCTAssertEqual(RoomBase64Files.mimeType(forName: "chart.png"), "image/png")
        XCTAssertEqual(RoomBase64Files.mimeType(forName: "page.html"), "application/octet-stream")
        XCTAssertEqual(RoomBase64Files.mimeType(forName: "zip"), "application/octet-stream", "no extension")
        XCTAssertTrue(RoomBase64Files.isPreviewable("knowledge.jsonl"))
        XCTAssertFalse(RoomBase64Files.isPreviewable("page.html"))
        XCTAssertFalse(RoomBase64Files.isPreviewable("image.svg"))
    }

    func test_base64_takes_the_url_safe_alphabet_and_missing_padding_and_nothing_else() {
        XCTAssertEqual(RoomBase64Files.decodeBase64("SGk"), Data("Hi".utf8))
        XCTAssertEqual(RoomBase64Files.decodeBase64("SGk="), Data("Hi".utf8))
        XCTAssertEqual(RoomBase64Files.decodeBase64("S G\nk"), Data("Hi".utf8), "whitespace is not data")
        XCTAssertEqual(RoomBase64Files.decodeBase64("-_8"), Data([0xfb, 0xff]))
        XCTAssertNil(RoomBase64Files.decodeBase64("SGk*"), "another character")
        XCTAssertNil(RoomBase64Files.decodeBase64("SG=k"), "data after the padding")
        XCTAssertNil(RoomBase64Files.decodeBase64("SGk==="), "three padding characters")
        XCTAssertNil(RoomBase64Files.decodeBase64("SGVsb"), "a length no base64 text has")
        XCTAssertEqual(RoomBase64Files.decodedLength(Array("SGVsbG8h".utf8)), 6)
        XCTAssertEqual(RoomBase64Files.decodedLength(Array("SGk=".utf8)), 2)
    }

    // MARK: - Unzipping

    /// Raw DEFLATE made by Compression.
    private func deflate(_ data: Data) throws -> Data {
        var deflated = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { (chunk: Data?) in
            if let chunk { deflated.append(chunk) }
        }
        try filter.write(data)
        try filter.finalize()
        return deflated
    }

    /// RFC 1952 around raw DEFLATE, with the header fields `flags` asks for; the trailer is zeros, which the hash check
    /// makes unneeded.
    private func gzip(_ data: Data, flags: UInt8 = 0) throws -> Data {
        var header = Data([0x1f, 0x8b, 8, flags, 0, 0, 0, 0, 0, 255])
        if flags & 0x04 != 0 { header += Data([5, 0]) + Data("extra".utf8) }
        if flags & 0x08 != 0 { header += Data("kb.jsonl".utf8) + Data([0]) }
        if flags & 0x10 != 0 { header += Data("a comment".utf8) + Data([0]) }
        if flags & 0x02 != 0 { header += Data([0x12, 0x34]) }
        return header + (try deflate(data)) + Data(count: 8)
    }

    func test_unzipping_stops_at_the_cap_as_the_bytes_come_out() throws {
        let zeros = Data(count: 4_096)
        let packed = try gzip(zeros)
        XCTAssertEqual(RoomBase64Files.gunzip(packed, limit: 4_096), zeros)
        XCTAssertNil(RoomBase64Files.gunzip(packed, limit: 1_024), "past the cap")
        XCTAssertNil(RoomBase64Files.gunzip(Data([0x1f, 0x8b, 7]) + Data(count: 20), limit: 4_096), "not DEFLATE")
    }

    /// The header's optional fields (extra field, name as `gzip -c` writes it, comment, header checksum), alone and
    /// together, are stepped over exactly.
    func test_gzip_headers_with_optional_fields_unzip() throws {
        let text = Data((1...50).map { "row \($0)" }.joined(separator: "\n").utf8)
        for flags: UInt8 in [0x02, 0x04, 0x08, 0x10, 0x0C, 0x1E] {
            XCTAssertEqual(RoomBase64Files.gunzip(try gzip(text, flags: flags), limit: 1_000_000), text,
                           "flags \(flags)")
        }
        let named = try gzip(text, flags: 0x08)
        let body = "kb.jsonl part 1/1 (\(text.count) bytes, SHA256 \(RoomBase64Files.sha256Hex(text)))\n"
            + named.base64EncodedString()
        XCTAssertEqual(RoomBase64Files.reassemble([post(body)]).first?.data, text)
    }

    /// A few kilobytes that unzip past 50 MiB are never a file: the unzipping stops at the cap.
    func test_a_post_that_unzips_past_fifty_megabytes_is_never_a_file() throws {
        let huge = Data(count: RoomBase64Files.maximumBytes + 1)
        let packed = try gzip(huge)
        XCTAssertLessThan(packed.count, 1_000_000)
        let body = try String(decoding: JSONSerialization.data(withJSONObject: [
            "artifact": "big.bin", "sha256": RoomBase64Files.sha256Hex(huge), "part": 1, "parts": 1,
            "data": packed.base64EncodedString()
        ]), as: UTF8.self)
        let file = try XCTUnwrap(RoomBase64Files.reassemble([post(body)]).first)
        XCTAssertEqual(file.status.line, "hash mismatch")
        XCTAssertNil(file.data)
    }
}
