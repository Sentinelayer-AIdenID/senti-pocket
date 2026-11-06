#if canImport(SwiftUI)
import SwiftUI

/// Files under a message. Photos show their preview, videos their poster frame with a play button, and other files a
/// card with the name, size and type, and a Share button. Tapping opens a photo full size (zoomable), plays a video
/// straight from storage, and previews any other file. A file taken back after it was sent shows only its name and
/// "Attachment removed", and nothing opens it. Two or more photos show as one strip of smaller thumbnails, side by side,
/// that scrolls sideways when they do not fit (`RoomAttachmentLayoutItem`).
struct RoomAttachmentsView: View {
    let chips: [RoomAttachmentChip]
    let previews: [String: Data]
    /// Your own message's files line up on the right, with its bubble.
    var alignment: HorizontalAlignment = .leading
    let send: (RoomChatIntent) -> Void
    /// A strip's thumbnail side: about 120 pt, as the web shows them, growing with the text size up to 200 pt.
    @ScaledMetric(relativeTo: .caption) private var thumbnailSide: CGFloat = 120

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            ForEach(RoomAttachmentLayoutItem.items(chips)) { item in
                switch item {
                case .strip(let photos):
                    strip(photos)
                case .single(let chip):
                    single(chip)
                }
            }
        }
        .padding(.top, 4)
    }

    /// A strip of this many photos or fewer shows them as they are when they fit, and scrolls when they do not. A longer
    /// one always scrolls: measuring whether they fit would build every photo it holds.
    static let measuredStripLimit = 4

    /// Photos side by side: as they are when a few fit, in a sideways scroll otherwise. Each opens as one alone does.
    /// The strip's own horizontal scroll view sits inside the message's one row.
    private func strip(_ photos: [RoomAttachmentChip]) -> some View {
        let side = min(thumbnailSide, 200)
        return Group {
            if photos.count <= Self.measuredStripLimit {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        stripPhotos(photos, side: side)
                    }
                    scrollingStrip(photos, side: side)
                }
            } else {
                scrollingStrip(photos, side: side)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.room.attachment.strip")
    }

    /// The strip in a sideways scroll, on a lazy stack: only the photos in sight are built.
    private func scrollingStrip(_ photos: [RoomAttachmentChip], side: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(spacing: 8) {
                stripPhotos(photos, side: side)
            }
            .padding(.bottom, 8)
        }
        .frame(height: side + 8)
    }

    private func stripPhotos(_ photos: [RoomAttachmentChip], side: CGFloat) -> some View {
        ForEach(Array(photos.enumerated()), id: \.element.id) { index, chip in
            let _ = RenderTrace.builtStripPhoto(index)
            Button {
                send(.openAttachment(attachmentId: chip.attachmentId))
            } label: {
                thumbnail(chip, side: side)
            }
            .buttonStyle(.plain)
            .onAppear { send(.attachmentAppeared(attachmentId: chip.attachmentId)) }
            .accessibilityLabel(RoomAttachmentLayoutItem.stripLabel(chip, index: index, count: photos.count))
            .accessibilityHint(chip.accessibilityHint)
            .accessibilityIdentifier("pocket.room.attachment.strip.photo")
        }
    }

    /// A photo's thumbnail, filling its square; until its preview arrives, a placeholder of the same size. `.clipShape`
    /// keeps the drawing inside the square; `.contentShape` makes the square, and only it, the tap and VoiceOver area
    /// (without it, a wide photo filling its square reached into its neighbours' areas).
    private func thumbnail(_ chip: RoomAttachmentChip, side: CGFloat) -> some View {
        ZStack {
            if let data = previews[chip.attachmentId], let image = RoomImageData.image(from: data) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                PocketPalette.inset
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if chip.processingStatus == "dead_letter" {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PocketPalette.danger)
                    .padding(6)
            }
        }
        .accessibilityHidden(true)
    }

    /// One file as before: a photo or a video's picture, a removed file, or a file's card with Share.
    @ViewBuilder
    private func single(_ chip: RoomAttachmentChip) -> some View {
        if chip.isRemoved {
            removed(chip)
        } else if chip.isVisual {
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

    /// A removed file: its name and that it was removed. No picture, no tap, no share.
    private func removed(_ chip: RoomAttachmentChip) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(chip.filename)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PocketPalette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(RoomAttachmentChip.removedLabel)
                .font(.caption2)
                .foregroundStyle(PocketPalette.textSecondary)
        }
        .padding(8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chip.accessibilityLabel)
        .accessibilityIdentifier("pocket.room.attachment.removed")
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
