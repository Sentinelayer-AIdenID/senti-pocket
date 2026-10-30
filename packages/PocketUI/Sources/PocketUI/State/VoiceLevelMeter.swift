import Combine
import Foundation

/// How loud a voice call is from moment to moment, for the call screen's waveform (Carter, 10-30: "a wave form for
/// when yall talking"). Your voice is measured at the microphone. An agent's voice comes from the phone's speech
/// synthesizer, which reports words, not loudness, so each word it says is one beat.
///
/// It keeps the last `barCount` steps: twenty a second, each the loudest level heard since the step before, fading
/// when nothing new is heard. It ticks only while there is something to show.
@MainActor
public final class VoiceLevelMeter: ObservableObject {
    public enum Source: Equatable, Sendable {
        case you
        case agent
    }

    public static let barCount = 32
    static let step: TimeInterval = 1.0 / 20
    /// What is left of a level after one step without anything new.
    static let fade = 0.78

    @Published public private(set) var bars: [Double] = Array(repeating: 0, count: VoiceLevelMeter.barCount)
    @Published public private(set) var source: Source = .you
    private var current = 0.0
    private var ticker: Timer?

    public init() {}

    /// A level from 0 (silence) to 1 (loud).
    public func hear(_ level: Double, from source: Source) {
        if source != self.source { self.source = source }
        current = max(current, min(1, max(0, level)))
        guard ticker == nil else { return }
        let ticker = Timer(timeInterval: Self.step, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    /// One step on: the newest bar takes the level heard since the last step, then the level fades. Once every bar
    /// is quiet the meter stops ticking.
    func advance() {
        bars.removeFirst()
        bars.append(current)
        current *= Self.fade
        if current < 0.02 { current = 0 }
        if current == 0, bars.allSatisfy({ $0 == 0 }) { stopTicking() }
    }

    /// The call ended: quiet at once.
    public func reset() {
        stopTicking()
        current = 0
        bars = Array(repeating: 0, count: Self.barCount)
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    var isTicking: Bool { ticker != nil }

    /// A microphone level in decibels (about -50 for a quiet room, 0 at the loudest) as 0 to 1.
    public nonisolated static func level(decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels + 50) / 42))
    }

    /// One spoken word as a beat: longer words a little stronger.
    public nonisolated static func level(wordLength: Int) -> Double {
        min(1, 0.5 + Double(max(0, wordLength)) * 0.05)
    }
}
