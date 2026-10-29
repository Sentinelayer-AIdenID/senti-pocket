import Foundation

/// A file attached to a message, as the room shows it.
public struct RoomAttachmentChip: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case markdown
        case json
        case image
        case pdf
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

    public init(
        attachmentId: String,
        filename: String,
        kind: Kind,
        sizeBytes: Int64? = nil,
        summary: String? = nil,
        processingStatus: String? = nil
    ) {
        self.attachmentId = attachmentId
        self.filename = filename
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.summary = summary
        self.processingStatus = processingStatus
    }

    public var kindLabel: String {
        switch kind {
        case .markdown: return "Markdown"
        case .json: return "JSON"
        case .image: return "Image"
        case .pdf: return "PDF"
        case .other: return "File"
        }
    }

    public var symbolName: String {
        switch kind {
        case .markdown: return "doc.richtext"
        case .json: return "curlybraces"
        case .image: return "photo"
        case .pdf: return "doc.text"
        case .other: return "doc"
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
