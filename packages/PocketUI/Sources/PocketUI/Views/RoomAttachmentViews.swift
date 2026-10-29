#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Files under a message: a card per file, with a small preview for images once it has loaded. Tapping opens the
/// file full size.
struct RoomAttachmentsView: View {
    let chips: [RoomAttachmentChip]
    let previews: [String: Data]
    let send: (RoomChatIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chips) { chip in
                Button {
                    send(.openAttachment(attachmentId: chip.attachmentId))
                } label: {
                    card(chip)
                }
                .buttonStyle(.plain)
                .onAppear {
                    if chip.kind == .image { send(.attachmentAppeared(attachmentId: chip.attachmentId)) }
                }
                .accessibilityLabel("\(chip.kindLabel) \(chip.filename)")
                .accessibilityIdentifier("pocket.room.attachment")
            }
        }
        .padding(.top, 4)
    }

    private func card(_ chip: RoomAttachmentChip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if chip.kind == .image, let data = previews[chip.attachmentId], let image = Self.image(from: data) {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 260, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                Image(systemName: chip.symbolName)
                    .foregroundStyle(PocketPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chip.filename)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text([chip.kindLabel, chip.sizeLabel, chip.statusLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(chip.processingStatus == "dead_letter" ? PocketPalette.danger : PocketPalette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            if let summary = chip.summary {
                Text(RoomChatText.attributed(summary))
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .lineLimit(4)
            }
        }
        .padding(8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}
#endif
