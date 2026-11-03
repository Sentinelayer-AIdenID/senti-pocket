import Foundation

/// Room messages whose send did not finish, kept on the phone across an app kill. A message whose
/// POST may have reached the room but whose answer was lost comes back after a relaunch under its original client
/// id, so retrying it is the same request and the room keeps one copy; typing it again would make a new id the room
/// cannot match. Kept per account and room, at most `kept` items for at most `maxAge`.
struct RoomSendOutbox: Sendable {
    struct Item: Codable, Equatable, Sendable {
        let clientId: String
        let text: String
        let createdAt: Date
    }

    static let kept = 50
    static let maxAge: TimeInterval = 24 * 60 * 60

    let url: URL
    private let now: @Sendable () -> Date

    init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    /// The app's outbox, in Application Support (not backed up as user content, kept across launches).
    static var standard: RoomSendOutbox? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        return RoomSendOutbox(url: base.appendingPathComponent("room-send-outbox.json"))
    }

    /// The account part of the key: your author ids, so another account on this phone never sees your unsent text.
    static func account(_ ownAuthorIds: Set<String>) -> String? {
        let ids = ownAuthorIds.map { $0.lowercased() }.filter { $0.hasPrefix("human-") }.sorted()
        return ids.isEmpty ? nil : ids.joined(separator: ",")
    }

    /// The signed-in account from its session token's subject, read only to keep each account's unsent text apart on
    /// this phone (the token is not verified here; the server does that on every send).
    static func account(token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body += "=" }
        guard let data = Data(base64Encoded: body),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = claims["sub"] as? String, !subject.isEmpty else { return nil }
        return "sub:" + subject
    }

    /// Signing out forgets every unsent message on the phone.
    static func clearStandard() {
        guard let url = standard?.url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func items(account: String, sessionId: String) -> [Item] {
        load()[Self.key(account, sessionId)] ?? []
    }

    /// False when the phone could not keep it (the send itself is not affected).
    @discardableResult
    func add(_ item: Item, account: String, sessionId: String) -> Bool {
        var all = load()
        var items = all[Self.key(account, sessionId)] ?? []
        items.removeAll { $0.clientId == item.clientId }
        items.append(item)
        all[Self.key(account, sessionId)] = Array(items.suffix(Self.kept))
        return save(all)
    }

    @discardableResult
    func remove(clientId: String, account: String, sessionId: String) -> Bool {
        var all = load()
        let key = Self.key(account, sessionId)
        guard var items = all[key], items.contains(where: { $0.clientId == clientId }) else { return true }
        items.removeAll { $0.clientId == clientId }
        all[key] = items.isEmpty ? nil : items
        return save(all)
    }

    private static func key(_ account: String, _ sessionId: String) -> String { account + "|" + sessionId }

    private func load() -> [String: [Item]] {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([String: [Item]].self, from: data) else { return [:] }
        let oldest = now().addingTimeInterval(-Self.maxAge)
        return all.compactMapValues { items in
            let fresh = items.filter { $0.createdAt >= oldest }
            return fresh.isEmpty ? nil : fresh
        }
    }

    private func save(_ all: [String: [Item]]) -> Bool {
        do {
            let data = try JSONEncoder().encode(all)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }
}
