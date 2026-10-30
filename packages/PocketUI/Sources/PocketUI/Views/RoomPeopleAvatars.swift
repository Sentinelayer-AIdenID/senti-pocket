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
    /// How many are here and active, as the people list counts them (Carter, 10-30: the ring said 2 while the list
    /// said 9 online); nil counts the ring's own logos that are not idle.
    var activeCount: Int?
    /// Who the people list counts as active, by `RoomRoster.presenceKey`: the coins not greyed. Nil uses the ring's own
    /// reading of who is idle.
    var activeKeys: Set<String>?
    /// Something covers the room (the people list, a call): the ring stops turning by itself.
    var isPaused = false
    let onOpen: () -> Void

    /// How long a note stays before it fades.
    static let noteLifetime: TimeInterval = 3.2

    private struct Note: Identifiable, Equatable {
        let id = UUID()
        let change: RoomPresenceChange
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomIsCovered) private var roomIsCovered
    @State private var notes: [Note] = []
    @State private var agents = 0
    @State private var humans = 0
    @State private var shown: RoomChatPresence?

    /// How far the ring has turned by hand, in radians; where a drag began; until when it holds still after a hand or
    /// an arrival; and from when it has been turning by itself (it drifts slowly from `rotation` after that).
    @State private var rotation = 0.0
    @State private var dragFrom: Double?
    @State private var settlingUntil = Date.distantPast
    @State private var turnBase = Date()
    @State private var front: Int?
    @State private var lastTick = Date.distantPast
    /// The signs already seen, to tell which agent just did something.
    @State private var seenSignals: [String: String] = [:]
    #if canImport(UIKit)
    @State private var haptics = UIImpactFeedbackGenerator(style: .light)
    #endif

    /// How fast the ring turns by itself, in radians a second.
    static let drift = 0.22
    /// Taps never come closer together than this (warden, #265: a 100-member ring tapped about three times a second).
    static let tickSpacing: TimeInterval = 0.08

    /// One logo on the ring: an agent (its lab's logo) or a person.
    private struct RingItem: Identifiable {
        let id: String
        let agent: AgentLab.Present?
        let isIdle: Bool
    }

    /// Agents first, then people, each once (warden, #265: a person seen twice was drawn twice).
    private var ringItems: [RingItem] {
        // Grey exactly when the count leaves it out, so a coin is never counted but grey (warden, #269).
        func idle(_ key: String, _ own: Bool) -> Bool { activeKeys.map { !$0.contains(key) } ?? own }
        let agents = agentsHere.map {
            RingItem(id: "a:" + $0.id.lowercased(), agent: $0, isIdle: idle($0.id.lowercased(), $0.isIdle))
        }
        var seen = Set<String>()
        let people = presence.people.filter(\.isHuman)
            .filter { seen.insert(RoomRoster.presenceKey($0)).inserted }
            .map { RingItem(id: "p:" + RoomRoster.presenceKey($0), agent: nil, isIdle: idle(RoomRoster.presenceKey($0), $0.isIdle)) }
        return agents + people
    }

    /// The ring rests while something covers the room: the people list, or a call over everything.
    private var resting: Bool { isPaused || roomIsCovered }

    /// The ring's turn at a moment: where a hand left it, plus its slow drift since it was last let go.
    private func turn(at date: Date, isRing: Bool) -> Double {
        guard isRing, dragFrom == nil, !reduceMotion, !resting else { return rotation }
        return drifted(at: date)
    }

    private func drifted(at date: Date) -> Double {
        rotation - Self.drift * max(0, date.timeIntervalSince(max(turnBase, settlingUntil)))
    }

    var body: some View {
        // Worked out once per change of who is here, not on every frame of the turn.
        let items = ringItems
        let isRing = PresenceRingLayout.isRing(items.count)
        let online = presence.isAvailable ? String(activeCount ?? items.filter { !$0.isIdle }.count) : "?"
        // Past six it turns by itself, slowly, unless a hand is on it (Carter, 10-30: "or it scrolls by itself"); the
        // clock stops for an arc, with Reduce Motion, under a hand, or while the room is covered (warden, #265).
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isRing || reduceMotion || dragFrom != nil || resting)) { context in
            let turned = turn(at: context.date, isRing: isRing)
            // The online count sits above the logos, where none of them covers it (Carter, 10-30: "move the number of
            // online a bit higher to be visible because the logos are hiding it").
            VStack(spacing: Self.countGap) {
                onlineCount(online)
                    .zIndex(1)
                ZStack {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ringItem(item)
                            .modifier(RingPlacement(index: index, count: items.count, rotation: turned))
                    }
                }
                .frame(height: isRing ? 56 : 44)
            }
        }
        .frame(width: PresenceRingLayout.radius(items.count) * 2 + 32, height: (isRing ? 56 : 44) + 22 + Self.countGap)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard isRing else { return }
                if dragFrom == nil {
                    // A hand takes the ring where the drift had it.
                    rotation = turn(at: Date(), isRing: isRing)
                    dragFrom = rotation
                    #if canImport(UIKit)
                    haptics.prepare()
                    #endif
                }
                rotation = (dragFrom ?? rotation) + value.translation.width / PresenceRingLayout.radius(items.count)
                tickIfNewFront(count: items.count)
            }
            .onEnded { value in
                guard isRing else { return }
                dragFrom = nil
                let now = Date()
                settlingUntil = now.addingTimeInterval(1.2)
                turnBase = now
                let fling = (value.predictedEndTranslation.width - value.translation.width) / PresenceRingLayout.radius(items.count)
                withAnimation(.easeOut(duration: 0.7)) { rotation += fling }
                // Where the fling comes to rest gets its tap.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { tickIfNewFront(count: items.count) }
            })
        .onTapGesture(perform: onOpen)
        // Resting keeps the ring where it was; turning again starts from there, with no jump for the time it rested.
        .onChange(of: resting) { nowResting in
            let now = Date()
            if nowResting, isRing, dragFrom == nil, !reduceMotion { rotation = drifted(at: now) }
            turnBase = now
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
            seenSignals = signals
        }
        .onChange(of: presence) { now in arrive(now) }
        // Whoever just posted comes to the front of the ring, and the ring holds there a while (Carter, 10-30:
        // "whenever each one sends a message it scrolls to that one. An indication of who's interacting now").
        .onChange(of: signals) { now in bringForward(now, items: items) }
    }

    @ViewBuilder
    private func ringItem(_ item: RingItem) -> some View {
        Group {
            if let agent = item.agent {
                AgentLogo(agent: agent, reduceMotion: reduceMotion)
                    .modifier(PresenceCoin(shape: Circle()))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PocketPalette.textPrimary)
                    .modifier(PresenceCoin(shape: Circle()))
            }
        }
        // Idle but not gone: still on the ring, greyed (Carter, 10-30), and still easy to see ("I can barely see the
        // logos").
        .saturation(item.isIdle ? 0.3 : 1)
        .opacity(item.isIdle ? 0.78 : 1)
    }

    /// The number online, with a green dot, in the middle (Carter, 10-30: "If one idles that number drops").
    private func onlineCount(_ online: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(online != "0" && online != "?" ? PocketPalette.verified : PocketPalette.textSecondary)
                .frame(width: 7, height: 7)
            Text(online)
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

    /// Between the online count and the logos under it: the back of the ring tucks just under the count.
    static let countGap: CGFloat = -2

    /// How long the ring holds on an agent that just did something before it turns by itself again.
    static let holdOnActivity: TimeInterval = 8

    private func bringForward(_ now: [String: String], items: [RingItem]) {
        let changed = now.filter { seenSignals[$0.key] != $0.value }.map(\.key)
        seenSignals = now
        guard PresenceRingLayout.isRing(items.count), dragFrom == nil, !resting,
              let index = items.firstIndex(where: { item in changed.contains { "a:" + $0 == item.id } }) else { return }
        let now = Date()
        rotation = turn(at: now, isRing: true)
        settlingUntil = now.addingTimeInterval(Self.holdOnActivity)
        turnBase = now
        let target = PresenceRingLayout.rotation(bringingToFront: index, count: items.count, from: rotation)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.8)) { rotation = target }
        // Taps are for a hand on the ring and its fling, not for the ring moving itself (warden, #265).
        front = index
    }

    /// A light tap each time a new logo comes to the front (Carter, 10-30: "that small vibration feel that we get when
    /// a new message comes").
    private func tickIfNewFront(count: Int) {
        let now = PresenceRingLayout.frontIndex(count: count, rotation: rotation)
        guard now != front else { return }
        let first = front == nil
        front = now
        guard !first, Date().timeIntervalSince(lastTick) >= Self.tickSpacing else { return }
        lastTick = Date()
        #if canImport(UIKit)
        haptics.impactOccurred(intensity: 0.6)
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

private struct RoomCoveredKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Something covers the room from outside its own view (a call's own window): its moving parts rest.
    var roomIsCovered: Bool {
        get { self[RoomCoveredKey.self] }
        set { self[RoomCoveredKey.self] = newValue }
    }
}

/// Where one logo sits for a turn of the ring. The turn itself is what animates, so a fling or an arrival moves each
/// logo along the circle, not straight across it (warden, #265).
private struct RingPlacement: ViewModifier, Animatable {
    let index: Int
    let count: Int
    var rotation: Double

    var animatableData: Double {
        get { rotation }
        set { rotation = newValue }
    }

    func body(content: Content) -> some View {
        let spot = PresenceRingLayout.spot(index: index, count: count, rotation: rotation)
        return content
            .scaleEffect(spot.scale)
            .opacity(spot.opacity)
            .offset(x: spot.x, y: spot.y)
            .zIndex(spot.depth)
    }
}

/// A coin under each presence logo: a little see-through glass, lit from above, ringed and shadowed, so the logo
/// stands out over any message behind it in light and dark (Carter, 10-30: "Make them more prominent and slight
/// transparent. Same for dark theme").
private struct PresenceCoin<S: InsettableShape>: ViewModifier {
    let shape: S
    var fixedWidth = true
    static var size: CGFloat { 34 }

    func body(content: Content) -> some View {
        content
            .frame(width: fixedWidth ? Self.size : nil, height: Self.size)
            .background(shape.fill(PocketPalette.raised.opacity(0.78)))
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center))
                .allowsHitTesting(false))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
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
            .frame(width: 21, height: 21)
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
