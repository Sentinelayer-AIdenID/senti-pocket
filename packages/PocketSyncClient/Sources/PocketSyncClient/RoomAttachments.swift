import Foundation
import PocketContracts

// Message attachments, source-bound to sentinelayer-api attachment pointers (`session_relay_service.py`
// `_attachment_pointer`, routes `GET /sessions/{sid}/attachments/{aid}`). Events carry only bounded metadata:
// never file contents, storage keys or links. To open a file the phone asks the API for a short-lived download
// link, built from the room and attachment ids; the event's own `pointer` is never followed.

/// A file attached to a room message.
public struct RoomAttachment: Equatable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case markdown
        case json
        case image
        case pdf
        /// A video file (mp4 or mov): the API files it as a `file`, and its content type says video.
        case video
        case other
    }

    public var id: String { attachmentId }
    public let attachmentId: String
    public let filename: String
    public let kind: Kind
    public let contentType: String?
    public let sizeBytes: Int64?
    public let summary: String?
    /// waiting_upload, pending, processing, retry, ready or dead_letter (the API's processing states).
    public let summaryStatus: String?

    public init(
        attachmentId: String,
        filename: String,
        kind: Kind,
        contentType: String? = nil,
        sizeBytes: Int64? = nil,
        summary: String? = nil,
        summaryStatus: String? = nil
    ) {
        self.attachmentId = attachmentId
        self.filename = filename
        self.kind = kind
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.summary = summary
        self.summaryStatus = summaryStatus
    }

    init?(json: JSONValue) {
        guard let id = json["attachmentId"]?.stringValue, Self.isValidId(id) else { return nil }
        let rawName = (json["filename"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = String((rawName.isEmpty ? "attachment" : rawName).prefix(160))
        let contentType = json["contentType"]?.stringValue.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let summary = json["summary"]?.stringValue.flatMap { text -> String? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(900))
        }
        self.init(
            attachmentId: id,
            filename: filename,
            kind: Self.kind(declared: json["kind"]?.stringValue, contentType: contentType, filename: filename),
            contentType: contentType,
            sizeBytes: json["sizeBytes"]?.intValue.flatMap { $0 >= 0 ? $0 : nil },
            summary: summary,
            summaryStatus: json["summaryStatus"]?.stringValue
        )
    }

    /// Every attachment a message payload names, in order, once each (`attachments` then the single
    /// `attachment` an upload event carries).
    static func list(from payload: JSONValue) -> [RoomAttachment] {
        var rows = payload["attachments"]?.arrayValue ?? []
        if let single = payload["attachment"], single.objectValue != nil { rows.append(single) }
        var seen = Set<String>()
        return rows.prefix(16).compactMap(RoomAttachment.init(json:)).filter { seen.insert($0.attachmentId).inserted }
    }

    /// The content type decides how a file is shown; the declared kind and the extension are fallbacks.
    static func kind(declared: String?, contentType: String?, filename: String) -> Kind {
        if let type = contentType {
            if type.hasPrefix("image/") { return .image }
            if type.hasPrefix("video/") { return .video }
            if type == "application/pdf" { return .pdf }
            if type == "application/json" || type == "text/json" { return .json }
            if type == "text/markdown" || type == "text/x-markdown" { return .markdown }
        }
        if let declared, let kind = Kind(rawValue: declared.lowercased()), kind != .other { return kind }
        switch (filename as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return .image
        case "pdf": return .pdf
        case "mp4", "mov", "m4v": return .video
        case "md", "markdown": return .markdown
        case "json": return .json
        default: return .other
        }
    }

    static func isValidId(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9._:-]{1,128}$"#, options: .regularExpression) != nil && !id.contains("..")
    }
}

/// A short-lived link to an attachment's bytes, and to its small preview when it has one. It needs no Authorization
/// header. It may be reused until a few minutes before it expires (`RoomMediaLinkCache`), never after.
public struct RoomAttachmentDownload: Decodable, Equatable, Sendable {
    public let url: URL
    public let expiresIn: Int
    /// When the link stops working (the API's `expiresAt`, ISO 8601 UTC); nil from an API that only says `expiresIn`.
    public let expiresAt: Date?
    /// The preview image (at most 640 px, 512 KiB; a poster frame for a video), when one was uploaded.
    public let previewURL: URL?
    public let previewContentType: String?

    enum CodingKeys: String, CodingKey { case download }
    enum DownloadKeys: String, CodingKey { case url, expiresIn, expiresAt, previewUrl, previewContentType }

    public init(url: URL, expiresIn: Int, expiresAt: Date? = nil, previewURL: URL? = nil, previewContentType: String? = nil) {
        self.url = url
        self.expiresIn = expiresIn
        self.expiresAt = expiresAt
        self.previewURL = previewURL
        self.previewContentType = previewContentType
    }

    public init(from decoder: Decoder) throws {
        // The link sits under `download`; a flatter answer (`url` at the top) is read the same way.
        let root = try decoder.container(keyedBy: CodingKeys.self)
        let download = root.contains(.download)
            ? try root.nestedContainer(keyedBy: DownloadKeys.self, forKey: .download)
            : try decoder.container(keyedBy: DownloadKeys.self)
        let raw = try download.decode(String.self, forKey: .url)
        // Only an https link is ever opened.
        guard let url = Self.httpsURL(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: download, debugDescription: "not an https link")
        }
        self.url = url
        self.expiresIn = (try? download.decode(Int.self, forKey: .expiresIn)) ?? 300
        self.expiresAt = (try? download.decode(String.self, forKey: .expiresAt)).flatMap(Self.date)
        // A preview that is not an https link is ignored; the file itself still opens.
        self.previewURL = (try? download.decode(String.self, forKey: .previewUrl)).flatMap(Self.httpsURL)
        self.previewContentType = previewURL == nil ? nil : (try? download.decode(String.self, forKey: .previewContentType))
    }

    /// When the link stops working: `expiresAt`, else `expiresIn` from when it was received.
    public func expiry(receivedAt: Date) -> Date {
        expiresAt ?? receivedAt.addingTimeInterval(TimeInterval(expiresIn))
    }

    static func httpsURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

extension HTTPSessionTransport {
    public func attachmentDownload(sessionId: String, attachmentId: String) async throws -> RoomAttachmentDownload {
        try await attachmentDownload(sessionId: sessionId, attachmentId: attachmentId, asDownload: false)
    }

    /// `asDownload` asks for the file as a download with a safe name (`?download=true`), for saving and sharing;
    /// otherwise images and videos come inline, so a player can stream them.
    public func attachmentDownload(sessionId: String, attachmentId: String, asDownload: Bool) async throws -> RoomAttachmentDownload {
        guard SessionIdentifier.isValid(sessionId), RoomAttachment.isValidId(attachmentId) else {
            throw SessionTransportError.invalidRequest
        }
        return try await getDecodable(
            RoomAttachmentDownload.self,
            path: ["api", "v1", "sessions", sessionId, "attachments", attachmentId],
            query: asDownload ? [URLQueryItem(name: "download", value: "true")] : []
        )
    }
}
