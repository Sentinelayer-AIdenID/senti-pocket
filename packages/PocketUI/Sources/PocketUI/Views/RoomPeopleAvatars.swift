import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Who is here, floating at the top center of the room, under the top bar (Carter, #55354, #55424, #55428, then
/// #55506: "all the logos in the room ... when one is working we can highlight it in the logo ... have a max number on
/// the screen and if that exceeds it we just put a group number"; 10-30: the web's ring): each agent here as its lab's
/// logo and each person as a figure, on coins, around the number online. Up to six sit on an arc; more go round a ring
/// that turns by itself or by hand, with a light tap as each comes to the front. Working logos beat; idle ones stay,
/// greyed. Someone arriving or leaving shows as a note that grows out of the row and fades. Tapping opens the people
/// list.
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

    /// How far the ring has turned, in radians; where a drag began; whether a hand is on it.
    @State private var rotation = 0.0
    @State private var dragFrom: Double?
    @State private var settlingUntil = Date.distantPast
    @State private var front: Int?
    private let turn = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    /// One logo on the ring: an agent (its lab's logo) or a person.
    private struct RingItem: Identifiable {
        let id: String
        let agent: AgentLab.Present?
        let isIdle: Bool
    }

    private var ringItems: [RingItem] {
        let agents = agentsHere.map { RingItem(id: "a:" + $0.id.lowercased(), agent: $0, isIdle: $0.isIdle) }
        let people = presence.people.filter(\.isHuman)
            .map { RingItem(id: "p:" + $0.id.lowercased(), agent: nil, isIdle: $0.isIdle) }
        return agents + people
    }

    var body: some View {
        let items = ringItems
        let isRing = PresenceRingLayout.isRing(items.count)
        let online = items.filter { !$0.isIdle }.count
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let spot = PresenceRingLayout.spot(index: index, count: items.count, rotation: rotation)
                ringItem(item)
                    .scaleEffect(spot.scale)
                    .opacity(spot.opacity)
                    .offset(x: spot.x, y: spot.y)
                    .zIndex(spot.depth)
            }
            onlineCount(online)
                .zIndex(isRing ? 0.2 : 2)
        }
        .frame(width: PresenceRingLayout.radius(items.count) * 2 + 32, height: isRing ? 56 : 44)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard isRing else { return }
                let from = dragFrom ?? rotation
                dragFrom = from
                rotation = from + value.translation.width / PresenceRingLayout.radius(items.count)
                tickIfNewFront(count: items.count)
            }
            .onEnded { value in
                guard isRing else { return }
                dragFrom = nil
                settlingUntil = Date().addingTimeInterval(1.2)
                let fling = (value.predictedEndTranslation.width - value.translation.width) / PresenceRingLayout.radius(items.count)
                withAnimation(.easeOut(duration: 0.7)) { rotation += fling }
            })
        .onTapGesture(perform: onOpen)
        // Past six it turns by itself, slowly, unless a hand is on it (Carter, 10-30: "or it scrolls by itself").
        .onReceive(turn) { _ in
            guard isRing, dragFrom == nil, Date() > settlingUntil, !reduceMotion else { return }
            rotation -= 0.22 / 30
            tickIfNewFront(count: items.count)
        }
        .overlay(alignment: .top) { noteColumn.offset(y: isRing ? 44 : 34) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint("Opens the people list")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onOpen)
        .accessibilityIdentifier("pocket.room.presence")
        .onAppear {
            shown = presence
            agents = presence.agentCount
            humans = presence.humanCount
        }
        .onChange(of: presence) { now in arrive(now) }
    }

    @ViewBuilder
    private func ringItem(_ item: RingItem) -> some View {
        Group {
            if let agent = item.agent {
                AgentLogo(agent: agent, reduceMotion: reduceMotion)
                    .modifier(PresenceCoin(shape: Circle()))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PocketPalette.textPrimary)
                    .modifier(PresenceCoin(shape: Circle()))
            }
        }
        // Idle but not gone: still on the ring, greyed (Carter, 10-30).
        .saturation(item.isIdle ? 0 : 1)
        .opacity(item.isIdle ? 0.5 : 1)
    }

    /// The number online, with a green dot, in the middle (Carter, 10-30: "If one idles that number drops").
    private func onlineCount(_ online: Int) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(online > 0 ? PocketPalette.verified : PocketPalette.textSecondary)
                .frame(width: 7, height: 7)
            Text("\(online)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(PocketPalette.textPrimary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(PocketPalette.raised))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
        .accessibilityHidden(true)
    }

    /// A light tap each time a new logo comes to the front (Carter, 10-30: "that small vibration feel that we get when
    /// a new message comes").
    private func tickIfNewFront(count: Int) {
        let now = PresenceRingLayout.frontIndex(count: count, rotation: rotation)
        guard now != front else { return }
        let first = front == nil
        front = now
        guard !first else { return }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
        #endif
    }

    private var agentsHere: [AgentLab.Present] {
        AgentLab.present(presence.people, models: models, signals: signals, working: working, boxes: boxes)
    }


    private var label: String {
        guard presence.isAvailable else { return "Who is here is not known right now" }
        let agents = agentsHere
        let working = agents.filter(\.isWorking).count
        let people = "\(humans) \(humans == 1 ? "person" : "people")"
        return "\(agents.count) agent\(agents.count == 1 ? "" : "s") (\(working) working) and \(people) here"
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
