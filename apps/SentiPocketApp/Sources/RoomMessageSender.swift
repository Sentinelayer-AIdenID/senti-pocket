import Foundation

/// Why a room message did not post. Response bodies are never surfaced, only their class.
enum RoomSendError: Error, Equatable {
    case notConfigured
    case reauthenticationRequired
    /// 403: this account may read the room but not post in it (a viewer), or no longer belongs to it.
    case notAllowed
    /// The request may not have landed (network, 409, 429, 5xx). Retrying with the SAME client id is safe: the API
    /// de-duplicates on (user, client id).
    case retryable(retryAfterSeconds: Int?)
    /// The API refused the message itself (400/413/422). Retrying the same text will not help.
    case rejected

    var userMessage: String {
        switch self {
        case .notConfigured: return "This build cannot reach Senti."
        case .reauthenticationRequired: return "Sign in again to send."
        case .notAllowed: return "You can read this room but not post in it."
        case .retryable: return "Not sent. Check your connection and retry."
        case .rejected: return "Senti did not accept this message."
        }
    }
}

/// Posting a typed message as yourself. A protocol so the room coordinator is testable without a network.
protocol RoomMessageSending: Sendable {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws
}

/// Web parity (sentinelayer-web `useSessionLiveController.ts`): `POST /api/v1/sessions/{id}/human-message` with
/// the user's own bearer, `{text, clientId}` and an `Idempotency-Key`. The API authors the message on the server as
/// `human-<your GitHub username>`, so a phone can never post as anyone else; the stream then echoes it back with
/// `payload.clientMessageId == clientId`, which is how the pending row is matched.
final class HTTPRoomMessageSender: RoomMessageSending, @unchecked Sendable {
    private let apiBaseURL: URL?
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?

    /// The API's limit (`HUMAN_MESSAGE_MAX_LENGTH`), counted in characters as the web does.
    static let maximumLength = 64_000

    init(
        apiBaseURL: URL?,
        urlSession: URLSession = SentiHTTPTransportPolicy.liveSession,
        tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }
    ) {
        self.apiBaseURL = apiBaseURL
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
    }

    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw RoomSendError.notConfigured
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw RoomSendError.reauthenticationRequired }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard !sessionId.isEmpty, sessionId.utf8.count <= 256,
              let encodedSession = sessionId.addingPercentEncoding(withAllowedCharacters: allowed),
              !text.isEmpty, text.count <= Self.maximumLength,
              clientId.utf8.count <= 120 else {
            throw RoomSendError.rejected
        }
        components.percentEncodedPath = "/api/v1/sessions/\(encodedSession)/human-message"
        components.query = nil
        guard let url = components.url else { throw RoomSendError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(clientId, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "clientId": clientId])

        let response: URLResponse
        do {
            (_, response) = try await urlSession.data(for: request)
        } catch {
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        }
        guard let http = response as? HTTPURLResponse else { throw RoomSendError.retryable(retryAfterSeconds: nil) }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw RoomSendError.reauthenticationRequired
        case 403, 404:
            throw RoomSendError.notAllowed
        case 409, 425, 429, 500..<600:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw RoomSendError.retryable(retryAfterSeconds: retryAfter)
        default:
            throw RoomSendError.rejected
        }
    }
}

/// Who is signed in, for "is this my message" and "am I mentioned". `GET /api/v1/auth/me` returns the GitHub
/// username the API authors human messages under (`human-<username>`).
protocol AccountIdentityProviding: Sendable {
    func currentAuthorId() async -> String?
}

final class HTTPAccountIdentity: AccountIdentityProviding, @unchecked Sendable {
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

    func currentAuthorId() async -> String? {
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              let token = tokenProvider(), !token.isEmpty else { return nil }
        components.percentEncodedPath = "/api/v1/auth/me"
        components.query = nil
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await urlSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              tokenProvider() == token,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let username = object["github_username"] as? String,
              username.range(of: #"^[A-Za-z0-9-]{1,39}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return "human-\(username.lowercased())"
    }
}
