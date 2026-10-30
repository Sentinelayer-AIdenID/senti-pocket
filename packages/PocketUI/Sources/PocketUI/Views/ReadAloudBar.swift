#if canImport(SwiftUI)
import SwiftUI

/// What the player bar shows while a message is read aloud. Times are estimates from the text: the phone's voices
/// cannot say how long they will take.
public struct ReadAloudBarState: Equatable, Sendable {
    public let title: String?
    public let isPaused: Bool
    public let elapsedBefore: TimeInterval
    public let sentenceStartedAt: Date?
    public let sentenceLength: TimeInterval
    public let total: TimeInterval
    public let hasGoodVoice: Bool

    public init(title: String?, isPaused: Bool, elapsedBefore: TimeInterval, sentenceStartedAt: Date?,
                sentenceLength: TimeInterval, total: TimeInterval, hasGoodVoice: Bool) {
        self.title = title
        self.isPaused = isPaused
        self.elapsedBefore = elapsedBefore
        self.sentenceStartedAt = sentenceStartedAt
        self.sentenceLength = sentenceLength
        self.total = total
        self.hasGoodVoice = hasGoodVoice
    }

    public func elapsed(at now: Date) -> TimeInterval {
        guard let sentenceStartedAt else { return min(total, elapsedBefore) }
        return min(total, elapsedBefore + min(sentenceLength, max(0, now.timeIntervalSince(sentenceStartedAt))))
    }

    public static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

public enum ReadAloudBarIntent: Equatable, Sendable {
    case togglePause
    case skip(TimeInterval)
    case close
}

/// The player for Listen, as in the assistant apps: who is being read, the time, back and forward 15 s, pause and
/// play, and close (which stops). It stays until the reading ends or is closed.
public struct ReadAloudBar: View {
    private let state: ReadAloudBarState
    private let send: (ReadAloudBarIntent) -> Void

    public init(state: ReadAloudBarState, send: @escaping (ReadAloudBarIntent) -> Void) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            let elapsed = state.elapsed(at: context.date)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: state.isPaused ? "speaker.wave.2" : "speaker.wave.2.fill")
                        .foregroundStyle(PocketPalette.listening)
                        .accessibilityHidden(true)
                    Text(state.title.map { "Reading \($0)" } ?? "Reading aloud")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PocketPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(ReadAloudBarState.clock(elapsed)) / \(ReadAloudBarState.clock(state.total))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PocketPalette.textSecondary)
                        .accessibilityLabel("\(ReadAloudBarState.clock(elapsed)) of about \(ReadAloudBarState.clock(state.total))")
                }
                ProgressView(value: state.total > 0 ? min(1, elapsed / state.total) : 0)
                    .tint(PocketPalette.listening)
                    .accessibilityHidden(true)
                HStack(spacing: 22) {
                    control("gobackward.15", label: "Back 15 seconds", id: "pocket.readAloud.back") { send(.skip(-15)) }
                    control(state.isPaused ? "play.fill" : "pause.fill", label: state.isPaused ? "Play" : "Pause",
                            id: "pocket.readAloud.pause", prominent: true) { send(.togglePause) }
                    control("goforward.15", label: "Forward 15 seconds", id: "pocket.readAloud.forward") { send(.skip(15)) }
                    Spacer(minLength: 0)
                    control("xmark", label: "Stop and close", id: "pocket.readAloud.close") { send(.close) }
                }
                if !state.hasGoodVoice {
                    Text("For a more natural voice: Settings › Accessibility › Spoken Content › Voices, then download an Enhanced or Premium voice.")
                        .font(.caption2)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .pocketFloating(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.readAloud.bar")
    }

    private func control(_ symbol: String, label: String, id: String, prominent: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(prominent ? .title2.weight(.semibold) : .title3)
                .foregroundStyle(prominent ? PocketPalette.accentStrong : PocketPalette.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
#endif
