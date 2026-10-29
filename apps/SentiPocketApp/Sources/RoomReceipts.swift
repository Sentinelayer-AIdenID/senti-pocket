import Foundation
import PocketSyncClient

/// Read receipts and presence as yourself, like the web: a view is recorded with `POST /view-receipts` (route-bound
/// CSRF, the scheme admission decisions use), who viewed is read with `GET /view-receipts`, and you are present
/// through `PUT /presence` heartbeats. A protocol so the room is testable without a network.
protocol RoomReceiptsClient: Sendable {
    func recordViews(sessionId: String, targets: [RoomViewTarget]) async throws
    func views(sessionId: String, targets: [RoomViewTarget]) async throws -> [RoomViewSummary]
    /// Returns how long the server keeps you present, in seconds, when it says.
    func publishPresence(sessionId: String, active: Bool, clientInstanceId: String) async throws -> Int?
    func presence(sessionId: String) async throws -> RoomPresence
}

final class HTTPRoomReceipts: RoomReceiptsClient, @unchecked Sendable {
    static let viewRouteTemplate = "POST /api/v1/sessions/{session_id}/view-receipts"
    /// The API takes at most 100 targets per request, either way.
    static let batchLimit = 100

    private let apiBaseURL: URL?
    private let writeSession: URLSession
    private let readSession: URLSession
    private let tokenProvider: @Sendable () -> String?

    init(
        apiBaseURL: URL?,
        writeSession: URLSession = SentiHTTPTransportPolicy.liveSession,
        readSession: URLSession = SentiHTTPTransportPolicy.protectedReadSession,
        tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }
    ) {
        self.apiBaseURL = apiBaseURL
        self.writeSession = writeSession
        self.readSession = readSession
        self.tokenProvider = tokenProvider
    }

    func recordViews(sessionId: String, targets: [RoomViewTarget]) async throws {
        guard !targets.isEmpty, targets.count <= Self.batchLimit else { throw RoomSendError.rejected }
        let (url, token) = try endpoint(sessionId: sessionId, path: "view-receipts")
        let key = "view-\(UUID().uuidString.lowercased())"
        guard let csrf = SessionMutationCSRF.token(
            bearer: token,
            sessionId: sessionId,
            routeTemplate: Self.viewRouteTemplate,
            idempotencyKey: key
        ) else { throw RoomSendError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("session-mutation", forHTTPHeaderField: "X-Sentinelayer-Session-Mutation")
        request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        // A person sends no agentId: the API names the viewer from the token.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "targets": targets.map { ["kind": $0.kind.rawValue, "id": $0.id, "targetRevision": $0.revision] }
        ])
        _ = try await perform(request, on: writeSession)
    }

    func views(sessionId: String, targets: [RoomViewTarget]) async throws -> [RoomViewSummary] {
        guard !targets.isEmpty, targets.count <= Self.batchLimit else { throw RoomSendError.rejected }
        let (url, token) = try endpoint(sessionId: sessionId, path: "view-receipts", query: [
            URLQueryItem(name: "messageIds", value: targets.filter { $0.kind == .message }.map(\.id).joined(separator: ",")),
            URLQueryItem(name: "replyIds", value: targets.filter { $0.kind == .reply }.map(\.id).joined(separator: ","))
        ].filter { $0.value?.isEmpty == false })
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request, on: readSession)
        guard let page = try? JSONDecoder().decode(RoomViewsPage.self, from: data) else { throw RoomSendError.rejected }
        return page.summaries
    }

    func publishPresence(sessionId: String, active: Bool, clientInstanceId: String) async throws -> Int? {
        let (url, token) = try endpoint(sessionId: sessionId, path: "presence")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // No agentId: that would publish an agent. The server names you from your account.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "state": active ? "active" : "stopped",
            "clientInstanceId": clientInstanceId
        ])
        let data = try await perform(request, on: writeSession)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["ttlSeconds"] as? NSNumber)?.intValue
    }

    func presence(sessionId: String) async throws -> RoomPresence {
        let (url, token) = try endpoint(sessionId: sessionId, path: "presence")
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request, on: readSession)
        guard let presence = try? JSONDecoder().decode(RoomPresence.self, from: data) else { throw RoomSendError.rejected }
        return presence
    }

    private func endpoint(sessionId: String, path: String, query: [URLQueryItem] = []) throws -> (URL, String) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              !sessionId.isEmpty, sessionId.utf8.count <= 256,
              let encodedSession = sessionId.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw RoomSendError.notConfigured
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw RoomSendError.reauthenticationRequired }
        components.percentEncodedPath = "/api/v1/sessions/\(encodedSession)/\(path)"
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw RoomSendError.notConfigured }
        return (url, token)
    }

    private func perform(_ request: URLRequest, on session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        }
        guard let http = response as? HTTPURLResponse else { throw RoomSendError.retryable(retryAfterSeconds: nil) }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw RoomSendError.reauthenticationRequired
        case 403, 404: throw RoomSendError.notAllowed
        case 409, 425, 429, 500..<600:
            throw RoomSendError.retryable(retryAfterSeconds: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default: throw RoomSendError.rejected
        }
    }
}

/// Read receipts and presence for one open room, timed like the web (`useNativeSessionView`,
/// `useSessionMessageInteractions`, `HumanPresencePill`):
/// - a row on screen for 0.75s is reported viewed, once per revision per visit, in batches of up to 100 sent one at
///   a time; a failed report retries after 1s, doubling to 30s, while the row stays on screen;
/// - who viewed the rows on screen is read 0.2s after they change, every 15s while the room is open, and 0.3s after
///   a report lands; a failed read clears the lines and pauses reads (Retry-After, else 30s, 60s, then 120s);
/// - you are present while the room is open and the app active: a heartbeat every third of the server's lifetime
///   (30s by default), and "stopped" when you leave, which removes only this device.
@MainActor
final class RoomReceiptsTracker {
    static let dwell: TimeInterval = 0.75
    static let batchDelay: TimeInterval = 0.05
    static let readDelay: TimeInterval = 0.2
    static let readAfterReport: TimeInterval = 0.3
    static let readInterval: TimeInterval = 15
    static let defaultPresenceLifetime = 90

    /// This device's presence, one per room visit (the server keeps one entry per device).
    let clientInstanceId = "ios-\(UUID().uuidString.lowercased())"
    /// Who viewed each message or reply, by its UUID.
    private(set) var summaries: [String: RoomViewSummary] = [:]
    private(set) var presence: RoomPresence?
    /// People's names from presence for this visit, keyed `human-<account id>`; a person who left keeps theirs.
    private(set) var names: [String: String] = [:]

    private let sessionId: String
    private let client: any RoomReceiptsClient
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let now: @Sendable () -> Date
    private let onChange: @MainActor () -> Void

    private var isActive = false
    private var onScreen: [String: RoomViewTarget] = [:]
    /// Each appearance gets a token, so a row that left and came back restarts its dwell.
    private var appearances: [String: UUID] = [:]
    private var reported: Set<RoomViewTarget> = []
    private var queue: [RoomViewTarget] = []
    private var isReporting = false
    private var isReading = false
    private var readsPausedUntil: Date?
    private var readFailures = 0
    private var scheduledRead: Task<Void, Never>?
    private var loops: [Task<Void, Never>] = []

    init(
        sessionId: String,
        client: any RoomReceiptsClient,
        sleep: @escaping @Sendable (TimeInterval) async -> Void,
        now: @escaping @Sendable () -> Date,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.sessionId = sessionId
        self.client = client
        self.sleep = sleep
        self.now = now
        self.onChange = onChange
    }

    /// The room is on screen and the app active.
    func start() {
        guard !isActive else { return }
        isActive = true
        loops.append(Task { [weak self] in await self?.presenceLoop() })
        loops.append(Task { [weak self] in await self?.readLoop() })
        if !queue.isEmpty { flush() }
        scheduleRead(after: Self.readDelay)
    }

    /// The room closed or the app left the foreground: no more reports or reads, and this device stops being
    /// present (other devices of yours stay).
    func stop() {
        guard isActive else { return }
        isActive = false
        loops.forEach { $0.cancel() }
        loops.removeAll()
        scheduledRead?.cancel()
        scheduledRead = nil
        let client = self.client
        let sessionId = self.sessionId
        let instance = clientInstanceId
        Task { _ = try? await client.publishPresence(sessionId: sessionId, active: false, clientInstanceId: instance) }
    }

    /// A row came on screen or left it.
    func setOnScreen(_ target: RoomViewTarget, _ isOnScreen: Bool) {
        guard isOnScreen else {
            if onScreen[target.id] == target {
                onScreen[target.id] = nil
                appearances[target.id] = nil
            }
            return
        }
        guard onScreen[target.id] != target else { return }
        onScreen[target.id] = target
        let token = UUID()
        appearances[target.id] = token
        scheduleRead(after: Self.readDelay)
        Task { [weak self] in
            await self?.sleep(Self.dwell)
            guard let self, self.appearances[target.id] == token, !self.reported.contains(target),
                  !self.queue.contains(target) else { return }
            self.queue.append(target)
            self.flush()
        }
    }

    private func flush() {
        guard isActive, !isReporting, !queue.isEmpty else { return }
        isReporting = true
        Task { [weak self] in
            await self?.sleep(Self.batchDelay)
            await self?.report()
        }
    }

    private func report() async {
        var backoff: TimeInterval = 0
        while isActive {
            // Only rows still on screen are reported; one that left before its batch went is reported next time.
            queue.removeAll { onScreen[$0.id] != $0 || reported.contains($0) }
            let batch = Array(queue.prefix(HTTPRoomReceipts.batchLimit))
            guard !batch.isEmpty else { break }
            do {
                try await client.recordViews(sessionId: sessionId, targets: batch)
                reported.formUnion(batch)
                queue.removeAll { batch.contains($0) }
                backoff = 0
                scheduleRead(after: Self.readAfterReport)
            } catch RoomSendError.notAllowed {
                // The room is not live (or no longer yours): views cannot be recorded.
                queue.removeAll()
                break
            } catch RoomSendError.reauthenticationRequired {
                // The room asks you to sign in again; rows report again when they next come on screen.
                queue.removeAll()
                break
            } catch {
                backoff = min(max(backoff * 2, 1), 30)
                await sleep(max(backoff, Self.retryAfter(error)))
            }
        }
        isReporting = false
        if isActive, !queue.isEmpty { flush() }
    }

    private func scheduleRead(after delay: TimeInterval) {
        guard isActive else { return }
        scheduledRead?.cancel()
        scheduledRead = Task { [weak self] in
            await self?.sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.readViews()
        }
    }

    private func readLoop() async {
        while isActive, !Task.isCancelled {
            await sleep(Self.readInterval)
            guard isActive, !Task.isCancelled else { return }
            await readViews()
        }
    }

    private func readViews() async {
        guard isActive, !isReading, !onScreen.isEmpty else { return }
        if let until = readsPausedUntil, now() < until { return }
        isReading = true
        defer { isReading = false }
        let targets = Array(onScreen.values).sorted { $0.id < $1.id }
        var fresh: [String: RoomViewSummary] = [:]
        var start = 0
        while start < targets.count {
            let chunk = Array(targets[start..<min(start + HTTPRoomReceipts.batchLimit, targets.count)])
            start += chunk.count
            do {
                for summary in try await client.views(sessionId: sessionId, targets: chunk) { fresh[summary.id] = summary }
            } catch {
                // Never show stale lines: clear them and wait before reading again.
                readFailures += 1
                let pause = [30.0, 60.0, 120.0][min(readFailures - 1, 2)]
                readsPausedUntil = now().addingTimeInterval(max(pause, Self.retryAfter(error)))
                summaries = [:]
                onChange()
                return
            }
        }
        readFailures = 0
        readsPausedUntil = nil
        summaries.merge(fresh) { $1 }
        onChange()
    }

    private func presenceLoop() async {
        var interval = TimeInterval(Self.defaultPresenceLifetime) / 3
        var failures = 0
        while isActive, !Task.isCancelled {
            do {
                if let lifetime = try await client.publishPresence(
                    sessionId: sessionId, active: true, clientInstanceId: clientInstanceId
                ), lifetime > 0 {
                    interval = TimeInterval(lifetime) / 3
                }
                let snapshot = try await client.presence(sessionId: sessionId)
                guard isActive, !Task.isCancelled else { return }
                presence = snapshot
                for person in snapshot.participants where person.isHuman {
                    if let name = person.displayName { names[person.id.lowercased()] = name }
                }
                failures = 0
            } catch {
                guard isActive, !Task.isCancelled else { return }
                presence = RoomPresence(isAvailable: false)
                failures += 1
            }
            onChange()
            await sleep(failures == 0 ? interval : min(pow(2, Double(failures - 1)), 30))
        }
    }

    private static func retryAfter(_ error: Error) -> TimeInterval {
        if let error = error as? RoomSendError, case .retryable(let seconds?) = error { return TimeInterval(max(seconds, 0)) }
        return 0
    }
}
