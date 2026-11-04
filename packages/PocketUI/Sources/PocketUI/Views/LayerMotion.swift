#if canImport(SwiftUI)
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A small view moved by Core Animation alone (Carter: the app must not get slower). The motion runs in the render
/// server: the room's views are not drawn again for it, frame by frame, and the main thread does nothing while it runs.
/// It is still with Reduce Motion, while the room is covered (a sheet, the side panel, a call), and while the app is not
/// active. A new `fadeKey` fades the content in, the same way, unless Reduce Motion is on.
struct LayerMotion<Content: View>: View {
    enum Kind: Equatable {
        /// Fading down and back, about once a second: something working now.
        case pulse
        /// Growing a little and lifting, then settling: someone thinking.
        case breathe
        /// No motion of its own; only the fade between contents.
        case still
    }

    let kind: Kind
    var fadeKey: AnyHashable = 0
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomIsCovered) private var roomIsCovered
    @Environment(\.scenePhase) private var scenePhase

    init(_ kind: Kind, fadeKey: AnyHashable = 0, @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.fadeKey = fadeKey
        self.content = content()
    }

    /// Whether the motion runs now.
    static func runs(reduceMotion: Bool, roomIsCovered: Bool, scenePhase: ScenePhase) -> Bool {
        !reduceMotion && !roomIsCovered && scenePhase == .active
    }

    var body: some View {
        #if os(iOS)
        LayerMotionHost(kind: kind,
                        isRunning: Self.runs(reduceMotion: reduceMotion, roomIsCovered: roomIsCovered, scenePhase: scenePhase),
                        fades: !reduceMotion, fadeKey: fadeKey, content: content)
        #else
        content
        #endif
    }
}

#if os(iOS)
private struct LayerMotionHost<Content: View>: UIViewRepresentable {
    let kind: LayerMotion<Content>.Kind
    let isRunning: Bool
    let fades: Bool
    let fadeKey: AnyHashable
    let content: Content

    func makeUIView(context: Context) -> LayerMotionView {
        let view = LayerMotionView(content: AnyView(content))
        view.fadeKey = fadeKey
        view.setMotion(Self.animation(kind), running: isRunning)
        return view
    }

    func updateUIView(_ view: LayerMotionView, context: Context) {
        view.show(AnyView(content), fadeKey: fadeKey, fades: fades)
        view.setMotion(Self.animation(kind), running: isRunning)
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LayerMotionView, context: Context) -> CGSize? {
        uiView.host.sizeThatFits(in: CGSize(width: proposal.width ?? .greatestFiniteMagnitude,
                                            height: proposal.height ?? .greatestFiniteMagnitude))
    }

    static func animation(_ kind: LayerMotion<Content>.Kind) -> CAAnimation? {
        switch kind {
        case .still:
            return nil
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

/// Hosts the SwiftUI content once, and moves its layer.
final class LayerMotionView: UIView {
    static let motionKey = "pocket.layerMotion"
    let host: UIHostingController<AnyView>
    var fadeKey: AnyHashable = 0
    private var motion: CAAnimation?
    private var running = false

    init(content: AnyView) {
        host = UIHostingController(rootView: content)
        super.init(frame: .zero)
        // A small piece of a row: never inset by the screen's edges.
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        host.view.backgroundColor = .clear
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// New content; a new `fadeKey` fades it in.
    func show(_ content: AnyView, fadeKey: AnyHashable, fades: Bool) {
        if fadeKey != self.fadeKey {
            self.fadeKey = fadeKey
            if fades, window != nil {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.25
                host.view.layer.add(fade, forKey: "pocket.layerFade")
            }
        }
        host.rootView = content
    }

    func setMotion(_ animation: CAAnimation?, running: Bool) {
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
