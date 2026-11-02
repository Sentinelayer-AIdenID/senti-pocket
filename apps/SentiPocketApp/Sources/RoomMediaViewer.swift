import AVKit
import ImageIO
import SwiftUI
import UIKit

/// A photo or video opened from a message.
enum RoomMediaViewerItem: Identifiable {
    /// A photo: its preview at once, the original once it has downloaded.
    case image(attachmentId: String, filename: String, preview: Data?)
    /// A video, streamed straight from its storage link (never downloaded first).
    case video(attachmentId: String, url: URL)

    var id: String {
        switch self {
        case .image(let attachmentId, _, _): return "image:\(attachmentId)"
        case .video(let attachmentId, _): return "video:\(attachmentId)"
        }
    }
}

/// A photo full screen: the preview at once, then the original, which pinches and double-taps to zoom. The original is
/// decoded by ImageIO at the screen's size (enough to zoom into), never at full size; its downloaded copy is deleted
/// when the viewer closes.
struct RoomImageViewer: View {
    let filename: String
    let preview: Data?
    /// Downloads the original into a temporary folder.
    let loadOriginal: () async throws -> URL
    let onClose: () -> Void

    @State private var image: UIImage?
    @State private var original: URL?
    @State private var failed = false
    @State private var sharing = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    RoomZoomableImage(image: image)
                        .ignoresSafeArea()
                        .accessibilityLabel("Photo, \(filename)")
                        .accessibilityAddTraits(.isImage)
                }
                if original == nil, !failed {
                    ProgressView()
                        .tint(.white)
                        .padding(10)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .accessibilityLabel("Loading the full photo")
                }
                if failed {
                    Text("Couldn't load the full photo. Showing its preview.")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle(filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("pocket.media.viewer.done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        sharing = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(original == nil)
                    .accessibilityLabel("Share the photo")
                    .accessibilityIdentifier("pocket.media.viewer.share")
                }
            }
            .sheet(isPresented: $sharing) {
                if let original { RoomShareSheet(items: [original]) }
            }
        }
        .task {
            if image == nil, let preview { image = UIImage(data: preview) }
            do {
                let file = try await loadOriginal()
                original = file
                let side = Int(max(UIScreen.main.nativeBounds.width, UIScreen.main.nativeBounds.height))
                let decoded = await Task.detached(priority: .userInitiated) {
                    RoomMediaImages.thumbnail(at: file, maxPixels: max(side, 1_024))
                }.value
                if let decoded { image = UIImage(cgImage: decoded) } else { failed = true }
            } catch {
                failed = true
            }
        }
        .onDisappear {
            if let original { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        }
    }
}

/// Pinch and double-tap zoom on a photo, as in Photos.
struct RoomZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .black
        scroll.contentInsetAdjustmentBehavior = .never
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.frame = scroll.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = true
        scroll.addSubview(view)
        context.coordinator.imageView = view
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}

/// A video played straight from its storage link: AVPlayer streams it with range requests, so it starts in moments
/// and is never downloaded whole first. If the link stops working mid-play (it expired, or storage refused it), a new
/// one is asked for and playing goes on from the same moment (twice at most).
struct RoomVideoPlayer: UIViewControllerRepresentable {
    let url: URL
    let refresh: () async throws -> URL

    func makeCoordinator() -> Coordinator { Coordinator(refresh: refresh) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        context.coordinator.watch(player)
        player.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.stop()
        controller.player?.pause()
        controller.player = nil
    }

    final class Coordinator: NSObject {
        let refresh: () async throws -> URL
        private var status: NSKeyValueObservation?
        private var failure: NSObjectProtocol?
        private var refreshes = 0
        private weak var player: AVPlayer?

        init(refresh: @escaping () async throws -> URL) {
            self.refresh = refresh
        }

        func watch(_ player: AVPlayer) {
            self.player = player
            status = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
                guard player.currentItem?.status == .failed else { return }
                DispatchQueue.main.async { self?.recover() }
            }
            failure = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil,
                                                             queue: .main) { [weak self] note in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player?.currentItem else { return }
                self.recover()
            }
        }

        func stop() {
            status = nil
            if let failure { NotificationCenter.default.removeObserver(failure) }
            failure = nil
        }

        private func recover() {
            guard refreshes < 2, let player else { return }
            refreshes += 1
            let time = player.currentTime()
            let refresh = self.refresh
            Task { @MainActor [weak player] in
                guard let url = try? await refresh(), let player else { return }
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                await player.seek(to: time)
                player.play()
            }
        }
    }
}

struct RoomVideoViewer: View {
    let url: URL
    let refresh: () async throws -> URL
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            RoomVideoPlayer(url: url, refresh: refresh)
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onClose)
                            .accessibilityIdentifier("pocket.media.viewer.done")
                    }
                }
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

/// The share sheet for a downloaded file (Save to Files, AirDrop, another app). The copy is deleted when it closes.
struct RoomShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    var deletesWhenDone = false

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let items = self.items
        let deletes = deletesWhenDone
        controller.completionWithItemsHandler = { _, _, _, _ in
            guard deletes else { return }
            for item in items { try? FileManager.default.removeItem(at: item.deletingLastPathComponent()) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A file downloaded to share.
struct RoomShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
