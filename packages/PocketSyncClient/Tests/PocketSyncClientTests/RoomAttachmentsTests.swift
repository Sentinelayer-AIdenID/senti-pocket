import Foundation
import XCTest
@testable import PocketSyncClient

final class RoomAttachmentsTests: XCTestCase {
    private func events(_ json: String) throws -> RoomEventPage {
        try JSONDecoder().decode(RoomEventPage.self, from: Data(json.utf8))
    }

    func test_a_message_lists_its_files_once_each_with_the_kind_its_content_type_says() throws {
        let page = try events("""
        {"events": [{"id": "e1", "sequenceId": 10, "event": "session_message", "agent": {"id": "human-mrrcarter"},
          "ts": "2026-10-28T20:50:00Z", "payload": {"message": "See the screenshot", "attachments": [
            {"attachmentId": "att_0123456789abcdef01234567", "filename": "screen.png", "kind": "image",
             "contentType": "image/png", "sizeBytes": 482000, "summaryStatus": "ready"},
            {"attachmentId": "att_0123456789abcdef01234567", "filename": "screen.png"},
            {"attachmentId": "spec-0001", "filename": "spec.pdf", "contentType": "application/pdf", "summaryStatus": "processing"},
            {"attachmentId": "notes-0001", "filename": "notes.md", "kind": "markdown", "summary": "  Two findings  "},
            {"attachmentId": "../escape", "filename": "x.json"},
            {"filename": "no-id.json"},
            {"attachmentId": "blob-0001", "filename": "data.bin", "kind": "something-new"}
          ]}}]}
        """)
        let files = try XCTUnwrap(page.messages.first?.attachments)
        XCTAssertEqual(files.map(\.attachmentId), ["att_0123456789abcdef01234567", "spec-0001", "notes-0001", "blob-0001"])
        XCTAssertEqual(files.map(\.kind), [.image, .pdf, .markdown, .other], "an unknown kind is a plain file")
        XCTAssertEqual(files[0].sizeBytes, 482000)
        XCTAssertEqual(files[1].summaryStatus, "processing")
        XCTAssertEqual(files[2].summary, "Two findings")
    }

    func test_an_upload_event_shows_like_the_web_with_its_file() throws {
        let page = try events("""
        {"events": [{"id": "e2", "sequenceId": 11, "event": "session_attachment", "agent": {"id": "human-mrrcarter"},
          "ts": "2026-10-28T20:51:00Z", "payload": {"message": "Attachment uploaded: plan.json", "attachmentId": "plan-0001",
            "attachment": {"attachmentId": "plan-0001", "filename": "plan.json", "kind": "json"},
            "attachments": [{"attachmentId": "plan-0001", "filename": "plan.json", "kind": "json"}]}}]}
        """)
        let message = try XCTUnwrap(page.messages.first)
        XCTAssertEqual(message.text, "Attachment uploaded: plan.json")
        XCTAssertEqual(message.attachments.map(\.attachmentId), ["plan-0001"], "the same file named twice shows once")
    }

    func test_only_an_https_download_link_is_accepted() throws {
        let good = try JSONDecoder().decode(RoomAttachmentDownload.self, from: Data("""
        {"ok": true, "download": {"url": "https://storage.example/obj?sig=1", "expiresIn": 300, "method": "GET"}}
        """.utf8))
        XCTAssertEqual(good.url.host, "storage.example")
        XCTAssertEqual(good.expiresIn, 300)
        XCTAssertThrowsError(try JSONDecoder().decode(RoomAttachmentDownload.self, from: Data("""
        {"download": {"url": "http://storage.example/obj", "expiresIn": 300}}
        """.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(RoomAttachmentDownload.self, from: Data("""
        {"download": {"url": "file:///etc/passwd"}}
        """.utf8)))
    }
}
