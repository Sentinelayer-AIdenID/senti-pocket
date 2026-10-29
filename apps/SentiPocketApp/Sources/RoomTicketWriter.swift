import Foundation
import PocketContracts
import PocketSyncClient

/// Why a ticket write did not land. Response bodies are never surfaced, only their class and the API's error code.
enum RoomTicketWriteError: Error, Equatable {
    case notConfigured
    case reauthenticationRequired
    /// 403, or a 404 that is not the ticket's: this account may read the room but not write tickets, or left it.
    case notAllowed
    /// 404 `TICKET_NOT_FOUND`.
    case notFound
    /// 409: `TICKET_CONFLICT` (changed since it was loaded, or someone holds a live lease), `STALE_LEASE` (the lease
    /// ended or was taken over), `IDEMPOTENCY_CONFLICT` (the key was already used for a different request).
    case conflict(code: String)
    /// No answer, 425, 429, 5xx or `TICKET_WRITES_PAUSED`: the same request may land later.
    case retryable(retryAfterSeconds: Int?)
    /// 400/422: the API refused the request itself.
    case rejected

    var userMessage: String {
        switch self {
        case .notConfigured: return "This build cannot reach Senti."
        case .reauthenticationRequired: return "Sign in again to change tickets."
        case .notAllowed: return "You can read this room's tickets but not change them."
        case .notFound: return "This ticket is no longer in this room."
        case .conflict(let code) where code == "STALE_LEASE":
            return "Your lease on this ticket ended or was taken over."
        case .conflict:
            return "This ticket changed since you opened it. It has been refreshed; check it and try again."
        case .retryable: return "Not saved. Check your connection and try again."
        case .rejected: return "Senti did not accept this change."
        }
    }
}

/// The lease credential a claim returns, once: no read ever returns the lease id again. Kept to release the lease.
struct RoomTicketLeaseCredential: Codable, Equatable, Sendable {
    let leaseId: String
    let fence: Int64
    let expiresAt: String?
    /// The ticket's version once claimed: a later version with no lease means the lease was given back or ended.
    let claimedVersion: Int64
}

/// One ticket write, with the API's own limits (sentinelayer-api `SessionTicketCreatePayload`,
/// `SessionTicketUpdatePayload`, `TicketClaimPayload`, `TicketReleasePayload` at 742d8c1).
enum RoomTicketWrite: Equatable, Sendable {
    case file(title: String, body: String?, assignee: String?)
    /// Claims an open ticket or one assigned to you, or takes over a lease that expired.
    case claim(ticketId: String, expectedVersion: Int64)
    case release(ticketId: String, lease: RoomTicketLeaseCredential, expectedVersion: Int64)
    /// An empty assignee unassigns ("" clears it on every deployed API version, as the web sends it).
    case assign(ticketId: String, assignee: String, expectedVersion: Int64)
    /// The changed fields only; the API refuses a title or body edit without `expectedVersion`.
    case edit(ticketId: String, title: String?, body: String?, expectedVersion: Int64)
    /// A comment (1–4000 characters). Comments are immutable and post no chat message.
    case comment(ticketId: String, body: String)

    static let titleLimit = 200
    static let bodyLimit = 8_000
    static let assigneeLimit = 64
    static let commentLimit = 4_000
    static let keyLimit = 128

    var method: String {
        switch self {
        case .file, .claim, .release, .comment: return "POST"
        case .assign, .edit: return "PATCH"
        }
    }

    func pathComponents(sessionId: String) -> [String] {
        let base = ["api", "v1", "sessions", sessionId, "tickets"]
        switch self {
        case .file: return base
        case .claim(let id, _): return base + [id, "claim"]
        case .release(let id, _, _): return base + [id, "lease", "release"]
        case .assign(let id, _, _), .edit(let id, _, _, _): return base + [id]
        case .comment(let id, _): return base + [id, "comments"]
        }
    }

    /// The JSON body, or nil when the request breaks one of the API's limits (sent anyway it would be a 422).
    var body: [String: Any]? {
        switch self {
        case .file(let title, let body, let assignee):
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= Self.titleLimit, (body?.count ?? 0) <= Self.bodyLimit,
                  (assignee?.count ?? 0) <= Self.assigneeLimit else { return nil }
            var out: [String: Any] = ["title": clean]
            out["body"] = body.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? NSNull()
            out["assignee"] = assignee.flatMap { $0.isEmpty ? nil : $0 } ?? NSNull()
            return out
        case .claim(_, let version):
            guard version >= 1 else { return nil }
            return ["expectedVersion": version]
        case .release(_, let lease, let version):
            guard version >= 1, lease.fence >= 1, UUID(uuidString: lease.leaseId) != nil else { return nil }
            return ["leaseId": lease.leaseId, "fence": lease.fence, "expectedVersion": version]
        case .assign(_, let assignee, let version):
            guard version >= 1, assignee.count <= Self.assigneeLimit else { return nil }
            return ["assignee": assignee, "expectedVersion": version]
        case .edit(_, let title, let body, let version):
            guard version >= 1, title != nil || body != nil else { return nil }
            var out: [String: Any] = ["expectedVersion": version]
            if let title {
                let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean.count <= Self.titleLimit else { return nil }
                out["title"] = clean
            }
            if let body {
                guard body.count <= Self.bodyLimit else { return nil }
                out["body"] = body
            }
            return out
        case .comment(_, let body):
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= Self.commentLimit else {
                return nil
            }
            return ["body": body, "kind": "comment"]
        }
    }

    var ticketId: String? {
        switch self {
        case .file: return nil
        case .claim(let id, _), .release(let id, _, _), .assign(let id, _, _), .edit(let id, _, _, _), .comment(let id, _):
            return id
        }
    }
}

struct RoomTicketWriteResult: Equatable, Sendable {
    /// The ticket after the write; for a replay, the ticket as it was stored then.
    let ticket: RoomTicket?
    /// Returned by a claim only.
    let lease: RoomTicketLeaseCredential?
    /// The API answered a repeated key with the stored reply: nothing changed now.
    let replayed: Bool
    /// Returned by a comment only.
    let comment: RoomTicketComment?

    /// File and edit answer with the ticket itself; claim and release wrap it with `version`, `cursor` and the lease.
    init(json: JSONValue) {
        let wrapped = json["ticket"]?.objectValue != nil
        let ticketJSON = wrapped ? json["ticket"] : json
        let ticket = ticketJSON.flatMap(RoomTicket.init(json:))
        self.ticket = ticket
        self.replayed = json["replayed"]?.boolValue ?? false
        self.comment = json["comment"].flatMap { RoomTicketComment(json: $0, cursor: json["cursor"]?.intValue) }
        if let lease = json["lease"], let leaseId = lease["leaseId"]?.stringValue, !leaseId.isEmpty,
           let fence = lease["fence"]?.intValue, fence >= 1 {
            self.lease = RoomTicketLeaseCredential(
                leaseId: leaseId,
                fence: fence,
                expiresAt: lease["expiresAt"]?.stringValue,
                claimedVersion: json["version"]?.intValue ?? ticket?.version ?? 1
            )
        } else {
            self.lease = nil
        }
    }

    init(ticket: RoomTicket?, lease: RoomTicketLeaseCredential? = nil, replayed: Bool = false, comment: RoomTicketComment? = nil) {
        self.ticket = ticket
        self.lease = lease
        self.replayed = replayed
        self.comment = comment
    }
}

/// Ticket writes as yourself. A protocol so the tickets coordinator is testable without a network.
protocol RoomTicketWriting: Sendable {
    func write(_ write: RoomTicketWrite, sessionId: String, idempotencyKey: String) async throws -> RoomTicketWriteResult
}

/// Web parity (sentinelayer-web `api.ts` ticket calls at 56a2435): the user's own bearer and an `Idempotency-Key` on
/// every write; no ticket route takes CSRF. The API records who acted from the token, never from the body, and
/// checks the room role (contributor or above) before and again under its lock.
final class HTTPRoomTicketWriter: RoomTicketWriting, @unchecked Sendable {
    private let apiBaseURL: URL?
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?

    init(
        apiBaseURL: URL?,
        urlSession: URLSession = SentiHTTPTransportPolicy.liveSession,
        tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }
    ) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
    }

    func write(_ write: RoomTicketWrite, sessionId: String, idempotencyKey: String) async throws -> RoomTicketWriteResult {
        let request = try Self.request(
            for: write, sessionId: sessionId, idempotencyKey: idempotencyKey, apiBaseURL: apiBaseURL, token: tokenProvider()
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw RoomTicketWriteError.retryable(retryAfterSeconds: nil)
        }
        guard let http = response as? HTTPURLResponse else { throw RoomTicketWriteError.retryable(retryAfterSeconds: nil) }
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        if (200..<300).contains(http.statusCode) {
            guard let json else { throw RoomTicketWriteError.retryable(retryAfterSeconds: nil) }
            return RoomTicketWriteResult(json: json)
        }
        throw Self.error(
            status: http.statusCode,
            code: Self.errorCode(json),
            retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
        )
    }

    static func request(
        for write: RoomTicketWrite,
        sessionId: String,
        idempotencyKey: String,
        apiBaseURL: URL?,
        token: String?
    ) throws -> URLRequest {
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw RoomTicketWriteError.notConfigured
        }
        guard let token, !token.isEmpty else { throw RoomTicketWriteError.reauthenticationRequired }
        let key = idempotencyKey.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var encoded: [String] = []
        for component in write.pathComponents(sessionId: sessionId) {
            guard !component.isEmpty, component.utf8.count <= 256,
                  let piece = component.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw RoomTicketWriteError.rejected
            }
            encoded.append(piece)
        }
        guard !key.isEmpty, key.count <= RoomTicketWrite.keyLimit, let body = write.body else {
            throw RoomTicketWriteError.rejected
        }
        components.percentEncodedPath = "/" + encoded.joined(separator: "/")
        components.query = nil
        guard let url = components.url else { throw RoomTicketWriteError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = write.method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// The API's code, wherever its error shape puts it: `error.code`, or `detail.error.code` (FastAPI's wrapper).
    static func errorCode(_ json: JSONValue?) -> String? {
        json?["error"]?["code"]?.stringValue ?? json?["detail"]?["error"]?["code"]?.stringValue
    }

    static func error(status: Int, code: String?, retryAfter: Int?) -> RoomTicketWriteError {
        switch status {
        case 401: return .reauthenticationRequired
        case 403: return .notAllowed
        case 404: return code == "TICKET_NOT_FOUND" ? .notFound : .notAllowed
        case 409: return .conflict(code: code ?? "TICKET_CONFLICT")
        case 425, 429, 500..<600: return .retryable(retryAfterSeconds: retryAfter)
        default: return .rejected
        }
    }
}

/// The lease credentials this phone holds, per room and ticket. A claim returns the credential once; keeping it is
/// what lets this phone release the lease later, after a relaunch too (the web keeps it in memory only, so a reload
/// loses it).
protocol TicketLeaseStoring: Sendable {
    func credential(sessionId: String, ticketId: String) -> RoomTicketLeaseCredential?
    func save(_ credential: RoomTicketLeaseCredential, sessionId: String, ticketId: String)
    func remove(sessionId: String, ticketId: String)
    /// The tickets in this room this phone holds a credential for.
    func ticketIds(sessionId: String) -> Set<String>
}

/// In the Keychain, this device only: the lease id is the holder's working credential (it releases the lease).
final class KeychainTicketLeaseStore: TicketLeaseStoring, @unchecked Sendable {
    private let service: String

    init(service: String = "com.plexaura.sentipocket.ticket-lease") {
        self.service = service
    }

    private func account(_ sessionId: String, _ ticketId: String) -> String { "\(sessionId)/\(ticketId)" }

    func credential(sessionId: String, ticketId: String) -> RoomTicketLeaseCredential? {
        var out: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(sessionId, ticketId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(RoomTicketLeaseCredential.self, from: data)
    }

    func save(_ credential: RoomTicketLeaseCredential, sessionId: String, ticketId: String) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        remove(sessionId: sessionId, ticketId: ticketId)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(sessionId, ticketId),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    func remove(sessionId: String, ticketId: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(sessionId, ticketId),
        ] as CFDictionary)
    }

    func ticketIds(sessionId: String) -> Set<String> {
        var out: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        let prefix = "\(sessionId)/"
        return Set(items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { return nil }
            let ticketId = String(account.dropFirst(prefix.count))
            return ticketId.isEmpty ? nil : ticketId
        })
    }
}

/// For tests and previews.
final class InMemoryTicketLeaseStore: TicketLeaseStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: RoomTicketLeaseCredential] = [:]

    init() {}

    func credential(sessionId: String, ticketId: String) -> RoomTicketLeaseCredential? {
        lock.withLock { items["\(sessionId)/\(ticketId)"] }
    }

    func save(_ credential: RoomTicketLeaseCredential, sessionId: String, ticketId: String) {
        lock.withLock { items["\(sessionId)/\(ticketId)"] = credential }
    }

    func remove(sessionId: String, ticketId: String) {
        _ = lock.withLock { items.removeValue(forKey: "\(sessionId)/\(ticketId)") }
    }

    func ticketIds(sessionId: String) -> Set<String> {
        lock.withLock {
            Set(items.keys.compactMap { key in
                key.hasPrefix("\(sessionId)/") ? String(key.dropFirst(sessionId.count + 1)) : nil
            })
        }
    }
}
