import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import PocketSyncClient
import UniformTypeIdentifiers

/// A photo, video or file picked for a room, already copied into the app's outbox folder (pickers hand out files that
/// disappear when their callback returns). Everything made from it is written beside it, in its own folder.
struct RoomMediaSource: Equatable, Sendable {
    let file: URL
    /// The name to send it under, with its extension.
    let filename: String

    var folder: URL { file.deletingLastPathComponent() }
}

/// A file as it will be stored: location removed from photos and videos, HEIC turned into JPEG, hashed, with its
/// preview.
struct RoomPreparedMedia: Equatable, Sendable {
    let file: URL
    let filename: String
    let type: RoomMediaType
    let sizeBytes: Int64
    /// Lowercase hex SHA-256 of `file`'s bytes, as init declares it.
    let sha256: String
    let preview: RoomPreparedPreview?
}

/// The preview uploaded with `previewOf`: a JPEG of at most 640 px and 512 KiB with no metadata at all.
struct RoomPreparedPreview: Equatable, Sendable {
    let file: URL
    let filename: String
    let sizeBytes: Int64
    let sha256: String
}

enum RoomMediaPreparationError: Error, Equatable {
    case unreadable
    /// A video's location could not be removed: it is not sent.
    case locationRemains
}

/// Turns a picked file into what is uploaded. A protocol so the upload coordinator is testable without ImageIO.
protocol RoomMediaPreparing: Sendable {
    /// A small JPEG to show at once: a photo's preview or a video's poster frame. Nil for other files.
    func thumbnail(for source: RoomMediaSource) async -> Data?
    /// The file to upload and its preview. `thumbnail` is the one already made, reused as the preview.
    func prepare(_ source: RoomMediaSource, thumbnail: Data?) async throws -> RoomPreparedMedia
}

/// The phone's own preparation: ImageIO for photos (never a full-size UIImage), AVFoundation for a video's poster and
/// its location, and a streamed SHA-256. Runs off the main thread. A photo's or video's original is deleted as soon
/// as its copy without location exists, so only that copy waits in the outbox.
struct RoomMediaPreparer: RoomMediaPreparing {
    func thumbnail(for source: RoomMediaSource) async -> Data? {
        let file = source.file
        switch RoomMediaFiles.kind(of: file) {
        case .image:
            return await Task.detached(priority: .userInitiated) { RoomMediaImages.preview(at: file) }.value
        case .video:
            guard let poster = await RoomMediaVideo.poster(at: file, maxPixels: RoomMediaRules.previewMaximumPixels) else {
                return nil
            }
            return RoomMediaImages.jpeg(poster, maxBytes: RoomMediaRules.previewMaximumBytes)
        case .file:
            return nil
        }
    }

    func prepare(_ source: RoomMediaSource, thumbnail: Data?) async throws -> RoomPreparedMedia {
        // A video is re-wrapped without its location first (AVFoundation is asynchronous); then the rest, off the main
        // thread.
        var video: URL?
        if RoomMediaFiles.kind(of: source.file) == .video {
            video = try await RoomMediaVideo.removingLocation(from: source.file, in: source.folder, baseName: "stored")
        }
        let stripped = video
        return try await Task.detached(priority: .userInitiated) {
            try Self.prepareNow(source, thumbnail: thumbnail, strippedVideo: stripped)
        }.value
    }

    static func prepareNow(_ source: RoomMediaSource, thumbnail: Data?, strippedVideo: URL? = nil) throws -> RoomPreparedMedia {
        var file = source.file
        let filename: String
        if RoomMediaFiles.kind(of: file) == .image {
            // Location never leaves the phone: the photo is rewritten without it before anything is hashed or sent.
            file = try RoomMediaImages.removingLocation(from: file, in: source.folder, baseName: "stored")
            filename = RoomMediaRules.safeFilename(source.filename, fileExtension: file.pathExtension)
        } else if let strippedVideo {
            file = strippedVideo
            filename = RoomMediaRules.safeFilename(source.filename, fileExtension: file.pathExtension)
        } else {
            filename = RoomMediaRules.safeFilename(source.filename, fileExtension: (source.filename as NSString).pathExtension)
        }
        if file != source.file {
            // Only the copy without location stays: the original, with whatever it says, goes now.
            try? FileManager.default.removeItem(at: source.file)
            RoomMediaFiles.protect(file)
        }
        let base = (filename as NSString).deletingPathExtension
        let size = try RoomMediaFiles.size(of: file)
        let type: RoomMediaType
        switch RoomMediaRules.check(filename: filename, sizeBytes: size) {
        case .success(let checked): type = checked
        case .failure(let refusal): throw refusal
        }
        let sha256 = try RoomMediaHashing.sha256(of: file)
        var preview: RoomPreparedPreview?
        if let data = thumbnail, data.count <= RoomMediaRules.previewMaximumBytes, type.kind == .image || type.isVideo {
            let previewFile = source.folder.appendingPathComponent("preview.jpg")
            try data.write(to: previewFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            preview = RoomPreparedPreview(
                file: previewFile,
                filename: RoomMediaRules.safeFilename(base + ".preview.jpg", fileExtension: "jpg"),
                sizeBytes: Int64(data.count),
                sha256: RoomMediaHashing.sha256(of: data)
            )
        }
        return RoomPreparedMedia(file: file, filename: filename, type: type, sizeBytes: size, sha256: sha256, preview: preview)
    }
}

enum RoomMediaFiles {
    enum Kind: Equatable { case image, video, file }

    /// What a file is, by its extension: a photo, a video, or any other file.
    static func kind(of url: URL) -> Kind {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return .file
    }

    static func size(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    /// The folder picked files are copied into, one folder per file; emptied as files are sent or discarded, and swept
    /// at launch (`RoomMediaOutbox.sweep`).
    static var outbox: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("room-media-outbox", isDirectory: true)
    }

    /// The outbox's data protection. Not `.complete`: the background upload reads the file while the phone may be
    /// locked, and a file under `.complete` cannot be read then, so the upload would stop when the phone locks. Until
    /// the phone is first unlocked after a restart, nothing can read it.
    static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    /// A new, empty folder for one picked file, under the outbox's protection (files made in it take it too).
    static func newFolder(in root: URL = outbox) throws -> URL {
        let attributes: [FileAttributeKey: Any] = [.protectionKey: protection]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: attributes)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: attributes)
        return folder
    }

    /// Puts a file copied or moved into the outbox under the outbox's protection.
    static func protect(_ file: URL) {
        try? FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: file.path)
    }

    /// Removes a picked file's folder, and only a folder inside the outbox.
    static func discard(_ source: RoomMediaSource, root: URL = outbox) {
        let folder = source.folder.standardizedFileURL
        guard folder.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}

enum RoomMediaHashing {
    /// SHA-256 of a file, read a megabyte at a time: a 250 MB video is never in memory at once.
    static func sha256(of url: URL, chunkBytes: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data = try autoreleasepool { try handle.read(upToCount: chunkBytes) ?? Data() }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Photos through ImageIO only. A photo is never decoded at full size into a UIImage: previews come from ImageIO's
/// thumbnail decoder, and location is removed by rewriting the file's metadata.
enum RoomMediaImages {
    /// The file is opened lazily and nothing is cached at full size.
    static let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]

    /// A thumbnail decoded straight from the file at `maxPixels` on its longest side, upright. ImageIO decodes only
    /// what that size needs (JPEG and HEIC decode subsampled), so the full image is never in memory.
    static func thumbnailOptions(maxPixels: Int) -> [CFString: Any] {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
    }

    static func thumbnail(at url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(maxPixels: maxPixels) as CFDictionary)
    }

    /// The qualities a preview steps down through until it fits its byte limit.
    static let previewQualities = [0.8, 0.7, 0.6, 0.5, 0.4, 0.3]

    /// JPEG bytes of a bare image (no EXIF, no GPS, nothing but pixels), the quality stepped down until it fits.
    static func jpeg(_ image: CGImage, maxBytes: Int) -> Data? {
        for quality in previewQualities {
            guard let data = jpeg(image, quality: quality) else { return nil }
            if data.count <= maxBytes { return data }
        }
        return nil
    }

    /// JPEG bytes of a bare image at one quality.
    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        encode(image, as: .jpeg, quality: quality)
    }

    /// A bare image's bytes: a CGImage carries no metadata, so none is written.
    static func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The preview: at most 640 px and 512 KiB, JPEG, no metadata.
    static func preview(at url: URL) -> Data? {
        guard let image = thumbnail(at: url, maxPixels: RoomMediaRules.previewMaximumPixels) else { return nil }
        return jpeg(image, maxBytes: RoomMediaRules.previewMaximumBytes)
    }

    /// The photo as the room will store it, without its location. JPEG and PNG keep their pixels exactly: only the
    /// metadata is rewritten, keeping the orientation (and a PNG that cannot be rewritten stays a PNG, so a screenshot's
    /// text stays sharp). GIF and WebP without metadata go as they are. Anything else (HEIC from the camera, or a GIF or
    /// WebP that carries metadata) becomes a JPEG re-encoded by ImageIO with its metadata dropped. The result is read
    /// back: if any location survived, the photo is re-encoded from pixels alone.
    static func removingLocation(from url: URL, in folder: URL, baseName: String) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier) else {
            throw RoomMediaPreparationError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var output: URL?
        if type.conforms(to: .jpeg) || type.conforms(to: .png) {
            let target = folder.appendingPathComponent("\(baseName).\(type.conforms(to: .png) ? "png" : "jpg")")
            if rewriteMetadata(source, typeIdentifier: typeIdentifier, orientation: properties[kCGImagePropertyOrientation],
                               to: target) {
                output = target
            }
        } else if type.conforms(to: .gif) || type.conforms(to: .webP),
                  carriesNoMetadata(properties, metadata: CGImageSourceCopyMetadataAtIndex(source, 0, nil)) {
            let target = folder.appendingPathComponent("\(baseName).\(type.conforms(to: .gif) ? "gif" : "webp")")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: url, to: target)
            output = target
        }
        // A PNG stays a PNG, and so does a GIF or WebP that had to be rewritten (they may be transparent).
        let keepsPNG = type.conforms(to: .png) || type.conforms(to: .gif) || type.conforms(to: .webP)
        if output == nil {
            let target = folder.appendingPathComponent("\(baseName).\(keepsPNG ? "png" : "jpg")")
            if reencode(source, as: keepsPNG ? .png : .jpeg, to: target) { output = target }
        }
        guard let written = output else { throw RoomMediaPreparationError.unreadable }
        if hasLocation(at: written) || !privateMetadata(at: written).isEmpty {
            // Belt and braces: pixels only, upright, nothing else.
            let target = folder.appendingPathComponent("\(baseName)-pixels.\(keepsPNG ? "png" : "jpg")")
            guard let pixelSize = pixelSize(properties), let image = thumbnail(at: url, maxPixels: pixelSize),
                  let data = encode(image, as: keepsPNG ? .png : .jpeg, quality: 0.9) else {
                throw RoomMediaPreparationError.unreadable
            }
            try data.write(to: target, options: .atomic)
            try? FileManager.default.removeItem(at: written)
            return target
        }
        return written
    }

    /// Rewrites a JPEG's or PNG's metadata without decoding it: an empty metadata set, GPS and XMP excluded, the
    /// orientation kept.
    private static func rewriteMetadata(_ source: CGImageSource, typeIdentifier: String, orientation: Any?, to target: URL) -> Bool {
        try? FileManager.default.removeItem(at: target)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, typeIdentifier as CFString, 1, nil) else {
            return false
        }
        var options: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true
        ]
        if let orientation { options[kCGImageDestinationOrientation] = orientation }
        return CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil)
    }

    /// Re-encodes through ImageIO with every metadata dictionary removed (the orientation is kept).
    private static func reencode(_ source: CGImageSource, as type: UTType, to target: URL) -> Bool {
        try? FileManager.default.removeItem(at: target)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, type.identifier as CFString, 1, nil) else {
            return false
        }
        let removed: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyGPSDictionary: kCFNull as Any,
            kCGImagePropertyExifDictionary: kCFNull as Any,
            kCGImagePropertyExifAuxDictionary: kCFNull as Any,
            kCGImagePropertyIPTCDictionary: kCFNull as Any,
            kCGImagePropertyTIFFDictionary: kCFNull as Any,
            kCGImagePropertyMakerAppleDictionary: kCFNull as Any
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, removed as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// A GIF or WebP that can go as it is: no EXIF, TIFF, GPS or IPTC dictionary, and no XMP at all (XMP can carry a
    /// location too).
    static func carriesNoMetadata(_ properties: [CFString: Any], metadata: CGImageMetadata?) -> Bool {
        let dictionaries = [kCGImagePropertyGPSDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                            kCGImagePropertyIPTCDictionary]
        guard !dictionaries.contains(where: { properties[$0] != nil }) else { return false }
        guard let metadata, let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return true }
        return tags.isEmpty
    }

    /// TIFF and EXIF fields that say who took a photo, when, or with what; maker notes; IPTC.
    static let privateTIFFKeys = ["Make", "Model", "Software", "DateTime", "Artist", "HostComputer", "Copyright",
                                  "ImageDescription"]
    static let privateExifKeys = ["DateTimeOriginal", "DateTimeDigitized", "SubsecTime", "SubsecTimeOriginal",
                                  "SubsecTimeDigitized", "OffsetTime", "OffsetTimeOriginal", "OffsetTimeDigitized",
                                  "LensMake", "LensModel", "LensSerialNumber", "LensSpecification", "BodySerialNumber",
                                  "CameraOwnerName", "UserComment", "MakerNote", "ImageUniqueID"]

    /// What a stored photo still says about its camera, owner or capture (empty when nothing): maker notes, make,
    /// model, software, lens, serials, capture times, IPTC. Location is `hasLocation`.
    static func privateMetadata(at url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [] }
        var found: [String] = []
        let makers = [kCGImagePropertyMakerAppleDictionary, kCGImagePropertyMakerCanonDictionary,
                      kCGImagePropertyMakerNikonDictionary, kCGImagePropertyMakerFujiDictionary,
                      kCGImagePropertyMakerOlympusDictionary, kCGImagePropertyMakerPentaxDictionary,
                      kCGImagePropertyMakerMinoltaDictionary]
        if makers.contains(where: { properties[$0] != nil }) { found.append("maker notes") }
        if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [String: Any], !iptc.isEmpty { found.append("IPTC") }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [String: Any] ?? [:]
        found += privateTIFFKeys.filter { tiff[$0] != nil }
        let exif = properties[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:]
        found += privateExifKeys.filter { exif[$0] != nil }
        return found
    }

    private static func pixelSize(_ properties: [CFString: Any]) -> Int? {
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let side = max(width, height)
        return side > 0 ? side : nil
    }

    /// Whether a photo still says where it was taken: a GPS dictionary, or GPS tags in its metadata.
    static func hasLocation(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return false }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty { return true }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return false }
        return CGImageMetadataCopyTagMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude) != nil
            || CGImageMetadataCopyTagMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude) != nil
    }
}

enum RoomMediaVideo {
    /// The video as it will be stored: re-wrapped without re-encoding (passthrough) and without the metadata that is not
    /// for sharing, location first (`AVMetadataItemFilter.forSharing()`). The moov box goes first, so it streams as
    /// soon as it starts arriving. Read back: if any location survived, the video is not sent.
    static func removingLocation(from url: URL, in folder: URL, baseName: String) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let isMP4 = url.pathExtension.lowercased() == "mp4" || url.pathExtension.lowercased() == "m4v"
        let target = folder.appendingPathComponent("\(baseName).\(isMP4 ? "mp4" : "mov")")
        try? FileManager.default.removeItem(at: target)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw RoomMediaPreparationError.unreadable
        }
        session.outputURL = target
        session.outputFileType = isMP4 ? .mp4 : .mov
        session.metadataItemFilter = .forSharing()
        session.shouldOptimizeForNetworkUse = true
        try await export(session)
        guard await !hasLocation(at: target) else {
            try? FileManager.default.removeItem(at: target)
            throw RoomMediaPreparationError.locationRemains
        }
        return target
    }

    private final class ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    private static func export(_ session: AVAssetExportSession) async throws {
        let box = ExportBox(session)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        try Task.checkCancellation()
        guard box.session.status == .completed else { throw RoomMediaPreparationError.unreadable }
    }

    /// Whether a video still says where it was taken: a location item in its metadata (any format) or a track's.
    static func hasLocation(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        var items = (try? await asset.load(.metadata)) ?? []
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            items += (try? await asset.loadMetadata(for: format)) ?? []
        }
        for track in (try? await asset.load(.tracks)) ?? [] {
            items += (try? await track.load(.metadata)) ?? []
        }
        return items.contains { item in
            if item.commonKey == .commonKeyLocation { return true }
            if item.identifier == .quickTimeUserDataLocationISO6709 { return true }
            return item.identifier?.rawValue.lowercased().contains("location") == true
        }
    }

    /// A video's poster frame, at most `maxPixels` on its longest side and upright, taken half a second in (the very
    /// first frame of a short clip). AVAssetImageGenerator decodes that one frame, never the whole video.
    static func poster(at url: URL, maxPixels: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let time = CMTime(seconds: duration > 1 ? 0.5 : 0, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}
