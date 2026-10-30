import SwiftUI
import UIKit

/// The call screen's own window, over the whole app: the room's bars and the side panel included (Carter, 10-30: "it
/// should be in the actual voice room with you"). A window rather than a full-screen cover, because a cover takes the
/// room off screen, and the room underneath must stay live to hear the answers. Banners still show above it.
@MainActor
final class VoiceCallWindow {
    static let shared = VoiceCallWindow()
    private var window: UIWindow?

    /// Whether a call is on screen: banners stay quiet under it, so a tap can't take the room away mid-call.
    var isShowing: Bool { window != nil }

    /// Shows the call; false when it cannot (one already up, or no screen at all), and the call must not start. A call
    /// answered with Pocket in the background or the phone locked is put on Pocket's screen for when you open it;
    /// until then the phone's own call screen hangs it up.
    @discardableResult
    func show<Content: View>(_ content: Content) -> Bool {
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

    func hide() {
        guard let window else { return }
        self.window = nil
        let view = window.rootViewController?.view
        UIView.animate(withDuration: 0.25, animations: {
            view?.transform = CGAffineTransform(translationX: 0, y: window.bounds.height)
        }, completion: { _ in
            window.isHidden = true
        })
    }
}
