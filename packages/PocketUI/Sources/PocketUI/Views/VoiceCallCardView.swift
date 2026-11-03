#if canImport(SwiftUI)
import SwiftUI

/// A voice room in the room, folded: one card with who and how long, live or ended; a tap opens the whole conversation
/// as short transcript lines, oldest first.
struct VoiceCallCardView: View {
    let card: VoiceCallCard
    let ownHandles: Set<String>
    /// Opens an attachment by id: the call's transcript.
    var openAttachment: (String) -> Void = { _ in }
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill((card.isLive ? PocketPalette.listening : PocketPalette.accent).opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: card.isLive ? "waveform" : "phone.fill")
                            .foregroundStyle(card.isLive ? PocketPalette.listening : PocketPalette.accentStrong)
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PocketPalette.textPrimary)
                            .lineLimit(1)
                        TimelineView(.periodic(from: Date(), by: 30)) { context in
                            Text(card.summary(now: context.date))
                                .font(.caption)
                                .foregroundStyle(card.isLive ? PocketPalette.listening : PocketPalette.textSecondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PocketPalette.textSecondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(card.title), \(card.summary())")
            .accessibilityHint(isOpen ? "Hides the conversation" : "Shows the conversation")

            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    if card.turns.isEmpty {
                        Text(card.isLive ? "Ringing…" : "Nothing was said.")
                            .font(.caption)
                            .foregroundStyle(PocketPalette.textSecondary)
                    }
                    ForEach(card.turns) { turn in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: turn.isHuman ? "mic.fill" : "speaker.wave.2.fill")
                                .font(.caption2)
                                .foregroundStyle(turn.isHuman ? PocketPalette.accentStrong : PocketPalette.listening)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(turn.speaker)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PocketPalette.textSecondary)
                                ChatMarkdownView(text: turn.text, ownHandles: ownHandles)
                                    .font(.callout)
                                    .foregroundStyle(PocketPalette.textPrimary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let transcript = card.transcript {
                        Button {
                            openAttachment(transcript.attachmentId)
                        } label: {
                            Label("Transcript", systemImage: "doc.text")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 2)
                        .accessibilityHint("Opens the call's whole transcript")
                        .accessibilityIdentifier("pocket.room.call.transcript")
                    }
                }
                .padding(.leading, 46)
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke((card.isLive ? PocketPalette.listening : PocketPalette.separator).opacity(0.6), lineWidth: card.isLive ? 1 : 0.5)
        )
    }
}
#endif
