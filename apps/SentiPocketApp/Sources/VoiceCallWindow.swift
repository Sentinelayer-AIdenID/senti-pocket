import SwiftUI
import UIKit

/// The call screen's own window, over the whole app: the room's bars and the side panel included, so you are in the
/// call. A window rather than a full-screen cover, because a cover takes the
/// room off screen, and the room underneath must stay live to hear the answers. Banners still show above it.
///
/// A voice room's call can be minimized (ticket bcdba8f3): the window hides, the call goes on, and a bar at the top of
/// the app (`VoiceCallBarSlot`) shows it, with Mute and End, until a tap on the bar brings the window back or the call
/// ends.
@MainActor
final class VoiceCallWindow: ObservableObject {
    static let shared = VoiceCallWindow()
    private var window: UIWindow?
    /// What the call on screen shows in its bar when minimized; nil for a call that cannot be (a question call).
    private var bar: VoiceCallBarModel?
    /// The call minimized to its bar, while it is.
    @Published private(set) var minimized: VoiceCallBarModel?

    /// Whether a call is on, on screen or minimized to its bar: banners stay quiet, so a tap can't take the room away
    /// mid-call (the call ends with its room).
    var isShowing: Bool { window != nil }

    /// Shows the call; false when it cannot (one already up, or no screen at all), and the call must not start. A call
    /// answered with Pocket in the background or the phone locked is put on Pocket's screen for when you open it;
    /// until then the phone's own call screen hangs it up. `bar` is what the call shows when minimized; without one it
    /// cannot be.
    @discardableResult
    func show<Content: View>(_ content: Content, bar: VoiceCallBarModel? = nil) -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard window == nil,
              let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return false }
        let made = UIWindow(windowScene: scene)
        made.windowLevel = .normal + 1
        // Light or dark as the app is.
        made.overrideUserInterfaceStyle = scene.windows.first { $0.isKeyWindow }?.traitCollection.userInterfaceStyle
            ?? .unspecified
        let host = UIHostingController(rootView: content)
        made.rootViewController = host
        made.isHidden = false
        window = made
        self.bar = bar
        CallPresence.shared.callScreen(up: true)
        // It slides up. The view moves, not the window: a window's own transform is not reliably drawn.
        let below = CGAffineTransform(translationX: 0, y: made.bounds.height)
        host.view.transform = below
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, animations: {
            host.view.transform = .identity
        }, completion: { _ in
            host.view.transform = .identity
        })
        return true
    }

    /// Minimizes the call: its screen slides down and its window hides, and the bar shows over the app. Nothing else
    /// changes: the call keeps listening and speaking, its room stays live, and `CallPresence` still says a call is on,
    /// so no alert comes up over it.
    func minimize() {
        guard let window, let bar, minimized == nil else { return }
        CrashReporter.shared.note("call minimized")
        minimized = bar
        let view = window.rootViewController?.view
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: {
            view?.transform = CGAffineTransform(translationX: 0, y: window.bounds.height)
        }, completion: { _ in
            // Brought back or hung up before the slide ended: left as that left it.
            guard self.window === window, self.minimized != nil else { return }
            window.isHidden = true
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        })
    }

    /// Brings a minimized call's screen back over the app.
    func restore() {
        guard let window, minimized != nil else { return }
        CrashReporter.shared.note("call screen back")
        minimized = nil
        // A draft being typed in the room would keep the keyboard up over the call's buttons.
        endAllEditing()
        window.isHidden = false
        let view = window.rootViewController?.view
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState], animations: {
            view?.transform = .identity
        }, completion: { _ in
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        })
    }

    func hide() {
        guard let window else { return }
        self.window = nil
        bar = nil
        minimized = nil
        CallPresence.shared.callScreen(up: false)
        let view = window.rootViewController?.view
        UIView.animate(withDuration: 0.25, animations: {
            view?.transform = CGAffineTransform(translationX: 0, y: window.bounds.height)
        }, completion: { _ in
            window.isHidden = true
        })
    }
}

#if DEBUG
extension VoiceCallWindow {
    /// The call screen's window while a call is on, shown or minimized, for the hosted tests (DEBUG only).
    var callWindow: UIWindow? { window }
}
#endif
