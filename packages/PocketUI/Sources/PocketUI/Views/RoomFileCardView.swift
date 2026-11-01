#if canImport(SwiftUI)
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A verified file on its way out of the app: written only when the person picks where it goes in the share sheet
/// (Files, AirDrop, another app), never before, and never opened or rendered here. Its bytes are made again and
/// checked again first, and nothing is written when they don't check out. Old exports are removed as it is written
/// (see `RoomFileExports`).
struct RoomFileExport: Transferable, Sendable {
    let name: String
    let content: RoomChatFileContent

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { export in
            SentTransferredFile(try RoomFileExports.write(export.content, named: export.name))
        }
    }
}

/// A file posted as base64 parts, at the root of its thread, with who posted it. Verified: its name, size, hash and
/// parts, and Download. Not verified: the reason, and no way to save it. The posts it came from fold behind
/// "N data parts".
struct RoomFileCardView: View {
    let card: RoomChatFileCard
    let showsParts: Bool
    let onToggleParts: () -> Void
    /// The preview, made from the file when it is opened; nil while closed.
    @State private var shownPreview: String?

    // Written out: the private state would make the memberwise one private to this file.
    init(card: RoomChatFileCard, showsParts: Bool, onToggleParts: @escaping () -> Void) {
        self.card = card
        self.showsParts = showsParts
        self.onToggleParts = onToggleParts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: card.isVerified ? "doc.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(card.isVerified ? PocketPalette.listening : PocketPalette.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: card.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                        .lineLimit(2)
                    Text(verbatim: card.postedBy)
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("pocket.room.file.author")
                    Text(verbatim: card.detail)
                        .font(.caption)
                        .foregroundStyle(card.isVerified ? PocketPalette.textSecondary : PocketPalette.warning)
                    if let mismatch = card.mismatch {
                        Text(verbatim: mismatch)
                            .font(.caption2.monospaced())
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                }
                Spacer(minLength: 4)
                if let content = card.content {
                    ShareLink(item: RoomFileExport(name: card.name, content: content),
                              preview: SharePreview(card.name)) {
                        Label("Download", systemImage: "square.and.arrow.down")
                            .font(.caption.weight(.semibold))
                    }
                    .accessibilityHint("Saves the file where you choose")
                    .accessibilityIdentifier("pocket.room.file.download")
                }
            }
            if card.previewable {
                Button(shownPreview == nil ? "Preview" : "Hide preview") {
                    shownPreview = shownPreview == nil ? (card.preview() ?? "") : nil
                }
                .font(.caption.weight(.semibold))
                .accessibilityIdentifier("pocket.room.file.preview")
                if let preview = shownPreview {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(verbatim: preview)
                            .font(.caption.monospaced())
                            .foregroundStyle(PocketPalette.textPrimary)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            Button(action: onToggleParts) {
                Label(card.partsToggleTitle, systemImage: showsParts ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityHint(showsParts ? "Hides the posts the file came from" : "Shows the posts the file came from")
            .accessibilityIdentifier("pocket.room.file.parts")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(card.isVerified ? PocketPalette.separator : PocketPalette.warning.opacity(0.5), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.room.file")
    }
}
#endif
