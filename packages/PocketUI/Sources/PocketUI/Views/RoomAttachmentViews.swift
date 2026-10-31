#if canImport(SwiftUI)
import SwiftUI

/// Files under a message. Photos show their preview, videos their poster frame with a play button, and other files a
/// card with the name, size and type, and a Share button. Tapping opens a photo full size (zoomable), plays a video
/// straight from storage, and previews any other file.
struct RoomAttachmentsView: View {
    let chips: [RoomAttachmentChip]
    let previews: [String: Data]
    let send: (RoomChatIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chips) { chip in
                if chip.isVisual {
                    Button {
                        send(.openAttachment(attachmentId: chip.attachmentId))
                    } label: {
                        visual(chip)
                    }
                    .buttonStyle(.plain)
                    .onAppear { send(.attachmentAppeared(attachmentId: chip.attachmentId)) }
                    .accessibilityLabel(chip.accessibilityLabel)
                    .accessibilityHint(chip.accessibilityHint)
                    .accessibilityIdentifier(chip.kind == .video ? "pocket.room.attachment.video" : "pocket.room.attachment")
                } else {
                    HStack(spacing: 6) {
                        Button {
                            send(.openAttachment(attachmentId: chip.attachmentId))
                        } label: {
                            card(chip)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(chip.accessibilityLabel)
                        .accessibilityHint(chip.accessibilityHint)
                        .accessibilityIdentifier("pocket.room.attachment")
                        Button {
                            send(.shareAttachment(attachmentId: chip.attachmentId))
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(PocketPalette.accent)
                                .frame(width: 40, height: 40)
                                .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Share \(chip.filename)")
                        .accessibilityHint("Save it to Files or send it to another app")
                        .accessibilityIdentifier("pocket.room.attachment.share")
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                }
            }
        }
        .padding(.top, 4)
    }

    /// A photo's preview, or a video's poster with a play button. Until the preview arrives, a placeholder of the
    /// same kind holds its place.
    private func visual(_ chip: RoomAttachmentChip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                if let data = previews[chip.attachmentId], let image = RoomImageData.image(from: data) {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 260, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(chip.kind == .video ? Color.black.opacity(0.82) : PocketPalette.inset)
                        .frame(width: chip.kind == .video ? 240 : 200, height: chip.kind == .video ? 135 : 150)
                        .overlay {
                            if chip.kind == .image {
                                Image(systemName: "photo")
                                    .font(.title2)
                                    .foregroundStyle(PocketPalette.textSecondary)
                            }
                        }
                }
                if chip.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(Color.white, Color.black.opacity(0.45))
                        .shadow(color: .black.opacity(0.25), radius: 4)
                }
            }
            .accessibilityHidden(true)
            HStack(spacing: 4) {
                Image(systemName: chip.symbolName)
                    .accessibilityHidden(true)
                Text([chip.filename, chip.sizeLabel, chip.statusLabel].compactMap { $0 }.joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption2)
            .foregroundStyle(chip.processingStatus == "dead_letter" ? PocketPalette.danger : PocketPalette.textSecondary)
            .frame(maxWidth: 260, alignment: .leading)
        }
    }

    private func card(_ chip: RoomAttachmentChip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: chip.symbolName)
                    .foregroundStyle(PocketPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chip.filename)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                        .lineLimit(2)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
#endif
