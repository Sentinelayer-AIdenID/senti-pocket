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
    private var _replies: [(target: RoomMediaReplyTarget, text: String?, ids: [String], key: String)] = []
    private var _replyOutcome: RoomMediaReplyOutcome = .posted
    private var _deletes: [String] = []
    private var _failingPuts = 0
    private var _failingPosts = 0
    private var _releasingCompletes = 0
    private var _failingChecks = 0
    private var _lostCompletes = 0
    /// The uploads the server holds, by id: init again with one of these is a duplicate.
    private var _rows: Set<String> = []
    /// The ids the server withdrew (deleted, released, refused): init with one again answers 409, as the API does for
    /// hours, and complete answers 404. Never made anew.
    private var _withdrawn: Set<String> = []
    /// Init answers with no upload link: storage has the bytes already (`upload: null`).
    var storedAlready = false
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
    /// The message's POST answers with this error (a reference the room refused).
    var postError: Error?
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
    var replies: [(target: RoomMediaReplyTarget, text: String?, ids: [String], key: String)] { locked { _replies } }
    /// What the API does with a reply's files: takes them, or (an API without reply attachments) does not.
    var replyOutcome: RoomMediaReplyOutcome {
        get { locked { _replyOutcome } }
        set { locked { _replyOutcome = newValue } }
    }
    var deletes: [String] { locked { _deletes } }
    var failingPuts: Int {
        get { locked { _failingPuts } }
        set { locked { _failingPuts = newValue } }
    }
    var failingPosts: Int {
        get { locked { _failingPosts } }
        set { locked { _failingPosts = newValue } }
    }
    /// This many completes of originals find the upload released by the server (a failed check, a storage cap, a
    /// reservation that ran out): it and its preview are gone, and init makes them anew.
    var releasingCompletes: Int {
        get { locked { _releasingCompletes } }
        set { locked { _releasingCompletes = newValue } }
    }
    /// This many completes of originals find storage's check failed (400): the server withdrew the upload.
    var failingChecks: Int {
        get { locked { _failingChecks } }
        set { locked { _failingChecks = newValue } }
    }
    /// This many completes of originals are stored, but their answer is lost on the way back.
    var lostCompletes: Int {
        get { locked { _lostCompletes } }
        set { locked { _lostCompletes = newValue } }
    }

    /// The server withdrew this id (a sweep of an unfinished upload, say): it is refused from now on.
    func withdraw(_ id: String) {
        locked { () -> Void in
            _rows.remove(id)
            _withdrawn.insert(id)
        }
    }

    func initUpload(sessionId: String, request: RoomMediaInitRequest) async throws -> RoomMediaInitAnswer {
        await shake()
        locked { _inits.append(request) }
        log("init:\(request.clientAttachmentId)")
        if request.previewOf == nil { try? await initGate?.wait() }
        if let initError { throw initError }
        if locked({ _withdrawn.contains(request.clientAttachmentId) }) {
            log("conflict:\(request.clientAttachmentId)")
            throw RoomMediaUploadError.refused(RoomMediaAPIRefusal(status: 409, code: "ATTACHMENT_CONFLICT"))
        }
        let duplicate = locked { !_rows.insert(request.clientAttachmentId).inserted }
        return RoomMediaInitAnswer(
            duplicate: duplicate,
            attachment: RoomMediaAttachment(attachmentId: request.clientAttachmentId, filename: request.filename,
                                            contentType: request.contentType, sizeBytes: request.sizeBytes,
                                            sha256: request.sha256, status: storedAlready ? "uploaded" : "initiated",
                                            previewOf: linksPreviews ? request.previewOf : nil),
            upload: storedAlready ? nil
                : RoomMediaUploadTarget(url: URL(string: "https://storage.example/\(request.clientAttachmentId)")!,
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
        locked { () -> Void in
            _deletes.append(attachmentId)
            _rows.remove(attachmentId)
            _withdrawn.insert(attachmentId)
        }
        log("delete:\(attachmentId)")
    }

    func completeUpload(sessionId: String, attachmentId: String) async throws -> RoomMediaAttachment {
        await shake()
        if !attachmentId.hasSuffix(".pv") {
            log("complete-asked:\(attachmentId)")
            try? await completeGate?.wait()
            await completeDelay?()
        }
        let released = locked { () -> Bool in
            if _withdrawn.contains(attachmentId) { return true }
            guard !attachmentId.hasSuffix(".pv"), _releasingCompletes > 0 else { return false }
            _releasingCompletes -= 1
            for id in [attachmentId, RoomMediaRules.previewClientId(for: attachmentId)] {
                _rows.remove(id)
                _withdrawn.insert(id)
            }
            return true
        }
        if released {
            log("released:\(attachmentId)")
            // What the uploader makes of complete's 404 for an upload the server released.
            throw RoomMediaUploadError.refused(RoomMediaAPIRefusal(status: 404, code: "ATTACHMENT_RELEASED"))
        }
        let failedCheck = locked { () -> Bool in
            guard !attachmentId.hasSuffix(".pv"), _failingChecks > 0 else { return false }
            _failingChecks -= 1
            _rows.remove(attachmentId)
            _withdrawn.insert(attachmentId)
            return true
        }
        if failedCheck {
            log("check-failed:\(attachmentId)")
            throw RoomMediaUploadError.refused(RoomMediaAPIRefusal(status: 400, code: "ATTACHMENT_VERIFICATION_FAILED"))
        }
        let lost = locked { () -> Bool in
            guard !attachmentId.hasSuffix(".pv"), _lostCompletes > 0 else { return false }
            _lostCompletes -= 1
            return true
        }
        locked { _completes.append(attachmentId) }
        log("complete:\(attachmentId)")
        if lost { throw RoomMediaUploadError.network }
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
        if let postError { throw postError }
        if fails { throw RoomSendError.retryable(retryAfterSeconds: nil) }
    }

    func postReply(sessionId: String, to target: RoomMediaReplyTarget, text: String?, attachments: [RoomMediaAttachment],
                   idempotencyKey: String) async throws -> RoomMediaReplyOutcome {
        await shake()
        try? await postGate?.wait()
        let outcome = locked { () -> RoomMediaReplyOutcome in
            _replies.append((target, text, attachments.map(\.attachmentId), idempotencyKey))
            return _replyOutcome
        }
        log("reply:\(idempotencyKey)")
        if let postError { throw postError }
        return outcome
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
    /// Told each time the coordinator lets a file's local copy go: a file taken back during a step that asks nothing
    /// of the server (its preview, its preparation) ends with no call to log, and `until` must hear of it too.
    private let discards = PassthroughSubject<Void, Never>()
    private var counter = 0
    /// This test's own outbox, removed when it ends.
    private lazy var root: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("media-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }()

    /// Waits for `condition`, checked again each time something it depends on happens: a call the uploader logs, a
    /// board change, a progress change, a local copy let go. No sleeping and no polling; the timeout only stops a hang
    /// from blocking the run.
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
        var watches: [AnyCancellable] = [discards.sink { _ in Task { @MainActor in check() } }]
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

    /// Waits for what no board or upload announces (a hook being called), looking every 10 ms, 30 s at most.
    private func poll(_ description: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<3_000 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), description)
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

    private func coordinator(_ uploader: FakeUploader?, keepAlive: any RoomMediaKeepingAlive = NoKeepAlive(),
                             session: String = "room_1", account: String? = nil,
                             consent: AIConsent? = nil) -> RoomMediaUploadCoordinator {
        RoomMediaUploadCoordinator(
            sessionId: session,
            account: account,
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
                self.discards.send(())
            },
            outboxRoot: root,
            aiConsent: consent
        )
    }

    // MARK: The AI consent (App Store guideline 5.1.2(i))

    func test_retry_of_a_message_an_earlier_build_left_asks_first_and_posts_only_after_ok() async throws {
        // An earlier build, without the question, left a photo cut off mid-upload.
        let uploader = FakeUploader()
        uploader.failingPuts = 1
        let earlier = coordinator(uploader)
        earlier.add([try source("IMG_0001.jpg")])
        earlier.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(earlier.board.outgoing.first?.id)
        await until("failed", boards: [earlier.board]) { earlier.board.outgoing.first?.isFailed == true }

        // This build, in a room this account never said OK for.
        let consent = AIConsent(account: nil)
        let again = FakeUploader()
        let reopened = coordinator(again, consent: consent)
        var asked: [AIConsentHeld] = []
        reopened.askAIConsent = { asked.append($0) }
        reopened.perform(.retry(clientId: clientId))
        XCTAssertEqual(asked.count, 1, "Retry asks first, as a text does")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(again.posts.isEmpty, "no photo and no words reach the room's agents before OK")
        XCTAssertTrue(again.inits.isEmpty && again.completes.isEmpty, "nothing of it goes at all")

        // Not now: it stays as it was.
        asked.first?.decline()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(again.posts.isEmpty)
        XCTAssertEqual(reopened.board.outgoing.first?.canRetry, true)

        // OK: it goes.
        reopened.perform(.retry(clientId: clientId))
        XCTAssertEqual(asked.count, 2)
        consent.grant()
        asked.last?.proceed()
        await until("posted", uploaders: [again]) { again.posts.count == 1 }
        XCTAssertEqual(again.posts.first?.clientId, clientId)
    }

    func test_retry_after_the_ok_was_withdrawn_asks_again_and_posts_nothing() async throws {
        let consent = AIConsent(account: nil)
        consent.grant()
        let uploader = FakeUploader()
        uploader.failingPuts = 1
        let media = coordinator(uploader, consent: consent)
        var asked = 0
        media.askAIConsent = { _ in asked += 1 }
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("failed", boards: [media.board]) { media.board.outgoing.first?.isFailed == true }

        consent.withdraw()
        media.perform(.retry(clientId: clientId))
        XCTAssertEqual(asked, 1, "withdrawn in Settings: Retry asks again")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(uploader.posts.isEmpty, "and nothing is posted")
    }

    func test_a_message_with_files_never_reaches_the_room_without_the_ok() async throws {
        // However it was sent (the room's box asks first; this is the coordinator's own stop).
        let consent = AIConsent(account: nil)
        let uploader = FakeUploader()
        let media = coordinator(uploader, consent: consent)
        media.add([try source("notes.md"), try source("IMG_0001.jpg")])
        await until("ready and uploaded", boards: [media.board]) {
            media.board.tray.map(\.phase) == [.ready, .uploaded]
        }
        media.perform(.send(text: "Notes and a photo"))
        await until("stopped", boards: [media.board]) { media.board.outgoing.first?.isFailed == true }
        XCTAssertEqual(media.board.outgoing.first?.status,
                       .failed(reason: RoomMediaUploadCoordinator.consentReason, canRetry: true))
        XCTAssertTrue(uploader.posts.isEmpty, "the message is not posted")
        XCTAssertFalse(uploader.events.contains("init:pm_test_000001"),
                       "the Markdown file, published as it completes, never even starts")
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
            // Its own room: a room restores the outbox entries it finds, and the rounds before left theirs.
            let media = coordinator(uploader, session: "room_stress_\(round)")
            media.add([try source("IMG_\(round).jpg")])
            let itemId = try XCTUnwrap(media.board.tray.first?.id)
            media.perform(.send(text: ""))
            let clientId = try XCTUnwrap(media.board.outgoing.first { $0.items.map(\.id) == [itemId] }?.id)
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
                XCTAssertFalse(uploader.deletes.contains(itemId), "round \(round): a posted file was deleted")
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

    func test_a_posted_message_is_not_shown_again_after_the_app_closes() async throws {
        let uploader = FakeUploader()
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        await until("sent", boards: [media.board]) { media.board.outgoing.first?.status == .sent }
        // The app closes before the room showed it; at the next launch it is not offered again.
        let reopened = coordinator(FakeUploader())
        XCTAssertTrue(reopened.board.outgoing.isEmpty, "a posted message is the room's: it is not shown as unsent")
        XCTAssertTrue(reopened.board.tray.isEmpty)
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

    /// Warden, #298 review: a file left unsent by one account (its upload failed, the app was closed) is never shown,
    /// retried or posted by another account signing in on this phone; its own account gets it back.
    func test_another_account_never_sees_or_retries_the_last_accounts_files() async throws {
        let uploader = FakeUploader()
        uploader.failingPuts = 1
        let alice = coordinator(uploader, account: "sub:alice")
        alice.add([try source("IMG_0001.jpg")])
        alice.perform(.send(text: "Alice's photo"))
        await until("failed", boards: [alice.board]) { alice.board.outgoing.first?.isFailed == true }

        let bob = coordinator(FakeUploader(), account: "sub:bob")
        XCTAssertTrue(bob.board.outgoing.isEmpty, "bob never sees alice's message")
        XCTAssertTrue(bob.board.tray.isEmpty)

        let aliceAgain = coordinator(FakeUploader(), account: "sub:alice")
        XCTAssertEqual(aliceAgain.board.outgoing.count, 1, "alice signing back in gets it back")
    }

    func test_each_account_has_its_own_coordinator_for_a_room() {
        let room = "room_accounts_" + UUID().uuidString
        let forAlice = RoomMediaUploadCoordinator.forRoom(room, account: "sub:alice", uploader: FakeUploader()) {
            RoomMediaUploadCoordinator(sessionId: room, account: "sub:alice", uploader: FakeUploader(),
                                       keepAlive: NoKeepAlive(), outboxRoot: root)
        }
        let forBob = RoomMediaUploadCoordinator.forRoom(room, account: "sub:bob", uploader: FakeUploader()) {
            RoomMediaUploadCoordinator(sessionId: room, account: "sub:bob", uploader: FakeUploader(),
                                       keepAlive: NoKeepAlive(), outboxRoot: root)
        }
        XCTAssertFalse(forAlice === forBob, "bob never gets alice's uploads in flight")
        let aliceAgain = RoomMediaUploadCoordinator.forRoom(room, account: "sub:alice", uploader: nil) {
            XCTFail("alice's room keeps its coordinator")
            return forAlice
        }
        XCTAssertTrue(aliceAgain === forAlice)
    }

    func test_the_launch_sweep_drops_files_no_one_can_tell_the_account_of() throws {
        let sweepRoot = root.appendingPathComponent("sweep-\(UUID().uuidString)")
        for (name, account) in [("kept", "sub:alice" as String?), ("old", nil)] {
            let folder = sweepRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var entry = RoomMediaOutboxEntry(sessionId: "room_1", account: account, itemId: name, filename: "a.jpg", kind: "image",
                                             sizeBytes: 1, createdAt: Date(), initiated: false, previewDone: false)
            entry.prepared = .init(file: "a.jpg", filename: "a.jpg", contentType: "image/jpeg", fileExtension: "jpg",
                                   sizeBytes: 1, sha256: String(repeating: "0", count: 64), preview: nil)
            RoomMediaOutbox.write(entry, in: folder)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("a.jpg").path, contents: Data([1]))
        }
        RoomMediaOutbox.sweep(root: sweepRoot)
        let left = try FileManager.default.contentsOfDirectory(atPath: sweepRoot.path)
        XCTAssertEqual(left, ["kept"])
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

    /// Markdown and JSON are published by complete itself (photos and files only by the message), so they are never
    /// uploaded while they wait in the tray, and go up last, right before the message.
    func test_a_markdown_file_waits_for_send_and_goes_up_last() async throws {
        let uploader = FakeUploader()
        let media = coordinator(uploader)
        media.add([try source("notes.md"), try source("IMG_0001.jpg")])
        await until("ready and uploaded", boards: [media.board]) {
            media.board.tray.map(\.phase) == [.ready, .uploaded]
        }
        XCTAssertFalse(uploader.events.contains("init:pm_test_000001"), "nothing of it reaches the server before Send")
        media.perform(.send(text: "Notes and a photo"))
        await until("sent", boards: [media.board]) { media.board.outgoing.first?.status == .sent }
        let events = uploader.events
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "complete:pm_test_000002")),
                          try XCTUnwrap(events.firstIndex(of: "init:pm_test_000001")), "it goes up after the photo")
        XCTAssertEqual(uploader.posts.first?.ids, ["pm_test_000001", "pm_test_000002"])

        // Taken out of the tray before Send: the server never hears of it.
        let other = FakeUploader()
        let room = coordinator(other, session: "room_markdown")
        room.add([try source("plan.json")])
        await until("ready", boards: [room.board]) { room.board.tray.first?.phase == .ready }
        room.perform(.remove(itemId: try XCTUnwrap(room.board.tray.first?.id)))
        XCTAssertTrue(other.inits.isEmpty)
        XCTAssertTrue(other.deletes.isEmpty)
    }

    func test_a_message_the_room_refuses_to_take_is_final_and_says_why() async throws {
        let uploader = FakeUploader()
        uploader.postError = RoomMediaUploadError.refused(RoomMediaAPIRefusal(
            status: 409, code: "ATTACHMENT_REFERENCE_REJECTED", message: "attachment expired"))
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        await until("failed", boards: [media.board]) { media.board.outgoing.first?.isFailed == true }
        XCTAssertEqual(media.board.outgoing.first?.canRetry, false, "posting it again cannot help")
        XCTAssertTrue(media.board.outgoing.first?.statusText.contains("expires") == true,
                      media.board.outgoing.first?.statusText ?? "")
    }

    /// The server releases an upload it could not finish (here a reservation that ran out) and its preview with it,
    /// and refuses the id from then on (409 for hours). The upload starts over under a new id at once, with its
    /// preview, and the message names the new one; nothing waits for Retry. A retry of an upload the server still
    /// holds keeps its id and sends no second preview.
    func test_an_upload_the_server_released_starts_over_under_a_new_id_at_once() async throws {
        let uploader = FakeUploader()
        uploader.releasingCompletes = 1
        let media = coordinator(uploader)
        media.add([try source("clip.mov")])
        media.perform(.send(text: ""))
        await until("sent", boards: [media.board]) { media.board.outgoing.first?.status == .sent }
        XCTAssertEqual(uploader.inits.filter { $0.previewOf == nil }.map(\.clientAttachmentId),
                       ["pm_test_000001", "pm_test_000002"], "the released id is never asked for again")
        XCTAssertEqual(uploader.inits.filter { $0.previewOf != nil }.map(\.clientAttachmentId),
                       ["pm_test_000001.pv", "pm_test_000002.pv"], "its poster goes up again with it")
        XCTAssertEqual(uploader.posts.first?.ids, ["pm_test_000002"])
        XCTAssertFalse(uploader.events.contains { $0.hasPrefix("conflict:") })
        XCTAssertFalse(uploader.deletes.contains("pm_test_000001"), "the server withdrew it already")

        // The bytes did not get there, and the server still holds the upload and its preview: no second preview.
        let held = FakeUploader()
        held.failingPuts = 1
        let room = coordinator(held, session: "room_held")
        room.add([try source("clip.mov")])
        room.perform(.send(text: ""))
        let heldId = try XCTUnwrap(room.board.outgoing.first?.id)
        await until("failed", boards: [room.board]) { room.board.outgoing.first?.isFailed == true }
        room.perform(.retry(clientId: heldId))
        await until("sent", boards: [room.board]) { room.board.outgoing.first?.status == .sent }
        XCTAssertEqual(held.inits.filter { $0.previewOf != nil }.count, 1, "its preview is sent once")
        XCTAssertEqual(held.inits.filter { $0.previewOf == nil }.count, 2, "the same upload, asked for again")
    }

    /// Storage's check of the bytes failed (400): the server withdrew the upload. The file waits for Retry, which sends
    /// it under a new id, never the withdrawn one; the withdrawn row is deleted.
    func test_a_failed_check_starts_over_under_a_new_id_on_retry() async throws {
        let uploader = FakeUploader()
        uploader.failingChecks = 1
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("failed", boards: [media.board]) { media.board.outgoing.first?.isFailed == true }
        XCTAssertEqual(media.board.outgoing.first?.items.first?.phase,
                       .failed(reason: "The upload didn't check out. Retry to send it again.", canRetry: true))
        media.perform(.retry(clientId: clientId))
        await until("sent", boards: [media.board]) { media.board.outgoing.first?.status == .sent }
        XCTAssertEqual(uploader.inits.filter { $0.previewOf == nil }.map(\.clientAttachmentId),
                       ["pm_test_000001", "pm_test_000002"])
        XCTAssertFalse(uploader.events.contains { $0.hasPrefix("conflict:") }, "the withdrawn id is never asked for")
        XCTAssertEqual(uploader.posts.first?.ids, ["pm_test_000002"])
        await until("withdrawn row deleted", uploaders: [uploader]) { uploader.deletes.contains("pm_test_000001") }
    }

    /// The server refuses the new id too: the upload does not start over again by itself (once only), and waits for
    /// Retry.
    func test_an_id_refused_again_after_a_new_one_waits_for_retry() async throws {
        let uploader = FakeUploader()
        uploader.initError = RoomMediaUploadError.refused(RoomMediaAPIRefusal(status: 409, code: "ATTACHMENT_CONFLICT"))
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        await until("failed", boards: [media.board]) { media.board.tray.first?.isFailed == true }
        XCTAssertEqual(uploader.inits.filter { $0.previewOf == nil }.map(\.clientAttachmentId),
                       ["pm_test_000001", "pm_test_000002"], "one new id, then it stops")
        XCTAssertEqual(media.board.tray.first?.phase,
                       .failed(reason: "The server withdrew this upload. Retry to send it again.", canRetry: true))
    }

    /// A file taken out after its upload started over under a new id is deleted under that id, with its preview.
    func test_a_file_taken_out_after_a_new_id_is_deleted_under_it() async throws {
        let uploader = FakeUploader()
        uploader.failingChecks = 1
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        await until("failed", boards: [media.board]) { media.board.tray.first?.isFailed == true }
        media.perform(.retryItem(itemId: "pm_test_000001"))
        await until("uploaded", boards: [media.board]) { media.board.tray.first?.phase == .uploaded }
        media.perform(.remove(itemId: "pm_test_000001"))
        await until("deleted", uploaders: [uploader]) {
            uploader.deletes.contains("pm_test_000002") && uploader.deletes.contains("pm_test_000002.pv")
        }
    }

    /// A new id is kept across the app closing: after the relaunch the upload goes on under it, never the old one.
    func test_a_new_id_survives_the_app_closing() async throws {
        let uploader = FakeUploader()
        uploader.failingChecks = 1
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("failed", boards: [media.board]) { media.board.outgoing.first?.isFailed == true }

        let again = FakeUploader()
        let reopened = coordinator(again)
        reopened.perform(.retry(clientId: clientId))
        await until("posted", uploaders: [again]) { again.posts.count == 1 }
        XCTAssertEqual(again.posts.first?.ids, ["pm_test_000002"])
        XCTAssertFalse(again.inits.contains { $0.clientAttachmentId == "pm_test_000001" }, "the old id is never asked for")
    }

    /// The app closed with an upload unfinished; meanwhile the server swept it and refuses its id. Retry after the next
    /// launch tries complete (404), init (409), then starts over under a new id at once: the message is sent with no
    /// second Retry.
    func test_an_upload_restored_after_its_id_was_withdrawn_goes_up_under_a_new_id() async throws {
        let uploader = FakeUploader()
        uploader.failingPuts = 1
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("failed", boards: [media.board]) { media.board.outgoing.first?.isFailed == true }

        let again = FakeUploader()
        again.withdraw("pm_test_000001")
        let reopened = coordinator(again)
        reopened.perform(.retry(clientId: clientId))
        await until("posted", uploaders: [again]) { again.posts.count == 1 }
        XCTAssertEqual(again.posts.first?.clientId, clientId, "the same message")
        XCTAssertEqual(again.posts.first?.ids, ["pm_test_000002"], "under a new id")
        XCTAssertEqual(again.events.filter { $0.hasPrefix("conflict:") }, ["conflict:pm_test_000001"], "refused once")
    }

    /// Init answers with no upload link (`upload: null`): storage has the bytes already, so nothing is sent before
    /// complete.
    func test_init_without_an_upload_link_completes_without_a_put() async throws {
        let uploader = FakeUploader()
        uploader.storedAlready = true
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        await until("sent", boards: [media.board]) { media.board.outgoing.first?.status == .sent }
        XCTAssertTrue(uploader.puts.isEmpty, "storage has the bytes")
        XCTAssertEqual(uploader.completes.last, "pm_test_000001")
        XCTAssertEqual(uploader.posts.first?.ids, ["pm_test_000001"])
    }

    /// Complete stored the file but its answer was lost: Retry completes again before anything else, and the bytes
    /// never go up a second time.
    func test_a_retry_after_the_bytes_landed_completes_without_sending_them_again() async throws {
        let uploader = FakeUploader()
        uploader.lostCompletes = 1
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("failed", boards: [media.board]) { media.board.outgoing.first?.isFailed == true }
        media.perform(.retry(clientId: clientId))
        await until("sent", boards: [media.board]) { media.board.outgoing.first?.status == .sent }
        XCTAssertEqual(uploader.puts.filter { $0.url.lastPathComponent == "pm_test_000001" }.count, 1,
                       "the bytes went up once")
        XCTAssertEqual(uploader.inits.filter { $0.previewOf == nil }.count, 1, "no second init")
    }

    /// A message whose post failed on its way may be in the room: discarding it never takes its files back on the
    /// server. One the API refused is not in the room, and discarding it deletes its uploads.
    func test_a_message_that_may_have_been_posted_is_never_taken_back_on_the_server() async throws {
        let uploader = FakeUploader()
        uploader.failingPosts = 1
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("post failed", uploaders: [uploader], boards: [media.board]) {
            uploader.posts.count == 1 && media.board.outgoing.first?.isFailed == true
        }
        media.perform(.cancel(clientId: clientId))
        await until("its card goes", boards: [media.board]) { media.board.outgoing.isEmpty }
        await until("its copy goes", boards: [media.board]) { self.discarded.contains("IMG_0001.jpg") }
        XCTAssertTrue(uploader.deletes.isEmpty, "what may be in the room stays there")

        // The same after a relaunch: the outbox remembers its post was asked for.
        let posting = FakeUploader()
        posting.failingPosts = 1
        let before = coordinator(posting, session: "room_relaunch")
        before.add([try source("IMG_0003.jpg")])
        before.perform(.send(text: "Hi"))
        let relaunchId = try XCTUnwrap(before.board.outgoing.first?.id)
        await until("post failed", uploaders: [posting], boards: [before.board]) {
            posting.posts.count == 1 && before.board.outgoing.first?.isFailed == true
        }
        let after = FakeUploader()
        let reopened = coordinator(after, session: "room_relaunch")
        reopened.perform(.cancel(clientId: relaunchId))
        await until("its card goes", boards: [reopened.board]) { reopened.board.outgoing.isEmpty }
        await until("its copy goes", boards: [reopened.board]) { self.discarded.contains("IMG_0003.jpg") }
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(after.deletes.isEmpty, "after a relaunch too")

        let refused = FakeUploader()
        refused.postError = RoomMediaUploadError.refused(RoomMediaAPIRefusal(status: 409, code: "ATTACHMENT_REFERENCE_REJECTED"))
        let room = coordinator(refused, session: "room_refused")
        room.add([try source("IMG_0002.jpg")])
        room.perform(.send(text: "Hi"))
        let refusedId = try XCTUnwrap(room.board.outgoing.first?.id)
        let fileId = try XCTUnwrap(room.board.outgoing.first?.items.first?.id)
        await until("refused", boards: [room.board]) { room.board.outgoing.first?.isFailed == true }
        room.perform(.cancel(clientId: refusedId))
        await until("deleted", uploaders: [refused]) { refused.deletes.contains(fileId) }
    }

    /// A Markdown file in a message goes up only once the message's photo is stored, after a relaunch too: the room
    /// shows it the moment it is uploaded.
    func test_a_restored_markdown_file_goes_up_after_the_photo() async throws {
        let uploader = FakeUploader()
        uploader.failingPuts = 1
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg"), try source("notes.md")])
        media.perform(.send(text: "Hi"))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("failed", boards: [media.board]) { media.board.outgoing.first?.isFailed == true }
        XCTAssertFalse(uploader.inits.contains { $0.filename == "notes.md" }, "the notes wait for the photo")

        let again = FakeUploader()
        let gate = Gate()
        again.completeGate = gate
        let reopened = coordinator(again)
        reopened.perform(.retry(clientId: clientId))
        await until("the photo completing", uploaders: [again]) { again.events.contains("complete-asked:pm_test_000001") }
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(again.inits.contains { $0.filename == "notes.md" }, "still waiting while the photo is stored")
        gate.open()
        await until("posted", uploaders: [again]) { again.posts.count == 1 }
        let events = again.events
        let photoStored = try XCTUnwrap(events.firstIndex(of: "complete:pm_test_000001"))
        let notesInit = try XCTUnwrap(events.firstIndex(of: "init:pm_test_000002"))
        XCTAssertLessThan(photoStored, notesInit)
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

    // MARK: - Replies with files (sentinelayer-api #1135)

    /// The "+" in a thread or a swipe to reply: the tray goes as one reply in that thread, never as a room message, with
    /// no words made up for a photo alone; its card goes once the thread has read it.
    func test_a_reply_with_files_posts_to_its_thread() async throws {
        let uploader = FakeUploader()
        let media = coordinator(uploader)
        // The room's reads showed the API takes files on a reply (a reply of files alone waits for that).
        media.replyAttachments = .supported
        var read: [Int64] = []
        media.onReplyPosted = { target, _ in read.append(target.sequenceId) }
        media.add([try source("IMG_0001.jpg"), try source("spec.pdf")])
        let target = RoomMediaReplyTarget(sequenceId: 42, replyId: "reply-1", name: "pat")
        media.perform(.sendReply(text: "  ", to: target))
        XCTAssertTrue(media.board.tray.isEmpty)
        XCTAssertEqual(media.board.outgoing.first?.replyTo, target, "the card shows at once, in its thread")
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("posted and read back", boards: [media.board]) { media.board.outgoing.isEmpty }
        XCTAssertEqual(uploader.replies.count, 1)
        XCTAssertEqual(uploader.replies.first?.target, target)
        XCTAssertNil(uploader.replies.first?.text, "a reply of files alone carries no words")
        XCTAssertEqual(uploader.replies.first?.ids, ["pm_test_000001", "pm_test_000002"])
        XCTAssertEqual(uploader.replies.first?.key, RoomMediaUploadCoordinator.replyKey(clientId))
        XCTAssertTrue(uploader.posts.isEmpty, "never a message in the room")
        XCTAssertEqual(read, [42], "its thread reads it before the card goes")
        XCTAssertTrue(uploader.deletes.isEmpty, "a posted reply's files belong to the room")
        XCTAssertEqual(media.replyAttachments, .supported)
    }

    /// Pocket ahead of the API (or an API that refuses the field): the files are never dropped without a word. The card
    /// says why and offers a new message; once known, the API is not asked again.
    func test_old_server_fallback_offers_send_as_a_new_message() async throws {
        let uploader = FakeUploader()
        uploader.replyOutcome = .filesNotTaken(replyPosted: true)
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        let target = RoomMediaReplyTarget(sequenceId: 42, name: "pat")
        media.perform(.sendReply(text: "look", to: target))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("refused", boards: [media.board]) { media.board.outgoing.first?.offersSendAsMessage == true }
        let card = try XCTUnwrap(media.board.outgoing.first)
        XCTAssertTrue(card.offersSendAsMessage, "the files can go as a new message")
        XCTAssertEqual(card.statusText, "Photos can't go in a reply yet")
        XCTAssertFalse(card.canRetry, "the same reply would be refused again")
        XCTAssertTrue(uploader.posts.isEmpty, "nothing goes to the room unasked")
        XCTAssertTrue(uploader.deletes.isEmpty, "the files wait on the card")
        XCTAssertEqual(media.replyAttachments, .unsupported)

        media.perform(.sendAsMessage(clientId: clientId))
        await until("sent as a message", uploaders: [uploader]) { uploader.posts.count == 1 }
        XCTAssertEqual(uploader.posts.first?.ids, ["pm_test_000001"], "the same upload")
        XCTAssertEqual(uploader.posts.first?.text, "Shared a photo.", "its words went in the reply already")
        XCTAssertNotEqual(uploader.posts.first?.clientId, clientId, "a message of its own")
        XCTAssertNil(media.board.outgoing.first?.replyTo, "a message in the room now")

        // Known now: the next reply with files is not asked of the API, and its words go with the files.
        media.add([try source("IMG_0002.jpg")])
        media.perform(.sendReply(text: "and this", to: target))
        await until("refused at once", boards: [media.board]) { media.board.outgoing.contains { $0.offersSendAsMessage } }
        XCTAssertEqual(uploader.replies.count, 1, "the API is not asked again")
        let second = try XCTUnwrap(media.board.outgoing.first { $0.offersSendAsMessage }?.id)
        media.perform(.sendAsMessage(clientId: second))
        await until("second message", uploaders: [uploader]) { uploader.posts.count == 2 }
        XCTAssertEqual(uploader.posts.last?.text, "and this")
        XCTAssertEqual(uploader.posts.last?.ids, ["pm_test_000002"])
    }

    /// Discarding a reply whose files the API refused takes them back on the server: nothing was posted. Where the API
    /// took the reply itself, they are only let go: its answer cannot prove none is in the reply.
    func test_a_refused_reply_discarded_takes_its_files_back_only_where_nothing_was_posted() async throws {
        let uploader = FakeUploader()
        uploader.replyOutcome = .filesNotTaken(replyPosted: false)
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.sendReply(text: "", to: RoomMediaReplyTarget(sequenceId: 42, name: "pat")))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("refused", boards: [media.board]) { media.board.outgoing.first?.offersSendAsMessage == true }
        media.perform(.cancel(clientId: clientId))
        XCTAssertTrue(media.board.outgoing.isEmpty)
        await until("deleted", uploaders: [uploader]) { uploader.deletes.contains("pm_test_000001") }

        let older = FakeUploader()
        older.replyOutcome = .filesNotTaken(replyPosted: true)
        let room = coordinator(older, session: "room_2")
        room.add([try source("IMG_0002.jpg")])
        room.perform(.sendReply(text: "look", to: RoomMediaReplyTarget(sequenceId: 42, name: "pat")))
        let second = try XCTUnwrap(room.board.outgoing.first?.id)
        await until("taken without files", boards: [room.board]) { room.board.outgoing.first?.offersSendAsMessage == true }
        room.perform(.cancel(clientId: second))
        XCTAssertTrue(room.board.outgoing.isEmpty)
        XCTAssertTrue(self.discarded.contains("IMG_0002.jpg"), "the phone's copy goes")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(older.deletes.isEmpty, "nothing is taken back on the server")
    }

    func test_a_reply_restored_after_the_app_closes_goes_back_to_its_thread() async throws {
        let uploader = FakeUploader()
        uploader.failingPuts = 1
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        let target = RoomMediaReplyTarget(sequenceId: 42, replyId: "reply-1", name: "pat")
        media.perform(.sendReply(text: "Hi", to: target))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("failed", boards: [media.board]) { media.board.outgoing.first?.isFailed == true }

        // The app closes; at the next launch the room opens again.
        let again = FakeUploader()
        let reopened = coordinator(again)
        XCTAssertEqual(reopened.board.outgoing.first?.replyTo, target, "back in its thread, answering the same reply")
        reopened.perform(.retry(clientId: clientId))
        await until("replied", uploaders: [again]) { again.replies.count == 1 }
        XCTAssertEqual(again.replies.first?.target, target)
        XCTAssertEqual(again.replies.first?.text, "Hi")
        XCTAssertEqual(again.replies.first?.key, RoomMediaUploadCoordinator.replyKey(clientId), "the same reply")
        XCTAssertTrue(again.posts.isEmpty, "never posted to the room as a message")
    }

    // MARK: - Round 2: files alone, the thread's own tray, the card after a relaunch, and the saved words

    /// A reply of files alone is posted only once the room's reads show the API takes files on a reply: an older API
    /// would keep it as an empty reply. Until then it goes straight to the card that offers a new message.
    func test_a_reply_of_files_alone_waits_for_an_api_known_to_take_files() async throws {
        let uploader = FakeUploader()
        let media = coordinator(uploader)
        XCTAssertEqual(media.replyAttachments, .unknown)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.sendReply(text: " ", to: RoomMediaReplyTarget(sequenceId: 42, name: "pat")))
        await until("the card", boards: [media.board]) { media.board.outgoing.first?.offersSendAsMessage == true }
        XCTAssertEqual(media.board.outgoing.first?.statusText, "Photos can't go in a reply yet")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(uploader.replies.isEmpty, "never an empty reply")

        // Words with the files are asked for: an older API takes the words, and the card offers the files.
        media.add([try source("IMG_0002.jpg")])
        media.perform(.sendReply(text: "look", to: RoomMediaReplyTarget(sequenceId: 43, name: "pat")))
        await until("asked", uploaders: [uploader]) { uploader.replies.count == 1 }
        XCTAssertEqual(uploader.replies.first?.text, "look")

        // Known to take files: files alone go.
        let room = coordinator(uploader, session: "room_2")
        room.replyAttachments = .supported
        room.add([try source("IMG_0003.jpg")])
        room.perform(.sendReply(text: "", to: RoomMediaReplyTarget(sequenceId: 44, name: "pat")))
        await until("posted", uploaders: [uploader]) { uploader.replies.count == 2 }
        XCTAssertNil(uploader.replies.last?.text)
    }

    /// A thread has its own tray: files picked there never show in, or go with, the room's box, and the room's never
    /// go with a reply.
    func test_a_thread_has_its_own_tray() async throws {
        let uploader = FakeUploader()
        let media = coordinator(uploader)
        media.replyAttachments = .supported
        let thread = try XCTUnwrap(media.threadBoard(42))
        XCTAssertTrue(media.threadBoard(42) === thread, "one board per thread")

        thread.perform(.choose(.files))
        media.add([try source("IMG_0001.jpg")])
        media.board.perform(.choose(.files))
        media.add([try source("spec.pdf"), try source("IMG_0002.jpg")])
        XCTAssertEqual(thread.tray.map(\.id), ["pm_test_000001"], "picked in the thread")
        XCTAssertEqual(media.board.tray.map(\.id), ["pm_test_000002", "pm_test_000003"], "picked in the room")
        XCTAssertEqual(media.pickerRemaining, RoomMediaRules.attachmentsPerMessage - 2)
        thread.perform(.choose(.files))
        XCTAssertEqual(media.pickerRemaining, RoomMediaRules.attachmentsPerMessage - 1, "the thread's own room left")

        thread.perform(.sendReply(text: "this one", to: RoomMediaReplyTarget(sequenceId: 42, name: "pat")))
        XCTAssertTrue(thread.tray.isEmpty)
        XCTAssertEqual(media.board.tray.count, 2, "the room's files stay in its box")
        await until("replied", uploaders: [uploader]) { uploader.replies.count == 1 }
        XCTAssertEqual(uploader.replies.first?.ids, ["pm_test_000001"], "only the thread's file")

        media.perform(.send(text: "these"))
        await until("posted", uploaders: [uploader]) { uploader.posts.count == 1 }
        XCTAssertEqual(uploader.posts.first?.ids, ["pm_test_000002", "pm_test_000003"], "only the room's files")
    }

    /// A file waiting in a thread's tray goes back to that thread's tray after a relaunch, never the room's.
    func test_a_threads_tray_comes_back_to_its_thread_after_a_relaunch() async throws {
        let uploader = FakeUploader()
        let media = coordinator(uploader)
        let thread = try XCTUnwrap(media.threadBoard(42))
        thread.perform(.choose(.files))
        media.add([try source("IMG_0001.jpg")])
        media.board.perform(.choose(.files))
        media.add([try source("spec.pdf")])
        await until("stored", boards: [media.board, thread]) {
            media.board.tray.first?.phase == .uploaded && thread.tray.first?.phase == .uploaded
        }

        // The app closes; at the next launch the room opens again.
        let reopened = coordinator(FakeUploader())
        XCTAssertEqual(reopened.threadBoard(42)?.tray.map(\.id), ["pm_test_000001"], "back in its thread")
        XCTAssertEqual(reopened.board.tray.map(\.id), ["pm_test_000002"], "and the room's in the room")
    }

    /// After a relaunch the old-server card is still that card: "Send as a new message", no Retry, and the words the
    /// API already took are never sent again.
    func test_the_fallback_card_comes_back_after_a_relaunch_and_never_resends_words() async throws {
        let uploader = FakeUploader()
        uploader.replyOutcome = .filesNotTaken(replyPosted: true)
        let media = coordinator(uploader)
        media.add([try source("IMG_0001.jpg")])
        media.perform(.sendReply(text: "look", to: RoomMediaReplyTarget(sequenceId: 42, name: "pat")))
        let clientId = try XCTUnwrap(media.board.outgoing.first?.id)
        await until("the card", boards: [media.board]) { media.board.outgoing.first?.offersSendAsMessage == true }

        // The app closes; at the next launch the room opens again.
        let again = FakeUploader()
        let reopened = coordinator(again)
        let card = try XCTUnwrap(reopened.board.outgoing.first)
        XCTAssertEqual(card.id, clientId)
        XCTAssertTrue(card.offersSendAsMessage, "still the card that offers a new message")
        XCTAssertFalse(card.canRetry, "never Retry: that would send the words again")
        XCTAssertEqual(card.statusText, "Photos can't go in a reply yet")
        XCTAssertNil(card.text, "the words are in the thread already: the card holds the photo alone")

        reopened.perform(.sendAsMessage(clientId: clientId))
        await until("sent as a message", uploaders: [again]) { again.posts.count == 1 }
        XCTAssertEqual(again.posts.first?.text, "Shared a photo.", "the words went in the reply already")
        XCTAssertEqual(again.posts.first?.ids, ["pm_test_000001"])
        XCTAssertTrue(again.replies.isEmpty, "the reply is never sent again")
    }

    /// The saved words of a reply go when they reach the room: when an older API took them in the reply (its files
    /// waiting on the card), and when "Send as a new message" posts them, after a relaunch too, never before.
    func test_a_replys_saved_words_go_when_the_old_api_takes_them_and_when_the_new_message_posts() async throws {
        let older = FakeUploader()
        older.replyOutcome = .filesNotTaken(replyPosted: true)
        let media = coordinator(older)
        var posted: [(Int64, String?)] = []
        media.onReplyPosted = { target, text in posted.append((target.sequenceId, text)) }
        media.add([try source("IMG_0001.jpg")])
        media.perform(.sendReply(text: "look", to: RoomMediaReplyTarget(sequenceId: 42, name: "pat")))
        await poll("the words went") { !posted.isEmpty }
        XCTAssertEqual(posted.first?.0, 42)
        XCTAssertEqual(posted.first?.1, "look", "the old API took the words: their draft goes")

        // An API that refused the reply took nothing: the words stay saved until the new message carrying them posts.
        let refusing = FakeUploader()
        refusing.replyOutcome = .filesNotTaken(replyPosted: false)
        refusing.failingPosts = 1
        let room = coordinator(refusing, session: "room_2")
        var sent: [(Int64, String?, String)] = []
        room.onReplyPosted = { _, _ in XCTFail("nothing was posted in the thread") }
        room.onReplyDraftSent = { target, text in sent.append((target.sequenceId, target.replyId, text)) }
        room.add([try source("IMG_0002.jpg")])
        room.perform(.sendReply(text: "see this", to: RoomMediaReplyTarget(sequenceId: 43, replyId: "reply-7", name: "sam")))
        let reply = try XCTUnwrap(room.board.outgoing.first?.id)
        await until("the card", boards: [room.board]) { room.board.outgoing.first?.offersSendAsMessage == true }
        room.perform(.sendAsMessage(clientId: reply))
        await until("the post failed", boards: [room.board]) { room.board.outgoing.first?.isFailed == true }
        XCTAssertTrue(sent.isEmpty, "not in the room yet: the words stay saved")

        // The app closes; at the next launch the message is retried and posts.
        let again = FakeUploader()
        let reopened = coordinator(again, session: "room_2")
        reopened.onReplyDraftSent = { target, text in sent.append((target.sequenceId, target.replyId, text)) }
        let message = try XCTUnwrap(reopened.board.outgoing.first?.id)
        reopened.perform(.retry(clientId: message))
        await until("posted", uploaders: [again]) { again.posts.count == 1 }
        await poll("its words let go") { !sent.isEmpty }
        XCTAssertEqual(again.posts.first?.text, "see this")
        XCTAssertEqual(sent.first?.0, 43)
        XCTAssertEqual(sent.first?.1, "reply-7", "the draft of the reply it answered")
        XCTAssertEqual(sent.first?.2, "see this")
    }
}
