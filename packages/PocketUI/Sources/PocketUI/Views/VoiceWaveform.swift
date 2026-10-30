#if canImport(SwiftUI)
import SwiftUI

/// The call's waveform: the last moments of sound as bars, newest on the right, in your colour while you talk and the
/// agent's while it speaks. Quiet, it lies flat.
public struct VoiceWaveform: View {
    @ObservedObject private var meter: VoiceLevelMeter
    private let agentTint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(meter: VoiceLevelMeter, agentTint: Color) {
        self.meter = meter
        self.agentTint = agentTint
    }

    public var body: some View {
        let tint = meter.source == .you ? PocketPalette.listening : agentTint
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(meter.bars.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(tint.opacity(0.35 + 0.65 * level))
                    .frame(width: 4, height: 5 + 55 * level)
            }
        }
        .frame(height: 64)
        .animation(reduceMotion ? nil : .linear(duration: VoiceLevelMeter.step), value: meter.bars)
        .accessibilityHidden(true)
        .accessibilityIdentifier("pocket.voice.waveform")
    }
}
#endif
