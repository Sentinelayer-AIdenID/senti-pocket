import Foundation
#if canImport(Combine)
import Combine
#endif

/// Where a photo, video or file comes from.
public enum RoomAttachSource: String, CaseIterable, Identifiable, Sendable {
    case photos
    case camera
    case files
    case paste

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .photos: return "Photos & videos"
        case .camera: return "Camera"
        case .files: return "Files"
        case .paste: return "Paste image"
        }
    }

    public var detail: String {
        switch self {
        case .photos: return "Choose several at once"
        case .camera: return "Take a photo or a video"
        case .files: return "PDF, CSV, ZIP, text, code or video"
        case .paste: return "The image you copied"
        }
    }

    public var symbolName: String {
        switch self {
        case .photos: return "photo.on.rectangle.angled"
        case .camera: return "camera"
        case .files: return "folder"
        case .paste: return "doc.on.clipboard"
        }
    }
}

/// How far one upload has got, in bytes. Its own object, so a progress tick redraws only the ring or line that shows
/// it, never the room or the composer. Updated on the main thread.
public final class RoomMediaProgress: ObservableObject {
    @Published public private(set) var sentBytes: Int64
    @Published public private(set) var totalBytes: Int64

    public init(sentBytes: Int64 = 0, totalBytes: Int64 = 0) {
        self.sentBytes = sentBytes
        self.totalBytes = totalBytes
    }

    /// 0...1; 0 while the size is unknown.
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(sentBytes) / Double(totalBytes)))
    }

    /// "4.2 MB of 12.6 MB".
    public var text: String {
        "\(Self.size(sentBytes)) of \(Self.size(totalBytes))"
    }

    public func update(sent: Int64, total: Int64) {
        let total = max(0, total)
        let sent = min(max(0, sent), total)
        if sent != sentBytes { sentBytes = sent }
        if total != totalBytes { totalBytes = total }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}

/// One photo, video or file on its way to the room: in the composer's tray, then in its message until the room shows it.
public struct RoomMediaItemRow: Identifiable, Equatable {
    public enum Kind: Equatable, Sendable {
        case image
        case video
        case file
    }

    public enum Phase: Equatable, Sendable {
        /// Making its preview, removing location, hashing.
        case preparing
        case uploading
        case uploaded
        /// Ready, and uploaded when the message is sent (a Markdown or JSON file, which the room publishes as soon as
        /// it is uploaded).
        case ready
        case failed(reason: String, canRetry: Bool)
    }

    /// Its client attachment id: a retry sends the same one, so the room never gets it twice.
    public let id: String
    public var filename: String
    public var kind: Kind
    public var sizeBytes: Int64?
    /// A small JPEG made on the phone (at most 640 px), shown at once.
    public var thumbnail: Data?
    public var phase: Phase
    public let progress: RoomMediaProgress

    public init(id: String, filename: String, kind: Kind, sizeBytes: Int64? = nil, thumbnail: Data? = nil,
                phase: Phase = .preparing, progress: RoomMediaProgress) {
        self.id = id
        self.filename = filename
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.thumbnail = thumbnail
        self.phase = phase
        self.progress = progress
    }

    public static func == (lhs: RoomMediaItemRow, rhs: RoomMediaItemRow) -> Bool {
        lhs.id == rhs.id && lhs.filename == rhs.filename && lhs.kind == rhs.kind && lhs.sizeBytes == rhs.sizeBytes
            && lhs.thumbnail == rhs.thumbnail && lhs.phase == rhs.phase && lhs.progress === rhs.progress
    }

    public var kindLabel: String {
        switch kind {
        case .image: return "Photo"
        case .video: return "Video"
        case .file: return "File"
        }
    }

    public var symbolName: String {
        switch kind {
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .file: return "doc"
        }
    }

    public var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// "Photo, IMG_0042.jpg, uploading": what it is and where it has got.
    public var accessibilityLabel: String {
        let state: String
        switch phase {
        case .preparing: state = "getting ready"
        case .uploading: state = "uploading"
        case .uploaded: state = "uploaded"
        case .ready: state = "ready to send"
        case .failed(let reason, _): state = "not sent. \(reason)"
        }
        return "\(kindLabel), \(filename), \(state)"
    }
}

/// A message with photos, videos or files, from Send until the room shows it.
public struct RoomMediaOutgoingRow: Identifiable, Equatable {
    public enum Status: Equatable, Sendable {
        case uploading
        /// Every file is stored: the message itself is being posted.
        case posting
        case sent
        case failed(reason: String, canRetry: Bool)
    }

    /// The message's client id: a retry posts the same message, which the room de-duplicates.
    public let id: String
    /// What was typed with the files; nil when nothing was.
    public var text: String?
    public var items: [RoomMediaItemRow]
    public var status: Status
    /// All of its files' bytes together.
    public let progress: RoomMediaProgress

    public init(id: String, text: String?, items: [RoomMediaItemRow], status: Status = .uploading, progress: RoomMediaProgress) {
        self.id = id
        self.text = text
        self.items = items
        self.status = status
        self.progress = progress
    }

    public static func == (lhs: RoomMediaOutgoingRow, rhs: RoomMediaOutgoingRow) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.items == rhs.items && lhs.status == rhs.status
            && lhs.progress === rhs.progress
    }

    public var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    public var canRetry: Bool {
        if case .failed(_, let canRetry) = status { return canRetry }
        return false
    }

    /// "Uploading", "Uploaded 1 of 3", "Sending…", or why it stopped.
    public var statusText: String {
        switch status {
        case .uploading:
            let done = items.filter { $0.phase == .uploaded }.count
            return items.count == 1 || done == 0 ? "Uploading" : "Uploaded \(done) of \(items.count)"
        case .posting: return "Sending…"
        case .sent: return "Sent"
        case .failed(let reason, _): return reason
        }
    }

    /// The words a message with only files carries (the API needs some): "Shared a photo.", "Shared 3 files."
    public static func defaultText(for kinds: [RoomMediaItemRow.Kind]) -> String {
        guard let first = kinds.first else { return "Shared a file." }
        let same = kinds.allSatisfy { $0 == first }
        let noun: (singular: String, plural: String)
        switch (same, first) {
        case (true, .image): noun = ("a photo", "photos")
        case (true, .video): noun = ("a video", "videos")
        default: noun = ("a file", "files")
        }
        return kinds.count == 1 ? "Shared \(noun.singular)." : "Shared \(kinds.count) \(noun.plural)."
    }
}

/// What the person does with media in the room.
public enum RoomMediaIntent: Equatable, Sendable {
    case choose(RoomAttachSource)
    /// Takes a file out of the tray (stopping its upload).
    case remove(itemId: String)
    /// Tries a file in the tray again.
    case retryItem(itemId: String)
    /// Sends the tray as one message, with what was typed.
    case send(text: String)
    case retry(clientId: String)
    case cancel(clientId: String)
    case dismissNotice
}

/// The room's photos, videos and files on their way: the composer's tray and the messages being sent. The app's media
/// coordinator writes it; the tray, the send button and the outgoing cards read it. Progress ticks never pass through
/// here (see `RoomMediaProgress`), so the board changes only when a file is added, finishes or fails.
@MainActor
public final class RoomMediaBoard: ObservableObject {
    @Published public private(set) var tray: [RoomMediaItemRow] = []
    @Published public private(set) var outgoing: [RoomMediaOutgoingRow] = []
    /// Why something picked was not added (too large, a type the room does not take), said once.
    @Published public private(set) var notice: String?
    /// How many files one message carries.
    public let perMessageLimit: Int
    /// This device has a camera.
    public let canUseCamera: Bool
    /// Whether the clipboard holds an image, asked when the attach sheet opens (never reads it).
    public var canPaste: () -> Bool
    public var perform: (RoomMediaIntent) -> Void
    /// The room on screen, told when a message is sent with files (it scrolls to it).
    var onNewOutgoing: (() -> Void)?

    public init(perMessageLimit: Int = 5, canUseCamera: Bool = false, canPaste: @escaping () -> Bool = { false },
                perform: @escaping (RoomMediaIntent) -> Void = { _ in }) {
        self.perMessageLimit = perMessageLimit
        self.canUseCamera = canUseCamera
        self.canPaste = canPaste
        self.perform = perform
    }

    public var remainingSlots: Int { max(0, perMessageLimit - tray.count) }

    public func setTray(_ rows: [RoomMediaItemRow]) {
        if rows != tray { tray = rows }
    }

    public func setOutgoing(_ rows: [RoomMediaOutgoingRow]) {
        let sent = rows.count > outgoing.count
        if rows != outgoing { outgoing = rows }
        if sent { onNewOutgoing?() }
    }

    public func setNotice(_ text: String?) {
        if text != notice { notice = text }
    }
}
