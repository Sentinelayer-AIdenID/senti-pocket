import Foundation

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
