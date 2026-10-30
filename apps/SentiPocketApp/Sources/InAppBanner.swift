import Foundation
import PocketSyncClient
import SwiftUI
import UIKit
import UserNotifications

/// How a notification that arrives while Pocket is open is shown.
enum ForegroundPush: Equatable {
    /// For the room on screen, which already shows the message and sounds it: Notification Center only.
    case quiet
    /// Pocket's own banner and soft sound (Carter, #55508), and Notification Center.
    case inApp
    /// iOS's banner and sound, where Pocket has no screen to show its own (signing in).
    case system

    static func presentation(sessionId: String?, roomOnScreen: String?, bannerHosted: Bool) -> ForegroundPush {
        if let sessionId, sessionId == roomOnScreen { return .quiet }
        return bannerHosted ? .inApp : .system
    }

    /// Whether Pocket's banner sounds and taps: as its notification settings say, and silent where the phone's
    /// settings turn this app's notification sounds off.
    static func feedback(soundSetting: Bool, vibrateSetting: Bool, systemSounds: Bool) -> (sound: Bool, haptic: Bool) {
        (soundSetting && systemSounds, vibrateSetting)
    }

    var options: UNNotificationPresentationOptions {
        switch self {
        case .quiet: return [.list]
        case .inApp: return [.list, .badge]
        case .system: return [.banner, .list, .sound, .badge]
        }
    }
}

/// A notification that arrives while Pocket is open, shown inside the app as WhatsApp does (Carter, #55508: "instead
/// of a big sound while I'm on the app it comes anyways inside the app ... makes a more smooth nice sound and I can
/// click on it to go there from the chat that I'm on"). It slides in at the top, plays the room's soft arrival sound
/// instead of the system's alert, stays four seconds, and a tap opens what it is about. It also stays in Notification
/// Center. It shows in a window of its own above the app, so a sheet open in a room does not hide it.
@MainActor
final class InAppBanner: ObservableObject {
    static let shared = InAppBanner(window: InAppBannerWindow())

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let body: String
        let link: SentiLink?
        /// The bell notification this is, when the push says.
        var notificationId: String?
    }

    @Published private(set) var current: Notice?
    /// Whether the signed-in app is up to take a tap on the banner; otherwise iOS shows its own.
    var isHosted = false
    /// Opens what a tapped banner is about (the signed-in app sets it).
    var onOpen: ((SentiLink) -> Void)?
    /// A tapped banner's notification, to read it (the signed-in app sets it).
    var onOpenedNotification: ((SentiLink, String?) -> Void)?
    let lifetime: TimeInterval
    private let window: InAppBannerWindow?

    init(lifetime: TimeInterval = 4, window: InAppBannerWindow? = nil) {
        self.lifetime = lifetime
        self.window = window
    }

    func show(title: String, body: String, link: SentiLink?, notificationId: String? = nil) {
        let notice = Notice(title: title.isEmpty ? "Senti" : title, body: body, link: link, notificationId: notificationId)
        window?.show(self)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { current = notice }
        UIAccessibility.post(notification: .announcement, argument: "\(notice.title): \(notice.body)")
        // Only this notice's own timer puts it away; a newer one gets its full time.
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in
            self?.dismiss(notice.id)
        }
    }

    func dismiss(_ id: UUID? = nil) {
        guard current != nil, id == nil || current?.id == id else { return }
        cardFrame = .zero
        withAnimation(.easeIn(duration: 0.25)) { current = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.current == nil else { return }
            self.window?.hide()
        }
    }

    /// Where the card is on screen, the only place the banner's window takes touches.
    var cardFrame: CGRect = .zero

    /// A tap on the card: put it away and open what it is about.
    func open(_ notice: Notice) {
        dismiss()
        guard let link = notice.link else { return }
        onOpenedNotification?(link, notice.notificationId)
        onOpen?(link)
    }
}

/// The window the banner shows in: above the app and every sheet it has open, up only while a notice is. Only the
/// card takes touches; everywhere else they fall through to the app underneath.
@MainActor
final class InAppBannerWindow {
    private var window: InAppBannerCardWindow?

    func show(_ banner: InAppBanner) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        if window?.windowScene !== scene {
            let made = InAppBannerCardWindow(windowScene: scene)
            made.banner = banner
            made.windowLevel = .alert + 1
            let host = UIHostingController(rootView: InAppBannerView(banner: banner))
            host.view.backgroundColor = .clear
            made.rootViewController = host
            window = made
        }
        // Light or dark as the app is.
        window?.overrideUserInterfaceStyle = scene.windows.first { $0.isKeyWindow }?.traitCollection.userInterfaceStyle
            ?? .unspecified
        window?.isHidden = false
    }

    func hide() {
        window?.isHidden = true
    }
}

final class InAppBannerCardWindow: UIWindow {
    weak var banner: InAppBanner?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let card = banner?.cardFrame, card.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// The banner itself: a frosted card under the status bar; tap to open, swipe up to put it away.
struct InAppBannerView: View {
    @ObservedObject var banner: InAppBanner

    var body: some View {
        VStack(spacing: 0) {
            if let notice = banner.current {
                card(notice)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
    }

    private func card(_ notice: InAppBanner.Notice) -> some View {
        Button {
            banner.open(notice)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bubble.left.fill")
                    .font(.body)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(notice.body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .gesture(DragGesture(minimumDistance: 10).onEnded { value in
            if value.translation.height < -10 { banner.dismiss() }
        })
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { banner.cardFrame = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { banner.cardFrame = $0 }
        })
        .padding(.horizontal, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityHint(notice.link == nil ? "" : "Opens it")
        .accessibilityIdentifier("pocket.inAppBanner")
    }
}
