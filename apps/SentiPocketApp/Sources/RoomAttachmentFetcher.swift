import Foundation
import ImageIO
import QuickLook
import SwiftUI
import UIKit

/// Fetches attachment bytes from the short-lived storage links the API issues. Those links carry their own
/// signature: the request has no Authorization header, no cookies and no cache, so the user's token never reaches
/// the storage host and nothing outlives the link.
protocol AttachmentFileFetching: Sendable {
    /// Bytes for a small preview; refuses anything over `maximumBytes`.
    func data(from url: URL, maximumBytes: Int) async throws -> Data
    /// Downloads the whole file into a fresh temporary folder, named `filename`.
    func file(from url: URL, filename: String) async throws -> URL
}

enum AttachmentFetchError: Error, Equatable {
    case tooLarge
    case failed
}

struct URLSessionAttachmentFetcher: AttachmentFileFetching {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    func data(from url: URL, maximumBytes: Int) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw AttachmentFetchError.failed
        }
        guard data.count <= maximumBytes else { throw AttachmentFetchError.tooLarge }
        return data
    }

    func file(from url: URL, filename: String) async throws -> URL {
        let (downloaded, response) = try await session.download(from: url)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            try? FileManager.default.removeItem(at: downloaded)
            throw AttachmentFetchError.failed
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("senti-attachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(AttachmentFiles.safeFilename(filename))
        try FileManager.default.moveItem(at: downloaded, to: destination)
        return destination
    }
}

enum AttachmentFiles {
    /// A file name that cannot leave its folder: the server's own alphabet, no leading dots, bounded.
    static func safeFilename(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._ -")
        var cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(160)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    /// A small JPEG preview (longest side `maxPixels`) decoded straight from the file, without inflating the full
    /// image in memory.
    static func preview(from data: Data, maxPixels: Int = 640) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    }
}

/// One downloaded attachment shown full size; the temporary copy is deleted when the preview closes.
struct AttachmentPreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct AttachmentQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Source { Source(url: url) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    static func dismantleUIViewController(_ controller: UINavigationController, coordinator: Source) {
        try? FileManager.default.removeItem(at: coordinator.url.deletingLastPathComponent())
    }

    final class Source: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
