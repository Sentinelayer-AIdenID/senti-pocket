import Combine
import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// A gate a call waits at until the test opens it. No clock is involved: the test decides the order. A waiter whose
/// task is cancelled leaves at once with `CancellationError`, like a URLSession task cancelled mid-flight.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func open() {
        lock.lock()
        isOpen = true
        let waiting = waiters.values
        waiters = [:]
        lock.unlock()
        waiting.forEach { $0.resume() }
    }

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.resume(throwing: CancellationError())
        }
    }
}

/// The API and storage, scripted: every call is logged in order ("init:id", "put:id", "complete-asked:id",
/// "complete:id", "delete:id", "post:clientId", "cancelled-put:id"), each one tells `onEvent`, and gates hold an init,
/// a PUT, a complete or the message's POST until the test opens them.
private final class FakeUploader: RoomMediaUploading, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    private var _inits: [RoomMediaInitRequest] = []
    private var _puts: [(file: URL, url: URL)] = []
    private var _completes: [String] = []
    private var _posts: [(text: String, ids: [String], clientId: String)] = []
    private var _deletes: [String] = []
    private var _failingPuts = 0
    private var _failingPosts = 0
    /// The API links previews (`previewOf` echoed); an older API would not.
    var linksPreviews = true
    /// Inits of originals wait here (after they are logged).
    var initGate: Gate?
    /// Original PUTs wait here (previews never do).
    var putGate: Gate?
    /// Completes of originals wait here.
    var completeGate: Gate?
    /// The message's POST waits here.
    var postGate: Gate?
    /// Init answers with this error (a sign-in that expired, a full storage).
    var initError: Error?
    /// Called inside complete, after the server would have stored it and before the answer arrives (stress tests).
    var completeDelay: (@Sendable () async -> Void)?
    /// Every logged call, as it happens.
    var onEvent: (@Sendable (String) -> Void)?
    /// `MEDIA_TEST_DELAYS=1` (xcodebuild: `TEST_RUNNER_MEDIA_TEST_DELAYS=1`) puts a random 0-2 ms delay before every
    /// call, so a loop of runs meets the calls in many orders.
    private let jitter = ProcessInfo.processInfo.environment["MEDIA_TEST_DELAYS"] == "1"

    private func shake() async {
        if jitter { try? await Task.sleep(nanoseconds: UInt64.random(in: 0...2_000_000)) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func log(_ event: String) {
        locked { _events.append(event) }
        onEvent?(event)
    }

    var events: [String] { locked { _events } }
    var inits: [RoomMediaInitRequest] { locked { _inits } }
    var puts: [(file: URL, url: URL)] { locked { _puts } }
    var completes: [String] { locked { _completes } }
    var posts: [(text: String, ids: [String], clientId: String)] { locked { _posts } }
    var deletes: [String] { locked { _deletes } }
    var failingPuts: Int {
        get { locked { _failingPuts } }
        set { locked { _failingPuts = newValue } }
    }
    var failingPosts: Int {
        get { locked { _failingPosts } }
        set { locked { _failingPosts = newValue } }
    }

    func initUpload(sessionId: String, request: RoomMediaInitRequest) async throws -> RoomMediaInitAnswer {
        await shake()
        locked { _inits.append(request) }
        log("init:\(request.clientAttachmentId)")
        if request.previewOf == nil { try? await initGate?.wait() }
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
        await shake()
        let id = target.url.lastPathComponent
        locked { _puts.append((file, target.url)) }
        log("put:\(id)")
        let total = Int64(1_000)
        progress(total / 2, total)
        if let putGate, !id.hasSuffix(".pv") {
            do {
                try await putGate.wait()
            } catch {
                log("cancelled-put:\(id)")
                throw error
            }
        }
        let fails = locked { () -> Bool in
            guard !id.hasSuffix(".pv"), _failingPuts > 0 else { return false }
            _failingPuts -= 1
            return true
        }
        if fails { throw RoomMediaUploadError.network }
        progress(total, total)
    }

    func deleteUpload(sessionId: String, attachmentId: String) async {
        await shake()
        locked { _deletes.append(attachmentId) }
        log("delete:\(attachmentId)")
    }

    func completeUpload(sessionId: String, attachmentId: String) async throws -> RoomMediaAttachment {
        await shake()
        if !attachmentId.hasSuffix(".pv") {
            log("complete-asked:\(attachmentId)")
            try? await completeGate?.wait()
            await completeDelay?()
        }
        locked { _completes.append(attachmentId) }
        log("complete:\(attachmentId)")
        return RoomMediaAttachment(attachmentId: attachmentId, filename: "\(attachmentId).bin", status: "uploaded")
    }

    func postMessage(sessionId: String, text: String, attachments: [RoomMediaAttachment], clientId: String) async throws {
        await shake()
        try? await postGate?.wait()
        let fails = locked { () -> Bool in
            _posts.append((text, attachments.map(\.attachmentId), clientId))
            guard _failingPosts > 0 else { return false }
            _failingPosts -= 1
            return true
        }
        log("post:\(clientId)")
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

    /// Waits for `condition`, checked again each time something it depends on happens: a call the uploader logs, a
    /// board change, a progress change. No sleeping and no polling; the timeout only stops a hang from blocking the run.
    private func until(_ description: String, uploaders: [FakeUploader] = [], boards: [RoomMediaBoard] = [],
                       progresses: [RoomMediaProgress] = [], _ condition: @escaping @MainActor () -> Bool) async {
        if condition() { return }
        let met = expectation(description: description)
        met.assertForOverFulfill = false
        var fulfilled = false
        let check: @MainActor () -> Void = {
            guard !fulfilled, condition() else { return }
            fulfilled = true
            met.fulfill()
        }
        var watches: [AnyCancellable] = []
        for board in boards {
            watches.append(board.objectWillChange.sink { _ in Task { @MainActor in check() } })
        }
        for progress in progresses {
            watches.append(progress.objectWillChange.sink { _ in Task { @MainActor in check() } })
        }
        for uploader in uploaders {
            uploader.onEvent = { _ in Task { @MainActor in check() } }
        }
        check()
        await fulfillment(of: [met], timeout: 30)
        watches.forEach { $0.cancel() }
        uploaders.forEach { $0.onEvent = nil }
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
        let gate = Gate()
        uploader.putGate = gate
        let media = coordinator(uploader)
        media.add([try source("IMG_0042.jpg")])
        let item = try XCTUnwrap(media.board.tray.first)
        await until("half way", progresses: [item.progress]) { item.progress.sentBytes == 500 }
        XCTAssertEqual(item.progress.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(media.board.tray.first?.phase, .uploading)
        gate.open()
        await until("uploaded", boards: [media.board]) { media.board.tray.first?.phase == .uploaded }
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
        await until("sent", boards: [media.board]) { media.board.outgoing.first?.status == .sent }
        XCTAssertEqual(uploader.posts.count, 1)
        XCTAssertEqual(uploader.posts.first?.text, "Look at these")
        XCTAssertEqual(uploader.posts.first?.ids, ["pm_test_000001", "pm_test_000002"])
        XCTAssertEqual(uploader.posts.first?.clientId, clientId)
        XCTAssertEqual(seeded, ["pm_test_000001"], "the photo's own preview is handed to the room")

        media.echoed([clientId])
        XCTAssertTrue(media.board.outgoing.isEmpty, "the card goes once the room shows the message")
        XCTAssertEqual(discarded, ["IMG_0001.jpg", "spec.pdf"])
        XCTAssertTrue(uploader.deletes.isEmpty, "a posted message's files belong to the room: nothing is deleted")

        media.add([try source("a.jpg"), try source("b.png")])
        media.perform(.send(text: ""))
        await until("posted again", uploaders: [uploader]) { uploader.posts.count == 2 }
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
        await until("failed", boards: [media.board]) { media.board.outgoing.first?.isFailed == true }
        XCTAssertEqual(media.board.outgoing.first?.canRetry, true)
        XCTAssertEqual(media.board.outgoing.first?.items.first?.isFailed, true, "the file stays, marked")

        media.perform(.retry(clientId: clientId))
        await until("post failed", uploaders: [uploader], boards: [media.board]) {
            uploader.posts.count == 1 && media.board.outgoing.first?.isFailed == true
        }
        media.perform(.retry(clientId: clientId))
        await until("sent", boards: [media.board]) { media.board.outgoing.first?.status == .sent }

        let originals = uploader.inits.filter { $0.previewOf == nil }.map(\.clientAttachmentId)
        XCTAssertEqual(originals, ["pm_test_000001", "pm_test_000001"], "the retry is the same upload")
        XCTAssertEqual(uploader.posts.map(\.clientId), [clientId, clientId], "the retry is the same message")
        XCTAssertEqual(media.board.outgoing.first?.id, clientId, "it kept its place")
    }

    func test_cancel_stops_the_upload_and_nothing_reaches_the_room() async throws {
        let uploader = FakeUploader()
        uploader.putGate = Gate()
        let media = coordinator(uploader)
        media.add([try source("clip.mov")])
        media.perform(.send(text: ""))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("uploading", uploaders: [uploader]) { uploader.events.contains("put:pm_test_000001") }
        media.perform(.cancel(clientId: clientId))
        XCTAssertTrue(media.board.outgoing.isEmpty, "the card goes at once")
        await until("deleted", uploaders: [uploader]) { uploader.deletes.contains("pm_test_000001") }
        XCTAssertTrue(uploader.events.contains("cancelled-put:pm_test_000001"), "the bytes stop at once")
        XCTAssertTrue(uploader.posts.isEmpty)
        XCTAssertFalse(uploader.completes.contains("pm_test_000001"))
        XCTAssertEqual(discarded, ["clip.mov"])

        let other = FakeUploader()
        let room = coordinator(other)
        room.add([try source("draft.jpg")])
        let itemId = try XCTUnwrap(room.board.tray.first?.id)
        room.perform(.remove(itemId: itemId))
        XCTAssertTrue(room.board.tray.isEmpty, "taken out of the tray, its upload stops")
    }

    func test_a_file_taken_out_or_a_message_cancelled_is_taken_back_on_the_server() async throws {
        let uploader = FakeUploader()
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        await until("uploaded", boards: [media.board]) { media.board.tray.first?.phase == .uploaded }
        media.perform(.remove(itemId: "pm_test_000001"))
        await until("deleted", uploaders: [uploader]) { uploader.deletes.count == 2 }
        XCTAssertEqual(uploader.deletes, ["pm_test_000001", "pm_test_000001.pv"], "the file and its preview")

        // Cancelled while its init is on its way: init ends first, then the delete.
        let initGate = Gate()
        let slow = FakeUploader()
        slow.initGate = initGate
        let room = coordinator(slow)
        room.add([try source("clip.mov")])
        room.perform(.send(text: ""))
        let clientId = try XCTUnwrap(room.board.outgoing.first?.id)
        await until("init asked", uploaders: [slow]) { slow.events.contains("init:pm_test_000002") }
        room.perform(.cancel(clientId: clientId))
        initGate.open()
        await until("deleted after init", uploaders: [slow]) { slow.deletes.contains("pm_test_000002") }
        XCTAssertTrue(slow.posts.isEmpty)
        XCTAssertFalse(slow.events.contains("put:pm_test_000002"), "nothing more is asked once it is taken back")

        // Taken out before its upload began: the server never heard of it, so nothing is deleted.
        let untouched = FakeUploader()
        let other = coordinator(untouched)
        other.add([try source("notes.txt")])
        let id = try XCTUnwrap(other.board.tray.first?.id)
        other.perform(.remove(itemId: id))
        XCTAssertTrue(untouched.inits.isEmpty)
        XCTAssertTrue(untouched.deletes.isEmpty, "nothing is deleted for a file the server never heard of")
    }

    /// The race: complete is on its way when the file is taken out. The delete must follow the completion (a file the
    /// server completed after the person took it back is deleted), and the file is never named in a message.
    func test_a_completion_landing_after_the_file_is_taken_out_is_deleted_after_it() async throws {
        let uploader = FakeUploader()
        let gate = Gate()
        uploader.completeGate = gate
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        await until("complete on its way", uploaders: [uploader]) {
            uploader.events.contains("complete-asked:pm_test_000001")
        }
        media.perform(.remove(itemId: "pm_test_000001"))
        XCTAssertTrue(uploader.deletes.isEmpty, "nothing is deleted while a call is still on its way")
        gate.open()
        await until("deleted", uploaders: [uploader]) { uploader.deletes.contains("pm_test_000001") }
        let events = uploader.events
        let completed = try XCTUnwrap(events.firstIndex(of: "complete:pm_test_000001"))
        let deleted = try XCTUnwrap(events.firstIndex(of: "delete:pm_test_000001"))
        XCTAssertLessThan(completed, deleted, "the delete follows the completion it takes back")
        XCTAssertTrue(uploader.posts.isEmpty)
        XCTAssertTrue(media.board.tray.isEmpty)
    }

    /// The same race for a message: its last file completes just after Cancel. The message is never posted, and the
    /// delete follows the completion.
    func test_a_message_cancelled_while_its_file_completes_is_never_posted() async throws {
        let uploader = FakeUploader()
        let gate = Gate()
        uploader.completeGate = gate
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("complete on its way", uploaders: [uploader]) {
            uploader.events.contains("complete-asked:pm_test_000001")
        }
        media.perform(.cancel(clientId: clientId))
        gate.open()
        await until("deleted", uploaders: [uploader]) { uploader.deletes.contains("pm_test_000001") }
        let events = uploader.events
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "complete:pm_test_000001")),
                          try XCTUnwrap(events.firstIndex(of: "delete:pm_test_000001")))
        XCTAssertFalse(events.contains { $0.hasPrefix("post:") }, "a cancelled message never reaches the room")
        XCTAssertTrue(media.board.outgoing.isEmpty)
    }

    /// Once its post has started, a message is the room's: Cancel is not offered, and a late tap does nothing.
    func test_cancel_after_the_post_started_does_nothing() async throws {
        let uploader = FakeUploader()
        let gate = Gate()
        uploader.postGate = gate
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("posting", boards: [media.board]) { media.board.outgoing.first?.status == .posting }
        media.perform(.cancel(clientId: clientId))
        XCTAssertEqual(media.board.outgoing.first?.status, .posting, "the card stays: the message is on its way")
        gate.open()
        await until("sent", boards: [media.board]) { media.board.outgoing.first?.status == .sent }
        XCTAssertTrue(uploader.deletes.isEmpty, "a posted file is never deleted from under its message")
    }

    /// Cancel and complete in every order, with delays injected on both sides: a cancelled message is never posted,
    /// and whatever was asked of the server is deleted after its last call.
    func test_cancel_and_complete_in_any_order_never_post_and_always_delete_last() async throws {
        for round in 0..<40 {
            let uploader = FakeUploader()
            uploader.completeDelay = { try? await Task.sleep(nanoseconds: UInt64.random(in: 0...3_000_000)) }
            let media = coordinator(uploader)
            media.add([try source("IMG_\(round).jpg")])
            media.perform(.send(text: ""))
            let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
            let itemId = try XCTUnwrap(media.board.outgoing.first?.items.first?.id)
            try await Task.sleep(nanoseconds: UInt64.random(in: 0...4_000_000))
            media.perform(.cancel(clientId: clientId))
            if media.board.outgoing.isEmpty {
                // Cancelled before the post began. The phone's copy goes once the last call has ended (`discard`), and
                // the delete follows when the server was asked anything.
                let name = "IMG_\(round).jpg"
                await until("settled \(round)", uploaders: [uploader]) {
                    self.discarded.contains(name)
                        && (!uploader.events.contains("init:\(itemId)") || uploader.deletes.contains(itemId))
                }
                let events = uploader.events
                XCTAssertFalse(events.contains { $0.hasPrefix("post:") }, "round \(round): never posted")
                if let deleted = events.firstIndex(of: "delete:\(itemId)") {
                    for (index, event) in events.enumerated()
                    where event.hasSuffix(":\(itemId)") && !event.hasPrefix("delete:") && !event.hasPrefix("complete-asked:") {
                        XCTAssertLessThan(index, deleted, "round \(round): \(event) came after the delete")
                    }
                } else {
                    XCTAssertFalse(events.contains("init:\(itemId)"), "round \(round): asked of the server, never deleted")
                }
            } else {
                // The post had already started: the message is the room's, and nothing of it is deleted.
                await until("sent \(round)", boards: [media.board]) { media.board.outgoing.first?.status == .sent }
                XCTAssertTrue(uploader.deletes.isEmpty, "round \(round): a posted file was deleted")
            }
        }
    }

    func test_a_message_the_room_shows_before_its_post_answers_goes_at_once() async throws {
        let uploader = FakeUploader()
        let gate = Gate()
        uploader.postGate = gate
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("posting", boards: [media.board]) { media.board.outgoing.first?.status == .posting }
        media.echoed([clientId])
        XCTAssertTrue(media.board.outgoing.isEmpty, "shown once, by the room")
        gate.open()
        await until("posted", uploaders: [uploader]) { uploader.posts.count == 1 }
        XCTAssertTrue(media.board.outgoing.isEmpty, "the post's answer never brings the card back")
    }

    func test_a_picture_the_phone_cannot_read_leaves_the_tray_with_why() async throws {
        let media = coordinator(FakeUploader())
        media.add([try source("broken.jpg"), try source("broken.svg")])
        await until("refused", boards: [media.board]) { media.board.tray.isEmpty }
        XCTAssertNotNil(media.board.notice)
        await until("discarded", boards: [media.board]) { Set(self.discarded) == ["broken.jpg", "broken.svg"] }
    }

    func test_ids_and_messages_survive_the_app_closing() async throws {
        let uploader = FakeUploader()
        uploader.failingPuts = 1
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("failed", boards: [media.board]) { media.board.outgoing.first?.isFailed == true }

        // The app closes; at the next launch the room opens again.
        let again = FakeUploader()
        let reopened = coordinator(again)
        XCTAssertEqual(reopened.board.outgoing.map(\.id), [clientId], "the message is back, with its client id")
        XCTAssertEqual(reopened.board.outgoing.first?.items.map(\.id), ["pm_test_000001"], "its file, with its id")
        XCTAssertEqual(reopened.board.outgoing.first?.text, "Hi")
        XCTAssertEqual(reopened.board.outgoing.first?.canRetry, true)
        XCTAssertNotNil(reopened.board.outgoing.first?.items.first?.thumbnail, "its preview shows again")

        reopened.perform(.retry(clientId: clientId))
        await until("posted", uploaders: [again]) { again.posts.count == 1 }
        XCTAssertEqual(again.posts.first?.clientId, clientId, "the same message")
        XCTAssertEqual(again.posts.first?.ids, ["pm_test_000001"], "the same upload")
        XCTAssertTrue(again.inits.allSatisfy { $0.clientAttachmentId.hasPrefix("pm_test_000001") })
        XCTAssertEqual(again.completes.first, "pm_test_000001", "completing is tried first: the bytes may have landed")
    }

    func test_a_grant_iOS_ended_is_asked_for_again_and_never_ended_twice() async throws {
        let keepAlive = ScriptedKeepAlive()
        let uploader = FakeUploader()
        let gate = Gate()
        uploader.putGate = gate
        let media = coordinator(uploader, keepAlive: keepAlive)
        media.add([try source("clip.mov")])
        XCTAssertEqual(keepAlive.begun, [1])
        keepAlive.expire(1)
        media.add([try source("other.mov")])
        XCTAssertEqual(keepAlive.begun, [1, 2], "asked for again while uploads go on")
        gate.open()
        await until("idle", boards: [media.board]) {
            media.board.tray.count == 2 && media.board.tray.allSatisfy { $0.phase == .uploaded }
        }
        XCTAssertEqual(keepAlive.ended, [2], "the grant iOS ended is never ended again")
    }

    func test_an_expired_sign_in_asks_for_it_again_and_the_file_waits() async throws {
        let uploader = FakeUploader()
        uploader.initError = RoomSendError.reauthenticationRequired
        let media = coordinator(uploader)
        var asked = 0
        media.onReauthenticationRequired = { asked += 1 }
        media.add([try source("IMG_0001.jpg")])
        await until("failed", boards: [media.board]) { media.board.tray.first?.isFailed == true }
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
        await until("uploaded", boards: [media.board]) { media.board.tray.first?.phase == .uploaded }
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
        await until("uploaded", boards: [media.board]) { media.board.tray.first?.phase == .uploaded }
        XCTAssertFalse(uploader.puts.contains { $0.url.lastPathComponent.hasSuffix(".pv") },
                       "an unlinked preview would show in the room as a photo of its own")
        XCTAssertEqual(uploader.completes, ["pm_test_000001"])
    }
}
