import SwiftUI

/// Who is here, floating at the top center of the room, under the top bar (Carter, #55354, then #55424: "no
/// backgrounds ... more transparent ... dead center of the top", then #55428: "Whichever labs you come from put that
/// icon there with its number badge and also pulsate ... to show they're working. Or idle"): one glyph per lab with
/// its agents' count, pulsing while any of them is active, and a person glyph with the people's count. Someone
/// arriving or leaving shows as a note that grows out of the row and fades, and the counts tick over. Tapping opens the
/// people list.
struct RoomPeopleAvatars: View {
    let presence: RoomChatPresence
    /// Each agent's model where the room knows it (a box's), lowercased id to model, to tell its lab.
    var models: [String: String] = [:]
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
                ForEach(labs) { group in
                    LabGlyph(group: group, reduceMotion: reduceMotion)
                }
                personGlyph
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private var labs: [AgentLab.Group] {
        AgentLab.groups(present: presence.people, models: models)
    }

    private var label: String {
        guard presence.isAvailable else { return "Who is here is not known right now" }
        let agentsLine = labs.map { "\($0.count) \($0.lab.name)\($0.isWorking ? ", working" : "")" }
        let people = "\(humans) \(humans == 1 ? "person" : "people")"
        return (agentsLine + [people]).joined(separator: ", ") + " here"
    }

    /// People: the glyph with its count beside it, no shape behind, quiet (Carter, #55424).
    private var personGlyph: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.fill")
                .font(.system(size: 13, weight: .semibold))
            if presence.isAvailable {
                Text("\(humans)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(PocketPalette.textPrimary)
        .opacity(0.55)
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

/// One lab's agents: its initial in its colour (a chip for an unknown lab) and how many, pulsing while any is active
/// and resting quiet when all are idle.
private struct LabGlyph: View {
    let group: AgentLab.Group
    let reduceMotion: Bool
    @State private var lifted = false

    var body: some View {
        let (red, green, blue) = group.lab.tint
        HStack(spacing: 3) {
            if let initial = group.lab.initial {
                Text(initial)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
            } else {
                Image(systemName: "cpu")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text("\(group.count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(Color(red: red, green: green, blue: blue))
        .opacity(group.isWorking ? (lifted ? 1 : 0.6) : 0.45)
        .scaleEffect(group.isWorking && lifted && !reduceMotion ? 1.12 : 1)
        .onAppear { pulse(group.isWorking) }
        .onChange(of: group.isWorking) { working in pulse(working) }
        .accessibilityHidden(true)
    }

    private func pulse(_ working: Bool) {
        guard working, !reduceMotion else {
            lifted = false
            return
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lifted = true }
    }
}
