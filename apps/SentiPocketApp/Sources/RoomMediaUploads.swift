import Foundation
import PocketSyncClient
import PocketUI
import UIKit

/// Why a file's bytes did not reach storage.
enum RoomMediaUploadError: Error, Equatable {
    /// Storage answered the PUT with this status (an expired link, a checksum that did not match).
    case storageRefused(status: Int)
    case network
    /// The room or its owner has used the storage they have (413).
    case quotaFull
}

/// The calls one upload makes: init, the PUT straight to storage, complete, then the message that names the files.
/// A protocol so the coordinator is testable without a network.
protocol RoomMediaUploading: Sendable {
    func initUpload(sessionId: String, request: RoomMediaInitRequest) async throws -> RoomMediaInitAnswer
    /// Streams the file from disk to storage, reporting bytes sent. Cancelling the task cancels the upload.
    func put(file: URL, to target: RoomMediaUploadTarget, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    func completeUpload(sessionId: String, attachmentId: String) async throws -> RoomMediaAttachment
    func postMessage(sessionId: String, text: String, attachments: [RoomMediaAttachment], clientId: String) async throws
}

/// The API half goes through the room's own authenticated sender; the bytes go through `RoomMediaPutSession`, which
/// never carries the user's token.
struct HTTPRoomMediaUploader: RoomMediaUploading {
    let api: HTTPRoomMessageSender
    var storage: RoomMediaPutSession = .shared

    func initUpload(sessionId: String, request: RoomMediaInitRequest) async throws -> RoomMediaInitAnswer {
        let data = try await post(sessionId: sessionId, path: "attachments/init", key: request.clientAttachmentId,
                                  body: request.body)
        return try RoomMediaInitAnswer.decode(data)
    }

    func put(file: URL, to target: RoomMediaUploadTarget, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await storage.put(file: file, to: target, progress: progress)
    }

    func completeUpload(sessionId: String, attachmentId: String) async throws -> RoomMediaAttachment {
        guard RoomMediaRules.isValidClientId(attachmentId) else { throw RoomSendError.rejected }
        let data = try await post(sessionId: sessionId, path: "attachments/\(attachmentId)/complete",
                                  key: attachmentId + ":complete", body: [:])
        return try RoomMediaInitAnswer.completed(data)
    }

    func postMessage(sessionId: String, text: String, attachments: [RoomMediaAttachment], clientId: String) async throws {
        _ = try await post(sessionId: sessionId, path: "human-message", key: clientId, body: [
            "text": text, "clientId": clientId, "attachments": attachments.map(\.reference)
        ])
    }

    /// The sender's POST, with a full room storage told apart from a refused file.
    private func post(sessionId: String, path: String, key: String, body: [String: Any]) async throws -> Data {
        let (data, http) = try await api.postAnswer(sessionId: sessionId, path: path, idempotencyKey: key, body: body)
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw RoomSendError.reauthenticationRequired
        case 403, 404: throw RoomSendError.notAllowed
        case 413: throw RoomMediaUploadError.quotaFull
        case 409, 425, 429, 500..<600:
            throw RoomSendError.retryable(retryAfterSeconds: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default: throw RoomSendError.rejected
        }
    }
}

/// PUTs files straight to storage from disk, on a background URLSession: an upload keeps going while the app is in the
/// background, and the system wakes the app when it ends. Requests carry exactly the signed headers init returned —
/// never an Authorization header or a cookie — and URLSession sets Content-Length from the file.
final class RoomMediaPutSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let backgroundIdentifier = "com.plexaura.sentipocket.app.room-media"
    static let shared = RoomMediaPutSession(backgroundIdentifier: backgroundIdentifier)

    private struct Waiting {
        let progress: @Sendable (Int64, Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var waiting: [Int: Waiting] = [:]
    private var finishedBackgroundEvents: (() -> Void)?
    private var session: URLSession!

    /// `backgroundIdentifier` nil gives an ordinary in-app session (tests, previews).
    init(backgroundIdentifier: String?) {
        super.init()
        let configuration: URLSessionConfiguration
        if let backgroundIdentifier {
            configuration = .background(withIdentifier: backgroundIdentifier)
            // Started by the person, so started now, not when the system finds it convenient.
            configuration.isDiscretionary = false
            configuration.sessionSendsLaunchEvents = true
        } else {
            configuration = .ephemeral
        }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func put(file: URL, to target: RoomMediaUploadTarget, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        var request = URLRequest(url: target.url)
        request.httpMethod = target.method.uppercased() == "POST" ? "POST" : "PUT"
        for (name, value) in target.headers {
            let lowered = name.lowercased()
            guard !["authorization", "cookie", "host", "content-length"].contains(lowered) else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        let task = session.uploadTask(with: request, fromFile: file)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                waiting[task.taskIdentifier] = Waiting(progress: progress, continuation: continuation)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The app was woken because background uploads ended: called back once their events are delivered.
    func handleBackgroundEvents(completion: @escaping () -> Void) {
        lock.lock()
        finishedBackgroundEvents = completion
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock()
        let progress = waiting[task.taskIdentifier]?.progress
        lock.unlock()
        progress?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = waiting.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        // A task from before the app was relaunched has no one waiting: its file is retried from the room.
        guard let entry else { return }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                entry.continuation.resume(throwing: CancellationError())
            } else {
                entry.continuation.resume(throwing: RoomMediaUploadError.network)
            }
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) {
            entry.continuation.resume()
        } else {
            entry.continuation.resume(throwing: RoomMediaUploadError.storageRefused(status: status))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let finished = finishedBackgroundEvents
        finishedBackgroundEvents = nil
        lock.unlock()
        DispatchQueue.main.async { finished?() }
    }
}

/// Keeps the app running for a little while after it goes to the background, while files upload or their message posts.
protocol RoomMediaKeepingAlive {
    func begin() -> Int
    func end(_ token: Int)
}

struct RoomMediaBackgroundTask: RoomMediaKeepingAlive {
    func begin() -> Int {
        var identifier = UIBackgroundTaskIdentifier.invalid
        // Ended by iOS's deadline if the uploads outlast it (the background session carries on with the bytes).
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Room media upload") {
            UIApplication.shared.endBackgroundTask(identifier)
        }
        return identifier.rawValue
    }

    func end(_ token: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
    }
}

/// Which picker is open. Read only by the picker host, so opening one never redraws the room.
@MainActor
final class RoomMediaPickerRequests: ObservableObject {
    @Published var source: RoomAttachSource?
}

/// One room's photos, videos and files on their way. Each file starts uploading the moment it is picked: its picture
/// shows at once (a downsampled thumbnail), location is removed, it is hashed, and its bytes stream from disk with real
/// progress. Send makes them one message, shown at once with each file's picture; the message posts when every file is
/// stored. A failed file keeps its place and retries with the same client attachment id, so the room never gets it
/// twice; a failed message retries with the same client id.
@MainActor
final class RoomMediaUploadCoordinator: ObservableObject {
    let board: RoomMediaBoard
    let pickers = RoomMediaPickerRequests()
    /// A preview made here, for the room to show its sent file at once.
    var onPreviewReady: (@MainActor (_ attachmentId: String, _ data: Data) -> Void)?
    /// The message posted: read the room now.
    var onPosted: (@MainActor () -> Void)?

    static let progressInterval: TimeInterval = 0.1
    /// How long a posted message waits for the room to show it before its card goes anyway.
    static let echoGrace: TimeInterval = 20

    @MainActor
    private final class Item {
        let id: String
        let source: RoomMediaSource
        var filename: String
        let kind: RoomMediaItemRow.Kind
        var sizeBytes: Int64?
        var thumbnail: Data?
        var prepared: RoomPreparedMedia?
        var stored: RoomMediaAttachment?
        var previewDone = false
        var phase: RoomMediaItemRow.Phase = .preparing
        let progress = RoomMediaProgress()
        var task: Task<Void, Never>?
        var lastTick = Date.distantPast

        init(id: String, source: RoomMediaSource, kind: RoomMediaItemRow.Kind, sizeBytes: Int64?) {
            self.id = id
            self.source = source
            self.filename = source.filename
            self.kind = kind
            self.sizeBytes = sizeBytes
        }

        var isFailed: Bool {
            if case .failed = phase { return true }
            return false
        }

        var canRetry: Bool {
            if case .failed(_, let canRetry) = phase { return canRetry }
            return false
        }
    }

    private struct Outgoing {
        let clientId: String
        let text: String?
        let itemIds: [String]
        var status: RoomMediaOutgoingRow.Status
        let progress = RoomMediaProgress()
        var postTask: Task<Void, Never>?

        var canRetry: Bool {
            if case .failed(_, let canRetry) = status { return canRetry }
            return false
        }
    }

    private let sessionId: String
    private let uploader: (any RoomMediaUploading)?
    private let preparer: any RoomMediaPreparing
    private let keepAlive: any RoomMediaKeepingAlive
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let makeId: () -> String
    private let discard: (RoomMediaSource) -> Void
    private var items: [String: Item] = [:]
    private var tray: [String] = []
    private var outgoing: [Outgoing] = []
    private var keepAliveToken: Int?

    init(
        sessionId: String,
        uploader: (any RoomMediaUploading)?,
        preparer: any RoomMediaPreparing = RoomMediaPreparer(),
        keepAlive: any RoomMediaKeepingAlive = RoomMediaBackgroundTask(),
        canUseCamera: Bool = false,
        canPaste: @escaping () -> Bool = { false },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        makeId: @escaping () -> String = RoomMediaUploadCoordinator.newClientAttachmentId,
        discard: @escaping (RoomMediaSource) -> Void = { RoomMediaFiles.discard($0) }
    ) {
        self.sessionId = sessionId
        self.uploader = uploader
        self.preparer = preparer
        self.keepAlive = keepAlive
        self.sleep = sleep
        self.makeId = makeId
        self.discard = discard
        self.board = RoomMediaBoard(perMessageLimit: RoomMediaRules.attachmentsPerMessage, canUseCamera: canUseCamera,
                                    canPaste: canPaste)
        board.perform = { [weak self] intent in self?.perform(intent) }
    }

    /// Whether this room can take files from this phone.
    var canUpload: Bool { uploader != nil }

    /// One coordinator per room for as long as the app runs: leaving the room never drops a message on its way, and
    /// coming back shows it still uploading.
    private static var rooms: [String: RoomMediaUploadCoordinator] = [:]

    static func forRoom(_ sessionId: String, make: () -> RoomMediaUploadCoordinator) -> RoomMediaUploadCoordinator {
        if let existing = rooms[sessionId] { return existing }
        let created = make()
        rooms[sessionId] = created
        return created
    }

    /// Signing out: every upload stops, the outbox empties and the kept previews go, so whoever signs in next sees
    /// none of it.
    static func forgetAll() {
        for room in rooms.values { room.stopAll() }
        rooms = [:]
        try? FileManager.default.removeItem(at: RoomMediaFiles.outbox)
        RoomMediaPreviewDiskCache.shared.removeAll()
    }

    private func stopAll() {
        for item in items.values { item.task?.cancel() }
        for message in outgoing { message.postTask?.cancel() }
        items = [:]
        tray = []
        outgoing = []
        publish()
    }

    nonisolated static func newClientAttachmentId() -> String {
        "pm_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
    }

    func perform(_ intent: RoomMediaIntent) {
        switch intent {
        case .choose(let source):
            pickers.source = source
        case .remove(let itemId):
            removeFromTray(itemId)
        case .retryItem(let itemId):
            retryItem(itemId)
        case .send(let text):
            send(text: text)
        case .retry(let clientId):
            retry(clientId)
        case .cancel(let clientId):
            cancel(clientId)
        case .dismissNotice:
            board.setNotice(nil)
        }
    }

    // MARK: - Adding

    /// Files picked for the next message. Each is checked at once (type, size, how many), shows in the tray, and
    /// starts uploading.
    func add(_ sources: [RoomMediaSource]) {
        var refusals: [String] = []
        for source in sources {
            guard tray.count < RoomMediaRules.attachmentsPerMessage else {
                refusals.append(RoomMediaRefusal.tooMany(limit: RoomMediaRules.attachmentsPerMessage).message)
                discard(source)
                continue
            }
            let size = (try? RoomMediaFiles.size(of: source.file)) ?? 0
            let kind = Self.kind(of: source.file)
            if let refusal = Self.earlyRefusal(source, size: size, kind: kind) {
                refusals.append(refusal.message)
                discard(source)
                continue
            }
            let item = Item(id: makeId(), source: source, kind: kind, sizeBytes: size)
            items[item.id] = item
            tray.append(item.id)
            start(item)
        }
        board.setNotice(Self.notice(refusals))
        publish()
    }

    /// Something picked that could not be added (a picker that could not read a file).
    func refuse(_ refusal: RoomMediaRefusal) {
        board.setNotice(refusal.message)
    }

    /// Refused before anything is done: a type the room never takes, an empty file, or one too large. Photos the phone
    /// converts (HEIC) are checked after converting.
    static func earlyRefusal(_ source: RoomMediaSource, size: Int64, kind: RoomMediaItemRow.Kind) -> RoomMediaRefusal? {
        let ext = (source.filename as NSString).pathExtension
        if RoomMediaRules.type(forExtension: ext) == nil, kind != .image {
            return .unsupported(filename: source.filename)
        }
        if size <= 0 { return .empty(filename: source.filename) }
        if RoomMediaRules.type(forExtension: ext) != nil, case .failure(let refusal) =
            RoomMediaRules.check(filename: source.filename, sizeBytes: size) {
            return refusal
        }
        // A photo the phone converts is never smaller than a few bytes nor, re-encoded, much larger: anything over
        // twice the photo limit cannot fit.
        if kind == .image, size > RoomMediaRules.imageMaximumBytes * 2 {
            return .tooLarge(filename: source.filename, sizeBytes: size,
                             type: RoomMediaType(kind: .image, contentType: "image/jpeg", fileExtension: "jpg"))
        }
        return nil
    }

    private static func notice(_ refusals: [String]) -> String? {
        guard let first = refusals.first else { return nil }
        return refusals.count == 1 ? first : "\(first) (\(refusals.count - 1) more not added.)"
    }

    static func kind(of file: URL) -> RoomMediaItemRow.Kind {
        switch RoomMediaFiles.kind(of: file) {
        case .image: return .image
        case .video: return .video
        case .file: return .file
        }
    }

    // MARK: - Uploading

    private func start(_ item: Item) {
        item.task?.cancel()
        item.phase = item.prepared == nil ? .preparing : .uploading
        item.task = Task { [weak self] in await self?.run(item.id) }
        updateKeepAlive()
    }

    private func run(_ id: String) async {
        guard let item = items[id] else { return }
        do {
            if item.thumbnail == nil, item.kind != .file {
                item.thumbnail = await preparer.thumbnail(for: item.source)
                publish()
            }
            if item.prepared == nil {
                let prepared = try await preparer.prepare(item.source, thumbnail: item.thumbnail)
                try Task.checkCancellation()
                item.prepared = prepared
                item.filename = prepared.filename
                item.sizeBytes = prepared.sizeBytes
                item.progress.update(sent: 0, total: prepared.sizeBytes)
            }
            guard let prepared = item.prepared, let uploader else { throw RoomSendError.notConfigured }
            item.phase = .uploading
            publish()
            if item.stored == nil {
                // The client attachment id becomes the attachment's id: a retry is the same upload, never a second one.
                let answer = try await uploader.initUpload(sessionId: sessionId, request: RoomMediaInitRequest(
                    filename: prepared.filename, contentType: prepared.type.contentType, sizeBytes: prepared.sizeBytes,
                    sha256: prepared.sha256, clientAttachmentId: item.id
                ))
                let parentId = answer.attachment.attachmentId
                if let preview = prepared.preview, !item.previewDone {
                    item.previewDone = await sendPreview(preview, of: parentId, uploader: uploader)
                }
                if let target = answer.upload, !answer.attachment.isUploaded {
                    try await uploader.put(file: prepared.file, to: target) { [weak self] sent, total in
                        Task { @MainActor in self?.tick(id, sent: sent, total: total) }
                    }
                }
                try Task.checkCancellation()
                item.stored = try await uploader.completeUpload(sessionId: sessionId, attachmentId: parentId)
            }
            try Task.checkCancellation()
            item.progress.update(sent: prepared.sizeBytes, total: prepared.sizeBytes)
            item.phase = .uploaded
            if let thumbnail = item.thumbnail, let stored = item.stored {
                onPreviewReady?(stored.attachmentId, thumbnail)
            }
            updateMessageProgress()
            publish()
            postReadyMessages()
        } catch {
            guard items[id] === item, !Task.isCancelled, !(error is CancellationError) else { return }
            if let index = tray.firstIndex(of: id), let refusal = Self.refusal(for: error, filename: item.source.filename) {
                // Refused by the room's rules (too large once converted), or not a picture the phone could read: out of
                // the tray, with why.
                tray.remove(at: index)
                items[id] = nil
                discard(item.source)
                board.setNotice(refusal.message)
                publish()
                return
            }
            item.phase = .failed(reason: Self.reason(for: error), canRetry: Self.canRetry(error))
            publish()
            postReadyMessages()
        }
    }

    /// Why a file leaves the tray instead of waiting there for a retry that cannot help.
    private static func refusal(for error: Error, filename: String) -> RoomMediaRefusal? {
        if let refusal = error as? RoomMediaRefusal { return refusal }
        guard error is RoomMediaPreparationError else { return nil }
        return RoomMediaRules.type(forExtension: (filename as NSString).pathExtension) == nil
            ? .unsupported(filename: filename)
            : .unreadable(filename: filename)
    }

    /// Uploads the preview, linked to its file with `previewOf`. Best effort: the file goes either way, and a retry
    /// tries the preview again. An API that does not link previews would file it as a photo of its own, shown in the
    /// room, so its bytes are sent only once init says it is this file's preview.
    private func sendPreview(_ preview: RoomPreparedPreview, of parentId: String, uploader: any RoomMediaUploading) async -> Bool {
        do {
            let answer = try await uploader.initUpload(sessionId: sessionId, request: RoomMediaInitRequest(
                filename: preview.filename, contentType: "image/jpeg", sizeBytes: preview.sizeBytes, sha256: preview.sha256,
                clientAttachmentId: RoomMediaRules.previewClientId(for: parentId), previewOf: parentId
            ))
            guard answer.attachment.previewOf == parentId else { return true }
            if let target = answer.upload, !answer.attachment.isUploaded {
                try await uploader.put(file: preview.file, to: target) { _, _ in }
            }
            _ = try await uploader.completeUpload(sessionId: sessionId, attachmentId: answer.attachment.attachmentId)
            return true
        } catch {
            return false
        }
    }

    /// Bytes sent, shown at most ten times a second (and always the last).
    private func tick(_ id: String, sent: Int64, total: Int64) {
        guard let item = items[id], item.phase == .uploading else { return }
        let now = Date()
        guard sent >= total || now.timeIntervalSince(item.lastTick) >= Self.progressInterval else { return }
        item.lastTick = now
        item.progress.update(sent: sent, total: max(total, item.sizeBytes ?? 0))
        updateMessageProgress()
    }

    private func updateMessageProgress() {
        for message in outgoing {
            let parts = message.itemIds.compactMap { items[$0] }
            message.progress.update(sent: parts.reduce(0) { $0 + $1.progress.sentBytes },
                                    total: parts.reduce(0) { $0 + max($1.progress.totalBytes, $1.sizeBytes ?? 0) })
        }
    }

    private func retryItem(_ id: String) {
        guard let item = items[id], case .failed(_, true) = item.phase else { return }
        start(item)
        publish()
    }

    private func removeFromTray(_ id: String) {
        guard let index = tray.firstIndex(of: id), let item = items[id] else { return }
        tray.remove(at: index)
        drop(item)
        publish()
    }

    private func drop(_ item: Item) {
        item.task?.cancel()
        items[item.id] = nil
        discard(item.source)
    }

    // MARK: - Sending

    /// The tray becomes one message, shown at once; it posts once every file is stored.
    private func send(text: String) {
        guard !tray.isEmpty else { return }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = Outgoing(clientId: RoomChatCoordinator.makeClientId(), text: words.isEmpty ? nil : words,
                               itemIds: tray, status: .uploading)
        tray = []
        outgoing.append(message)
        for id in message.itemIds {
            if let item = items[id], case .failed(_, true) = item.phase { start(item) }
        }
        board.setNotice(nil)
        updateMessageProgress()
        publish()
        postReadyMessages()
    }

    /// Posts each message whose files are all stored; stops one whose file failed (it keeps its place, with Retry).
    private func postReadyMessages() {
        for index in outgoing.indices {
            let message = outgoing[index]
            // Only a message still uploading moves on: one posting, sent or stopped waits for its outcome or a retry.
            guard message.status == .uploading else { continue }
            let parts = message.itemIds.compactMap { items[$0] }
            if let failed = parts.first(where: { $0.isFailed }), case .failed(let reason, _) = failed.phase {
                outgoing[index].status = .failed(reason: reason, canRetry: parts.allSatisfy { !$0.isFailed || $0.canRetry })
                continue
            }
            guard parts.count == message.itemIds.count,
                  parts.allSatisfy({ $0.phase == .uploaded && $0.stored != nil }) else { continue }
            outgoing[index].status = .posting
            post(message.clientId)
        }
        publish()
    }

    private func post(_ clientId: String) {
        guard let uploader, let message = outgoing.first(where: { $0.clientId == clientId }) else { return }
        let parts = message.itemIds.compactMap { items[$0] }
        let references = parts.compactMap(\.stored)
        let text = message.text ?? RoomMediaOutgoingRow.defaultText(for: parts.map(\.kind))
        let sessionId = self.sessionId
        let task = Task { [weak self] in
            do {
                try await uploader.postMessage(sessionId: sessionId, text: text, attachments: references, clientId: clientId)
                guard let self else { return }
                self.setStatus(clientId, .sent)
                self.onPosted?()
                // The room shows it (`echoed`); if it never does, the card still goes.
                await self.sleep(Self.echoGrace)
                if self.outgoing.contains(where: { $0.clientId == clientId && $0.status == .sent }) { self.finish(clientId) }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.setStatus(clientId, .failed(reason: Self.reason(for: error), canRetry: Self.canRetry(error)))
            }
        }
        if let index = outgoing.firstIndex(where: { $0.clientId == clientId }) { outgoing[index].postTask = task }
    }

    private func setStatus(_ clientId: String, _ status: RoomMediaOutgoingRow.Status) {
        guard let index = outgoing.firstIndex(where: { $0.clientId == clientId }) else { return }
        outgoing[index].status = status
        publish()
    }

    /// Tries a stopped message again: its failed files with their same ids, then the message with its same client id.
    private func retry(_ clientId: String) {
        guard let index = outgoing.firstIndex(where: { $0.clientId == clientId }), outgoing[index].canRetry else { return }
        outgoing[index].status = .uploading
        for id in outgoing[index].itemIds {
            if let item = items[id], case .failed(_, true) = item.phase { start(item) }
        }
        publish()
        postReadyMessages()
    }

    /// Stops a message: its uploads end and its card goes. Nothing reaches the room.
    private func cancel(_ clientId: String) {
        guard let index = outgoing.firstIndex(where: { $0.clientId == clientId }) else { return }
        let message = outgoing.remove(at: index)
        message.postTask?.cancel()
        for id in message.itemIds { if let item = items[id] { drop(item) } }
        publish()
    }

    /// The room shows these messages now: their cards go, and their files leave the phone's outbox.
    func echoed(_ clientIds: Set<String>) {
        // Whatever the card says: the room can show a message before its post has answered.
        for message in outgoing where clientIds.contains(message.clientId) {
            finish(message.clientId)
        }
    }

    private func finish(_ clientId: String) {
        guard let index = outgoing.firstIndex(where: { $0.clientId == clientId }) else { return }
        let message = outgoing.remove(at: index)
        for id in message.itemIds { if let item = items[id] { drop(item) } }
        publish()
    }

    // MARK: - Showing

    private func publish() {
        board.setTray(tray.compactMap { items[$0].map(Self.row) })
        board.setOutgoing(outgoing.map { message in
            RoomMediaOutgoingRow(id: message.clientId, text: message.text,
                                 items: message.itemIds.compactMap { items[$0].map(Self.row) },
                                 status: message.status, progress: message.progress)
        })
        updateKeepAlive()
    }

    private static func row(_ item: Item) -> RoomMediaItemRow {
        RoomMediaItemRow(id: item.id, filename: item.filename, kind: item.kind, sizeBytes: item.sizeBytes,
                         thumbnail: item.thumbnail, phase: item.phase, progress: item.progress)
    }

    /// While anything uploads or posts, the app asks for time to finish in the background.
    private func updateKeepAlive() {
        let busy = items.values.contains { $0.phase == .preparing || $0.phase == .uploading }
            || outgoing.contains { $0.status == .posting }
        if busy, keepAliveToken == nil {
            keepAliveToken = keepAlive.begin()
        } else if !busy, let token = keepAliveToken {
            keepAliveToken = nil
            keepAlive.end(token)
        }
    }

    // MARK: - Errors

    static func reason(for error: Error) -> String {
        if let refusal = error as? RoomMediaRefusal { return refusal.message }
        if let upload = error as? RoomMediaUploadError, upload == .quotaFull {
            return "The room's storage is full. Ask its owner to make room, then try again."
        }
        if let send = error as? RoomSendError {
            switch send {
            case .notAllowed, .reauthenticationRequired, .notConfigured: return send.userMessage
            case .rejected: return "Senti did not accept this file."
            case .retryable: break
            }
        }
        if error is RoomMediaPreparationError { return "This file couldn't be read." }
        return "Not sent. Check your connection and retry."
    }

    static func canRetry(_ error: Error) -> Bool {
        if error is RoomMediaRefusal || error is RoomMediaPreparationError { return false }
        if let upload = error as? RoomMediaUploadError { return upload != .quotaFull }
        if let send = error as? RoomSendError {
            switch send {
            case .notAllowed, .notConfigured, .rejected: return false
            case .reauthenticationRequired, .retryable: return true
            }
        }
        return true
    }
}
