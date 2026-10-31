import Foundation
import PocketContracts

// Photos, videos and files sent from the phone, bound to the API's room media kinds and its session attachment
// routes: init (`POST .../attachments/init`), a presigned PUT straight to storage, complete
// (`POST .../attachments/{id}/complete`), then the message that names the attachments. The bytes never pass through
// the API, and the PUT never carries the user's token.

/// How the API files an upload: `image` and `file` are the media kinds; Markdown and JSON are the original text kinds.
public enum RoomMediaKind: String, Equatable, Sendable {
    case image
    case file
    case markdown
    case json
}

/// A file type a room accepts: its kind, the media type init declares, and the byte limit for it.
public struct RoomMediaType: Equatable, Sendable {
    public let kind: RoomMediaKind
    /// The canonical media type: what init declares, and what the PUT is signed for.
    public let contentType: String
    /// The extension the file is sent with, lowercased.
    public let fileExtension: String

    public init(kind: RoomMediaKind, contentType: String, fileExtension: String) {
        self.kind = kind
        self.contentType = contentType
        self.fileExtension = fileExtension
    }

    public var isVideo: Bool { contentType.hasPrefix("video/") }

    public var maximumBytes: Int64 {
        switch kind {
        case .image: return RoomMediaRules.imageMaximumBytes
        case .file: return RoomMediaRules.fileMaximumBytes
        case .markdown, .json: return RoomMediaRules.textMaximumBytes
        }
    }
}

/// Why a file cannot be sent, in words for the person who picked it.
public enum RoomMediaRefusal: Error, Equatable, Sendable {
    case unsupported(filename: String)
    case tooLarge(filename: String, sizeBytes: Int64, type: RoomMediaType)
    case empty(filename: String)
    case tooMany(limit: Int)
    case unreadable(filename: String)
    /// A video whose location could not be removed: it is never sent with it.
    case locationRemains(filename: String)

    public var message: String {
        switch self {
        case .unsupported(let name):
            return "\u{201C}\(name)\u{201D} can't be sent. Rooms take photos (PNG, JPEG, WebP, GIF), videos (MP4, MOV), "
                + "PDF, CSV, ZIP, text and code files."
        case .tooLarge(let name, let size, let type):
            let limit: String
            switch type.kind {
            case .image: limit = "Photos can be up to 50 MB."
            case .file: limit = type.isVideo
                ? "Videos can be up to 250 MB. Trim it in Photos, then try again."
                : "Files can be up to 250 MB."
            case .markdown, .json: limit = "Markdown and JSON files can be up to 256 KB."
            }
            return "\u{201C}\(name)\u{201D} is \(RoomMediaRules.sizeText(size)). \(limit)"
        case .empty(let name):
            return "\u{201C}\(name)\u{201D} is empty."
        case .tooMany(let limit):
            return "A message can carry up to \(limit) files. Send these, then add more."
        case .unreadable(let name):
            return "\u{201C}\(name)\u{201D} couldn't be read. Try choosing it again."
        case .locationRemains(let name):
            return "\u{201C}\(name)\u{201D} wasn't added: Pocket couldn't remove where it was taken."
        }
    }
}

public enum RoomMediaRules {
    /// 50 MiB, the API's photo limit.
    public static let imageMaximumBytes: Int64 = 52_428_800
    /// 250 MiB, the API's file limit (videos are files).
    public static let fileMaximumBytes: Int64 = 262_144_000
    /// 256 KiB, the original Markdown/JSON limit.
    public static let textMaximumBytes: Int64 = 262_144
    /// A preview image: at most 512 KiB (the API's preview limit) and 640 px on its longest side.
    public static let previewMaximumBytes = 524_288
    public static let previewMaximumPixels = 640
    /// How many attachments the API lets one message name.
    public static let attachmentsPerMessage = 5

    /// Plain-text and source files: stored and served as text/plain.
    static let textExtensions: Set<String> = [
        "txt", "text", "log", "tsv",
        "py", "pyi", "js", "mjs", "cjs", "ts", "tsx", "jsx", "vue", "svelte",
        "java", "kt", "kts", "scala", "go", "rs", "rb", "php", "pl", "lua", "r", "dart",
        "c", "h", "cc", "cpp", "cxx", "hpp", "cs", "swift",
        "sh", "bash", "zsh", "ps1",
        "sql", "graphql", "gql", "proto", "tf",
        "yaml", "yml", "toml", "ini", "cfg", "conf",
        "xml", "html", "htm", "css", "scss",
        "diff", "patch", "tex"
    ]

    /// The type a room files under this extension, or nil when rooms do not take it.
    public static func type(forExtension raw: String) -> RoomMediaType? {
        let ext = raw.lowercased()
        func image(_ type: String) -> RoomMediaType { RoomMediaType(kind: .image, contentType: type, fileExtension: ext) }
        func file(_ type: String) -> RoomMediaType { RoomMediaType(kind: .file, contentType: type, fileExtension: ext) }
        switch ext {
        case "png": return image("image/png")
        case "jpg", "jpeg": return image("image/jpeg")
        case "webp": return image("image/webp")
        case "gif": return image("image/gif")
        case "pdf": return file("application/pdf")
        case "zip": return file("application/zip")
        case "mp4": return file("video/mp4")
        case "mov": return file("video/quicktime")
        case "csv": return file("text/csv")
        case "md", "markdown": return RoomMediaType(kind: .markdown, contentType: "text/markdown", fileExtension: ext)
        case "json": return RoomMediaType(kind: .json, contentType: "application/json", fileExtension: ext)
        default: return textExtensions.contains(ext) ? file("text/plain") : nil
        }
    }

    /// Whether a file of this name and size can be sent, and as what.
    public static func check(filename: String, sizeBytes: Int64) -> Result<RoomMediaType, RoomMediaRefusal> {
        guard let type = type(forExtension: (filename as NSString).pathExtension) else {
            return .failure(.unsupported(filename: filename))
        }
        guard sizeBytes > 0 else { return .failure(.empty(filename: filename)) }
        guard sizeBytes <= type.maximumBytes else {
            return .failure(.tooLarge(filename: filename, sizeBytes: sizeBytes, type: type))
        }
        return .success(type)
    }

    /// "4.2 MB": sizes as the limits are written (1 MB = 1,048,576 bytes, like the API's MiB).
    public static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    /// The API's attachment id alphabet (`^[A-Za-z0-9._:-]{8,120}$`, never `..`). A client attachment id becomes the
    /// attachment's id, so a retry with the same one is the same upload.
    public static func isValidClientId(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9._:-]{8,120}$"#, options: .regularExpression) != nil && !id.contains("..")
    }

    /// The preview's own client id, derived from its parent's: a retry names the same preview.
    public static func previewClientId(for parentId: String) -> String { parentId + ".pv" }

    /// A file name the API keeps as written: its alphabet, no leading dots, at most 160 characters with the extension.
    public static func safeFilename(_ name: String, fileExtension: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._ -")
        let base = ((name as NSString).deletingPathExtension as String)
        var cleaned = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { cleaned = "attachment" }
        let ext = fileExtension.lowercased()
        guard !ext.isEmpty else { return String(cleaned.prefix(160)) }
        return String(cleaned.prefix(max(1, 159 - ext.count))) + "." + ext
    }
}

/// Where and how to PUT the bytes: exactly the headers init returned, and never an Authorization header.
public struct RoomMediaUploadTarget: Equatable, Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]

    public init(url: URL, method: String = "PUT", headers: [String: String]) {
        self.url = url
        self.method = method
        self.headers = headers
    }
}

/// An attachment as the API returns it from init and complete, and as a message names it.
public struct RoomMediaAttachment: Equatable, Sendable {
    public let attachmentId: String
    public let filename: String
    public let kind: String?
    public let contentType: String?
    public let sizeBytes: Int64?
    public let sha256: String?
    public let status: String?
    /// For a preview, the attachment it previews (the API echoes `previewOf`).
    public let previewOf: String?

    public init(attachmentId: String, filename: String, kind: String? = nil, contentType: String? = nil,
                sizeBytes: Int64? = nil, sha256: String? = nil, status: String? = nil, previewOf: String? = nil) {
        self.attachmentId = attachmentId
        self.filename = filename
        self.kind = kind
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.status = status
        self.previewOf = previewOf
    }

    init?(json: JSONValue?) {
        guard let json, let id = json["attachmentId"]?.stringValue, RoomMediaRules.isValidClientId(id) else { return nil }
        self.init(
            attachmentId: id,
            filename: json["filename"]?.stringValue ?? "attachment",
            kind: json["kind"]?.stringValue,
            contentType: json["contentType"]?.stringValue,
            sizeBytes: json["sizeBytes"]?.intValue,
            sha256: json["sha256"]?.stringValue,
            status: json["status"]?.stringValue,
            previewOf: json["previewOf"]?.stringValue
        )
    }

    /// The reference a message carries (`SessionAttachmentReferencePayload`).
    public var reference: [String: Any] {
        var json: [String: Any] = ["attachmentId": attachmentId, "filename": filename]
        if let kind { json["kind"] = kind }
        if let contentType { json["contentType"] = contentType }
        if let sizeBytes { json["sizeBytes"] = sizeBytes }
        if let sha256 { json["sha256"] = sha256 }
        if let status { json["status"] = status }
        return json
    }

    public var isUploaded: Bool { status == "uploaded" }
}

/// What init asks for. The client attachment id becomes the attachment id, so a retry is the same upload.
public struct RoomMediaInitRequest: Equatable, Sendable {
    public let filename: String
    public let contentType: String
    public let sizeBytes: Int64
    /// 64 lowercase hex characters.
    public let sha256: String
    public let clientAttachmentId: String
    /// Set on a preview image: the attachment it previews.
    public let previewOf: String?

    public init(filename: String, contentType: String, sizeBytes: Int64, sha256: String, clientAttachmentId: String,
                previewOf: String? = nil) {
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.clientAttachmentId = clientAttachmentId
        self.previewOf = previewOf
    }

    public var body: [String: Any] {
        var json: [String: Any] = [
            "filename": filename,
            "contentType": contentType,
            "sizeBytes": sizeBytes,
            "sha256": sha256,
            "clientAttachmentId": clientAttachmentId
        ]
        if let previewOf { json["previewOf"] = previewOf }
        return json
    }
}

/// Init's answer: the attachment row, and where to PUT its bytes (none when they are already stored).
public struct RoomMediaInitAnswer: Equatable, Sendable {
    public let duplicate: Bool
    public let attachment: RoomMediaAttachment
    public let upload: RoomMediaUploadTarget?

    public init(duplicate: Bool = false, attachment: RoomMediaAttachment, upload: RoomMediaUploadTarget?) {
        self.duplicate = duplicate
        self.attachment = attachment
        self.upload = upload
    }

    /// `{ok, duplicate, attachment, upload: {url, method, headers, expiresIn} | null}`. Only an https PUT is accepted.
    public static func decode(_ data: Data) throws -> RoomMediaInitAnswer {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let attachment = RoomMediaAttachment(json: root["attachment"]) else { throw SessionTransportError.invalidResponse }
        var target: RoomMediaUploadTarget?
        if let upload = root["upload"], upload.objectValue != nil {
            guard let raw = upload["url"]?.stringValue, let url = URL(string: raw),
                  url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
                throw SessionTransportError.invalidResponse
            }
            var headers: [String: String] = [:]
            for (name, value) in upload["headers"]?.objectValue ?? [:] {
                guard let text = value.stringValue ?? value.intValue.map(String.init) else { continue }
                // The PUT goes to storage with its own signature: the user's credentials never ride along.
                guard !["authorization", "cookie", "host"].contains(name.lowercased()) else { continue }
                headers[name] = text
            }
            target = RoomMediaUploadTarget(url: url, method: upload["method"]?.stringValue ?? "PUT", headers: headers)
        }
        return RoomMediaInitAnswer(duplicate: root["duplicate"]?.boolValue ?? false, attachment: attachment, upload: target)
    }

    /// Complete's answer: `{ok, attachment, event, duplicate}`.
    public static func completed(_ data: Data) throws -> RoomMediaAttachment {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let attachment = RoomMediaAttachment(json: root["attachment"]) else { throw SessionTransportError.invalidResponse }
        return attachment
    }
}

/// Why the API refused an upload step, from its `{"error": {"code", "message"}}` body. It says whether trying again
/// can help and, for a storage limit (413), whose limit it is.
public struct RoomMediaAPIRefusal: Equatable, Sendable {
    public enum QuotaScope: Equatable, Sendable {
        /// The room's storage for photos and files is full.
        case room
        /// The room owner's storage, across their rooms, is full.
        case owner
        /// Too many of this person's uploads are unfinished in the owner's rooms; they free up as uploads finish.
        case uploader
        case unknown
    }

    public let status: Int
    public let code: String?
    public let message: String?

    public init(status: Int, code: String? = nil, message: String? = nil) {
        self.status = status
        self.code = code
        self.message = message
    }

    public init(status: Int, body: Data) {
        let root = try? JSONDecoder().decode(JSONValue.self, from: body)
        let error = root?["error"]
        self.init(status: status, code: error?["code"]?.stringValue, message: error?["message"]?.stringValue)
    }

    /// Whose storage limit a 413 names. The API says it in its message (and may say it as `scope`).
    public var quotaScope: QuotaScope? {
        guard status == 413 else { return nil }
        let text = (message ?? "").lowercased()
        if text.contains("your limit") || text.contains("unfinished") { return .uploader }
        if text.contains("room owner") { return .owner }
        if text.contains("room attachment") { return .room }
        return .unknown
    }

    /// Trying again with the same ids can help: storage verification (re-init gives a fresh link), an upload still
    /// landing, too many unfinished uploads, a busy or unavailable server.
    public var isRetryable: Bool {
        if code == "ATTACHMENT_VERIFICATION_FAILED" || code == "ATTACHMENT_UPLOAD_PENDING" { return true }
        // An unfinished upload the server let expire: init again (the same id) makes it anew.
        if status == 404, code?.hasPrefix("ATTACHMENT") == true { return true }
        if quotaScope == .uploader { return true }
        return [409, 425, 429].contains(status) || (500..<600).contains(status)
    }
}
