import Foundation
import Security

/// Where the Apple Calendar subscribe link is kept for the signed-in person, so Subscribe opens it again instead of
/// making a new one (each new one stops the old). The link carries a secret token, so it lives only in the Keychain.
protocol CalendarLinkKeeping: Sendable {
    /// The link kept for this person, if any. Another person's link is never returned (and is dropped).
    func link(for person: String) -> URL?
    /// Keeps this link for this person, in place of any link kept before, theirs or anyone else's.
    func keep(_ link: URL, for person: String)
    /// Drops every kept link: on sign-out, on a refused credential (another account may sign in next) and with the
    /// account's deletion.
    func forgetAll()
}

/// The three Keychain calls the vault makes. The app uses the system's; tests stand in for it where the host has no
/// Keychain (a simulator app built unsigned, as CI builds it, gets errSecMissingEntitlement).
protocol KeychainItems: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?)
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychain: KeychainItems {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: CFTypeRef?) {
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        return (status, out)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// The link as one Keychain item per service: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (never in a backup,
/// never on another device, readable only while the phone is unlocked), its account the signed-in person. Never in
/// UserDefaults, files, logs or analytics.
struct CalendarLinkVault: CalendarLinkKeeping {
    static let live = CalendarLinkVault(service: "com.plexaura.sentipocket.calendar-feed-link")

    let service: String
    let keychain: any KeychainItems

    init(service: String, keychain: any KeychainItems = SystemKeychain()) {
        self.service = service
        self.keychain = keychain
    }

    func link(for person: String) -> URL? {
        for account in accounts() where account != person {
            _ = keychain.delete(base(account: account))
        }
        var query = base(account: person)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let found = keychain.copyMatching(query)
        guard found.status == errSecSuccess, let data = found.result as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: text)
    }

    func keep(_ link: URL, for person: String) {
        forgetAll()
        var item = base(account: person)
        item[kSecValueData as String] = Data(link.absoluteString.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        // If the Keychain refuses it, nothing is kept: the next Subscribe asks again before making a link.
        _ = keychain.add(item)
    }

    func forgetAll() {
        _ = keychain.delete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service])
    }

    /// The accessibility class of the person's item, as the Keychain reports it (for the tests).
    func accessibility(for person: String) -> String? {
        var query = base(account: person)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let found = keychain.copyMatching(query)
        guard found.status == errSecSuccess, let attributes = found.result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessible as String] as? String
    }

    /// Every person with a kept link (one at most, as `keep` leaves it).
    func accounts() -> [String] {
        let found = keychain.copyMatching([kSecClass as String: kSecClassGenericPassword,
                                           kSecAttrService as String: service,
                                           kSecReturnAttributes as String: true,
                                           kSecMatchLimit as String: kSecMatchLimitAll])
        guard found.status == errSecSuccess, let items = found.result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func base(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
