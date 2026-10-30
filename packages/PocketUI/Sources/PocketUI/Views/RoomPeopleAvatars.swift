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
    /// Each agent's newest sign of activity, by lowercased id: its logo beats once per new sign.
    var signals: [String: String] = [:]
    /// The agents the server says are working, by lowercased id: a logo beats once as its agent starts.
    var working: Set<String> = []
    /// The room's running boxes, by name: shown even when not in presence, with a box badge.
    var boxes: [String] = []
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
            HStack(spacing: 8) {
                // Said plainly that this is who is here (Carter, 10-30: "make it known it's a presence icon").
                HStack(spacing: 4) {
                    Circle()
                        .fill(PocketPalette.verified)
                        .frame(width: 6, height: 6)
                    Text("Here")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                .accessibilityHidden(true)
                // Close together and lifted off the room, as on the web (Carter, 10-30: "put them closer to each other
                // ... make them feel more 3D so they can stand out and prevent the background from inhaling them").
                HStack(spacing: -6) {
                    ForEach(shownAgents) { agent in
                        AgentLogo(agent: agent, reduceMotion: reduceMotion)
                            .modifier(PresenceCoin(shape: Circle()))
                    }
                    if hiddenAgents > 0 {
                        Text("+\(hiddenAgents)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(PocketPalette.textPrimary)
                            .modifier(PresenceCoin(shape: Circle()))
                    }
                }
                personGlyph
                    .padding(.horizontal, 8)
                    .modifier(PresenceCoin(shape: Capsule(), fixedWidth: false))
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

    private var agentsHere: [AgentLab.Present] {
        AgentLab.present(presence.people, models: models, signals: signals, working: working, boxes: boxes)
    }

    private var shownAgents: [AgentLab.Present] { AgentLab.shown(agentsHere).shown }
    private var hiddenAgents: Int { AgentLab.shown(agentsHere).more }

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

/// A coin under each presence logo: solid, lit from above, ringed and shadowed, so it reads over any message behind it.
private struct PresenceCoin<S: InsettableShape>: ViewModifier {
    let shape: S
    var fixedWidth = true
    static var size: CGFloat { 28 }

    func body(content: Content) -> some View {
        content
            .frame(width: fixedWidth ? Self.size : nil, height: Self.size)
            .background(shape.fill(PocketPalette.raised))
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center))
                .allowsHitTesting(false))
            .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
    }
}

/// One agent here: its lab's logo in the lab's colour, solid (Carter, #55506: "I cannot see them anymore. They're too
/// damn transparent"), or the lab's initial, or a chip for an unknown lab, with a small box badge for an agent running
/// in a box. Still, until the agent does something: then it beats once, slowly, and Claude's mark turns a quarter,
/// and it is still again (Carter, #55533: "palpitation movement when it senses something and then stillness").
private struct AgentLogo: View {
    let agent: AgentLab.Present
    let reduceMotion: Bool
    @State private var beating = false
    @State private var turn = 0.0

    var body: some View {
        let (red, green, blue) = agent.lab.tint
        let tint = Color(red: red, green: green, blue: blue)
        mark
            .foregroundStyle(tint)
            .frame(width: 17, height: 17)
            .rotationEffect(.degrees(turn))
            .scaleEffect(beating ? 1.22 : 1)
            .shadow(color: tint.opacity(beating ? 0.75 : 0), radius: 7)
            .overlay(alignment: .bottomTrailing) {
                if agent.isBox {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(PocketPalette.textPrimary)
                        .padding(2)
                        .background(Circle().fill(PocketPalette.raised))
                        .offset(x: 5, y: 5)
                }
            }
            .onAppear { if agent.isWorking { beat() } }
            .onChange(of: agent.signal) { signal in if signal != nil { beat() } }
            .onChange(of: agent.isWorking) { working in if working { beat() } }
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

    /// One slow beat: up and glowing over half a second, back down over most of a second, then still.
    private func beat() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.5)) {
            beating = true
            if agent.lab == .anthropic { turn += 90 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeInOut(duration: 0.9)) { beating = false }
        }
    }
}
