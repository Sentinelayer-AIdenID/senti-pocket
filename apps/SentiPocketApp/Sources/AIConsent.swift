import Foundation
import PocketUI

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
/// answers it with AI and posts your reply, so it waits here for this account's OK. The signed-in screens give it the
/// account's consent and show its question (`aiConsentPrompt`); until they have, the phone's copy for the account
/// signed in answers.
@MainActor
final class AIConsentAsker: ObservableObject {
    static let shared = AIConsentAsker()

    /// The question while something waits on it.
    @Published var held: AIConsentHeld?
    /// The signed-in account's consent, set by the signed-in screens.
    weak var consent: AIConsent?
    private let storedConsent: @MainActor () -> AIConsent

    init(storedConsent: @escaping @MainActor () -> AIConsent = {
        AIConsent(account: RoomSendOutbox.account(token: SessionTokenStore.load()))
    }) {
        self.storedConsent = storedConsent
    }

    /// True at once when this account has said OK; otherwise asks, and is true only once OK is tapped. Not now, or the
    /// wait being cancelled (the call ended), is false.
    func allows() async -> Bool {
        if (consent ?? storedConsent()).isGiven { return true }
        guard !Task.isCancelled else { return false }
        let answer = OneAnswer()
        let request = AIConsentHeld({ answer.give(true) }, onDecline: { answer.give(false) })
        let requestId = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                answer.resume = { continuation.resume(returning: $0) }
                held = request
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                answer.give(false)
                if self?.held?.id == requestId { self?.held = nil }
            }
        }
    }

    /// Resumes a wait once, whichever answer comes first.
    @MainActor
    private final class OneAnswer {
        var resume: ((Bool) -> Void)?

        func give(_ allowed: Bool) {
            let resume = self.resume
            self.resume = nil
            resume?(allowed)
        }
    }
}
