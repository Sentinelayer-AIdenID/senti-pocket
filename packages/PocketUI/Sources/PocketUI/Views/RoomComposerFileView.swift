#if os(iOS) && canImport(QuickLook)
import QuickLook
import SwiftUI
import UIKit

/// A file in the composer's tray, open full screen before it is sent (Carter, ticket 77fcdd2b: "When I click on a pic I
/// attach before I send it I wanna be able to open it and inspect it. Same for attachments. Anything I attach."). A
/// photo pinches to zoom and pans, a video plays, and any other file shows in Quick Look. Remove takes this one file out
/// of the tray; Done goes back to the composer, with the words typed and the other files as they were.
struct RoomComposerFileView: View {
    let item: RoomMediaItemRow
    let onRemove: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let file = item.localFile, FileManager.default.fileExists(atPath: file.path) {
                    RoomComposerQuickLook(url: file)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityLabel("\(item.kindLabel), \(item.filename)")
                } else if let data = item.thumbnail, let image = RoomImageData.image(from: data) {
                    image
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("\(item.kindLabel), \(item.filename)")
                } else {
                    Text("This file can't be shown yet.")
                        .font(.body)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(item.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("pocket.room.media.viewer.done")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove", systemImage: "trash")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel("Remove \(item.filename)")
                    .accessibilityHint("Takes it out of this message")
                    .accessibilityIdentifier("pocket.room.media.viewer.remove")
                }
            }
        }
        .accessibilityIdentifier("pocket.room.media.viewer")
    }
}

/// Quick Look, embedded: a photo zooms and pans, a video plays, a PDF or document reads. It never deletes the file:
/// it is still to be sent.
struct RoomComposerQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Source { Source(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Source: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#endif
