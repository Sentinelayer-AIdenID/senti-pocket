#if canImport(SwiftUI)
import SwiftUI

/// The voice room as a call, filling the screen: who
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var pressStarted = Date()
    @State private var startedByPress = false
    @State private var pulse = false
    @State private var ringing = false
    @State private var adding = false
    @State private var candidates: [String] = []

    /// `partnerLab` is the called agent's lab, for its logo and colour; nil in a meeting. `addable` is who could be
    /// brought into the call now, asked when Add is tapped.
    public init(state: VoiceRoomState, meter: VoiceLevelMeter, partnerLab: AgentLab?,
                addable: @escaping () -> [String] = { [] }, send: @escaping (VoiceRoomIntent) -> Void) {
        self.state = state
        self.meter = meter
        self.partnerLab = partnerLab
        self.addable = addable
        self.send = send
    }

    /// The accessibility text sizes: the words get the room, so the face, the coin and the gaps between parts shrink.
    private var largeText: Bool { typeSize.isAccessibilitySize }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: largeText ? 4 : 12)
            partner
            VoiceWaveform(meter: meter, agentTint: partnerTint)
                .padding(.top, largeText ? 12 : 28)
            nowLine
                .padding(.top, largeText ? 8 : 16)
            Spacer(minLength: largeText ? 4 : 12)
            controls
        }
        .padding(.horizontal, 22)
        .padding(.top, largeText ? 8 : 20)
        .padding(.bottom, largeText ? 8 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            speakerButton
                .padding(.top, 16)
                .padding(.leading, 18)
        }
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

    /// The loudspeaker or the earpiece, as on the phone's own call screen (Carter, 11-05: a call picked up on the speaker
    /// by accident had no way back). Filled while on; VoiceOver reads it as "Speaker, On" or "Speaker, Off".
    private var speakerButton: some View {
        Button { send(.setSpeaker(!state.isSpeakerOn)) } label: {
            Image(systemName: speakerSymbol)
                .font(.title3)
                .roundGlyph()
                .voiceLayoutProbe("speaker.glyph")
                .frame(width: 44, height: 44)
                .background(state.isSpeakerOn ? PocketPalette.textPrimary : PocketPalette.inset, in: Circle())
                .voiceLayoutProbe("speaker.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(state.isSpeakerOn ? PocketPalette.canvas : PocketPalette.textPrimary)
        .disabled(state.phase == .ending || state.phase == .ended)
        .accessibilityLabel("Speaker")
        .accessibilityValue(state.speakerValue)
        .accessibilityHint(state.isSpeakerOn ? "Plays the call through the earpiece" : "Plays the call through the speaker")
        .accessibilityIdentifier("pocket.voice.speaker")
        .roundButtonLargeContent("Speaker", systemImage: speakerSymbol)
    }

    private var speakerSymbol: String { state.isSpeakerOn ? "speaker.wave.2.fill" : "speaker.fill" }

    /// Brings someone else into the call: whoever can answer now and isn't in it already.
    private var addButton: some View {
        Button {
            let inCall = Set(state.with.map { $0.lowercased() })
            candidates = addable().filter { !inCall.contains($0.lowercased()) }
            adding = true
        } label: {
            Image(systemName: "person.badge.plus")
                .font(.title3)
                .roundGlyph()
                .voiceLayoutProbe("add.glyph")
                .frame(width: 44, height: 44)
                .background(PocketPalette.inset, in: Circle())
                .voiceLayoutProbe("add.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(PocketPalette.textPrimary)
        .accessibilityLabel("Add someone to the call")
        .accessibilityIdentifier("pocket.voice.add")
        .roundButtonLargeContent("Add someone to the call", systemImage: "person.badge.plus")
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
            // Several names shrink a little, then end in "…", and never run under the Speaker or Add button.
            Text(state.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(PocketPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
                .padding(.horizontal, 52)
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
        .voiceLayoutProbe("header")
    }

    /// The agent's logo on a large coin; while it rings, rings spread out from it. While an agent answers, its face
    /// instead: the room's avatar for it, whose mouth moves with its voice.
    private var partner: some View {
        ZStack {
            if let face = state.face {
                VoiceCallFace(face: face, meter: meter, reduceMotion: reduceMotion)
                    .equatable()
            } else {
                coin
            }
        }
        // At the accessibility text sizes the face (or the coin) is drawn smaller, so the words below it fit.
        .scaleEffect(largeText ? 0.7 : 1)
        .frame(height: largeText ? 154 : 220)
        .accessibilityHidden(true)
    }

    private var coin: some View {
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
                if let answering = state.answeringLine {
                    // Who the server gave the turn to, before any of the answer is heard (Carter, 11-05).
                    Text(answering)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .voiceLayoutProbe("answering")
                        .accessibilityIdentifier("pocket.voice.answering")
                } else if let speaker = state.speaker {
                    Text("\(speaker) is speaking")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(statusText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(state.isListening ? PocketPalette.accentStrong : PocketPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
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
                .lineLimit(largeText ? 2 : 6)
                .minimumScaleFactor(largeText ? 0.6 : 0.8)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.15), value: lineText)
                .voiceLayoutProbe("caption")
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
                        .roundGlyph()
                        .voiceLayoutProbe("skip.glyph")
                        .frame(width: 48, height: 48)
                        .background(PocketPalette.inset, in: Circle())
                        .voiceLayoutProbe("skip.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.speaker == nil ? PocketPalette.textSecondary.opacity(0.5) : PocketPalette.textPrimary)
                .disabled(state.speaker == nil)
                .accessibilityLabel("Skip this answer")
                .accessibilityIdentifier("pocket.voice.skip")
                .roundButtonLargeContent("Skip this answer", systemImage: "forward.end.fill")
                Toggle(isOn: Binding(get: { state.isHandsFree }, set: { send(.setHandsFree($0)) })) {
                    Text("Hands-free").font(.caption2).lineLimit(1)
                        .voiceLayoutProbe("handsFree.label")
                }
                .toggleStyle(.button)
                .font(.caption2)
                // Like the round buttons: its text stops growing at the largest standard size, so it stays one line
                // under Skip and the controls stay one row; a long press shows it large.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .tint(PocketPalette.listening)
                .accessibilityIdentifier("pocket.voice.handsFree")
                .roundButtonLargeContent("Hands-free", systemImage: "waveform")
                .voiceLayoutProbe("handsFree")
            }
            Spacer()
            talkButton
            Spacer()
            HStack(spacing: 14) {
                muteButton
                Button { send(.hangUp) } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title3)
                        .roundGlyph()
                        .foregroundStyle(.white)
                        .voiceLayoutProbe("end.glyph")
                        .frame(width: 52, height: 52)
                        .background(PocketPalette.danger, in: Circle())
                        .voiceLayoutProbe("end.circle")
                }
                .buttonStyle(.plain)
                .disabled(state.phase == .ending || state.phase == .ended)
                .accessibilityLabel("End the voice room")
                .accessibilityIdentifier("pocket.voice.end")
                .roundButtonLargeContent("End the voice room", systemImage: "phone.down.fill")
            }
        }
        .voiceLayoutProbe("controls")
    }

    /// Mute, on the panel of every call. As on the phone's own
    /// call screen it always shows a crossed-out mic, so it never reads as a second Talk button, and it is filled
    /// while on. In a call the phone's call screen also shows, it mutes that call too.
    private var muteButton: some View {
        Button { send(.setMuted(!state.isMuted)) } label: {
            Image(systemName: "mic.slash")
                .font(.title3.weight(.semibold))
                .roundGlyph()
                .voiceLayoutProbe("mute.glyph")
                .frame(width: 48, height: 48)
                .background(state.isMuted ? PocketPalette.textPrimary : PocketPalette.inset, in: Circle())
                .voiceLayoutProbe("mute.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(state.isMuted ? PocketPalette.canvas : PocketPalette.textPrimary)
        .disabled(state.phase == .ending || state.phase == .ended)
        .accessibilityLabel(state.muteLabel)
        .accessibilityIdentifier("pocket.voice.mute")
        .roundButtonLargeContent(state.muteLabel, systemImage: "mic.slash")
    }

    /// Muted, it is greyed out like Skip with nothing to skip, says so under it, and takes no turn.
    private var talkButton: some View {
        let listening = state.isListening
        let muted = state.isMuted
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
                .fill(muted ? PocketPalette.inset : listening ? PocketPalette.accent : PocketPalette.accentStrong)
                .frame(width: 76, height: 76)
            Image(systemName: muted ? "mic.slash.fill" : listening ? "waveform" : "mic.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(muted ? PocketPalette.textSecondary.opacity(0.6) : .white)
        }
        .frame(width: 100, height: 100)
        .overlay(alignment: .bottom) {
            if muted {
                Text("Muted")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PocketPalette.textSecondary)
                    .offset(y: 8)
                    .accessibilityHidden(true)
            }
        }
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
        .accessibilityLabel(muted ? "Muted" : listening ? "Send what you said" : "Talk")
        .accessibilityHint(muted ? "Unmute to talk" : listening ? "Ends your turn and sends it to the room" : "Starts listening")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { send(.toggleTalk) }
        .accessibilityIdentifier("pocket.voice.talk")
        .disabled(!state.canTalk)
    }

    static let holdThreshold: TimeInterval = 0.35

    private var statusText: String {
        switch state.phase {
        case .ready where state.isRinging: return "Waiting for \(state.title) to pick up"
        case .ready where state.isMuted: return state.mutedStatus
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

#if DEBUG
/// DEBUG builds: where the call screen laid out its parts (each round button's glyph and circle, who is answering, the
/// caption, the header and the controls), in the window's space, for its layout tests. Release builds have none of it.
public enum VoiceRoomPanelLayout {
    public private(set) static var frames: [String: CGRect] = [:]

    public static func reset() {
        frames = [:]
    }

    static func record(_ part: String, _ frame: CGRect) {
        frames[part] = frame
    }
}
#endif

private extension View {
    /// A round button's glyph: its text size stops growing at the largest standard size, so it stays inside its circle
    /// at every text size. With an accessibility size, a long press on the button shows it large instead.
    func roundGlyph() -> some View {
        dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// A long press on a round button shows its glyph and name large, as the system's own bars do (iOS).
    @ViewBuilder
    func roundButtonLargeContent(_ title: String, systemImage: String) -> some View {
        #if os(iOS)
        accessibilityShowsLargeContentViewer { Label(title, systemImage: systemImage) }
        #else
        self
        #endif
    }
}

private extension View {
    /// Records this part's frame in DEBUG builds; nothing in Release.
    @ViewBuilder
    func voiceLayoutProbe(_ part: String) -> some View {
        #if DEBUG
        background(GeometryReader { proxy in
            Color.clear
                .onAppear { VoiceRoomPanelLayout.record(part, proxy.frame(in: .global)) }
                .onChange(of: proxy.frame(in: .global)) { VoiceRoomPanelLayout.record(part, $0) }
        })
        #else
        self
        #endif
    }
}
#endif
