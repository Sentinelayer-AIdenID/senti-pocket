import SwiftUI

/// Two avatars floating under the room's top bar, the agents and the people here, each with its count (Carter,
/// #55354: "a bot avatar and a human avatar ... just floating under the top part"). Someone arriving or leaving
/// shows as a note that grows out of their avatar and fades, and the count ticks over. Tapping opens the people list.
/// Agents are a rounded square and people a circle, as their avatars are in the room.
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
            HStack(spacing: 12) {
                avatar(isHuman: false, count: agents)
                avatar(isHuman: true, count: humans)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5))
            .shadow(color: PocketPalette.floatingEdge.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { noteColumn.offset(y: 48) }
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

    private func avatar(isHuman: Bool, count: Int) -> some View {
        Image(systemName: isHuman ? "person.fill" : "cpu")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(isHuman ? PocketPalette.accent : PocketPalette.listening,
                        in: RoundedRectangle(cornerRadius: isHuman ? 15 : 8, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if presence.isAvailable {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Capsule().fill(PocketPalette.verified))
                        .overlay(Capsule().stroke(PocketPalette.canvas, lineWidth: 1.5))
                        .offset(x: 7, y: -7)
                }
            }
            .accessibilityHidden(true)
    }

    /// The notes under the avatars, newest last. Each lines up under its own avatar and grows out of it; one column,
    /// so a person's note and an agent's never overlap.
    private var noteColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
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
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5))
                .fixedSize()
                // The person avatar ends 10 pt in from the capsule's right edge, the agent avatar 52 pt.
                .padding(.trailing, note.change.isHuman ? 4 : 46)
                .transition(reduceMotion
                    ? .opacity
                    : .scale(scale: 0.2, anchor: .topTrailing).combined(with: .opacity))
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
