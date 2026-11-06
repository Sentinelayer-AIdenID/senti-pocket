import SwiftUI
import UIKit

/// The call screen's own window, over the whole app: the room's bars and the side panel included, so you are in the
/// call. A window rather than a full-screen cover, because a cover takes the
/// room off screen, and the room underneath must stay live to hear the answers. Banners still show above it.
@MainActor
final class VoiceCallWindow {
    static let shared = VoiceCallWindow()
    private var window: UIWindow?
    /// The window that had the keys before the call (the room's), given them back when the call ends.
    private weak var keyBefore: UIWindow?
    /// While the call is up: a box under it that starts editing lets its keyboard go.
    private var editingWatch: [NSObjectProtocol] = []

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
        // The call has no box to type in (Carter, 11-05: a keyboard came up during a call with no box, and could not be
        // put away). A box being written in under it (the room's) lets its keyboard go, and the call's window asks for
        // the keys. While the call is up, a box under it that starts editing again (focus given back to it, or iOS
        // restoring it as Pocket comes back to the front) lets its keyboard go at once.
        keyBefore = scene.windows.first { $0.isKeyWindow }
        for other in scene.windows { other.endEditing(true) }
        made.makeKeyAndVisible()
        window = made
        editingWatch = [UITextView.textDidBeginEditingNotification, UITextField.textDidBeginEditingNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { note in
                let box = note.object as? UIView
                MainActor.assumeIsolated { VoiceCallWindow.shared.keepKeyboardAway(from: box) }
            }
        }
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
        for watch in editingWatch { NotificationCenter.default.removeObserver(watch) }
        editingWatch = []
        // The room has the keys again, so a tap in its box writes there as before. If the window that had them is gone
        // (or none had them), the front window the call covered takes them: the call's window never keeps them.
        let below = window.windowScene?.windows.filter {
            $0 !== window && !$0.isHidden && $0.windowLevel.rawValue < window.windowLevel.rawValue
        } ?? []
        let front = below.map { $0.windowLevel.rawValue }.max()
        let back = keyBefore.flatMap { $0.isHidden || $0.windowScene == nil ? nil : $0 }
            ?? below.last { $0.windowLevel.rawValue == front }
        back?.makeKey()
        keyBefore = nil
        let view = window.rootViewController?.view
        UIView.animate(withDuration: 0.25, animations: {
            view?.transform = CGAffineTransform(translationX: 0, y: window.bounds.height)
        }, completion: { _ in
            window.isHidden = true
        })
    }

    /// A box began editing while the call is up. One the call covers (in a window under it) lets its keyboard go on the
    /// next turn of the run loop, after its own begin-editing work; one above the call (an alert's) keeps it.
    private func keepKeyboardAway(from box: UIView?) {
        guard let box, let call = window, let under = box.window, under !== call,
              under.windowLevel <= call.windowLevel else { return }
        DispatchQueue.main.async { [weak box] in
            guard let box, box.isFirstResponder, self.window != nil else { return }
            box.resignFirstResponder()
        }
    }
}
