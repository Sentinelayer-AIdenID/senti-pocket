import SwiftUI

/// Who is here, floating at the top center of the room, under the top bar (Carter, #55354, #55424, #55428, then
/// #55506: "all the logos in the room ... when one is working we can highlight it in the logo ... have a max number on
/// the screen and if that exceeds it we just put a group number"): each agent here as its lab's logo, solid, pulsing
/// while it works, at most six and then "+N", then a person glyph with the people's count. Someone arriving or leaving
/// shows as a note that grows out of the row and fades. Tapping opens the people list.
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
            HStack(spacing: 10) {
                ForEach(shownAgents) { agent in
                    AgentLogo(agent: agent, reduceMotion: reduceMotion)
                }
                if hiddenAgents > 0 {
                    Text("+\(hiddenAgents)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(PocketPalette.textPrimary)
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

    /// How many agents' logos show before the rest become "+N".
    static let maximumShown = 6

    private var agentsHere: [AgentLab.Present] {
        AgentLab.present(presence.people, models: models)
    }

    private var shownAgents: [AgentLab.Present] { Array(agentsHere.prefix(Self.maximumShown)) }
    private var hiddenAgents: Int { max(0, agentsHere.count - Self.maximumShown) }

    private var label: String {
        guard presence.isAvailable else { return "Who is here is not known right now" }
        let agents = agentsHere
        let working = agents.filter(\.isWorking).count
        let people = "\(humans) \(humans == 1 ? "person" : "people")"
        return "\(agents.count) agent\(agents.count == 1 ? "" : "s") (\(working) working) and \(people) here"
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

/// One agent here: its lab's logo in the lab's colour, solid (Carter, #55506: "I cannot see them anymore. They're too
/// damn transparent"), or the lab's initial, or a chip for an unknown lab. While the agent works it pulses, and
/// Claude's mark turns slowly, as its terminal spinner does; resting, it stays still.
private struct AgentLogo: View {
    let agent: AgentLab.Present
    let reduceMotion: Bool
    @State private var lifted = false
    @State private var turned = false

    var body: some View {
        let (red, green, blue) = agent.lab.tint
        mark
            .foregroundStyle(Color(red: red, green: green, blue: blue))
            .frame(width: 20, height: 20)
            .rotationEffect(.degrees(agent.lab == .anthropic && turned ? 360 : 0))
            .scaleEffect(agent.isWorking && lifted && !reduceMotion ? 1.18 : 1)
            .shadow(color: Color(red: red, green: green, blue: blue).opacity(agent.isWorking && lifted ? 0.7 : 0), radius: 6)
            .onAppear { animate(agent.isWorking) }
            .onChange(of: agent.isWorking) { working in animate(working) }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        if let asset = agent.lab.logoAsset {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        } else if let initial = agent.lab.initial {
            Text(initial).font(.system(size: 15, weight: .heavy, design: .rounded))
        } else {
            Image(systemName: "cpu").font(.system(size: 15, weight: .semibold))
        }
    }

    private func animate(_ working: Bool) {
        guard working, !reduceMotion else {
            lifted = false
            turned = false
            return
        }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { lifted = true }
        if agent.lab == .anthropic {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) { turned = true }
        }
    }
}
