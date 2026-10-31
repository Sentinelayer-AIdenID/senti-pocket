import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import PocketSyncClient
import UniformTypeIdentifiers
import XCTest
@testable import SentiPocketApp

final class RoomMediaPreparationTests: XCTestCase {
    private lazy var folder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("prep-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }()

    /// Pixels: random noise (which compresses badly, like a busy photo) or one flat colour.
    private static func image(width: Int, height: Int, noise: Bool) -> CGImage {
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            if noise { arc4random_buf(base, buffer.count) } else { memset(base, 0x80, buffer.count) }
        }
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Where it was taken, when, with what, and turned on its side: what a phone's camera writes into a photo.
    private static let cameraMetadata: [CFString: Any] = [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 40.7128, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 74.006, kCGImagePropertyGPSLongitudeRef: "W"
        ] as [CFString: Any],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:10:31 09:00:00", kCGImagePropertyExifLensModel: "Test lens"
        ] as [CFString: Any],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"] as [CFString: Any]
    ]

    private func write(_ image: CGImage, _ type: UTType, named name: String, metadata: [CFString: Any] = [:]) -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private static func properties(_ data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    private static func properties(at url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    private static func pixels(_ properties: [CFString: Any]) -> (Int, Int) {
        ((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
         (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0)
    }

    /// The size a photo shows at, upright (orientations 5-8 are on their side).
    private static func shownSize(_ properties: [CFString: Any]) -> (Int, Int) {
        let (width, height) = pixels(properties)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    func test_thumbnails_come_from_imageio_at_the_preview_size_never_a_full_decode() {
        let options = RoomMediaImages.thumbnailOptions(maxPixels: RoomMediaRules.previewMaximumPixels)
        XCTAssertEqual(options[kCGImageSourceCreateThumbnailFromImageAlways] as? Bool, true)
        XCTAssertEqual(options[kCGImageSourceThumbnailMaxPixelSize] as? Int, 640)
        XCTAssertEqual(options[kCGImageSourceCreateThumbnailWithTransform] as? Bool, true, "upright, as the photo shows")
        XCTAssertEqual(RoomMediaImages.sourceOptions[kCGImageSourceShouldCache] as? Bool, false,
                       "the full image is never cached in memory")
    }

    func test_a_preview_stays_under_640_px_and_512_kb_with_no_location_or_exif() throws {
        let photo = write(Self.image(width: 4_000, height: 3_000, noise: true), .jpeg, named: "busy.jpg",
                          metadata: Self.cameraMetadata)
        XCTAssertTrue(RoomMediaImages.hasLocation(at: photo), "the test photo says where it was taken")
        let preview = try XCTUnwrap(RoomMediaImages.preview(at: photo))
        XCTAssertLessThanOrEqual(preview.count, RoomMediaRules.previewMaximumBytes)
        let properties = Self.properties(preview)
        let (width, height) = Self.pixels(properties)
        XCTAssertEqual(max(width, height), 640)
        XCTAssertEqual(width, 480, "turned upright: the photo was on its side")
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "no location in a preview")
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal], "nothing about when or with what")
        XCTAssertNil(exif[kCGImagePropertyExifLensModel])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
    }

    func test_a_busy_preview_steps_its_quality_down_until_it_fits() throws {
        let busy = Self.image(width: 640, height: 480, noise: true)
        let best = try XCTUnwrap(RoomMediaImages.jpeg(busy, quality: RoomMediaImages.previewQualities[0])).count
        let least = try XCTUnwrap(RoomMediaImages.jpeg(busy, quality: RoomMediaImages.previewQualities.last ?? 0.3)).count
        XCTAssertLessThan(least, best)
        let limit = (best + least) / 2
        let fitted = try XCTUnwrap(RoomMediaImages.jpeg(busy, maxBytes: limit))
        XCTAssertLessThanOrEqual(fitted.count, limit, "never over the limit, however busy the picture")
        XCTAssertNil(RoomMediaImages.jpeg(busy, maxBytes: least / 2), "too busy even at the lowest quality: no preview")
    }

    func test_location_is_removed_from_the_original_and_it_still_shows_upright() throws {
        let original = write(Self.image(width: 300, height: 200, noise: false), .jpeg, named: "original.jpg",
                             metadata: Self.cameraMetadata)
        XCTAssertTrue(RoomMediaImages.hasLocation(at: original))
        let stored = try RoomMediaImages.removingLocation(from: original, in: folder, baseName: "stored")
        XCTAssertEqual(stored.pathExtension, "jpg")
        XCTAssertFalse(RoomMediaImages.hasLocation(at: stored), "no location leaves the phone")
        XCTAssertEqual(RoomMediaImages.privateMetadata(at: original).sorted(),
                       ["DateTimeOriginal", "LensModel", "Make", "Model"], "the test photo says when and with what")
        XCTAssertEqual(RoomMediaImages.privateMetadata(at: stored), [], "nor the camera, the lens or the time")
        let properties = Self.properties(at: stored)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil((properties[kCGImagePropertyTIFFDictionary] as? [String: Any])?["Model"])
        XCTAssertNil((properties[kCGImagePropertyExifDictionary] as? [String: Any])?["LensModel"])
        XCTAssertTrue(Self.shownSize(properties) == (200, 300), "it still shows upright, as it was taken")

        // A format the room does not take (TIFF here, HEIC from a camera) becomes a JPEG, also without location.
        let scan = write(Self.image(width: 300, height: 200, noise: false), .tiff, named: "original.tiff",
                         metadata: Self.cameraMetadata)
        XCTAssertTrue(RoomMediaImages.hasLocation(at: scan))
        let converted = try RoomMediaImages.removingLocation(from: scan, in: folder, baseName: "converted")
        XCTAssertEqual(converted.pathExtension, "jpg")
        XCTAssertFalse(RoomMediaImages.hasLocation(at: converted))
        XCTAssertEqual(RoomMediaImages.privateMetadata(at: converted), [])
        XCTAssertTrue(Self.shownSize(Self.properties(at: converted)) == (200, 300))

        // A screenshot stays a PNG: lossless, so its text stays sharp.
        let screenshot = write(Self.image(width: 300, height: 200, noise: false), .png, named: "original.png",
                               metadata: Self.cameraMetadata)
        let kept = try RoomMediaImages.removingLocation(from: screenshot, in: folder, baseName: "screenshot")
        XCTAssertEqual(kept.pathExtension, "png")
        XCTAssertFalse(RoomMediaImages.hasLocation(at: kept))
        XCTAssertEqual(RoomMediaImages.privateMetadata(at: kept), [])
    }

    func test_a_gif_or_webp_goes_as_it_is_only_with_no_metadata_at_all_xmp_included() {
        XCTAssertTrue(RoomMediaImages.carriesNoMetadata([:], metadata: nil))
        XCTAssertTrue(RoomMediaImages.carriesNoMetadata([:], metadata: CGImageMetadataCreateMutable()))
        let xmp = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataSetValueMatchingImageProperty(xmp, kCGImagePropertyGPSDictionary,
                                                                  kCGImagePropertyGPSLatitude, 40.7128 as CFNumber))
        XCTAssertFalse(RoomMediaImages.carriesNoMetadata([:], metadata: xmp), "a location in XMP is metadata too")
        XCTAssertFalse(RoomMediaImages.carriesNoMetadata([kCGImagePropertyTIFFDictionary: [String: Any]()], metadata: nil))
    }

    func test_the_hash_is_streamed_and_matches_the_bytes() throws {
        var data = Data(count: 3 * 1_048_576 + 17)
        data.withUnsafeMutableBytes { buffer in arc4random_buf(buffer.baseAddress!, buffer.count) }
        let file = folder.appendingPathComponent("blob.bin")
        try data.write(to: file)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try RoomMediaHashing.sha256(of: file, chunkBytes: 1_048_576), expected)
        XCTAssertEqual(RoomMediaHashing.sha256(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func test_a_photo_is_prepared_with_its_preview_and_without_its_location() async throws {
        let picked = try RoomMediaFiles.newFolder(in: folder)
        let file = picked.appendingPathComponent("original.tiff")
        let image = write(Self.image(width: 1_200, height: 900, noise: false), .tiff, named: "scan-source.tiff",
                          metadata: Self.cameraMetadata)
        try FileManager.default.moveItem(at: image, to: file)
        let source = RoomMediaSource(file: file, filename: "Receipt scan.tiff")
        let preparer = RoomMediaPreparer()
        let thumbnail = await preparer.thumbnail(for: source)
        let prepared = try await preparer.prepare(source, thumbnail: thumbnail)
        XCTAssertEqual(prepared.filename, "Receipt scan.jpg", "sent as a JPEG, which the room takes")
        XCTAssertEqual(prepared.type.contentType, "image/jpeg")
        XCTAssertEqual(prepared.sha256, try RoomMediaHashing.sha256(of: prepared.file))
        XCTAssertFalse(RoomMediaImages.hasLocation(at: prepared.file))
        let preview = try XCTUnwrap(prepared.preview)
        XCTAssertLessThanOrEqual(preview.sizeBytes, Int64(RoomMediaRules.previewMaximumBytes))
        XCTAssertEqual(preview.filename, "Receipt scan.preview.jpg")
        XCTAssertEqual(preview.sha256, RoomMediaHashing.sha256(of: try Data(contentsOf: preview.file)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the original, location and all, is gone")
    }

    func test_a_video_loses_its_location_before_it_leaves_the_phone() async throws {
        let picked = try RoomMediaFiles.newFolder(in: folder)
        let movie = picked.appendingPathComponent("original.mov")
        try await Self.writeVideo(to: movie, width: 640, height: 360, frames: 10, location: "+40.7128-074.0060/")
        let hadLocation = await RoomMediaVideo.hasLocation(at: movie)
        XCTAssertTrue(hadLocation, "the test video says where it was taken")
        let source = RoomMediaSource(file: movie, filename: "Walkthrough.mov")
        let prepared = try await RoomMediaPreparer().prepare(source, thumbnail: nil)
        let stillThere = await RoomMediaVideo.hasLocation(at: prepared.file)
        XCTAssertFalse(stillThere, "the bytes uploaded say nothing about where")
        XCTAssertEqual(prepared.filename, "Walkthrough.mov")
        XCTAssertEqual(prepared.type.contentType, "video/quicktime")
        XCTAssertEqual(prepared.sha256, try RoomMediaHashing.sha256(of: prepared.file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path), "the original is gone")
        let tracks = try await AVURLAsset(url: prepared.file).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1, "still the same video")
    }

    func test_a_video_poster_is_one_small_upright_frame() async throws {
        let movie = folder.appendingPathComponent("clip.mov")
        try await Self.writeVideo(to: movie, width: 1_280, height: 720, frames: 10)
        let frame = await RoomMediaVideo.poster(at: movie, maxPixels: RoomMediaRules.previewMaximumPixels)
        let poster = try XCTUnwrap(frame)
        XCTAssertEqual(poster.width, 640)
        XCTAssertEqual(poster.height, 360)
        let jpeg = try XCTUnwrap(RoomMediaImages.jpeg(poster, maxBytes: RoomMediaRules.previewMaximumBytes))
        XCTAssertLessThanOrEqual(jpeg.count, RoomMediaRules.previewMaximumBytes)
    }

    /// A short H.264 video, written frame by frame, saying where it was taken when given a location (ISO 6709).
    private static func writeVideo(to url: URL, width: Int, height: Int, frames: Int, location: String? = nil) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        if let location {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataLocationISO6709
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = location as NSString
            writer.metadata = [item]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                throw RoomMediaPreparationError.unreadable
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(40 + frame * 20), CVPixelBufferGetBytesPerRow(buffer) * height)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
