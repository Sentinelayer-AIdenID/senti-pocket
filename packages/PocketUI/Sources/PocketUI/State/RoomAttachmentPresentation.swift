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

/// How a strip of photos sits in the width its row gives it (the row's real width, after its inset and quote bar).
/// When every photo fits at 96 pt or more, the photos fill the row, up to 120 pt each, and nothing scrolls (three
/// photos on an iPhone's 390-pt screen). When they do not, they stay up to 120 pt and scroll sideways, and the first
/// photo not wholly in sight shows at least 30 pt of itself, so it is plain there is more. The text size does not
/// change them.
public struct RoomStripMetrics: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// Every photo in sight, filling the row.
        case fit
        /// A sideways scroll.
        case scroll
    }

    public static let spacing: CGFloat = 8
    public static let largest: CGFloat = 120
    public static let smallest: CGFloat = 96
    /// How much of the next photo a scrolling strip shows, at least.
    public static let leastPeek: CGFloat = 30
    /// The room the scroll's indicator takes under the photos.
    public static let indicator: CGFloat = 8

    public let mode: Mode
    /// Each photo's side.
    public let side: CGFloat

    /// The strip's height: its photos, and the indicator's room when it scrolls.
    public var height: CGFloat { mode == .fit ? side : side + Self.indicator }

    public init(count: Int, width: CGFloat) {
        let count = max(count, 1)
        let gaps = Self.spacing * CGFloat(count - 1)
        let fitting = ((width - gaps) / CGFloat(count)).rounded(.down)
        if fitting >= Self.smallest {
            self.mode = .fit
            self.side = min(Self.largest, fitting)
            return
        }
        // The largest side, up to 120, at which the next photo shows at least 30 pt.
        var candidate = Self.largest
        while candidate > Self.smallest, Self.nextPhotoShows(side: candidate, width: width) < Self.leastPeek {
            candidate -= 1
        }
        self.mode = .scroll
        self.side = candidate
    }

    /// How much of the first photo not wholly in sight shows, at the start of a scrolling strip `width` wide.
    public static func nextPhotoShows(side: CGFloat, width: CGFloat) -> CGFloat {
        let pitch = side + spacing
        let whole = ((width + spacing) / pitch).rounded(.down)
        return max(0, min(side, width - whole * pitch))
    }

    /// The width a strip of `count` photos would like when nothing gives it one: up to three of them at 120 pt (a
    /// strip never asks for more than a phone's row).
    public static func idealWidth(count: Int) -> CGFloat {
        let shown = CGFloat(min(max(count, 1), 3))
        return shown * largest + (shown - 1) * spacing
    }
}
