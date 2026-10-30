import SwiftUI
import UIKit

/// The call screen's own window, over the whole app: the room's bars and the side panel included (Carter, 10-30: "it
/// should be in the actual voice room with you"). A window rather than a full-screen cover, because a cover takes the
/// room off screen, and the room underneath must stay live to hear the answers. Banners still show above it.
@MainActor
final class VoiceCallWindow {
    static let shared = VoiceCallWindow()
    private var window: UIWindow?

    func show<Content: View>(_ content: Content) {
        guard window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        let made = UIWindow(windowScene: scene)
        made.windowLevel = .normal + 1
        // Light or dark as the app is.
        made.overrideUserInterfaceStyle = scene.windows.first { $0.isKeyWindow }?.traitCollection.userInterfaceStyle
            ?? .unspecified
        made.rootViewController = UIHostingController(rootView: content)
        made.transform = CGAffineTransform(translationX: 0, y: made.bounds.height)
        made.isHidden = false
        window = made
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            made.transform = .identity
        }
    }

    func hide() {
        guard let window else { return }
        self.window = nil
        UIView.animate(withDuration: 0.25, animations: {
            window.transform = CGAffineTransform(translationX: 0, y: window.bounds.height)
        }, completion: { _ in
            window.isHidden = true
        })
    }
}
