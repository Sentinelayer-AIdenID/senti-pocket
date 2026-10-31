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
    /// Attachments that have an uploaded preview, and how long links last.
    var previewed: Set<String> = []
    var expiresIn = 300

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
        return RoomAttachmentDownload(
            url: URL(string: "https://storage.example/\(attachmentId)?sig=1")!,
            expiresIn: expiresIn,
            previewURL: previewed.contains(attachmentId) ? URL(string: "https://storage.example/\(attachmentId).pv?sig=1") : nil
        )
    }
}

private final class ScriptedFetcher: AttachmentFileFetching, @unchecked Sendable {
    let image: Data
    private let lock = NSLock()
    private var fetched: [String] = []
    init(image: Data) { self.image = image }

    func fetchedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return fetched
    }

    private func record(_ path: String) {
        lock.lock()
        fetched.append(path)
        lock.unlock()
    }

    func data(from url: URL, maximumBytes: Int) async throws -> Data {
        record(url.path)
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

    private func coordinator(_ transport: FileRoomTransport, _ fetcher: ScriptedFetcher,
                             store: any RoomMediaPreviewStoring = RoomMediaPreviewMemoryStore(),
                             now: @escaping @Sendable () -> Date = { Date() }) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            now: now,
            attachmentFetcher: fetcher,
            previewStore: store,
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
        let fetcher = ScriptedFetcher(image: Self.png(width: 2000, height: 1000))
        let room = coordinator(transport, fetcher)
        room.resume()
        await waitUntil("loaded") { !room.state.isLoadingInitial }

        room.send(.attachmentAppeared(attachmentId: "img-0001"))
        room.send(.attachmentAppeared(attachmentId: "big-0001"))
        room.send(.attachmentAppeared(attachmentId: "doc-0001"))
        await waitUntil("preview") { room.state.attachmentPreviews["img-0001"] != nil }
        await waitUntil("big image asked") { transport.requestedLinks().count == 2 }

        let preview = UIImage(data: room.state.attachmentPreviews["img-0001"] ?? Data())
        XCTAssertNotNil(preview)
        XCTAssertLessThanOrEqual(max(preview?.size.width ?? .infinity, preview?.size.height ?? .infinity), 640,
                                 "the preview is downsampled, never the full image")
        XCTAssertNil(room.state.attachmentPreviews["big-0001"], "an image over 10 MB with no uploaded preview is not previewed")
        XCTAssertNil(room.state.attachmentPreviews["doc-0001"])
        XCTAssertEqual(Set(transport.requestedLinks()), ["room_1/img-0001", "room_1/big-0001"],
                       "photos ask whether they have a preview; a PDF asks nothing")
        XCTAssertEqual(fetcher.fetchedPaths(), ["/img-0001"], "the photo over 10 MB is never downloaded")
        room.pause()
    }

    func test_a_photo_or_video_with_an_uploaded_preview_shows_it_and_keeps_it_on_the_phone() async {
        let files = [
            RoomAttachment(attachmentId: "pm_photo_0001", filename: "IMG_0042.jpg", kind: .image, sizeBytes: 40_000_000),
            RoomAttachment(attachmentId: "pm_video_0001", filename: "demo.mov", kind: .video, contentType: "video/quicktime",
                           sizeBytes: 90_000_000)
        ]
        let transport = FileRoomTransport(history: [Self.message(files)])
        transport.previewed = ["pm_photo_0001", "pm_video_0001"]
        let fetcher = ScriptedFetcher(image: Self.png(width: 640, height: 360))
        let store = RoomMediaPreviewMemoryStore()
        let room = coordinator(transport, fetcher, store: store)
        room.resume()
        await waitUntil("loaded") { !room.state.isLoadingInitial }
        room.send(.attachmentAppeared(attachmentId: "pm_photo_0001"))
        room.send(.attachmentAppeared(attachmentId: "pm_video_0001"))
        await waitUntil("previews") {
            room.state.attachmentPreviews["pm_photo_0001"] != nil && room.state.attachmentPreviews["pm_video_0001"] != nil
        }
        XCTAssertEqual(Set(fetcher.fetchedPaths()), ["/pm_photo_0001.pv", "/pm_video_0001.pv"],
                       "only the previews are downloaded, never the 40 MB photo or the video")
        await waitUntil("kept on disk") { store.data(for: "room_1/pm_video_0001") != nil }
        room.pause()

        // Opened again: the kept preview shows, and nothing is asked of the API or storage.
        let again = FileRoomTransport(history: [Self.message(files)])
        let quiet = ScriptedFetcher(image: Data())
        let reopened = coordinator(again, quiet, store: store)
        reopened.resume()
        await waitUntil("loaded again") { !reopened.state.isLoadingInitial }
        reopened.send(.attachmentAppeared(attachmentId: "pm_video_0001"))
        await waitUntil("kept preview") { reopened.state.attachmentPreviews["pm_video_0001"] != nil }
        XCTAssertTrue(again.requestedLinks().isEmpty)
        XCTAssertTrue(quiet.fetchedPaths().isEmpty)
        reopened.pause()
    }

    func test_an_upload_notice_steps_aside_when_its_files_show_in_a_message() async {
        let photo = RoomAttachment(attachmentId: "pm_photo_0001", filename: "IMG_0042.jpg", kind: .image, sizeBytes: 1_000)
        let plan = RoomAttachment(attachmentId: "plan-0001", filename: "plan.json", kind: .json)
        func event(_ id: String, _ seq: Int64, _ text: String, _ files: [RoomAttachment], _ type: String) -> RoomMessage {
            RoomMessage(id: id, sequenceId: seq, kind: .message, authorId: "human-mrrcarter", authorName: "mrrCarter",
                        isHuman: true, text: text, timestamp: "2026-10-31T13:3\(seq):00Z", attachments: files, eventType: type)
        }
        let transport = FileRoomTransport(history: [
            event("u1", 1, "Attachment uploaded: IMG_0042.jpg", [photo], "session_attachment"),
            event("u2", 2, "Attachment uploaded: plan.json", [plan], "session_attachment"),
            event("m3", 3, "Look", [photo], "session_message")
        ])
        let room = coordinator(transport, ScriptedFetcher(image: Data()))
        room.resume()
        await waitUntil("loaded") { !room.state.isLoadingInitial }
        let shown = room.state.rows.compactMap { row -> String? in
            if case .message(let message) = row { return message.id }
            return nil
        }
        XCTAssertEqual(shown, ["u2", "m3"], "the photo shows once, with its message; a file sent alone keeps its notice")
        room.pause()
    }

    func test_a_link_is_reused_until_five_minutes_before_it_expires() async throws {
        let files = [RoomAttachment(attachmentId: "pm_video_0001", filename: "demo.mov", kind: .video, sizeBytes: 9_000_000)]
        let transport = FileRoomTransport(history: [Self.message(files)])
        transport.expiresIn = 3_600
        let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
        let room = coordinator(transport, ScriptedFetcher(image: Data()), now: { clock.now })
        room.resume()
        await waitUntil("loaded") { !room.state.isLoadingInitial }

        _ = try await room.mediaLink("pm_video_0001")
        clock.advance(3_600 - 301)
        _ = try await room.mediaLink("pm_video_0001")
        XCTAssertEqual(transport.requestedLinks().count, 1, "reused while more than five minutes are left")
        clock.advance(2)
        _ = try await room.mediaLink("pm_video_0001")
        XCTAssertEqual(transport.requestedLinks().count, 2, "asked again inside the last five minutes")
        _ = try await room.mediaLink("pm_video_0001", asDownload: true)
        XCTAssertEqual(transport.requestedLinks().count, 3, "a download link is its own link")
        room.forgetLink("pm_video_0001")
        _ = try await room.mediaLink("pm_video_0001")
        XCTAssertEqual(transport.requestedLinks().count, 4, "a link storage refused is asked for again")
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

/// A clock the test moves.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}
