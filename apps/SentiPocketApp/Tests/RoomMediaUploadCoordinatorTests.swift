import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// The API and storage, scripted: records every call, can hold a PUT open, and can fail a PUT or the message.
private final class FakeUploader: RoomMediaUploading, @unchecked Sendable {
    private let lock = NSLock()
    private var _inits: [RoomMediaInitRequest] = []
    private var _puts: [(file: URL, url: URL)] = []
    private var _completes: [String] = []
    private var _posts: [(text: String, ids: [String], clientId: String)] = []
    private var _cancelledPuts = 0
    private var _released = false
    private var _deletes: [String] = []
    /// Init answers with this error (a sign-in that expired, a full storage).
    var initError: Error?
    /// The API links previews (`previewOf` echoed); an older API would not.
    var linksPreviews = true
    /// Original PUTs hold at half way until `release()`.
    var holdsPuts = false
    /// The message's POST holds until `release()` (the room can show it first).
    var holdsPosts = false
    var failingPuts = 0
    var failingPosts = 0

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var inits: [RoomMediaInitRequest] { locked { _inits } }
    var puts: [(file: URL, url: URL)] { locked { _puts } }
    var completes: [String] { locked { _completes } }
    var posts: [(text: String, ids: [String], clientId: String)] { locked { _posts } }
    var cancelledPuts: Int { locked { _cancelledPuts } }
    var deletes: [String] { locked { _deletes } }
    func release() { locked { _released = true } }

    func initUpload(sessionId: String, request: RoomMediaInitRequest) async throws -> RoomMediaInitAnswer {
        locked { _inits.append(request) }
        if let initError { throw initError }
        return RoomMediaInitAnswer(
            attachment: RoomMediaAttachment(attachmentId: request.clientAttachmentId, filename: request.filename,
                                            contentType: request.contentType, sizeBytes: request.sizeBytes,
                                            sha256: request.sha256, status: "initiated",
                                            previewOf: linksPreviews ? request.previewOf : nil),
            upload: RoomMediaUploadTarget(url: URL(string: "https://storage.example/\(request.clientAttachmentId)")!,
                                          headers: ["content-type": request.contentType])
        )
    }

    func put(file: URL, to target: RoomMediaUploadTarget, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        locked { _puts.append((file, target.url)) }
        let isPreview = target.url.lastPathComponent.hasSuffix(".pv")
        let total = Int64(1_000)
        progress(total / 2, total)
        if holdsPuts, !isPreview {
            while !locked({ _released }) {
                if Task.isCancelled {
                    locked { _cancelledPuts += 1 }
                    throw CancellationError()
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let fails = locked { () -> Bool in
            guard !isPreview, failingPuts > 0 else { return false }
            failingPuts -= 1
            return true
        }
        if fails { throw RoomMediaUploadError.network }
        progress(total, total)
    }

    func deleteUpload(sessionId: String, attachmentId: String) async {
        locked { _deletes.append(attachmentId) }
    }

    func completeUpload(sessionId: String, attachmentId: String) async throws -> RoomMediaAttachment {
        locked { _completes.append(attachmentId) }
        return RoomMediaAttachment(attachmentId: attachmentId, filename: "\(attachmentId).bin", status: "uploaded")
    }

    func postMessage(sessionId: String, text: String, attachments: [RoomMediaAttachment], clientId: String) async throws {
        while holdsPosts, !locked({ _released }) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let fails = locked { () -> Bool in
            _posts.append((text, attachments.map(\.attachmentId), clientId))
            guard failingPosts > 0 else { return false }
            failingPosts -= 1
            return true
        }
        if fails { throw RoomSendError.retryable(retryAfterSeconds: nil) }
    }
}

/// Preparation without ImageIO: the file as it is, a fixed hash, and a three-byte "preview".
private struct FakePreparer: RoomMediaPreparing {
    func thumbnail(for source: RoomMediaSource) async -> Data? {
        RoomMediaFiles.kind(of: source.file) == .file ? nil : Data([0xFF, 0xD8, 0xFF])
    }

    func prepare(_ source: RoomMediaSource, thumbnail: Data?) async throws -> RoomPreparedMedia {
        if source.filename.hasPrefix("broken") { throw RoomMediaPreparationError.unreadable }
        let size = try RoomMediaFiles.size(of: source.file)
        let type = try RoomMediaRules.check(filename: source.filename, sizeBytes: size).get()
        var preview: RoomPreparedPreview?
        if let thumbnail {
            let file = source.folder.appendingPathComponent("preview.jpg")
            try thumbnail.write(to: file)
            preview = RoomPreparedPreview(file: file, filename: "preview.jpg", sizeBytes: Int64(thumbnail.count),
                                          sha256: String(repeating: "b", count: 64))
        }
        return RoomPreparedMedia(file: source.file, filename: source.filename, type: type, sizeBytes: size,
                                 sha256: String(repeating: "a", count: 64), preview: preview)
    }
}

private struct NoKeepAlive: RoomMediaKeepingAlive {
    func begin(onExpire: @escaping @MainActor () -> Void) -> Int? { 1 }
    func end(_ token: Int) {}
}

/// Background time on demand: counts what was asked for and ended, and lets the test run iOS's deadline.
private final class ScriptedKeepAlive: RoomMediaKeepingAlive {
    private(set) var begun: [Int] = []
    private(set) var ended: [Int] = []
    private var expirations: [Int: @MainActor () -> Void] = [:]

    func begin(onExpire: @escaping @MainActor () -> Void) -> Int? {
        let token = begun.count + 1
        begun.append(token)
        expirations[token] = onExpire
        return token
    }

    func end(_ token: Int) { ended.append(token) }

    /// iOS ends the grant at its deadline (and ends it itself).
    @MainActor
    func expire(_ token: Int) { expirations[token]?() }
}

@MainActor
final class RoomMediaUploadCoordinatorTests: XCTestCase {
    private var discarded: [String] = []
    private var counter = 0
    /// This test's own outbox, removed when it ends.
    private lazy var root: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("media-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }()

    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        // Generous: the Mac that runs these is shared, and a busy one schedules slowly.
        for _ in 0..<2_500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    /// A picked file in its own folder, `size` bytes long (sparse: nothing is written).
    private func source(_ name: String, size: Int64 = 1_000) throws -> RoomMediaSource {
        let folder = try RoomMediaFiles.newFolder(in: root)
        let file = folder.appendingPathComponent("original." + (name as NSString).pathExtension)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return RoomMediaSource(file: file, filename: name)
    }

    private func coordinator(_ uploader: FakeUploader?, keepAlive: any RoomMediaKeepingAlive = NoKeepAlive())
        -> RoomMediaUploadCoordinator {
        RoomMediaUploadCoordinator(
            sessionId: "room_1",
            uploader: uploader,
            preparer: FakePreparer(),
            keepAlive: keepAlive,
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            makeId: { [unowned self] in
                self.counter += 1
                return String(format: "pm_test_%06ld", self.counter)
            },
            discard: { [unowned self] source in
                self.discarded.append(source.filename)
                RoomMediaFiles.discard(source, root: self.root)
            },
            outboxRoot: root
        )
    }

    func test_files_over_the_limits_or_of_other_types_never_enter_the_tray() async throws {
        let media = coordinator(FakeUploader())
        media.add([try source("setup.exe"), try source("empty.txt", size: 0), try source("huge.png", size: 52_428_801),
                   try source("long.mov", size: 262_144_001)])
        XCTAssertTrue(media.board.tray.isEmpty)
        XCTAssertEqual(discarded, ["setup.exe", "empty.txt", "huge.png", "long.mov"], "refused files leave the phone's outbox")
        XCTAssertTrue(media.board.notice?.contains("can't be sent") == true, media.board.notice ?? "")
        XCTAssertTrue(media.board.notice?.contains("3 more not added") == true)

        media.add([try source("limit.png", size: 52_428_800)])
        XCTAssertEqual(media.board.tray.count, 1, "a photo of exactly 50 MB is taken")
        media.add(try (1...5).map { try source("photo\($0).jpg") })
        XCTAssertEqual(media.board.tray.count, 5, "a message carries five files")
        XCTAssertTrue(media.board.notice?.contains("up to 5") == true, media.board.notice ?? "")
    }

    func test_progress_is_the_bytes_storage_has_taken() async throws {
        let uploader = FakeUploader()
        uploader.holdsPuts = true
        let media = coordinator(uploader)
        media.add([try source("IMG_0042.jpg")])
        let item = try XCTUnwrap(media.board.tray.first)
        await waitUntil("half way") { item.progress.sentBytes == 500 }
        XCTAssertEqual(item.progress.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(media.board.tray.first?.phase, .uploading)
        uploader.release()
        await waitUntil("uploaded") { media.board.tray.first?.phase == .uploaded }
        XCTAssertEqual(item.progress.fraction, 1)
        XCTAssertNotNil(media.board.tray.first?.thumbnail, "the picture shows at once")
    }

    func test_send_posts_one_message_naming_every_file_in_order() async throws {
        let uploader = FakeUploader()
        let media = coordinator(uploader)
        var seeded: [String] = []
        media.onPreviewReady = { id, _ in seeded.append(id) }
        media.add([try source("IMG_0001.jpg"), try source("spec.pdf")])
        media.perform(.send(text: "  Look at these  "))
        XCTAssertTrue(media.board.tray.isEmpty)
        XCTAssertEqual(media.board.outgoing.count, 1, "the message shows at once")
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await waitUntil("posted") { uploader.posts.count == 1 }
        XCTAssertEqual(uploader.posts.first?.text, "Look at these")
        XCTAssertEqual(uploader.posts.first?.ids, ["pm_test_000001", "pm_test_000002"])
        XCTAssertEqual(uploader.posts.first?.clientId, clientId)
        await waitUntil("sent") { media.board.outgoing.first?.status == .sent }
        XCTAssertEqual(seeded, ["pm_test_000001"], "the photo's own preview is handed to the room")

        media.echoed([clientId])
        XCTAssertTrue(media.board.outgoing.isEmpty, "the card goes once the room shows the message")
        XCTAssertEqual(discarded, ["IMG_0001.jpg", "spec.pdf"])

        media.add([try source("a.jpg"), try source("b.png")])
        media.perform(.send(text: ""))
        await waitUntil("posted again") { uploader.posts.count == 2 }
        XCTAssertEqual(uploader.posts.last?.text, "Shared 2 photos.")
    }

    func test_a_failed_upload_keeps_its_place_and_retries_with_the_same_ids() async throws {
        let uploader = FakeUploader()
        uploader.failingPuts = 1
        uploader.failingPosts = 1
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await waitUntil("failed") { media.board.outgoing.first?.isFailed == true }
        XCTAssertEqual(media.board.outgoing.first?.canRetry, true)
        XCTAssertEqual(media.board.outgoing.first?.items.first?.isFailed, true, "the file stays, marked")

        media.perform(.retry(clientId: clientId))
        await waitUntil("post failed") { uploader.posts.count == 1 && media.board.outgoing.first?.isFailed == true }
        media.perform(.retry(clientId: clientId))
        await waitUntil("sent") { media.board.outgoing.first?.status == .sent }

        let originals = uploader.inits.filter { $0.previewOf == nil }.map(\.clientAttachmentId)
        XCTAssertEqual(originals, ["pm_test_000001", "pm_test_000001"], "the retry is the same upload")
        XCTAssertEqual(uploader.posts.map(\.clientId), [clientId, clientId], "the retry is the same message")
        XCTAssertEqual(media.board.outgoing.first?.id, clientId, "it kept its place")
    }

    func test_cancel_stops_the_upload_and_nothing_reaches_the_room() async throws {
        let uploader = FakeUploader()
        uploader.holdsPuts = true
        let media = coordinator(uploader)
        media.add([try source("clip.mov")])
        media.perform(.send(text: ""))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await waitUntil("uploading") { uploader.puts.contains { $0.url.lastPathComponent == "pm_test_000001" } }
        media.perform(.cancel(clientId: clientId))
        XCTAssertTrue(media.board.outgoing.isEmpty)
        await waitUntil("put cancelled") { uploader.cancelledPuts == 1 }
        uploader.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(uploader.posts.isEmpty)
        XCTAssertFalse(uploader.completes.contains("pm_test_000001"))
        XCTAssertEqual(discarded, ["clip.mov"])

        media.add([try source("draft.jpg")])
        let itemId = try XCTUnwrap(media.board.tray.first?.id)
        media.perform(.remove(itemId: itemId))
        XCTAssertTrue(media.board.tray.isEmpty, "taken out of the tray, its upload stops")
    }

    func test_a_message_the_room_shows_before_its_post_answers_goes_at_once() async throws {
        let uploader = FakeUploader()
        uploader.holdsPosts = true
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await waitUntil("posting") { media.board.outgoing.first?.status == .posting }
        media.echoed([clientId])
        XCTAssertTrue(media.board.outgoing.isEmpty, "shown once, by the room")
        uploader.release()
        await waitUntil("posted") { uploader.posts.count == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(media.board.outgoing.isEmpty, "the post's answer never brings the card back")
    }

    func test_a_picture_the_phone_cannot_read_leaves_the_tray_with_why() async throws {
        let media = coordinator(FakeUploader())
        media.add([try source("broken.jpg"), try source("broken.svg")])
        await waitUntil("refused") { media.board.tray.isEmpty }
        XCTAssertNotNil(media.board.notice)
        XCTAssertEqual(Set(discarded), ["broken.jpg", "broken.svg"])
    }

    func test_a_file_taken_out_or_a_message_cancelled_is_taken_back_on_the_server() async throws {
        let uploader = FakeUploader()
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        await waitUntil("uploaded") { media.board.tray.first?.phase == .uploaded }
        media.perform(.remove(itemId: "pm_test_000001"))
        await waitUntil("deleted") { uploader.deletes.count == 2 }
        XCTAssertEqual(uploader.deletes, ["pm_test_000001", "pm_test_000001.pv"], "the file and its preview")

        uploader.holdsPuts = true
        media.add([try source("clip.mov")])
        media.perform(.send(text: ""))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await waitUntil("initiated") { uploader.inits.contains { $0.clientAttachmentId == "pm_test_000002" } }
        media.perform(.cancel(clientId: clientId))
        await waitUntil("cancelled upload deleted") { uploader.deletes.contains("pm_test_000002") }

        // Taken out before its upload began: the server never heard of it, so nothing is deleted.
        let untouched = FakeUploader()
        let other = coordinator(untouched)
        other.add([try source("notes.txt")])
        let id = try XCTUnwrap(other.board.tray.first?.id)
        other.perform(.remove(itemId: id))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(untouched.inits.isEmpty)
        XCTAssertTrue(untouched.deletes.isEmpty, "nothing is deleted for a file the server never heard of")
    }

    func test_ids_and_messages_survive_the_app_closing() async throws {
        let uploader = FakeUploader()
        uploader.failingPuts = 1
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await waitUntil("failed") { media.board.outgoing.first?.isFailed == true }

        // The app closes; at the next launch the room opens again.
        let again = FakeUploader()
        let reopened = coordinator(again)
        XCTAssertEqual(reopened.board.outgoing.map(\.id), [clientId], "the message is back, with its client id")
        XCTAssertEqual(reopened.board.outgoing.first?.items.map(\.id), ["pm_test_000001"], "its file, with its id")
        XCTAssertEqual(reopened.board.outgoing.first?.text, "Hi")
        XCTAssertEqual(reopened.board.outgoing.first?.canRetry, true)
        XCTAssertNotNil(reopened.board.outgoing.first?.items.first?.thumbnail, "its preview shows again")

        reopened.perform(.retry(clientId: clientId))
        await waitUntil("posted") { again.posts.count == 1 }
        XCTAssertEqual(again.posts.first?.clientId, clientId, "the same message")
        XCTAssertEqual(again.posts.first?.ids, ["pm_test_000001"], "the same upload")
        XCTAssertTrue(again.inits.allSatisfy { $0.clientAttachmentId.hasPrefix("pm_test_000001") })
        XCTAssertEqual(again.completes.first, "pm_test_000001", "completing is tried first: the bytes may have landed")
    }

    func test_a_grant_iOS_ended_is_asked_for_again_and_never_ended_twice() async throws {
        let keepAlive = ScriptedKeepAlive()
        let uploader = FakeUploader()
        uploader.holdsPuts = true
        let media = coordinator(uploader, keepAlive: keepAlive)
        media.add([try source("clip.mov")])
        XCTAssertEqual(keepAlive.begun, [1])
        keepAlive.expire(1)
        media.add([try source("other.mov")])
        XCTAssertEqual(keepAlive.begun, [1, 2], "asked for again while uploads go on")
        uploader.release()
        await waitUntil("idle") { media.board.tray.allSatisfy { $0.phase == .uploaded } }
        XCTAssertEqual(keepAlive.ended, [2], "the grant iOS ended is never ended again")
    }

    func test_an_expired_sign_in_asks_for_it_again_and_the_file_waits() async throws {
        let uploader = FakeUploader()
        uploader.initError = RoomSendError.reauthenticationRequired
        let media = coordinator(uploader)
        var asked = 0
        media.onReauthenticationRequired = { asked += 1 }
        media.add([try source("IMG_0001.jpg")])
        await waitUntil("failed") { media.board.tray.first?.isFailed == true }
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(media.board.tray.first?.phase, .failed(reason: RoomSendError.reauthenticationRequired.userMessage,
                                                              canRetry: true))
    }

    func test_a_viewer_made_a_contributor_can_upload_without_relaunching() {
        let room = "room_promoted_" + UUID().uuidString
        let asViewer = RoomMediaUploadCoordinator.forRoom(room, uploader: nil) {
            RoomMediaUploadCoordinator(sessionId: room, uploader: nil, keepAlive: NoKeepAlive(), outboxRoot: root)
        }
        XCTAssertFalse(asViewer.canUpload)
        let promoted = RoomMediaUploadCoordinator.forRoom(room, uploader: FakeUploader()) {
            XCTFail("the room keeps its coordinator")
            return asViewer
        }
        XCTAssertTrue(promoted === asViewer)
        XCTAssertTrue(promoted.canUpload)
    }

    func test_a_storage_limit_says_whose_it_is() {
        func reason(_ status: Int, _ code: String, _ message: String) -> (String, Bool) {
            let error = RoomMediaUploadError.refused(RoomMediaAPIRefusal(status: status, code: code, message: message))
            return (RoomMediaUploadCoordinator.reason(for: error), RoomMediaUploadCoordinator.canRetry(error))
        }
        let room = reason(413, "ATTACHMENT_QUOTA_EXCEEDED", "would exceed the room attachment storage limit of 1 bytes")
        XCTAssertEqual(room.0, "This room's storage for photos and files is full.")
        XCTAssertFalse(room.1)
        let owner = reason(413, "ATTACHMENT_QUOTA_EXCEEDED", "would exceed the room owner's attachment storage limit of 1 bytes")
        XCTAssertEqual(owner.0, "The room owner's storage for photos and files is full.")
        let mine = reason(413, "ATTACHMENT_QUOTA_EXCEEDED", "would exceed your limit of 1 bytes of unfinished image and file uploads")
        XCTAssertTrue(mine.0.contains("unfinished"))
        XCTAssertTrue(mine.1)
        let checked = reason(400, "ATTACHMENT_VERIFICATION_FAILED", "checksum mismatch")
        XCTAssertTrue(checked.1, "a failed check is uploaded again with the same id")
    }

    func test_a_preview_goes_up_linked_to_its_file() async throws {
        let uploader = FakeUploader()
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        await waitUntil("uploaded") { media.board.tray.first?.phase == .uploaded }
        let preview = try XCTUnwrap(uploader.inits.first { $0.previewOf != nil })
        XCTAssertEqual(preview.previewOf, "pm_test_000001")
        XCTAssertEqual(preview.clientAttachmentId, "pm_test_000001.pv", "a retry names the same preview")
        XCTAssertEqual(preview.contentType, "image/jpeg")
        XCTAssertTrue(uploader.puts.contains { $0.url.lastPathComponent == "pm_test_000001.pv" })
        XCTAssertEqual(uploader.completes, ["pm_test_000001.pv", "pm_test_000001"], "the preview is stored before its file")
    }

    func test_a_preview_the_api_does_not_link_is_never_sent() async throws {
        let uploader = FakeUploader()
        uploader.linksPreviews = false
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        await waitUntil("uploaded") { media.board.tray.first?.phase == .uploaded }
        XCTAssertFalse(uploader.puts.contains { $0.url.lastPathComponent.hasSuffix(".pv") },
                       "an unlinked preview would show in the room as a photo of its own")
        XCTAssertEqual(uploader.completes, ["pm_test_000001"])
    }
}
