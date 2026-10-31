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
                let thread: Int64
                let body: String
            }
            struct Expect: Decodable, Equatable {
                let status: String
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
        testCase.posts.enumerated().map { RoomFilePost(thread: $0.element.thread, id: "\(testCase.id)-\($0.offset)",
                                                       body: $0.element.body) }
    }

    /// As the reference checks them: a verified file by its status, name, size and the hash of its bytes; any other
    /// outcome by its status line and name.
    private func outcome(_ file: RoomBase64File) -> Vectors.Case.Expect {
        guard file.isVerified, let data = file.data else {
            return .init(status: file.status.line, name: file.name, bytes: nil, sha256: nil)
        }
        return .init(status: "verified", name: file.name, bytes: data.count, sha256: RoomBase64Files.sha256Hex(data))
    }

    func test_every_vector_gives_its_expected_outcome() throws {
        let all = try vectors()
        XCTAssertEqual(all.spec, "room-base64-files/1")
        XCTAssertEqual(all.cases.count, 13)
        for testCase in all.cases {
            XCTAssertEqual(RoomBase64Files.reassemble(posts(testCase)).map(outcome), testCase.expect, testCase.id)
        }
    }

    /// Only the bodies, their threads and the part indexes count: any order of the same posts gives the same files.
    func test_the_outcome_never_depends_on_the_order_of_the_posts() throws {
        for testCase in try vectors().cases {
            let given = RoomBase64Files.reassemble(posts(testCase))
            let reversed = RoomBase64Files.reassemble(Array(posts(testCase).reversed()))
            XCTAssertEqual(given.map(outcome), reversed.map(outcome), testCase.id)
            XCTAssertEqual(given.map(\.data), reversed.map(\.data), testCase.id)
        }
    }

    func test_the_parts_of_a_file_are_named_for_folding() throws {
        let missing = try XCTUnwrap(try vectors().cases.first { $0.id == "missing-part" })
        let file = try XCTUnwrap(RoomBase64Files.reassemble(posts(missing)).first)
        XCTAssertEqual(file.partPostIds, ["missing-part-0", "missing-part-1"])
        XCTAssertEqual(file.partsFound, 2)
        XCTAssertEqual(file.partsTotal, 3)
        XCTAssertNil(file.data, "no file without every part")
    }

    func test_a_hash_mismatch_shows_what_the_bytes_hash_to() throws {
        let corrupted = try XCTUnwrap(try vectors().cases.first { $0.id == "corrupted-part" })
        let file = try XCTUnwrap(RoomBase64Files.reassemble(posts(corrupted)).first)
        guard case .hashMismatch(let decoded, let gunzipped) = file.status else {
            return XCTFail("\(file.status)")
        }
        XCTAssertEqual(decoded.count, 64)
        XCTAssertNotEqual(decoded, file.declaredSHA256)
        XCTAssertNil(gunzipped, "not gzip")
        XCTAssertNil(file.data)
    }

    func test_names_are_made_safe() {
        let bell = String(Character(Unicode.Scalar(7)))
        XCTAssertEqual(RoomBase64Files.sanitizedName("../../etc/fixture.zip"), "fixture.zip")
        XCTAssertEqual(RoomBase64Files.sanitizedName("C:\\notes\\..hidden.txt"), "hidden.txt")
        XCTAssertEqual(RoomBase64Files.sanitizedName("a" + bell + "b.csv"), "ab.csv")
        XCTAssertEqual(RoomBase64Files.sanitizedName("folder/"), "file.bin")
        XCTAssertEqual(RoomBase64Files.sanitizedName("..."), "file.bin")
        XCTAssertEqual(RoomBase64Files.sanitizedName(String(repeating: "n", count: 200) + ".md").count, 128)
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
    }

    // MARK: - Unzipping

    /// RFC 1952 around raw DEFLATE made by Compression; the trailer is zeros, which the hash check makes unneeded.
    private func gzip(_ data: Data) throws -> Data {
        var deflated = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { (chunk: Data?) in
            if let chunk { deflated.append(chunk) }
        }
        try filter.write(data)
        try filter.finalize()
        return Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255]) + deflated + Data(count: 8)
    }

    func test_unzipping_stops_at_the_cap_as_the_bytes_come_out() throws {
        let zeros = Data(count: 4_096)
        let packed = try gzip(zeros)
        XCTAssertEqual(RoomBase64Files.gunzip(packed, limit: 4_096), zeros)
        XCTAssertNil(RoomBase64Files.gunzip(packed, limit: 1_024), "past the cap")
        XCTAssertNil(RoomBase64Files.gunzip(Data([0x1f, 0x8b, 7]) + Data(count: 20), limit: 4_096), "not DEFLATE")
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
        let file = try XCTUnwrap(RoomBase64Files.reassemble([RoomFilePost(thread: 1, id: "p1", body: body)]).first)
        XCTAssertEqual(file.status.line, "hash mismatch")
        XCTAssertNil(file.data)
    }
}
