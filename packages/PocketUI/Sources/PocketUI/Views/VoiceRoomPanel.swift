#if canImport(SwiftUI)
import SwiftUI

/// The voice room as a call, filling the screen (Carter, 10-30: "it should be in the actual voice room with you"): who
/// you are talking with, large, ringing until it picks up; a live waveform of whoever is talking; what is being said
/// now as captions (yours as it is recognized, or the agent's as it is read aloud); and one big button. Tap it to talk
/// and tap again to send, or hold it while you talk and let go to send. In hands-free, a pause sends and listening
/// comes back after each answer. The room's chat stays behind it until you hang up.
public struct VoiceRoomPanel: View {
    private let state: VoiceRoomState
    private let meter: VoiceLevelMeter
    private let partnerLab: AgentLab?
    private let addable: () -> [String]
    private let send: (VoiceRoomIntent) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressStarted = Date()
    @State private var startedByPress = false
    @State private var pulse = false
    @State private var ringing = false
    @State private var adding = false
    @State private var candidates: [String] = []

    /// `partnerLab` is the called agent's lab, for its logo and colour; nil in a meeting. `addable` is who could be
    /// brought into the call now (Carter, 10-30: "add warden mid-call"), asked when Add is tapped.
    public init(state: VoiceRoomState, meter: VoiceLevelMeter, partnerLab: AgentLab?,
                addable: @escaping () -> [String] = { [] }, send: @escaping (VoiceRoomIntent) -> Void) {
        self.state = state
        self.meter = meter
        self.partnerLab = partnerLab
        self.addable = addable
        self.send = send
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 12)
            partner
            VoiceWaveform(meter: meter, agentTint: partnerTint)
                .padding(.top, 28)
            nowLine
                .padding(.top, 16)
            Spacer(minLength: 12)
            controls
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if state.canAdd {
                addButton
                    .padding(.top, 16)
                    .padding(.trailing, 18)
            }
        }
        .pocketCanvas()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.voice.panel")
        .confirmationDialog("Add to the call", isPresented: $adding, titleVisibility: .visible) {
            ForEach(candidates, id: \.self) { agent in
                Button(agent) { send(.add(agent)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(candidates.isEmpty
                 ? "No other agent here can answer right now."
                 : "They're asked to join with a hello. With more than one agent, the first to answer each turn has the floor.")
        }
    }

    /// Brings someone else into the call: whoever can answer now and isn't in it already.
    private var addButton: some View {
        Button {
            let inCall = Set(state.with.map { $0.lowercased() })
            candidates = addable().filter { !inCall.contains($0.lowercased()) }
            adding = true
        } label: {
            Image(systemName: "person.badge.plus")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(PocketPalette.inset, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PocketPalette.textPrimary)
        .accessibilityLabel("Add someone to the call")
        .accessibilityIdentifier("pocket.voice.add")
    }

    /// The called agent's lab, only while the call has one agent: a group shows no one's logo.
    private var lab: AgentLab? {
        state.with.count == 1 ? partnerLab : nil
    }

    private var partnerTint: Color {
        guard let lab else { return PocketPalette.accent }
        let (red, green, blue) = lab.tint
        return Color(red: red, green: green, blue: blue)
    }

    private var header: some View {
        VStack(spacing: 4) {
            // Several names shrink a little, then end in "…", and never run under the Add button.
            Text(state.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(PocketPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
                .padding(.horizontal, state.canAdd ? 52 : 0)
            if state.isRinging {
                Text("Ringing…")
                    .font(.subheadline)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .accessibilityIdentifier("pocket.voice.ringing")
            } else {
                TimelineView(.periodic(from: state.startedAt, by: 1)) { context in
                    Text(Self.elapsed(from: state.startedAt, to: context.date))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                .accessibilityLabel("Call time")
            }
        }
    }

    /// The agent's logo on a large coin; while it rings, rings spread out from it.
    private var partner: some View {
        ZStack {
            if state.isRinging && !reduceMotion {
                ForEach(0..<2, id: \.self) { index in
                    Circle()
                        .stroke(partnerTint.opacity(ringing ? 0 : 0.5), lineWidth: 2)
                        .frame(width: 150, height: 150)
                        .scaleEffect(ringing ? 1.6 : 1)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(Double(index) * 0.8),
                                   value: ringing)
                }
                .onAppear { ringing = true }
                .onDisappear { ringing = false }
            }
            Circle()
                .fill(PocketPalette.raised)
                .frame(width: 150, height: 150)
                .overlay(Circle().stroke(partnerTint.opacity(0.55), lineWidth: 2))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
            mark
                .foregroundStyle(partnerTint)
                .frame(width: 70, height: 70)
        }
        .frame(height: 220)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        if state.with.isEmpty {
            Image(systemName: "person.3.fill").resizable().scaledToFit()
        } else if state.with.count > 1 {
            Image(systemName: "person.2.fill").resizable().scaledToFit()
        } else if let asset = lab?.logoAsset {
            Image(asset).renderingMode(.template).resizable().scaledToFit()
        } else if let initial = lab?.initial {
            Text(initial).font(.system(size: 60, weight: .heavy, design: .rounded))
        } else {
            Image(systemName: "cpu").resizable().scaledToFit()
        }
    }

    @ViewBuilder
    private var nowLine: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if let speaker = state.speaker {
                    Text("\(speaker) is speaking")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                } else {
                    Text(statusText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(state.isListening ? PocketPalette.accentStrong : PocketPalette.textSecondary)
                }
                if state.waiting > 0 {
                    Text("\(state.waiting) more")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PocketPalette.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(PocketPalette.inset, in: Capsule())
                }
            }
            Text(lineText)
                .font(.title3)
                .foregroundStyle(PocketPalette.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(6)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.15), value: lineText)
                .accessibilityIdentifier("pocket.voice.caption")
            if let notice = state.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(PocketPalette.warning)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("pocket.voice.notice")
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(alignment: .center) {
            VStack(spacing: 4) {
                Button { send(.skip) } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title3)
                        .frame(width: 48, height: 48)
                        .background(PocketPalette.inset, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.speaker == nil ? PocketPalette.textSecondary.opacity(0.5) : PocketPalette.textPrimary)
                .disabled(state.speaker == nil)
                .accessibilityLabel("Skip this answer")
                .accessibilityIdentifier("pocket.voice.skip")
                Toggle(isOn: Binding(get: { state.isHandsFree }, set: { send(.setHandsFree($0)) })) {
                    Text("Hands-free").font(.caption2)
                }
                .toggleStyle(.button)
                .font(.caption2)
                .tint(PocketPalette.listening)
                .accessibilityIdentifier("pocket.voice.handsFree")
            }
            Spacer()
            talkButton
            Spacer()
            Button { send(.hangUp) } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(PocketPalette.danger, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(state.phase == .ending || state.phase == .ended)
            .accessibilityLabel("End the voice room")
            .accessibilityIdentifier("pocket.voice.end")
        }
    }

    private var talkButton: some View {
        let listening = state.isListening
        return ZStack {
            if listening && !reduceMotion {
                Circle()
                    .fill(PocketPalette.accent.opacity(0.25))
                    .frame(width: 96, height: 96)
                    .scaleEffect(pulse ? 1.12 : 0.92)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .onDisappear { pulse = false }
            }
            Circle()
                .fill(listening ? PocketPalette.accent : PocketPalette.accentStrong)
                .frame(width: 76, height: 76)
            Image(systemName: listening ? "waveform" : "mic.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 100, height: 100)
        .contentShape(Circle())
        // A tap starts your turn and the next tap sends it; a hold talks while held and sends when let go.
        .onLongPressGesture(minimumDuration: Self.holdThreshold, maximumDistance: 60, perform: {}, onPressingChanged: { pressing in
            if pressing {
                pressStarted = Date()
                startedByPress = !state.isListening
                if startedByPress { send(.talk(true)) }
            } else {
                let held = Date().timeIntervalSince(pressStarted) >= Self.holdThreshold
                if !startedByPress || held { send(.talk(false)) }
            }
        })
        .accessibilityElement()
        .accessibilityLabel(listening ? "Send what you said" : "Talk")
        .accessibilityHint(listening ? "Ends your turn and sends it to the room" : "Starts listening")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { send(.toggleTalk) }
        .accessibilityIdentifier("pocket.voice.talk")
        .disabled(state.phase == .ending || state.phase == .ended)
    }

    static let holdThreshold: TimeInterval = 0.35

    private var statusText: String {
        switch state.phase {
        case .ready where state.isRinging: return "Waiting for \(state.title) to pick up"
        case .ready: return state.isHandsFree ? "Your turn: talk, a pause sends it" : "Tap or hold to talk"
        case .listening: return "Listening"
        case .sending: return "Sending"
        case .speaking: return ""
        case .ending: return "Saving the transcript to the room"
        case .ended: return "Ended"
        }
    }

    private var lineText: String {
        switch state.phase {
        case .listening:
            return state.partial.isEmpty ? "…" : state.partial
        default:
            return state.turns.last?.text ?? state.about.map { "Calling about: \($0)" } ?? "Say something to \(state.title)."
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
#endif
