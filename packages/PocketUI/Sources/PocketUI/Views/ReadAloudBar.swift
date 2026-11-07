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

    /// The position as VoiceOver says it: "42 seconds of about 2 minutes 10 seconds".
    public static func spoken(_ elapsed: TimeInterval, of total: TimeInterval) -> String {
        "\(spokenClock(elapsed)) of about \(spokenClock(total))"
    }

    static func spokenClock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        let minutes = whole / 60, rest = whole % 60
        let secondsPart = "\(rest) \(rest == 1 ? "second" : "seconds")"
        guard minutes > 0 else { return secondsPart }
        let minutesPart = "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        return rest == 0 ? minutesPart : "\(minutesPart) \(secondsPart)"
    }

    /// The title's line: whose message is read.
    public var line: String { title.map { "Reading \($0)" } ?? "Reading aloud" }

    /// What VoiceOver reads for the title: the whole line and the position, never cut short as the line on screen
    /// may be.
    public func spokenLine(_ elapsed: TimeInterval) -> String { "\(line), \(Self.spoken(elapsed, of: total))" }
}

public enum ReadAloudBarIntent: Equatable, Sendable {
    case togglePause
    case close
    /// Take me to the message being read (Carter, #55229: "I can't remember what that message was").
    case showMessage
}

/// Where the bar and its controls were laid out, by name ("bar", "title", "line", "pause", "close"), in the window: for
/// the app's hosted tests (the bar sits at the top, one line, every control at least 44 pt and on the screen).
public struct ReadAloudBarFrames: PreferenceKey {
    public static let defaultValue: [String: CGRect] = [:]

    public static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The player for Listen: one thin line at the top of the screen (Carter, #62471: "place the reader overlay at the top
/// and make it thinner"). Who is being read (a tap takes you to the message), the position, pause and play, and close
/// (which stops), each at least 44 pt, with a thin line of progress along its foot. It stays until the reading ends or
/// is closed.
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
            HStack(spacing: 2) {
                Button {
                    send(.showMessage)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: state.isPaused ? "speaker.wave.2" : "speaker.wave.2.fill")
                            .font(.footnote)
                            .foregroundStyle(PocketPalette.listening)
                        Text(state.line)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(PocketPalette.textPrimary)
                            .lineLimit(1)
                            .reportsFrame("line")
                        Spacer(minLength: 4)
                        Text("\(ReadAloudBarState.clock(elapsed)) / \(ReadAloudBarState.clock(state.total))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(PocketPalette.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(state.spokenLine(elapsed))
                .accessibilityHint(state.hasGoodVoice ? "Shows the message being read"
                    : "Shows the message being read. For a more natural voice, download an Enhanced or Premium voice in "
                        + "Settings, Accessibility, Spoken Content, Voices.")
                .accessibilityIdentifier("pocket.readAloud.title")
                .reportsFrame("title")
                control(state.isPaused ? "play.fill" : "pause.fill", label: state.isPaused ? "Play" : "Pause",
                        id: "pocket.readAloud.pause", frame: "pause") { send(.togglePause) }
                control("xmark", label: "Stop reading and close", id: "pocket.readAloud.close", frame: "close") {
                    send(.close)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 2)
            .overlay(alignment: .bottom) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(PocketPalette.listening)
                        .frame(width: proxy.size.width * (state.total > 0 ? min(1, elapsed / state.total) : 0), height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 12)
                .accessibilityHidden(true)
            }
        }
        // Its text stops growing at the largest standard size: at the largest accessibility sizes the position pushed
        // the title out and Close off the screen. The title is cut short if it must be, the controls keep 44 pt, and
        // VoiceOver reads the whole title and position.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .pocketFloating(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.readAloud.bar")
        .reportsFrame("bar")
    }

    private func control(_ symbol: String, label: String, id: String, frame: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(PocketPalette.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
        .reportsFrame(frame)
    }
}

private extension View {
    func reportsFrame(_ name: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ReadAloudBarFrames.self, value: [name: proxy.frame(in: .global)])
        })
    }
}

/// The read-aloud bar a sheet on the room shows at its top while something is read (a thread). The app supplies it, and
/// it watches the reader itself, so a reading never draws the sheet or the room again.
public struct RoomReadAloudBarHost: Equatable {
    let content: () -> AnyView

    public init<Content: View>(@ViewBuilder _ content: @escaping () -> Content) {
        self.content = { AnyView(content()) }
    }

    /// Every one the room screen makes shows the same reader: a new one each time the screen draws is the same bar.
    public static func == (lhs: RoomReadAloudBarHost, rhs: RoomReadAloudBarHost) -> Bool { true }
}

private struct RoomReadAloudBarHostKey: EnvironmentKey {
    static let defaultValue: RoomReadAloudBarHost? = nil
}

extension EnvironmentValues {
    /// Set by the room screen for its sheets (see `RoomReadAloudBarHost`).
    public var roomReadAloudBar: RoomReadAloudBarHost? {
        get { self[RoomReadAloudBarHostKey.self] }
        set { self[RoomReadAloudBarHostKey.self] = newValue }
    }
}
#endif
