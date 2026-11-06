#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import Combine
import UIKit
#endif

/// The answering agent on the call screen: its avatar as the room shows it, large, with a mouth that opens as loud as
/// its voice is, from the answer's first sound to its end (Carter, 11-05). The phone speaks each agent's answers in that
/// agent's voice, and the speech reports each word as it is said; each word opens the mouth by the beat the call's
/// waveform shows, and it closes as the word fades. With Reduce Motion the avatar stays still and a level bar under it
/// shows the voice instead.
///
/// Nothing here is redrawn as the voice moves: the mouth (or the bar) is a Core Animation layer that follows the
/// meter's ticks itself, so no view's body runs per tick, and it is hidden from VoiceOver (the line under it says who is
/// answering, once per turn).
struct VoiceCallFace: View, Equatable {
    let face: VoiceRoomFace
    let meter: VoiceLevelMeter
    let reduceMotion: Bool

    static let size: CGFloat = 150

    /// The same face on the same meter is not drawn again when the rest of the call screen changes (a caption, a count).
    static func == (lhs: VoiceCallFace, rhs: VoiceCallFace) -> Bool {
        lhs.face == rhs.face && lhs.meter === rhs.meter && lhs.reduceMotion == rhs.reduceMotion
    }

    var body: some View {
        let _ = VoiceCallTrace.faceDrawn()
        VStack(spacing: 12) {
            RoomAvatar(name: face.id, isHuman: false, size: Self.size)
                .overlay(alignment: .bottom) { mouth }
                .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
            levelBar
        }
        .accessibilityHidden(true)
        .accessibilityIdentifier("pocket.voice.face")
    }

    /// The mouth on the avatar, low on it, under the initials.
    @ViewBuilder
    private var mouth: some View {
        #if canImport(UIKit)
        if !reduceMotion {
            VoiceCallMouth(meter: meter, talks: face.talks, style: .mouth)
                .frame(width: 52, height: 24)
                .padding(.bottom, 16)
        }
        #endif
    }

    /// With Reduce Motion, the voice's level under the still avatar.
    @ViewBuilder
    private var levelBar: some View {
        #if canImport(UIKit)
        if reduceMotion {
            VoiceCallMouth(meter: meter, talks: face.talks, style: .bar)
                .frame(width: 120, height: 6)
        }
        #endif
    }
}

/// How often the call's face has been drawn (its body run): it should be once per answer, never per tick of the voice.
public enum VoiceCallTrace {
    private static let lock = NSLock()
    private static var faces = 0

    static func faceDrawn() {
        lock.lock()
        faces &+= 1
        lock.unlock()
    }

    /// The face's draws so far; safe from any thread.
    public static var faceDraws: Int {
        lock.lock()
        defer { lock.unlock() }
        return faces
    }
}

#if canImport(UIKit)
/// The mouth on the face, or the level bar under a still face, moved by the meter's own ticks.
struct VoiceCallMouth: UIViewRepresentable {
    let meter: VoiceLevelMeter
    let talks: Bool
    let style: VoiceCallMouthView.Style

    func makeUIView(context: Context) -> VoiceCallMouthView {
        let view = VoiceCallMouthView(style: style)
        view.follow(meter)
        view.talks = talks
        return view
    }

    func updateUIView(_ view: VoiceCallMouthView, context: Context) {
        view.follow(meter)
        view.talks = talks
    }
}

/// A mouth that opens with the agent's voice (or a bar that fills with it). It follows a `VoiceLevelMeter` directly:
/// each tick of the meter sets its layer, and Core Animation moves it over the tick. Only the agent's voice moves it,
/// never yours, and only while the face talks.
public final class VoiceCallMouthView: UIView {
    public enum Style: Sendable {
        /// A mouth on the avatar that opens with the voice.
        case mouth
        /// A still face's level bar (Reduce Motion): it fills with the voice, without animation.
        case bar
    }

    public let style: Style
    /// How open the mouth is (or how full the bar), 0 to 1.
    public private(set) var level: Double = 0
    /// The face talks now: from the answer's first sound to its end. Otherwise the mouth stays closed.
    public var talks = false {
        didSet {
            guard talks != oldValue else { return }
            if !talks { show(0) }
        }
    }

    private let shape = CAShapeLayer()
    private let track = CALayer()
    private weak var meter: VoiceLevelMeter?
    private var watch: AnyCancellable?

    public init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
        if style == .bar { layer.addSublayer(track) }
        layer.addSublayer(shape)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Follows this meter: each of its ticks sets the mouth to the agent's level. The same meter again changes nothing.
    public func follow(_ meter: VoiceLevelMeter) {
        guard meter !== self.meter else { return }
        self.meter = meter
        watch = meter.$bars.sink { [weak self, weak meter] bars in
            MainActor.assumeIsolated {
                guard let self else { return }
                let agent = meter?.source == .agent
                self.show(self.talks && agent ? (bars.last ?? 0) : 0)
            }
        }
    }

    /// Opens the mouth (or fills the bar) to this level, 0 to 1. The mouth moves over one tick of the meter.
    public func show(_ level: Double) {
        let level = min(1, max(0, level.isFinite ? level : 0))
        guard level != self.level else { return }
        self.level = level
        CATransaction.begin()
        switch style {
        case .mouth:
            CATransaction.setAnimationDuration(VoiceLevelMeter.step)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
            shape.transform = CATransform3DMakeScale(1, Self.openness(level), 1)
        case .bar:
            CATransaction.setDisableActions(true)
            shape.frame = barFrame(level)
        }
        CATransaction.commit()
    }

    /// The mouth's height as a share of its full opening: a closed mouth is a thin line.
    public static func openness(_ level: Double) -> CGFloat {
        0.14 + 0.86 * CGFloat(min(1, max(0, level)))
    }

    /// The mouth's vertical scale now (1 is fully open).
    public var mouthScale: CGFloat { shape.transform.m22 }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style {
        case .mouth:
            shape.bounds = CGRect(origin: .zero, size: bounds.size)
            shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
            shape.path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: bounds.size)).cgPath
            shape.transform = CATransform3DMakeScale(1, Self.openness(level), 1)
        case .bar:
            track.frame = bounds
            track.cornerRadius = bounds.height / 2
            shape.cornerRadius = bounds.height / 2
            shape.frame = barFrame(level)
        }
        CATransaction.commit()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyColors()
    }

    private func barFrame(_ level: Double) -> CGRect {
        CGRect(x: 0, y: 0, width: bounds.width * CGFloat(level), height: bounds.height)
    }

    private func applyColors() {
        switch style {
        case .mouth:
            // Dark on the avatar's colour, as the initials are light on it.
            shape.fillColor = UIColor.black.withAlphaComponent(0.55).cgColor
        case .bar:
            let accent = UIColor(PocketPalette.accent).resolvedColor(with: traitCollection)
            let inset = UIColor(PocketPalette.inset).resolvedColor(with: traitCollection)
            track.backgroundColor = inset.cgColor
            shape.backgroundColor = accent.cgColor
        }
    }
}
#endif
#endif
