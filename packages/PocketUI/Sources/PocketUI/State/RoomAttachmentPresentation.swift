import Foundation

/// A file attached to a message, as the room shows it.
public struct RoomAttachmentChip: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case markdown
        case json
        case image
        case pdf
        case video
        case other
    }

    public var id: String { attachmentId }
    public let attachmentId: String
    public let filename: String
    public let kind: Kind
    public let sizeBytes: Int64?
    public let summary: String?
    /// The API's processing state (waiting_upload, pending, processing, retry, ready, dead_letter).
    public let processingStatus: String?
    /// Taken back after it was sent: only its name shows, with "Attachment removed", and nothing opens it.
    public let isRemoved: Bool

    public init(
        attachmentId: String,
        filename: String,
        kind: Kind,
        sizeBytes: Int64? = nil,
        summary: String? = nil,
        processingStatus: String? = nil,
        isRemoved: Bool = false
    ) {
        self.attachmentId = attachmentId
        self.filename = filename
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.summary = summary
        self.processingStatus = processingStatus
        self.isRemoved = isRemoved
    }

    public var kindLabel: String {
        switch kind {
        case .markdown: return "Markdown"
        case .json: return "JSON"
        case .image: return "Image"
        case .pdf: return "PDF"
        case .video: return "Video"
        case .other: return "File"
        }
    }

    public var symbolName: String {
        switch kind {
        case .markdown: return "doc.richtext"
        case .json: return "curlybraces"
        case .image: return "photo"
        case .pdf: return "doc.text"
        case .video: return "play.rectangle"
        case .other: return "doc"
        }
    }

    /// Shown as a picture (a photo, or a video's poster frame), not as a file card. A removed one never is.
    public var isVisual: Bool { !isRemoved && (kind == .image || kind == .video) }

    /// What VoiceOver says: the kind, the name and the size, then what a tap does; or that it was removed.
    public var accessibilityLabel: String {
        if isRemoved { return [kind == .image ? "Photo" : kindLabel, filename, Self.removedLabel].joined(separator: ", ") }
        return [kind == .image ? "Photo" : kindLabel, filename, sizeLabel, statusLabel].compactMap { $0 }.joined(separator: ", ")
    }

    /// What a removed attachment says under its name.
    public static let removedLabel = "Attachment removed"

    public var accessibilityHint: String {
        switch kind {
        case .image: return "Opens it full size"
        case .video: return "Plays it"
        default: return "Opens it"
        }
    }

    /// "820 KB", "1.2 MB"; nil when the size is unknown.
    public var sizeLabel: String? {
        guard let sizeBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// Said only when the file is not ready: "Processing…" while the API works on it, "Couldn't process" when it
    /// gave up (`dead_letter`, the API's terminal state). Ready or unknown says nothing.
    public var statusLabel: String? {
        switch processingStatus {
        case "waiting_upload", "pending", "processing", "retry": return "Processing…"
        case "dead_letter": return "Couldn't process"
        default: return nil
        }
    }
}

/// How a message's files line up (Carter, ticket 3b458212: "smaller and side by side horizontal with scrollers for large
/// numbers"): two or more photos as one strip of thumbnails, where the first photo was; one photo, videos, removed
/// files and other files one by one, as before.
public enum RoomAttachmentLayoutItem: Equatable, Identifiable, Sendable {
    case strip([RoomAttachmentChip])
    case single(RoomAttachmentChip)

    public var id: String {
        switch self {
        case .strip(let photos): return "strip-" + (photos.first?.id ?? "")
        case .single(let chip): return chip.id
        }
    }

    /// A photo that goes in a strip: an image, not removed.
    static func isStripPhoto(_ chip: RoomAttachmentChip) -> Bool { chip.kind == .image && !chip.isRemoved }

    public static func items(_ chips: [RoomAttachmentChip]) -> [RoomAttachmentLayoutItem] {
        let photos = chips.filter(isStripPhoto)
        guard photos.count >= 2 else { return chips.map { .single($0) } }
        var items: [RoomAttachmentLayoutItem] = []
        for chip in chips {
            if !isStripPhoto(chip) {
                items.append(.single(chip))
            } else if chip.id == photos.first?.id {
                items.append(.strip(photos))
            }
        }
        return items
    }

    /// What VoiceOver says for a photo in a strip: its name and its place, "beach.jpg, 2 of 3" (and its state, if any).
    public static func stripLabel(_ chip: RoomAttachmentChip, index: Int, count: Int) -> String {
        [chip.filename, "\(index + 1) of \(count)", chip.statusLabel].compactMap { $0 }.joined(separator: ", ")
    }
}
