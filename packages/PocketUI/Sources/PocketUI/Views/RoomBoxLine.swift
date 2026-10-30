#if canImport(SwiftUI)
import SwiftUI

/// A box's thread, collapsed (warden, at Carter's #54962): one line with the box's name and status, how much was said
/// in its thread, and a tap to open it.
struct RoomBoxLine: View {
    let box: RoomBoxThread
    /// What happened in its thread, in a sentence or two, when the phone has summarized it.
    var summary: String?
    /// The summary is being read aloud.
    var isReadingSummary = false
    /// Read the summary aloud, or stop (Carter, on #55474: "a voice version of the summary").
    var onListen: (() -> Void)?
    /// Open the whole summary (Carter, 10-30: "clicking on the summary message can give you a pop up of the rest").
    var onOpenSummary: (() -> Void)?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
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
            if let summary {
                // Room on the right for the open and speaker buttons, which sit over the card and are their own.
                ThreadSummaryText(text: summary)
                    .padding(.trailing, ThreadSummaryListenButton.size * CGFloat([onListen != nil, onOpenSummary != nil].filter { $0 }.count))
            }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(PocketPalette.inset.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Box \(box.name), \(box.status), \(box.replies) in its thread\(summary.map { ". Summary: \($0)" } ?? "")")
        .accessibilityHint("Opens its thread")
        .overlay(alignment: .bottomTrailing) {
            if summary != nil {
                HStack(spacing: 0) {
                    if let onOpenSummary { ThreadSummaryOpenButton(action: onOpenSummary) }
                    if let onListen { ThreadSummaryListenButton(isReading: isReadingSummary, action: onListen) }
                }
                .padding(.trailing, 4)
                .padding(.bottom, 2)
            }
        }
    }
}

/// A thread's summary on its row: a small spark, then the sentence, quiet.
struct ThreadSummaryText: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "sparkles")
                .font(.caption2)
                .foregroundStyle(PocketPalette.accentStrong)
                .accessibilityHidden(true)
            Text(ThreadSummaryFormat.headline(text))
                .font(.caption)
                .foregroundStyle(PocketPalette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("pocket.room.threadSummary")
    }
}

/// Opens a thread's whole summary: a small page icon beside the speaker.
struct ThreadSummaryOpenButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.caption)
                .foregroundStyle(PocketPalette.accentStrong)
                .frame(width: ThreadSummaryListenButton.size, height: ThreadSummaryListenButton.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Read the whole summary")
        .accessibilityIdentifier("pocket.room.threadSummary.open")
    }
}

/// A thread's whole summary, in a sheet: each part on its line, the record's ids as written, and Listen.
struct ThreadSummarySheet: View {
    let summary: String
    let isReading: Bool
    let onListen: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button(action: onListen) {
                        Label(isReading ? "Stop" : "Listen", systemImage: isReading ? "stop.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pocket.room.threadSummary.sheet.listen")
                    ChatMarkdownView(text: summary.replacingOccurrences(of: "\n", with: "\n\n"), ownHandles: [])
                        .accessibilityIdentifier("pocket.room.threadSummary.sheet.text")
                    Text("Written on this phone from the thread's newest replies. The record is copied from the thread.")
                        .font(.footnote)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .pocketCanvas()
            .navigationTitle("Thread summary")
            .navigationBarTitleDisplayModeInlineIfAvailable()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Reads a thread's summary aloud, or stops it: a small speaker after the summary.
struct ThreadSummaryListenButton: View {
    static let size: CGFloat = 30
    let isReading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isReading ? "stop.fill" : "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(PocketPalette.accentStrong)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isReading ? "Stop reading the summary" : "Listen to the summary")
        .accessibilityIdentifier("pocket.room.threadSummary.listen")
    }
}
#endif
