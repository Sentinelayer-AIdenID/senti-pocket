import Foundation
import PocketSyncClient
import PocketUI
import UIKit
import XCTest
@testable import SentiPocketApp

private final class FileRoomTransport: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let history: [RoomMessage]
    private var links: [String] = []

    init(history: [RoomMessage]) { self.history = history }

    func requestedLinks() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return links
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: beforeSequence == nil ? history : [])
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> {
        AsyncStream { _ in }
    }

    func attachmentDownload(sessionId: String, attachmentId: String) async throws -> RoomAttachmentDownload {
        lock.lock()
        links.append("\(sessionId)/\(attachmentId)")
        lock.unlock()
        return RoomAttachmentDownload(url: URL(string: "https://storage.example/\(attachmentId)?sig=1")!, expiresIn: 300)
    }
}

private final class ScriptedFetcher: AttachmentFileFetching, @unchecked Sendable {
    let image: Data
    init(image: Data) { self.image = image }

    func data(from url: URL, maximumBytes: Int) async throws -> Data {
        guard image.count <= maximumBytes else { throw AttachmentFetchError.tooLarge }
        return image
    }

    func file(from url: URL, filename: String) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(AttachmentFiles.safeFilename(filename))
        try image.write(to: file)
        return file
    }
}

@MainActor
final class RoomAttachmentsCoordinatorTests: XCTestCase {
    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    private static func png(width: Int, height: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        return renderer.pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private static func message(_ files: [RoomAttachment]) -> RoomMessage {
        RoomMessage(id: "m1", sequenceId: 1, kind: .message, authorId: "human-mrrcarter", authorName: "mrrCarter",
                    isHuman: true, text: "Look", timestamp: "2026-10-28T20:50:00Z", attachments: files)
    }

    private func coordinator(_ transport: FileRoomTransport, _ fetcher: ScriptedFetcher) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            attachmentFetcher: fetcher,
            onReauthenticationRequired: {}
        )
    }

    func test_an_image_in_view_gets_a_small_preview_and_other_files_do_not() async {
        let files = [
            RoomAttachment(attachmentId: "img-0001", filename: "screen.png", kind: .image, contentType: "image/png", sizeBytes: 50_000),
            RoomAttachment(attachmentId: "big-0001", filename: "huge.png", kind: .image, sizeBytes: 40_000_000),
            RoomAttachment(attachmentId: "doc-0001", filename: "spec.pdf", kind: .pdf, sizeBytes: 10_000)
        ]
        let transport = FileRoomTransport(history: [Self.message(files)])
        let room = coordinator(transport, ScriptedFetcher(image: Self.png(width: 2000, height: 1000)))
        room.resume()
        await waitUntil("loaded") { !room.state.isLoadingInitial }

        room.send(.attachmentAppeared(attachmentId: "img-0001"))
        room.send(.attachmentAppeared(attachmentId: "big-0001"))
        room.send(.attachmentAppeared(attachmentId: "doc-0001"))
        await waitUntil("preview") { room.state.attachmentPreviews["img-0001"] != nil }

        let preview = UIImage(data: room.state.attachmentPreviews["img-0001"] ?? Data())
        XCTAssertNotNil(preview)
        XCTAssertLessThanOrEqual(max(preview?.size.width ?? .infinity, preview?.size.height ?? .infinity), 640,
                                 "the preview is downsampled, never the full image")
        XCTAssertNil(room.state.attachmentPreviews["big-0001"], "an image over 10 MB is not previewed")
        XCTAssertNil(room.state.attachmentPreviews["doc-0001"])
        XCTAssertEqual(transport.requestedLinks(), ["room_1/img-0001"], "only the previewed image asked for a link")
        room.pause()
    }

    func test_opening_a_file_asks_for_a_fresh_link_every_time() async throws {
        let files = [RoomAttachment(attachmentId: "doc-0001", filename: "../../spec.pdf", kind: .pdf, sizeBytes: 10_000)]
        let transport = FileRoomTransport(history: [Self.message(files)])
        let room = coordinator(transport, ScriptedFetcher(image: Self.png(width: 10, height: 10)))
        room.resume()
        await waitUntil("loaded") { !room.state.isLoadingInitial }

        let first = try await room.prepareAttachment("doc-0001")
        _ = try await room.prepareAttachment("doc-0001")
        XCTAssertEqual(transport.requestedLinks(), ["room_1/doc-0001", "room_1/doc-0001"])
        XCTAssertFalse(first.lastPathComponent.contains("/"))
        XCTAssertFalse(first.lastPathComponent.hasPrefix("."), "a file name cannot climb out of its folder")
        do {
            _ = try await room.prepareAttachment("not-in-this-room")
            XCTFail("an attachment the room does not show cannot be opened")
        } catch {}
        room.pause()
    }
}
