import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts

/// One call to the Senti API as the signed-in person, for the routes that are yours alone (direct messages and room
/// folders). The origin is checked as the session transport checks it, every path segment is percent-encoded, and an
/// answer that arrives after another account signed in is dropped: it belongs to nobody on screen.
struct PersonalRequest {
    enum Failure: Error, Equatable {
        case notConfigured
        case notLoggedIn
        case invalidRequest
        /// No answer: the network, or the request was cancelled.
        case network
        /// Another account signed in (or this one signed out) while the call was out.
        case accountChanged
    }

    struct Answer {
        let status: Int
        let json: JSONValue?
        let retryAfter: Int?
    }

    let apiBaseURL: URL?
    let urlSession: URLSession
    let tokenProvider: @Sendable () -> String?

    func send(_ method: String, _ path: [String], body: [String: Any]? = nil) async throws -> Answer {
        guard let origin = HTTPSessionTransport.validOrigin(apiBaseURL) else { throw Failure.notConfigured }
        guard let token = tokenProvider(), !token.isEmpty else { throw Failure.notLoggedIn }
        guard token.utf8.count <= 8_192, token.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw Failure.invalidRequest
        }
        let url: URL
        do {
            url = try HTTPSessionTransport.makeURL(baseURL: origin, path: path, query: [])
        } catch {
            throw Failure.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Failure.network
        }
        guard tokenProvider() == token else { throw Failure.accountChanged }
        guard let http = response as? HTTPURLResponse else { throw Failure.network }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            .flatMap(Int.init)
            .flatMap { (1...86_400).contains($0) ? $0 : nil }
        let json = data.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: data)
        return Answer(status: http.statusCode, json: json, retryAfter: retryAfter)
    }

    /// A path segment the API could hold: a session or folder id as the session transport accepts them.
    static func isIdentifier(_ value: String) -> Bool {
        SessionIdentifier.isValid(value)
    }
}
