import Foundation
import PocketSyncClient

/// Resolve the person with the exact bearer the pin request will send. A token refresh retries the identity read;
/// it does not make a new bearer look like a new account or alter the shared authenticated-request implementation.
struct RoomFolderPinsAccountCredentials: Sendable {
    let apiBaseURL: URL?
    let urlSession: URLSession
    var tokenProvider: @Sendable () -> String? = { SessionTokenStore.load() }

    func current() async throws -> RoomFolderPinsCredential {
        guard let apiBaseURL, var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw RoomFolderError.notConfigured
        }
        components.percentEncodedPath = "/api/v1/auth/me"
        components.query = nil
        guard let url = components.url else { throw RoomFolderError.notConfigured }
        for _ in 0..<2 {
            guard let token = tokenProvider(), !token.isEmpty else { throw RoomFolderError.reauthenticationRequired }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpShouldHandleCookies = false
            let data: Data
            let response: URLResponse
            do { (data, response) = try await urlSession.data(for: request) }
            catch {
                guard tokenProvider() == token else { continue }
                throw RoomFolderError.retryable
            }
            guard tokenProvider() == token else { continue }
            guard let http = response as? HTTPURLResponse else { throw RoomFolderError.retryable }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = object?["detail"] as? [String: Any]
            let error = (object?["error"] as? [String: Any]) ?? (detail?["error"] as? [String: Any])
            let code = (error?["code"] as? String) ?? (detail?["code"] as? String) ?? (object?["code"] as? String)
            // Unlike the display-name lookup, this lookup must keep an expired or revoked credential actionable.
            if http.statusCode == 401 || (http.statusCode == 403 && code?.hasPrefix("ACCOUNT_") == true) {
                throw RoomFolderError.reauthenticationRequired
            }
            guard http.statusCode == 200, let rawId = object?["id"] as? String else { throw RoomFolderError.retryable }
            let accountId = rawId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !accountId.isEmpty else { throw RoomFolderError.retryable }
            return RoomFolderPinsCredential(accountId: accountId, token: token)
        }
        throw RoomFolderError.accountChanged
    }
}
