import Foundation
import XCTest
@testable import PocketSyncClient

final class RoomMediaTests: XCTestCase {
    func test_each_kind_takes_up_to_its_limit_and_not_a_byte_more() {
        XCTAssertEqual(try RoomMediaRules.check(filename: "shot.png", sizeBytes: 52_428_800).get().kind, .image)
        XCTAssertEqual(try RoomMediaRules.check(filename: "clip.mov", sizeBytes: 262_144_000).get().contentType, "video/quicktime")
        XCTAssertEqual(try RoomMediaRules.check(filename: "notes.md", sizeBytes: 262_144).get().kind, .markdown)

        guard case .failure(let photo) = RoomMediaRules.check(filename: "shot.png", sizeBytes: 52_428_801) else {
            return XCTFail("a photo over 50 MB is refused")
        }
        XCTAssertTrue(photo.message.contains("Photos can be up to 50 MB"), photo.message)
        guard case .failure(let video) = RoomMediaRules.check(filename: "clip.mp4", sizeBytes: 262_144_001) else {
            return XCTFail("a video over 250 MB is refused")
        }
        XCTAssertTrue(video.message.contains("Videos can be up to 250 MB"), video.message)
        guard case .failure(let file) = RoomMediaRules.check(filename: "dump.zip", sizeBytes: 300_000_000) else {
            return XCTFail("a file over 250 MB is refused")
        }
        XCTAssertTrue(file.message.contains("Files can be up to 250 MB"), file.message)
        XCTAssertEqual(RoomMediaRules.check(filename: "notes.json", sizeBytes: 262_145).failureMessage?
            .contains("256 KB"), true)
    }

    func test_only_the_types_the_room_takes_are_offered() {
        XCTAssertEqual(RoomMediaRules.check(filename: "setup.exe", sizeBytes: 10), .failure(.unsupported(filename: "setup.exe")))
        XCTAssertEqual(RoomMediaRules.check(filename: "IMG_0001.HEIC", sizeBytes: 10), .failure(.unsupported(filename: "IMG_0001.HEIC")),
                       "HEIC is turned into JPEG on the phone before it is checked")
        XCTAssertEqual(RoomMediaRules.check(filename: "empty.txt", sizeBytes: 0), .failure(.empty(filename: "empty.txt")))
        XCTAssertEqual(RoomMediaRules.type(forExtension: "JPG")?.contentType, "image/jpeg")
        XCTAssertEqual(RoomMediaRules.type(forExtension: "swift")?.contentType, "text/plain")
        XCTAssertEqual(RoomMediaRules.type(forExtension: "ts")?.contentType, "text/plain")
        XCTAssertEqual(RoomMediaRules.type(forExtension: "csv")?.kind, .file)
        XCTAssertEqual(RoomMediaRules.type(forExtension: "mp4")?.isVideo, true)
        XCTAssertTrue(RoomMediaRefusal.tooMany(limit: 5).message.contains("up to 5"))
    }

    func test_client_ids_and_names_fit_the_api() {
        XCTAssertTrue(RoomMediaRules.isValidClientId("pm_0123456789abcdef01234567"))
        XCTAssertTrue(RoomMediaRules.isValidClientId(RoomMediaRules.previewClientId(for: "pm_0123456789abcdef01234567")))
        XCTAssertFalse(RoomMediaRules.isValidClientId("short"))
        XCTAssertFalse(RoomMediaRules.isValidClientId("pm_a..b_cdefgh"))
        XCTAssertEqual(RoomMediaRules.safeFilename("../IMG 0042.HEIC", fileExtension: "jpg"), "-IMG 0042.jpg")
        XCTAssertEqual(RoomMediaRules.safeFilename("", fileExtension: "PNG"), "attachment.png")
        XCTAssertLessThanOrEqual(RoomMediaRules.safeFilename(String(repeating: "a", count: 400), fileExtension: "pdf").count, 160)
    }

    func test_init_body_names_its_parent_only_for_a_preview() {
        let original = RoomMediaInitRequest(filename: "a.jpg", contentType: "image/jpeg", sizeBytes: 10,
                                            sha256: String(repeating: "a", count: 64), clientAttachmentId: "pm_0123456789")
        XCTAssertNil(original.body["previewOf"])
        let preview = RoomMediaInitRequest(filename: "a.preview.jpg", contentType: "image/jpeg", sizeBytes: 5,
                                           sha256: String(repeating: "b", count: 64), clientAttachmentId: "pm_0123456789.pv",
                                           previewOf: "pm_0123456789")
        XCTAssertEqual(preview.body["previewOf"] as? String, "pm_0123456789")
        XCTAssertEqual(preview.body["clientAttachmentId"] as? String, "pm_0123456789.pv")
    }

    func test_init_answer_keeps_the_signed_headers_and_never_credentials() throws {
        let answer = try RoomMediaInitAnswer.decode(Data("""
        {"ok": true, "duplicate": false,
         "attachment": {"attachmentId": "pm_0123456789", "filename": "a.jpg", "kind": "image", "contentType": "image/jpeg",
                        "sizeBytes": 10, "status": "initiated"},
         "upload": {"url": "https://storage.example/put?sig=1", "method": "PUT", "expiresIn": 900,
                    "headers": {"content-type": "image/jpeg", "x-amz-checksum-sha256": "q83v", "Authorization": "Bearer x",
                                "content-length": "10"}}}
        """.utf8))
        XCTAssertEqual(answer.attachment.attachmentId, "pm_0123456789")
        XCTAssertEqual(answer.upload?.headers["x-amz-checksum-sha256"], "q83v")
        XCTAssertEqual(answer.upload?.headers["content-type"], "image/jpeg")
        XCTAssertNil(answer.upload?.headers["Authorization"])

        let stored = try RoomMediaInitAnswer.decode(Data("""
        {"ok": true, "duplicate": true, "attachment": {"attachmentId": "pm_0123456789", "filename": "a.jpg", "status": "uploaded"},
         "upload": null}
        """.utf8))
        XCTAssertNil(stored.upload, "bytes already stored need no PUT")
        XCTAssertTrue(stored.attachment.isUploaded)

        XCTAssertThrowsError(try RoomMediaInitAnswer.decode(Data("""
        {"attachment": {"attachmentId": "pm_0123456789", "filename": "a.jpg"}, "upload": {"url": "http://storage.example/put"}}
        """.utf8)), "only an https PUT")
    }

    func test_a_link_reads_its_preview_and_when_it_expires() throws {
        let link = try JSONDecoder().decode(RoomAttachmentDownload.self, from: Data("""
        {"ok": true, "download": {"url": "https://storage.example/obj?sig=1", "expiresIn": 3600,
          "expiresAt": "2026-10-31T15:00:00Z", "method": "GET",
          "previewUrl": "https://storage.example/pv?sig=2", "previewContentType": "image/jpeg"}}
        """.utf8))
        XCTAssertEqual(link.previewURL?.absoluteString, "https://storage.example/pv?sig=2")
        XCTAssertEqual(link.previewContentType, "image/jpeg")
        XCTAssertEqual(link.expiresAt, ISO8601DateFormatter().date(from: "2026-10-31T15:00:00Z"))

        let old = try JSONDecoder().decode(RoomAttachmentDownload.self, from: Data("""
        {"download": {"url": "https://storage.example/obj", "expiresIn": 300, "previewUrl": "http://storage.example/pv"}}
        """.utf8))
        XCTAssertNil(old.previewURL, "a preview that is not https is ignored")
        let received = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(old.expiry(receivedAt: received), received.addingTimeInterval(300))

        let flat = try JSONDecoder().decode(RoomAttachmentDownload.self, from: Data("""
        {"url": "https://storage.example/obj", "expiresAt": "2026-10-31T15:00:00.250Z"}
        """.utf8))
        XCTAssertNotNil(flat.expiresAt)
    }
}

private extension Result where Failure == RoomMediaRefusal {
    var failureMessage: String? {
        if case .failure(let refusal) = self { return refusal.message }
        return nil
    }
}
