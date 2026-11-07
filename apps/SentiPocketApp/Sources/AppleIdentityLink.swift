import AuthenticationServices
import Foundation
import SwiftUI

struct LinkedSignIns: Decodable, Equatable, Sendable {
    let google: Bool
    var apple: Bool
    let github: Bool
}

struct AppleLinkChallenge: Decodable, Equatable, Sendable {
    let state: String
    let nonce: String
    let expiresIn: Int

    var valid: Bool {
        Self.validState(state) && Self.opaque(nonce, length: 32...128) && (1...300).contains(expiresIn)
    }

    static func validState(_ state: String) -> Bool {
        state.hasPrefix("link_") && opaque(String(state.dropFirst(5)), length: 32...128)
    }

    private static func opaque(_ value: String, length: ClosedRange<Int>) -> Bool {
        length.contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

struct AppleLinkProof: Equatable, Sendable {
    let state: String
    let identityToken: String
    let authorizationCode: String
}

enum IdentityLinkFailure: Error, Equatable {
    case unavailable, sessionChanged, expired, unreadable, unreachable, refused(Int)
}

protocol AppleIdentityLinkAPI: Sendable {
    var sessionIsCurrent: Bool { get }
    func identities() async throws -> LinkedSignIns
    func challenge() async throws -> AppleLinkChallenge
    func complete(_ proof: AppleLinkProof) async throws
}

/// A purpose-specific client: there is no AuthResponse, login route or token-save capability here. The current
/// human bearer is attached per request and compared before and after every suspension.
struct AppleIdentityLinkClient: AppleIdentityLinkAPI {
    private let baseURL: URL?
    private let session: URLSession
    private let tokenProvider: @Sendable () -> String?
    private let startingToken: String?

    init(baseURL: URL? = GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_API_URL"]),
         session: URLSession = SentiHTTPTransportPolicy.protectedReadSession,
         tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        startingToken = tokenProvider()
    }

    var sessionIsCurrent: Bool { startingToken.map { !$0.isEmpty && tokenProvider() == $0 } ?? false }

    func identities() async throws -> LinkedSignIns {
        try decode(LinkedSignIns.self, from: await send("GET", suffix: "", body: nil))
    }

    func challenge() async throws -> AppleLinkChallenge {
        let challenge = try decode(AppleLinkChallenge.self, from: await send("POST", suffix: "/apple/challenge", body: [:]))
        guard challenge.valid else { throw IdentityLinkFailure.unreadable }
        return challenge
    }

    func complete(_ proof: AppleLinkProof) async throws {
        guard AppleLinkChallenge.validState(proof.state),
              (1...16_384).contains(proof.identityToken.utf8.count),
              (1...4_096).contains(proof.authorizationCode.utf8.count) else { throw IdentityLinkFailure.unreadable }
        let data = try await send("POST", suffix: "/apple/complete", body: [
            "state": proof.state, "identityToken": proof.identityToken, "authorizationCode": proof.authorizationCode,
        ])
        struct Receipt: Decodable { let provider: String; let linked: Bool }
        let receipt = try decode(Receipt.self, from: data)
        guard receipt.provider == "apple", receipt.linked else { throw IdentityLinkFailure.unreadable }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else { throw IdentityLinkFailure.unreadable }
        return value
    }

    private func send(_ method: String, suffix: String, body: [String: String]?) async throws -> Data {
        try Task.checkCancellation()
        guard sessionIsCurrent, let startingToken else { throw IdentityLinkFailure.sessionChanged }
        guard let baseURL, var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { throw IdentityLinkFailure.unavailable }
        parts.percentEncodedPath = "/api/v1/auth/identities" + suffix
        parts.query = nil
        guard let url = parts.url else { throw IdentityLinkFailure.unavailable }
        var request = URLRequest(url: url, timeoutInterval: SentiHTTPTransportPolicy.requestTimeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(startingToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            guard sessionIsCurrent else { throw IdentityLinkFailure.sessionChanged }
            throw IdentityLinkFailure.unreachable
        }
        try Task.checkCancellation()
        guard sessionIsCurrent else { throw IdentityLinkFailure.sessionChanged }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw IdentityLinkFailure.refused(status) }
        return data
    }
}

@MainActor
protocol AppleLinkAuthorizing {
    func authorize(state: String, nonceDigest: String) async throws -> AppleLinkProof
}

@MainActor
struct NativeAppleLinkAuthorizer: AppleLinkAuthorizing {
    func authorize(state: String, nonceDigest: String) async throws -> AppleLinkProof {
        guard let base = GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_API_URL"])
        else { throw IdentityLinkFailure.unavailable }
        let native = SentiNativeAuth(apiBaseURL: base, appVersion: "identity-link",
                                    saveToken: { _ in throw IdentityLinkFailure.unreadable })
        let credential = try await native.appleCredential(nonceDigest: nonceDigest, state: state)
        try Task.checkCancellation()
        guard credential.state == state,
              let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
              let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }),
              !token.isEmpty, !code.isEmpty else { throw IdentityLinkFailure.unreadable }
        return AppleLinkProof(state: state, identityToken: token, authorizationCode: code)
    }
}

@MainActor
final class AppleLinkSettings: ObservableObject {
    enum Phase: Equatable { case loading, ready, linking, needsRead, unavailable }
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var identities: LinkedSignIns?
    @Published private(set) var notice: String?
    private let api: any AppleIdentityLinkAPI
    private let authorizer: any AppleLinkAuthorizing
    private let now: () -> Date
    private var generation = 0
    private var operation: Task<Void, Never>?

    init(api: any AppleIdentityLinkAPI = AppleIdentityLinkClient(),
         authorizer: (any AppleLinkAuthorizing)? = nil, now: @escaping () -> Date = { Date() }) {
        self.api = api
        self.authorizer = authorizer ?? NativeAppleLinkAuthorizer()
        self.now = now
    }

    func refresh() async {
        guard phase != .linking else { return }
        generation += 1
        let revision = generation
        phase = .loading
        do {
            let links = try await api.identities()
            guard revision == generation, !Task.isCancelled else { return }
            identities = links
            notice = nil
            phase = .ready
        } catch {
            guard revision == generation, !Task.isCancelled else { return }
            identities = nil
            phase = (error as? IdentityLinkFailure) == .refused(404) ? .unavailable : .needsRead
            notice = message(for: error)
        }
    }

    func link() {
        guard phase == .ready, identities?.apple == false else { return }
        generation += 1
        let revision = generation
        phase = .linking
        notice = nil
        operation = Task { [weak self] in
            guard let self else { return }
            await self.performLink(revision: revision)
        }
    }

    private func performLink(revision: Int) async {
        do {
            let started = now()
            let challenge = try await api.challenge()
            let expiry = started.addingTimeInterval(TimeInterval(challenge.expiresIn))
            try check(revision, expiry: expiry)
            guard challenge.valid else { throw IdentityLinkFailure.unreadable }
            let proof = try await authorizer.authorize(state: challenge.state, nonceDigest: AppleSignInNonce.digest(challenge.nonce))
            try check(revision, expiry: expiry)
            guard proof.state == challenge.state else { throw IdentityLinkFailure.unreadable }
            try await api.complete(proof)
            try check(revision, expiry: nil)
            identities?.apple = true
            phase = .ready
            notice = "Apple is linked to this Senti account."
        } catch {
            guard revision == generation, !Task.isCancelled else { return }
            if (error as? NativeAuthError) == .userCancelledWeb {
                phase = .ready
                notice = "Apple linking was cancelled."
            } else {
                phase = (error as? IdentityLinkFailure) == .refused(404) ? .unavailable : .needsRead
                if (error as? IdentityLinkFailure) == .sessionChanged { identities = nil }
                notice = message(for: error)
            }
        }
    }

    private func check(_ revision: Int, expiry: Date?) throws {
        try Task.checkCancellation()
        guard revision == generation, api.sessionIsCurrent else { throw IdentityLinkFailure.sessionChanged }
        if let expiry, now() >= expiry { throw IdentityLinkFailure.expired }
    }

    func cancel() {
        generation += 1
        operation?.cancel()
        operation = nil
        if phase == .linking { phase = .needsRead }
    }

    private func message(for error: Error) -> String {
        switch error as? IdentityLinkFailure {
        case .sessionChanged, .refused(401), .refused(403): return "Your sign-in changed. Close Settings and sign in again."
        case .refused(409): return "Apple could not be linked because this identity or account already has a link. Your current sign-in stays the same."
        case .refused(404), .unavailable: return "Apple linking is not available yet."
        case .expired: return "The Apple linking request expired. Read your linked sign-ins and try again."
        default: return "Apple linking is not confirmed. Read your linked sign-ins before trying again."
        }
    }
}

struct AppleIdentityLinkSettingsRow: View {
    @StateObject private var model = AppleLinkSettings()

    var body: some View {
        Group {
            if model.phase != .unavailable {
                VStack(alignment: .leading, spacing: 8) {
                    if model.identities?.apple == true {
                        Label("Apple linked", systemImage: "checkmark.circle")
                    } else {
                        Button("Link Apple to this account") { model.link() }
                            .disabled(model.phase != .ready)
                            .accessibilityIdentifier("settings.appleLink.link")
                    }
                    if model.phase == .loading || model.phase == .linking { ProgressView() }
                    if model.phase == .needsRead {
                        Button("Read linked sign-ins") { Task { await model.refresh() } }
                            .accessibilityIdentifier("settings.appleLink.refresh")
                    }
                    Text(model.notice ?? "Add Apple as another way to sign in to this Senti account.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("settings.appleLink")
            }
        }
        .task { await model.refresh() }
        .onDisappear { model.cancel() }
    }
}
