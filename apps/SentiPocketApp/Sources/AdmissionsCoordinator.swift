import Foundation
import SwiftUI
#if canImport(CryptoKit)
import CryptoKit
#endif
import PocketSyncClient
import PocketUI

/// The API's route-bound mutation token for session mutations (sentinelayer-api `_session_mutation_csrf_token`):
/// hex HMAC-SHA256 keyed by the caller's own bearer over
/// `session-mutation-csrf:v1 \0 <canonical session ref> \0 <route template> \0 <Idempotency-Key>`.
/// A native client sends it with `X-Sentinelayer-Session-Mutation: session-mutation` and no browser headers.
enum SessionMutationCSRF {
    static let schema = "session-mutation-csrf:v1"

    /// A UUID (32 hex digits, dashes anywhere, any case, as Python's `UUID()` accepts) becomes the lowercase dashed
    /// form; anything else is lowercased.
    static func canonicalSessionRef(_ value: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "unavailable" }
        let hex = raw.replacingOccurrences(of: "-", with: "").lowercased()
        let asciiHex = hex.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        if hex.unicodeScalars.count == 32, asciiHex {
            let chars = Array(hex)
            let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }
            let dashed = parts.joined(separator: "-")
            if UUID(uuidString: dashed) != nil { return dashed }
        }
        return raw.lowercased()
    }

    static func token(bearer: String, sessionId: String, routeTemplate: String, idempotencyKey: String) -> String? {
        #if canImport(CryptoKit)
        let message = [schema, canonicalSessionRef(sessionId), routeTemplate, idempotencyKey].joined(separator: "\u{0}")
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(bearer.utf8))
        )
        return mac.map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}

/// Approving or denying an agent's request to join a room (owners and admins).
protocol AdmissionDeciding: Sendable {
    func decide(sessionId: String, admissionId: String, approve: Bool, grantedActions: [String], ttlSeconds: Int?) async throws
}

final class HTTPAdmissionDecider: AdmissionDeciding, @unchecked Sendable {
    static let routeTemplate = "POST /api/v1/sessions/{session_id}/admissions/{admission_id}/decision"
    static let allowedActions: Set<String> = ["session.read", "session.post", "session.react", "tickets.read", "tickets.work"]

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

    func decide(sessionId: String, admissionId: String, approve: Bool, grantedActions: [String], ttlSeconds: Int?) async throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              !sessionId.isEmpty, sessionId.utf8.count <= 256,
              let encodedSession = sessionId.addingPercentEncoding(withAllowedCharacters: allowed),
              let admission = UUID(uuidString: admissionId) else {
            throw RoomSendError.rejected
        }
        if approve {
            guard !grantedActions.isEmpty, grantedActions.count <= 8,
                  grantedActions.allSatisfy(Self.allowedActions.contains) else { throw RoomSendError.rejected }
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw RoomSendError.reauthenticationRequired }
        let idempotencyKey = "pocket-admission-\(UUID().uuidString.lowercased())"
        guard let csrf = SessionMutationCSRF.token(
            bearer: token,
            sessionId: sessionId,
            routeTemplate: Self.routeTemplate,
            idempotencyKey: idempotencyKey
        ) else { throw RoomSendError.notConfigured }

        components.percentEncodedPath = "/api/v1/sessions/\(encodedSession)/admissions/\(admission.uuidString.lowercased())/decision"
        components.query = nil
        guard let url = components.url else { throw RoomSendError.notConfigured }

        var body: [String: Any] = ["decision": approve ? "approve" : "deny"]
        if approve {
            body["grantedActions"] = grantedActions
            if let ttlSeconds { body["ttlSeconds"] = ttlSeconds }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("session-mutation", forHTTPHeaderField: "X-Sentinelayer-Session-Mutation")
        request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response: URLResponse
        do {
            (_, response) = try await urlSession.data(for: request)
        } catch {
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return
        case 401: throw RoomSendError.reauthenticationRequired
        case 403, 404: throw RoomSendError.notAllowed
        case 409, 429, 500..<600: throw RoomSendError.retryable(retryAfterSeconds: nil)
        default: throw RoomSendError.rejected
        }
    }
}

/// The room's agent requests: polled every 10 seconds while on screen (the web polls every 5).
@MainActor
final class AdmissionsCoordinator: ObservableObject {
    @Published private(set) var state = AdmissionsPresentationState(rows: [], isLoading: true)

    private let sessionId: String
    private let transport: any RoomAdmissionsTransport
    private let decider: any AdmissionDeciding
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let onReauthenticationRequired: @MainActor () -> Void

    private var page = RoomAdmissionsPage(admissions: [])
    private var deciding: Set<String> = []
    private var errorText: String?
    private var isLoading = false
    private var failure: SessionLoadFailure?
    private var pollTask: Task<Void, Never>?

    static let pollInterval: TimeInterval = 10

    init(
        sessionId: String,
        transport: any RoomAdmissionsTransport,
        decider: any AdmissionDeciding,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        self.sessionId = sessionId
        self.transport = transport
        self.decider = decider
        self.sleep = sleep
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                await self.sleep(Self.pollInterval)
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func send(_ intent: AdmissionsIntent) {
        switch intent {
        case .refresh:
            Task { await refresh() }
        case .approve(let id, let actions, let ttl):
            decide(id, approve: true, actions: actions, ttl: ttl)
        case .deny(let id):
            decide(id, approve: false, actions: [], ttl: nil)
        }
    }

    func refresh() async {
        guard failure != .reauthenticationRequired, failure != .accessDenied else { return }
        if page.admissions.isEmpty { isLoading = true; publish() }
        do {
            page = try await transport.roomAdmissions(sessionId: sessionId)
            failure = nil
        } catch SessionTransportError.reauthenticationRequired {
            failure = .reauthenticationRequired
            onReauthenticationRequired()
            stop()
        } catch SessionTransportError.accessDenied {
            failure = .accessDenied
            stop()
        } catch {
            if page.admissions.isEmpty { failure = .network }
        }
        isLoading = false
        publish()
    }

    private func decide(_ id: String, approve: Bool, actions: [String], ttl: Int?) {
        guard !deciding.contains(id) else { return }
        deciding.insert(id)
        errorText = nil
        publish()
        let sessionId = self.sessionId
        let decider = self.decider
        Task { [weak self] in
            do {
                try await decider.decide(sessionId: sessionId, admissionId: id, approve: approve, grantedActions: actions, ttlSeconds: ttl)
                guard let self else { return }
                self.deciding.remove(id)
                await self.refresh()
            } catch let error as RoomSendError {
                guard let self else { return }
                self.deciding.remove(id)
                switch error {
                case .reauthenticationRequired:
                    self.onReauthenticationRequired()
                    self.errorText = error.userMessage
                case .notAllowed:
                    self.errorText = "Only the room's owner or an admin can decide, or this request is no longer pending."
                default:
                    self.errorText = approve ? "The approval did not go through. Try again." : "The denial did not go through. Try again."
                }
                self.publish()
                await self.refresh()
            } catch {
                self?.deciding.remove(id)
                self?.publish()
            }
        }
    }

    private func publish() {
        state = AdmissionsPresentationState(
            rows: page.admissions.map { admission in
                let detail = [admission.model, admission.provider, admission.clientKind.map { "via \($0)" }]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                return AdmissionRow(
                    id: admission.admissionId,
                    status: admission.status,
                    agentId: admission.agentId,
                    detail: detail.isEmpty ? nil : detail,
                    goalSummary: admission.goalSummary,
                    deliverables: admission.deliverables,
                    stopConditions: admission.stopConditions,
                    requestedActions: admission.requestedActions,
                    requestedTTLSeconds: admission.requestedTTLSeconds,
                    grantedActions: admission.grantedActions,
                    grantedExpiresAt: admission.grantedExpiresAt,
                    pendingExpiresAt: admission.pendingExpiresAt
                )
            },
            mode: page.mode,
            deciding: deciding,
            errorText: errorText,
            isLoading: isLoading,
            failure: failure
        )
    }
}

/// Hosts the room's agent requests; polls only while visible.
struct AdmissionsScreen: View {
    @StateObject private var coordinator: AdmissionsCoordinator

    init(sessionId: String, transport: any RoomAdmissionsTransport, decider: any AdmissionDeciding, onReauthenticationRequired: @escaping @MainActor () -> Void) {
        _coordinator = StateObject(wrappedValue: AdmissionsCoordinator(
            sessionId: sessionId,
            transport: transport,
            decider: decider,
            onReauthenticationRequired: onReauthenticationRequired
        ))
    }

    var body: some View {
        AdmissionsView(state: coordinator.state) { coordinator.send($0) }
            .onAppear { coordinator.start() }
            .onDisappear { coordinator.stop() }
    }
}
