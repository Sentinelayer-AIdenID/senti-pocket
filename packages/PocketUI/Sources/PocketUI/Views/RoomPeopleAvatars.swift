import SwiftUI

/// Who is here, floating at the top center of the room, under the top bar (Carter, #55354, then #55424: "no
/// backgrounds ... more transparent ... dead center of the top"): an agent glyph and a person glyph, each with its
/// count. Someone arriving or leaving shows as a note that grows out of the pair and fades, and the count ticks over.
/// Tapping opens the people list.
struct RoomPeopleAvatars: View {
    let presence: RoomChatPresence
    let onOpen: () -> Void

    /// How long a note stays before it fades.
    static let noteLifetime: TimeInterval = 3.2

    private struct Note: Identifiable, Equatable {
        let id = UUID()
        let change: RoomPresenceChange
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var notes: [Note] = []
    @State private var agents = 0
    @State private var humans = 0
    @State private var shown: RoomChatPresence?

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                glyph(isHuman: false, count: agents)
                glyph(isHuman: true, count: humans)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Quiet (Carter, #55424: "no backgrounds ... more transparent"): the glyphs and counts alone, half see-through.
        .opacity(0.55)
        .overlay(alignment: .top) { noteColumn.offset(y: 30) }
        .accessibilityLabel(label)
        .accessibilityHint("Opens the people list")
        .accessibilityIdentifier("pocket.room.presence")
        .onAppear {
            shown = presence
            agents = presence.agentCount
            humans = presence.humanCount
        }
        .onChange(of: presence) { now in arrive(now) }
    }

    private var label: String {
        guard presence.isAvailable else { return "Who is here is not known right now" }
        return "\(agents) agent\(agents == 1 ? "" : "s") and \(humans) \(humans == 1 ? "person" : "people") here"
    }

    /// An agent or a person, and how many: the glyph with its count beside it, no shape behind either.
    private func glyph(isHuman: Bool, count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: isHuman ? "person.fill" : "cpu")
                .font(.system(size: 13, weight: .semibold))
            if presence.isAvailable {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(PocketPalette.textPrimary)
        .accessibilityHidden(true)
    }

    /// The notes under the glyphs, newest last, centered under the pair and growing out of it.
    private var noteColumn: some View {
        VStack(spacing: 4) {
            ForEach(notes) { note in
                HStack(spacing: 5) {
                    Image(systemName: note.change.joined ? "arrow.down.right.circle.fill" : "arrow.up.left.circle.fill")
                        .foregroundStyle(note.change.joined ? PocketPalette.verified : PocketPalette.textSecondary)
                    Text(note.change.text)
                        .foregroundStyle(PocketPalette.textPrimary)
                        .lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .opacity(0.9)
                .fixedSize()
                .transition(reduceMotion
                    ? .opacity
                    : .scale(scale: 0.2, anchor: .top).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func arrive(_ now: RoomChatPresence) {
        let changes = RoomChatPresence.changes(from: shown, to: now)
        shown = now
        let added = changes.map { Note(change: $0) }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.72)) {
            agents = now.agentCount
            humans = now.humanCount
            // A busy room keeps the last few notes, not a column down the screen.
            notes = Array((notes + added).suffix(4))
        }
        for note in added {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.noteLifetime) {
                withAnimation(.easeIn(duration: 0.5)) { notes.removeAll { $0.id == note.id } }
            }
        }
    }
}
