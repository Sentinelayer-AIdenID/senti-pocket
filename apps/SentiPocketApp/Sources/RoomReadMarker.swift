import Foundation

/// Tells the server how far you have read a room (Carter, 10-31: the room list's unread badge follows your reading,
/// like Discord). A protocol so the room is testable without a network.
protocol RoomReadMarking: Sendable {
    /// You have read the room through the message at `sequenceId`.
    func markRead(sessionId: String, through sequenceId: Int64) async throws
}

/// `PUT /api/v1/sessions/{session_id}/read-cursor` with `{"targetSequenceId": n}`, as yourself (no agentId: the API
/// names you from the token). The server keeps the furthest position it is told and never moves it back, so a late,
/// repeated or out-of-order request changes nothing; it writes no message or action into the room.
final class HTTPRoomReadMarker: RoomReadMarking, @unchecked Sendable {
    private let apiBaseURL: URL?
    private let session: URLSession
    private let tokenProvider: @Sendable () -> String?

    init(
        apiBaseURL: URL?,
        session: URLSession = SentiHTTPTransportPolicy.liveSession,
        tokenProvider: @escaping @Sendable () -> String? = { SessionTokenStore.load() }
    ) {
        self.apiBaseURL = apiBaseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    func markRead(sessionId: String, through sequenceId: Int64) async throws {
        guard sequenceId > 0 else { throw RoomSendError.rejected }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let apiBaseURL,
              var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              !sessionId.isEmpty, sessionId.utf8.count <= 256,
              let encodedSession = sessionId.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw RoomSendError.notConfigured
        }
        guard let token = tokenProvider(), !token.isEmpty else { throw RoomSendError.reauthenticationRequired }
        components.percentEncodedPath = "/api/v1/sessions/\(encodedSession)/read-cursor"
        guard let url = components.url else { throw RoomSendError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["targetSequenceId": sequenceId])
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw RoomSendError.retryable(retryAfterSeconds: nil)
        }
        guard let http = response as? HTTPURLResponse else { throw RoomSendError.retryable(retryAfterSeconds: nil) }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw RoomSendError.reauthenticationRequired
        case 403, 404: throw RoomSendError.notAllowed
        case 409, 425, 429, 500..<600:
            throw RoomSendError.retryable(retryAfterSeconds: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default: throw RoomSendError.rejected
        }
    }
}
