import Foundation
import PocketSyncClient
import SwiftUI
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
/// Center.
@MainActor
final class InAppBanner: ObservableObject {
    static let shared = InAppBanner()

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let body: String
        let link: SentiLink?
    }

    @Published private(set) var current: Notice?
    /// Whether a screen that shows the banner is up (the signed-in app); otherwise iOS shows its own.
    var isHosted = false
    let lifetime: TimeInterval

    init(lifetime: TimeInterval = 4) {
        self.lifetime = lifetime
    }

    func show(title: String, body: String, link: SentiLink?) {
        let notice = Notice(title: title.isEmpty ? "Senti" : title, body: body, link: link)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) { current = notice }
        // Only this notice's own timer puts it away; a newer one gets its full time.
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in
            self?.dismiss(notice.id)
        }
    }

    func dismiss(_ id: UUID? = nil) {
        guard current != nil, id == nil || current?.id == id else { return }
        withAnimation(.easeIn(duration: 0.25)) { current = nil }
    }
}

/// The banner itself: a frosted card under the status bar; tap to open, swipe up to put it away.
struct InAppBannerView: View {
    @ObservedObject var banner: InAppBanner
    let onOpen: (SentiLink) -> Void

    var body: some View {
        if let notice = banner.current {
            Button {
                banner.dismiss()
                if let link = notice.link { onOpen(link) }
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
                .padding(.horizontal, 10)
            }
            .buttonStyle(.plain)
            .gesture(DragGesture(minimumDistance: 10).onEnded { value in
                if value.translation.height < -10 { banner.dismiss() }
            })
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityHint(notice.link == nil ? "" : "Opens it")
            .accessibilityIdentifier("pocket.inAppBanner")
        }
    }
}
