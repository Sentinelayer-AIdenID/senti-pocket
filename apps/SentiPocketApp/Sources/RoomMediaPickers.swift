import PhotosUI
import PocketSyncClient
import PocketUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Shows the picker the attach sheet chose (photos and videos, the camera, or files) and hands what was picked to the
/// room's media coordinator, each file copied into its own outbox folder. Pasting reads the clipboard's images at once.
struct RoomMediaPickerHost: View {
    @ObservedObject var requests: RoomMediaPickerRequests
    /// How many more files the next message can carry.
    let remaining: () -> Int
    let onPicked: ([RoomMediaSource]) -> Void
    let onRefused: (RoomMediaRefusal) -> Void

    private var sheet: Binding<RoomAttachSource?> {
        Binding(
            get: { requests.source == .photos || requests.source == .files ? requests.source : nil },
            set: { if $0 == nil, requests.source == .photos || requests.source == .files { requests.source = nil } }
        )
    }

    private var camera: Binding<Bool> {
        Binding(
            get: { requests.source == .camera },
            set: { if !$0, requests.source == .camera { requests.source = nil } }
        )
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .sheet(item: sheet) { source in
                if source == .photos {
                    RoomPhotoPicker(limit: remaining(), onDone: { requests.source = nil }, onPicked: imported)
                        .ignoresSafeArea()
                } else {
                    RoomDocumentPicker(onDone: { requests.source = nil }, onPicked: imported)
                        .ignoresSafeArea()
                }
            }
            .fullScreenCover(isPresented: camera) {
                RoomCameraPicker(onDone: { requests.source = nil }, onPicked: imported)
                    .ignoresSafeArea()
            }
            .onChange(of: requests.source) { source in
                guard source == .paste else { return }
                requests.source = nil
                Task { @MainActor in
                    let pasted = await RoomMediaImport.pastedImages(limit: remaining())
                    imported(pasted)
                }
            }
    }

    private func imported(_ result: RoomMediaImport.Result) {
        if !result.sources.isEmpty { onPicked(result.sources) }
        if let failed = result.failedNames.first { onRefused(.unreadable(filename: failed)) }
    }
}

/// Copies picked files into the outbox: a picker's own copy disappears once its callback returns.
enum RoomMediaImport {
    struct Result {
        var sources: [RoomMediaSource] = []
        var failedNames: [String] = []
    }

    /// Each item in order; one that cannot be read is named, never silently dropped.
    static func copy(_ providers: [NSItemProvider], fallbackName: String) async -> Result {
        var result = Result()
        for (index, provider) in providers.enumerated() {
            let name = provider.suggestedName ?? "\(fallbackName) \(index + 1)"
            if let source = await copy(provider, name: name) {
                result.sources.append(source)
            } else {
                result.failedNames.append(name)
            }
        }
        return result
    }

    static func copy(_ provider: NSItemProvider, name: String) async -> RoomMediaSource? {
        guard let typeIdentifier = preferredType(provider.registeredTypeIdentifiers) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let ext = url.pathExtension.isEmpty
                    ? (UTType(typeIdentifier)?.preferredFilenameExtension ?? "dat")
                    : url.pathExtension
                continuation.resume(returning: try? store(url, named: name, fileExtension: ext, move: false))
            }
        }
    }

    /// A photo is taken as its image (a Live Photo too), in a format the room takes as is when there is one; a video
    /// as its movie.
    static func preferredType(_ identifiers: [String]) -> String? {
        let types = identifiers.compactMap { id in UTType(id).map { (id, $0) } }
        // A Live Photo's bundle is not a picture the room can take; its still image is.
        let images = types.filter { $0.1.conforms(to: .image) && !$0.1.conforms(to: .livePhoto) && !$0.0.contains("live-photo") }
        let direct: [UTType] = [.jpeg, .png, .gif, .webP]
        if let image = images.first(where: { candidate in direct.contains { candidate.1.conforms(to: $0) } }) ?? images.first {
            return image.0
        }
        if let movie = types.first(where: { $0.1.conforms(to: .movie) }) { return movie.0 }
        return types.first(where: { $0.1.conforms(to: .data) })?.0
    }

    /// Copies (or moves, for a copy that is already ours) a file into a new outbox folder as `original.<ext>`, sent
    /// under `name` with that extension.
    static func store(_ url: URL, named name: String, fileExtension ext: String, move: Bool) throws -> RoomMediaSource {
        let folder = try RoomMediaFiles.newFolder()
        let lowered = ext.lowercased()
        let destination = folder.appendingPathComponent("original.\(lowered)")
        if move {
            try FileManager.default.moveItem(at: url, to: destination)
        } else {
            try FileManager.default.copyItem(at: url, to: destination)
        }
        let base = (name as NSString).pathExtension.lowercased() == lowered ? (name as NSString).deletingPathExtension : name
        return RoomMediaSource(file: destination, filename: "\(base).\(lowered)")
    }

    /// The images on the clipboard, read once the person chose Paste.
    @MainActor
    static func pastedImages(limit: Int) async -> Result {
        let providers = UIPasteboard.general.itemProviders.filter { provider in
            provider.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: .image) == true }
        }
        return await copy(Array(providers.prefix(max(0, limit))), fallbackName: "Pasted image")
    }

    /// "Photo 2026-10-31 14.05.12": a name for what the camera made.
    static func cameraName(_ prefix: String, at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date))"
    }
}

/// Photos and videos from the library, several at once. The system picker runs outside the app: it needs no access to
/// the library, and hands over the originals untouched (no waiting while a video is converted).
struct RoomPhotoPicker: UIViewControllerRepresentable {
    let limit: Int
    let onDone: () -> Void
    let onPicked: (RoomMediaImport.Result) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = max(1, limit)
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: RoomPhotoPicker
        init(_ parent: RoomPhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.onDone()
            let providers = results.map(\.itemProvider)
            guard !providers.isEmpty else { return }
            let onPicked = parent.onPicked
            Task { @MainActor in
                onPicked(await RoomMediaImport.copy(providers, fallbackName: "Photo"))
            }
        }
    }
}

/// Files from Files, iCloud Drive or another app's provider, several at once, as copies the app owns.
struct RoomDocumentPicker: UIViewControllerRepresentable {
    let onDone: () -> Void
    let onPicked: (RoomMediaImport.Result) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: RoomDocumentPicker
        init(_ parent: RoomDocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onDone()
            var result = RoomMediaImport.Result()
            for url in urls {
                // The picker made these copies for the app: moved into the outbox, never copied twice.
                if let source = try? RoomMediaImport.store(url, named: url.lastPathComponent,
                                                            fileExtension: url.pathExtension, move: true) {
                    result.sources.append(source)
                } else {
                    result.failedNames.append(url.lastPathComponent)
                }
            }
            parent.onPicked(result)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onDone()
        }
    }
}

/// The camera: a photo or a video, straight into the message.
struct RoomCameraPicker: UIViewControllerRepresentable {
    let onDone: () -> Void
    let onPicked: (RoomMediaImport.Result) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: RoomCameraPicker
        init(_ parent: RoomCameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.onDone()
            var result = RoomMediaImport.Result()
            if let movie = info[.mediaURL] as? URL {
                let name = RoomMediaImport.cameraName("Video")
                if let source = try? RoomMediaImport.store(movie, named: name, fileExtension: movie.pathExtension, move: true) {
                    result.sources.append(source)
                } else {
                    result.failedNames.append(name)
                }
            } else if let image = info[.originalImage] as? UIImage {
                // The camera's photo is already decoded by the camera; it is written once as JPEG (the camera adds no
                // location to it here), then prepared like any photo.
                let name = RoomMediaImport.cameraName("Photo")
                if let data = image.jpegData(compressionQuality: 0.9),
                   let folder = try? RoomMediaFiles.newFolder() {
                    let file = folder.appendingPathComponent("original.jpg")
                    if (try? data.write(to: file, options: .atomic)) != nil {
                        result.sources.append(RoomMediaSource(file: file, filename: name + ".jpg"))
                    } else {
                        result.failedNames.append(name)
                    }
                } else {
                    result.failedNames.append(name)
                }
            }
            parent.onPicked(result)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onDone()
        }
    }
}
