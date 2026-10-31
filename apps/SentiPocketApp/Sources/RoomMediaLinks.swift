import CryptoKit
import Foundation
import PocketSyncClient

/// Storage links, reused until five minutes before they expire. Opening a photo, playing a video or loading a preview
/// again within the hour asks the API nothing; a link that would expire mid-download is never handed out. A link the
/// API gives for minutes only (`expiresIn` 300, the older API) is never reused.
@MainActor
final class RoomMediaLinkCache {
    /// How long before its expiry a link stops being reused.
    static let margin: TimeInterval = 5 * 60
    static let capacity = 300

    private let now: () -> Date
    private var links: [String: (link: RoomAttachmentDownload, expiry: Date)] = [:]

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    func link(sessionId: String, attachmentId: String, asDownload: Bool = false,
              fetch: () async throws -> RoomAttachmentDownload) async throws -> RoomAttachmentDownload {
        let key = Self.key(sessionId: sessionId, attachmentId: attachmentId, asDownload: asDownload)
        if let cached = links[key], cached.expiry.addingTimeInterval(-Self.margin) > now() {
            return cached.link
        }
        let received = now()
        let link = try await fetch()
        let expiry = link.expiry(receivedAt: received)
        if expiry.addingTimeInterval(-Self.margin) > now() {
            links[key] = (link, expiry)
            if links.count > Self.capacity { prune() }
        }
        return link
    }

    /// Storage refused a link (it expired early, or was revoked): the next open asks for a new one.
    func forget(sessionId: String, attachmentId: String) {
        links[Self.key(sessionId: sessionId, attachmentId: attachmentId, asDownload: false)] = nil
        links[Self.key(sessionId: sessionId, attachmentId: attachmentId, asDownload: true)] = nil
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(Self.margin)
        links = links.filter { $0.value.expiry > cutoff }
        while links.count > Self.capacity, let soonest = links.min(by: { $0.value.expiry < $1.value.expiry })?.key {
            links[soonest] = nil
        }
    }

    private static func key(sessionId: String, attachmentId: String, asDownload: Bool) -> String {
        "\(sessionId)/\(attachmentId)/\(asDownload ? "download" : "inline")"
    }
}

/// Previews kept on the phone. An attachment's bytes never change (they are bound to their SHA-256), so a preview read
/// once is good for as long as it is kept; the oldest go past a few hundred.
protocol RoomMediaPreviewStoring: Sendable {
    func data(for key: String) -> Data?
    func store(_ data: Data, for key: String)
}

final class RoomMediaPreviewDiskCache: RoomMediaPreviewStoring, @unchecked Sendable {
    static let shared = RoomMediaPreviewDiskCache(
        folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("room-media-previews", isDirectory: true)
    )

    private let folder: URL
    private let capacity: Int
    private let lock = NSLock()
    private var storesSinceTrim = 0

    init(folder: URL, capacity: Int = 400) {
        self.folder = folder
        self.capacity = capacity
    }

    /// The preview for `sessionId/attachmentId`, by a hash of that key: no name from the room reaches the disk.
    static func key(sessionId: String, attachmentId: String) -> String { "\(sessionId)/\(attachmentId)" }

    private func file(for key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name + ".jpg")
    }

    func data(for key: String) -> Data? {
        try? Data(contentsOf: file(for: key))
    }

    func store(_ data: Data, for key: String) {
        guard !data.isEmpty, data.count <= 1_048_576 else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file(for: key), options: .atomic)
        lock.lock()
        storesSinceTrim += 1
        let trims = storesSinceTrim >= 25
        if trims { storesSinceTrim = 0 }
        lock.unlock()
        if trims { trim() }
    }

    /// Every kept preview goes (signing out).
    func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Keeps the newest `capacity` previews.
    func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys),
              files.count > capacity else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - capacity) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Previews in memory only: for tests and the DEBUG preview room.
final class RoomMediaPreviewMemoryStore: RoomMediaPreviewStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Data] = [:]

    func data(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored[key]
    }

    func store(_ data: Data, for key: String) {
        lock.lock()
        stored[key] = data
        lock.unlock()
    }
}
