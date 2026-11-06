#if canImport(SwiftUI)
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Small shapes moved by Core Animation alone (Carter: the app must not get slower). The motion runs in the render
/// server: the room's views are not drawn again for it, frame by frame, and the main thread does nothing while it runs.
/// The shapes are drawn by UIKit, not hosted SwiftUI, so laying out the room never re-lays them out (a hosted view's
/// size, asked again and again at the largest text sizes, kept the main thread busy). They are still with Reduce Motion,
/// while the room is covered (a sheet, the side panel, a call), and while the app is not active.
enum LayerMotion {
    enum Kind: Equatable {
        /// Fading down and back, about once a second: something working now.
        case pulse
        /// Growing a little, lifting and tilting, then settling: someone thinking.
        case breathe
    }

    /// Whether the motion runs now.
    static func runs(reduceMotion: Bool, roomIsCovered: Bool, scenePhase: ScenePhase) -> Bool {
        !reduceMotion && !roomIsCovered && scenePhase == .active
    }
}

/// The Working row's dot, pulsing while its agent works.
struct PulsingDot: View {
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomIsCovered) private var roomIsCovered
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        #if os(iOS)
        LayerMotionHost(kind: .pulse, look: .dot(UIColor(color)),
                        isRunning: LayerMotion.runs(reduceMotion: reduceMotion, roomIsCovered: roomIsCovered,
                                                    scenePhase: scenePhase))
        #else
        Circle().fill(color)
        #endif
    }
}

/// An agent's avatar (as `RoomAvatar` draws it) moving a little while it thinks.
struct MovingAvatar: View {
    let name: String
    var size: CGFloat = 26

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomIsCovered) private var roomIsCovered
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        #if os(iOS)
        LayerMotionHost(kind: .breathe,
                        look: .badge(text: RoomAvatar.initials(for: name), color: UIColor(RoomAvatar.tint(for: name)),
                                     cornerRadius: (size * 0.27).rounded(), fontSize: (size * 0.42).rounded()),
                        isRunning: LayerMotion.runs(reduceMotion: reduceMotion, roomIsCovered: roomIsCovered,
                                                    scenePhase: scenePhase))
            .frame(width: size, height: size)
        #else
        RoomAvatar(name: name, isHuman: false, size: size)
        #endif
    }
}

#if os(iOS)
private struct LayerMotionHost: UIViewRepresentable {
    let kind: LayerMotion.Kind
    let look: LayerMotionView.Look
    let isRunning: Bool

    func makeUIView(context: Context) -> LayerMotionView {
        let view = LayerMotionView()
        view.show(look)
        view.setMotion(Self.animation(kind), running: isRunning)
        return view
    }

    func updateUIView(_ view: LayerMotionView, context: Context) {
        view.show(look)
        view.setMotion(Self.animation(kind), running: isRunning)
    }

    static func animation(_ kind: LayerMotion.Kind) -> CAAnimation {
        switch kind {
        case .pulse:
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0.3
            fade.duration = 0.9
            fade.autoreverses = true
            fade.repeatCount = .infinity
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return fade
        case .breathe:
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = 1.08
            let lift = CABasicAnimation(keyPath: "transform.translation.y")
            lift.fromValue = 0
            lift.toValue = -1.5
            let tilt = CABasicAnimation(keyPath: "transform.rotation.z")
            tilt.fromValue = -0.04
            tilt.toValue = 0.04
            let group = CAAnimationGroup()
            group.animations = [grow, lift, tilt]
            group.duration = 1.1
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return group
        }
    }
}

/// A dot or an avatar's badge drawn by UIKit, and its layer's motion.
final class LayerMotionView: UIView {
    enum Look: Equatable {
        case dot(UIColor)
        /// Initials on a rounded square, as `RoomAvatar` draws an agent.
        case badge(text: String, color: UIColor, cornerRadius: CGFloat, fontSize: CGFloat)
    }

    static let motionKey = "pocket.layerMotion"
    private var look: Look?
    private var motion: CAAnimation?
    private var running = false
    private lazy var label: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)
        return label
    }()

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        // Only something to look at: a tap goes to the row it sits in.
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// What it shows; the same look again changes nothing.
    func show(_ look: Look) {
        guard look != self.look else { return }
        self.look = look
        switch look {
        case .dot(let color):
            backgroundColor = color
            layer.cornerCurve = .circular
        case .badge(let text, let color, let cornerRadius, let fontSize):
            backgroundColor = color
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            label.text = text
            label.font = .systemFont(ofSize: fontSize, weight: .bold)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if case .dot = look { layer.cornerRadius = min(bounds.width, bounds.height) / 2 }
        if case .badge = look { label.frame = bounds }
    }

    func setMotion(_ animation: CAAnimation, running: Bool) {
        motion = animation
        self.running = running
        apply()
    }

    /// Core Animation drops a layer's animations when it leaves the window, and the app's return from the background
    /// can too: put back on arrival.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    private func apply() {
        guard running, let motion, window != nil else {
            layer.removeAnimation(forKey: Self.motionKey)
            return
        }
        if layer.animation(forKey: Self.motionKey) == nil { layer.add(motion, forKey: Self.motionKey) }
    }

    /// Whether the motion is on the layer now (for tests).
    var isMoving: Bool { layer.animation(forKey: Self.motionKey) != nil }
}
#endif
#endif
