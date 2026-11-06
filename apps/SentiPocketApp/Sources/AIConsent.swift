import Foundation
import PocketUI
import SwiftUI
import UIKit
import UserNotifications

/// Whether this account said OK to what it shares in rooms being shared with AI (App Store guideline 5.1.2(i)): the
/// rooms' agents and Senti's own AI features (`AIConsentText.notice`). Asked once, before its first write to any room
/// (a message, a reply, a file, an edit, a reaction, a ticket, a call), whatever the room. Kept on the phone under the
/// account (`RoomSendOutbox.account(token:)`), so another account signing in here is asked for itself. Withdrawn in
/// Settings, it is asked again.
@MainActor
final class AIConsent: ObservableObject {
    /// When this account said OK; nil until it does, and again after it withdraws.
    @Published private(set) var givenAt: Date?

    /// The account this is for; nil keeps the answer in memory only, so it is asked again after a relaunch.
    let account: String?
    private let defaults: UserDefaults
    private let now: () -> Date

    init(account: String?, defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }) {
        self.account = account
        self.defaults = defaults
        self.now = now
        givenAt = account.flatMap { defaults.object(forKey: Self.key($0)) as? Date }
    }

    var isGiven: Bool { givenAt != nil }

    /// A write to a room asks first, until this account says OK.
    var asks: Bool { !isGiven }

    func grant() {
        let date = now()
        givenAt = date
        if let account { defaults.set(date, forKey: Self.key(account)) }
    }

    func withdraw() {
        givenAt = nil
        if let account { defaults.removeObject(forKey: Self.key(account)) }
    }

    static func key(_ account: String) -> String { "pocket.aiConsent." + account }
}

/// The same question, for what is not a room screen: a dial (Senti calling you about a decision) hears what you say,
/// answers it with AI and posts your reply, so it goes on only with this account's OK; the calendar's Draft sends what
/// you typed to Senti's AI, so it asks the same way. The question shows over the
/// whole app, any sheet open in it included (`AIConsentWindow`), and goes again when the call ends. With the app not on
/// screen to show it (the phone locked, Pocket in the background), the call ends at once and a notification says why:
/// it never waits silent. The signed-in screens give it the account's consent; until they have, the phone's copy for
/// the account signed in answers.
@MainActor
final class AIConsentAsker {
    static let shared = AIConsentAsker()

    /// The question on screen; `withdraw` takes it away.
    struct Showing {
        let withdraw: @MainActor () -> Void
    }

    /// What a call ended without asking says, where it is seen.
    static let notOnScreen = "Senti's call ended: open Senti Pocket and say whether what you share may go to AI, "
        + "then take the call again."

    /// The signed-in account's consent, set by the signed-in screens.
    weak var consent: AIConsent?
    private let storedConsent: @MainActor () -> AIConsent
    /// Shows the question (OK, Not now); nil when nothing can show it now.
    private let show: @MainActor (_ onAllow: @escaping () -> Void, _ onNotNow: @escaping () -> Void) -> Showing?
    /// Says why a call ended without the question.
    private let tell: @MainActor (String) -> Void

    init(
        storedConsent: @escaping @MainActor () -> AIConsent = {
            AIConsent(account: RoomSendOutbox.account(token: SessionTokenStore.load()))
        },
        show: @escaping @MainActor (_ onAllow: @escaping () -> Void, _ onNotNow: @escaping () -> Void) -> Showing? = {
            AIConsentWindow.show(onAllow: $0, onNotNow: $1)
        },
        tell: @escaping @MainActor (String) -> Void = { AIConsentWindow.notify($0) }
    ) {
        self.storedConsent = storedConsent
        self.show = show
        self.tell = tell
    }

    /// True at once when this account has said OK. Otherwise asks, and is true only once OK is tapped; Not now, or the
    /// call ending first, is false, and the question goes. Nothing on screen to ask with is false at once, said.
    func allows() async -> Bool {
        let consent = self.consent ?? storedConsent()
        if consent.isGiven { return true }
        guard !Task.isCancelled else { return false }
        let answer = OneAnswer()
        // An answer after the wait ended (the call hung up) changes nothing.
        guard let showing = show({
            guard answer.isOpen else { return }
            consent.grant()
            answer.give(true)
        }, { answer.give(false) }) else {
            tell(Self.notOnScreen)
            return false
        }
        let allowed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                answer.wait { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in answer.give(false) }
        }
        // Answered, or the call ended: the question goes either way.
        showing.withdraw()
        return allowed
    }

    /// Resumes a wait once, whichever answer comes first, an answer given before the wait began included.
    @MainActor
    private final class OneAnswer {
        private var resume: ((Bool) -> Void)?
        private var given: Bool?

        var isOpen: Bool { given == nil }

        func wait(_ resume: @escaping (Bool) -> Void) {
            if let given {
                resume(given)
            } else {
                self.resume = resume
            }
        }

        func give(_ allowed: Bool) {
            guard given == nil else { return }
            given = allowed
            let resume = self.resume
            self.resume = nil
            resume?(allowed)
        }
    }
}

/// The dial's AI question in a window of its own, above the app and every sheet open in it (as the in-app banner is),
/// up only while it asks.
@MainActor
enum AIConsentWindow {
    static func show(onAllow: @escaping () -> Void, onNotNow: @escaping () -> Void) -> AIConsentAsker.Showing? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return nil }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert
        // Light or dark as the app is.
        window.overrideUserInterfaceStyle = scene.windows.first { $0.isKeyWindow }?.traitCollection.userInterfaceStyle
            ?? .unspecified
        let host = UIHostingController(rootView: AIConsentWindowContent(onAllow: onAllow, onNotNow: onNotNow))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        UIAccessibility.post(notification: .screenChanged, argument: nil)
        return AIConsentAsker.Showing {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// A notification, for a call that ended with Pocket off screen.
    static func notify(_ text: String) {
        CrashReporter.shared.note("dial ended: no screen to ask about AI")
        let content = UNMutableNotificationContent()
        content.title = "Senti Pocket"
        content.body = text
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "pocket.dial.aiConsent", content: content, trigger: nil)
        )
    }
}

/// The sheet the window shows: the same as in the rooms, answered with OK or Not now, never swiped away.
private struct AIConsentWindowContent: View {
    let onAllow: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        Color.clear
            .sheet(isPresented: .constant(true)) {
                RoomAIConsentSheet(onAllow: onAllow, onNotNow: onNotNow)
                    .interactiveDismissDisabled()
            }
    }
}
