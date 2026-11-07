import Foundation
import PocketContracts
import PocketUI

/// Someone this account blocked (App Store guideline 1.2): a person or an agent, by the author id messages carry.
struct BlockedAuthor: Codable, Equatable, Identifiable, Sendable {
    /// `human-<login>` or an agent id, lowercased.
    let actorId: String
    /// The name the room showed when you blocked them, else the id without `human-`.
    var name: String
    var blockedAt: Date

    var id: String { actorId }

    static func name(for actorId: String) -> String {
        actorId.hasPrefix("human-") ? String(actorId.dropFirst("human-".count)) : actorId
    }
}

/// The post a block was chosen on (`POST /api/v1/me/blocks`, the report route's fields): the server ties the block to
/// the author stamped on it, the one you saw, even after a rename or a reclaimed login (sentinelayer-api #1118).
struct BlockReference: Codable, Equatable, Sendable {
    let sessionId: String
    /// The message, or the message the reply is on.
    let sequenceId: Int64
    /// The reply, by its action id.
    let replyId: String?
}

/// A block or unblock the server has not taken yet.
struct BlockChange: Codable, Equatable, Sendable {
    let actorId: String
    /// True blocks, false unblocks.
    let blocks: Bool
    /// The post a block was chosen on; nil for an unblock, or a block from anywhere else.
    var reference: BlockReference? = nil
}

/// One block as the server lists it (`GET /api/v1/me/blocks`).
struct ServerBlock: Equatable, Sendable {
    let actorId: String
    let createdAt: Date?
}

/// The blocks API (`GET`, `POST` and `DELETE /api/v1/me/blocks`). A protocol so the list is testable without a network.
protocol BlockListClient: Sendable {
    func blocks() async throws -> [ServerBlock]
    /// Blocks `actorId`, naming the post it was chosen on when there is one.
    func block(_ actorId: String, from reference: BlockReference?) async throws
    func unblock(_ actorId: String) async throws
}

/// The phone's copy of each account's blocks, with the changes the server has not taken yet: blocking works offline and
/// before the API has the route. Kept per account (`RoomSendOutbox.account(token:)`), so one account's blocks are never
/// read under another's on the same phone.
struct BlockListStore: Sendable {
    struct Saved: Codable, Equatable, Sendable {
        var blocks: [BlockedAuthor] = []
        var changes: [BlockChange] = []
    }

    let url: URL

    /// The app's copy, in Application Support (kept across launches and sign-outs, under each account).
    static var standard: BlockListStore? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        return BlockListStore(url: base.appendingPathComponent("room-blocks.json"))
    }

    func load(account: String) -> Saved {
        all()[account] ?? Saved()
    }

    /// False when the phone could not keep it (the list on screen is not affected).
    @discardableResult
    func save(_ saved: Saved, account: String) -> Bool {
        var all = all()
        all[account] = saved.blocks.isEmpty && saved.changes.isEmpty ? nil : saved
        do {
            let data = try JSONEncoder().encode(all)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    private func all() -> [String: Saved] {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([String: Saved].self, from: data) else { return [:] }
        return all
    }
}

/// Who this account blocked, for every room: their messages and replies show as one line (`RoomBlocking.hiddenLine`).
/// Changes show at once from the phone's copy and go to the server when it can take them; the server's list, with the
/// changes still on their way on top, then becomes the copy. One per signed-in account, for that account alone.
@MainActor
final class BlockList: ObservableObject {
    /// Newest first.
    @Published private(set) var blocked: [BlockedAuthor] = []
    /// Lowercased author ids, for hiding.
    @Published private(set) var actorIds: Set<String> = []

    /// The account this list belongs to; nil keeps it in memory only.
    let account: String?
    private let store: BlockListStore?
    private let client: (any BlockListClient)?
    private let now: () -> Date
    /// Changes not taken by the server yet, oldest first; at most one per author.
    private(set) var changes: [BlockChange] = []
    private var isSyncing = false
    private var syncsAgain = false

    init(account: String?, store: BlockListStore?, client: (any BlockListClient)?, now: @escaping () -> Date = { Date() }) {
        self.account = account
        self.store = store
        self.client = client
        self.now = now
        if let account, let store {
            let saved = store.load(account: account)
            blocked = saved.blocks
            changes = saved.changes
        }
        actorIds = Set(blocked.map(\.actorId))
    }

    func isBlocked(_ actorId: String) -> Bool {
        actorIds.contains(actorId.lowercased())
    }

    /// Blocks the target's author; chosen on a message or a reply in room `sessionId`, the server is told which.
    func block(_ target: RoomBlockTarget, in sessionId: String? = nil) {
        let id = target.actorId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return }
        if !actorIds.contains(id) {
            let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
            blocked.insert(BlockedAuthor(actorId: id, name: name.isEmpty ? BlockedAuthor.name(for: id) : name,
                                         blockedAt: now()), at: 0)
        }
        let reference = sessionId.flatMap { sessionId in
            target.sequenceId.map { BlockReference(sessionId: sessionId, sequenceId: $0, replyId: target.replyId) }
        }
        note(BlockChange(actorId: id, blocks: true, reference: reference))
    }

    func unblock(_ actorId: String) {
        let id = actorId.lowercased()
        blocked.removeAll { $0.actorId == id }
        note(BlockChange(actorId: id, blocks: false))
    }

    /// Sends the changes the server has not taken, then reads its list. Offline, or before the API has the route, the
    /// phone's copy stands and the changes wait for the next sync.
    func sync() async {
        guard let client else { return }
        guard !isSyncing else {
            syncsAgain = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            syncsAgain = false
            guard await push(client) else { return }
            guard let server = try? await client.blocks() else { return }
            take(server)
        } while syncsAgain || !changes.isEmpty
    }

    /// A newer change for an author replaces one not sent yet: blocking then unblocking before the server heard sends
    /// only the unblock.
    private func note(_ change: BlockChange) {
        changes.removeAll { $0.actorId == change.actorId }
        changes.append(change)
        changed()
        Task { await sync() }
    }

    /// Sends the kept changes, oldest first. False when the server cannot take them now (offline, signed out, or the
    /// route not there yet): they stay kept.
    private func push(_ client: any BlockListClient) async -> Bool {
        while let change = changes.first {
            do {
                if change.blocks {
                    try await client.block(change.actorId, from: change.reference)
                } else {
                    try await client.unblock(change.actorId)
                }
            } catch RoomSendError.rejected {
                // The server will never take it (yourself, or past its limit): its list decides below.
            } catch {
                return false
            }
            // Only what was sent goes; a different change for the same author, made meanwhile, waits its turn.
            if let index = changes.firstIndex(of: change) { changes.remove(at: index) }
            changed()
        }
        return true
    }

    /// The server's list, with the changes still on their way on top: a block not sent yet stays, an unblock not sent
    /// yet stays gone. Names the phone knows are kept.
    private func take(_ server: [ServerBlock]) {
        let known = Dictionary(blocked.map { ($0.actorId, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [BlockedAuthor] = []
        var seen = Set<String>()
        for item in server {
            let id = item.actorId.lowercased()
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            next.append(BlockedAuthor(actorId: id, name: known[id]?.name ?? BlockedAuthor.name(for: id),
                                      blockedAt: item.createdAt ?? known[id]?.blockedAt ?? now()))
        }
        for change in changes {
            if change.blocks {
                if seen.insert(change.actorId).inserted, let kept = known[change.actorId] { next.append(kept) }
            } else {
                next.removeAll { $0.actorId == change.actorId }
            }
        }
        blocked = next.sorted { $0.blockedAt > $1.blockedAt }
        changed()
    }

    private func changed() {
        let ids = Set(blocked.map(\.actorId))
        if ids != actorIds { actorIds = ids }
        if let account, let store { store.save(BlockListStore.Saved(blocks: blocked, changes: changes), account: account) }
    }
}

/// `GET`, `POST` and `DELETE /api/v1/me/blocks` with the person's own bearer. Bound to the list's account: a token for
/// another account is never used, and an answer that comes back after the account changed is dropped, so one account's
/// list never lands in another's copy.
final class HTTPBlockListClient: BlockListClient, @unchecked Sendable {
    private let apiBaseURL: URL?
    private let urlSession: URLSession
    private let account: String?
    private let tokenProvider: @Sendable () -> String?

    init(
        apiBaseURL: URL?,
        account: String?,
        urlSession: URLSession = SentiHTTPTransportPolicy.liveSession,
        tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }
    ) {
        self.apiBaseURL = apiBaseURL
        self.account = account
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
    }

    func blocks() async throws -> [ServerBlock] {
        let (data, status) = try await send("GET", path: "/api/v1/me/blocks", body: nil)
        guard (200..<300).contains(status) else { throw Self.error(status) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["blocks"] as? [[String: Any]] else {
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        }
        return rows.compactMap { row in
            guard let actorId = row["actorId"] as? String, !actorId.isEmpty else { return nil }
            return ServerBlock(actorId: actorId, createdAt: (row["createdAt"] as? String).flatMap { ParsedSessionTimestamp($0).date })
        }
    }

    func block(_ actorId: String, from reference: BlockReference?) async throws {
        var body: [String: Any] = ["actorId": actorId]
        if let reference {
            body["sessionId"] = reference.sessionId
            body["sequenceId"] = reference.sequenceId
            if let replyId = reference.replyId { body["replyId"] = replyId }
        }
        // Every API with this route takes the post (sentinelayer-api #1118): a refusal is final, never sent again by id.
        let (_, status) = try await send("POST", path: "/api/v1/me/blocks", body: body)
        guard (200..<300).contains(status) else { throw Self.error(status) }
    }

    func unblock(_ actorId: String) async throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = actorId.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty else {
            throw RoomSendError.rejected
        }
        let (_, status) = try await send("DELETE", path: "/api/v1/me/blocks/\(encoded)", body: nil)
        // Already gone answers 204 too.
        guard (200..<300).contains(status) else { throw Self.error(status) }
    }

    /// The API's answer as an error: 422 (yourself, or not an author id) and 409 (the limit) will never be taken;
    /// anything else (401, 403, 404 before the route is deployed, 429, 5xx) may be later.
    static func error(_ status: Int) -> RoomSendError {
        switch status {
        case 401: return .reauthenticationRequired
        case 409, 422: return .rejected
        default: return .retryable(retryAfterSeconds: nil)
        }
    }

    private func send(_ method: String, path: String, body: [String: Any]?) async throws -> (Data, Int) {
        guard let apiBaseURL, var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw RoomSendError.notConfigured
        }
        guard let account, let token = tokenProvider(), !token.isEmpty, RoomSendOutbox.account(token: token) == account else {
            throw RoomSendError.reauthenticationRequired
        }
        components.percentEncodedPath = path
        components.query = nil
        guard let url = components.url else { throw RoomSendError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-Id")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        }
        // Signed out or another account signed in while this was on its way: its answer is not this list's.
        guard tokenProvider() == token else { throw RoomSendError.reauthenticationRequired }
        guard let http = response as? HTTPURLResponse else { throw RoomSendError.retryable(retryAfterSeconds: nil) }
        return (data, http.statusCode)
    }
}
