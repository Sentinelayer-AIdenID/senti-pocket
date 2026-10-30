#if canImport(SwiftUI)
import SwiftUI

/// A box's thread, collapsed (warden, at Carter's #54962): one line with the box's name and status, how much was said
/// in its thread, and a tap to open it.
struct RoomBoxLine: View {
    let box: RoomBoxThread
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: box.isEnded ? "shippingbox" : "shippingbox.fill")
                    .font(.caption)
                    .foregroundStyle(box.isEnded ? PocketPalette.textSecondary : PocketPalette.listening)
                    .accessibilityHidden(true)
                Text(box.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PocketPalette.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(box.status)
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if box.replies > 0 {
                    Label("\(box.replies)", systemImage: "bubble.left.and.bubble.right")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PocketPalette.textSecondary)
                        .labelStyle(.titleAndIcon)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PocketPalette.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(PocketPalette.inset.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Box \(box.name), \(box.status), \(box.replies) in its thread")
        .accessibilityHint("Opens its thread")
    }
}
#endif
