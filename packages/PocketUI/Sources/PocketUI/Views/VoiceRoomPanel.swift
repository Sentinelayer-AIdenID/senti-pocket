#if canImport(SwiftUI)
import SwiftUI

/// The voice room, over the bottom of the room: who you are talking with and for how long, what is being said now
/// (yours as it is recognized, or the agent's as it is read aloud), and one big button. Tap it to talk and tap again
/// to send, or hold it while you talk and let go to send. In hands-free, a pause sends and listening comes back after
/// each answer.
public struct VoiceRoomPanel: View {
    private let state: VoiceRoomState
    private let send: (VoiceRoomIntent) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressStarted = Date()
    @State private var startedByPress = false
    @State private var pulse = false

    public init(state: VoiceRoomState, send: @escaping (VoiceRoomIntent) -> Void) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        VStack(spacing: 14) {
            header
            nowLine
            controls
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(PocketPalette.raised)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(PocketPalette.separator.opacity(0.6), lineWidth: 0.5)
        )
        .padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.voice.panel")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(PocketPalette.listening)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(state.isRinging ? "Ringing \(state.title)…" : "Voice · \(state.title)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PocketPalette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            TimelineView(.periodic(from: state.startedAt, by: 1)) { context in
                Text(Self.elapsed(from: state.startedAt, to: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PocketPalette.textSecondary)
            }
            .accessibilityLabel("Call time")
        }
    }

    @ViewBuilder
    private var nowLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let speaker = state.speaker {
                    RoomAvatar(name: speaker, isHuman: false)
                    Text("\(speaker) is speaking")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                } else {
                    Text(statusText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(state.isListening ? PocketPalette.accentStrong : PocketPalette.textSecondary)
                }
                Spacer(minLength: 0)
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
                .font(.callout)
                .foregroundStyle(PocketPalette.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.15), value: lineText)
            if let notice = state.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(PocketPalette.warning)
                    .accessibilityIdentifier("pocket.voice.notice")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            return state.turns.last?.text ?? "Say something to \(state.title)."
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
#endif
