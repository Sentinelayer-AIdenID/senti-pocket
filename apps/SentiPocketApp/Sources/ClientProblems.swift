import Foundation

/// Reports a failed request to the server, so a failure reaches the agents without anyone posting it (Carter,
/// #55375: "that error should somehow reach you guys quick. We cannot allow an error like that to go unnoticed").
/// `POST /api/v1/client-problems` (API #1051) takes only the route's template, the status, the server's request id
/// (none when the request never reached the server), the build, the platform and the time: never a room id, text,
/// a token or a header. Fire and forget: a report that fails is dropped, and a failed report is never reported.
final class ClientProblems: @unchecked Sendable {
    static let shared = ClientProblems(apiBaseURL: GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_API_URL", "SENTI_GATEWAY_URL"]),
                                       tokenProvider: { SessionTokenStore.load() })

    struct Report: Equatable {
        let route: String
        let status: Int
        let requestId: String?
        let build: String
        let at: Date
    }

    /// One report per route and status in this window, and at most `hourlyLimit` an hour, from this phone.
    static let window: TimeInterval = 15 * 60
    static let hourlyLimit = 10

    private let apiBaseURL: URL?
    private let tokenProvider: @Sendable () -> String?
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var lastSent: [String: Date] = [:]
    private var sentTimes: [Date] = []

    init(apiBaseURL: URL?, tokenProvider: @escaping @Sendable () -> String?,
         session: URLSession = ClientProblems.ephemeralSession, now: @escaping @Sendable () -> Date = { Date() }) {
        self.apiBaseURL = apiBaseURL
        self.tokenProvider = tokenProvider
        self.session = session
        self.now = now
    }

    static let ephemeralSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// A failed answer from a room route: its template (`/api/v1/sessions/{session_id}/<path>`), its status, and the
    /// server's request id when the server answered. Sign-in failures are not problems to report.
    func roomRequestFailed(path: String, status: Int, response: HTTPURLResponse?) {
        guard (400...599).contains(status), status != 401 else { return }
        let route = "/api/v1/sessions/{session_id}/" + path
        report(route: route, status: status, requestId: Self.serverRequestId(response))
    }

    /// The server's own request id (`req-` and 12 hex digits); anything else (an edge's answer, none) is none.
    static func serverRequestId(_ response: HTTPURLResponse?) -> String? {
        guard let value = response?.value(forHTTPHeaderField: "X-Request-Id")?.lowercased(),
              value.range(of: #"^req-[0-9a-f]{12}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// Whether this report goes out now, and notes it if so.
    func shouldSend(route: String, status: Int) -> Bool {
        let at = now()
        let key = "\(route) \(status)"
        lock.lock()
        defer { lock.unlock() }
        sentTimes.removeAll { at.timeIntervalSince($0) > 3_600 }
        if let last = lastSent[key], at.timeIntervalSince(last) < Self.window { return false }
        guard sentTimes.count < Self.hourlyLimit else { return false }
        lastSent[key] = at
        sentTimes.append(at)
        return true
    }

    func report(route: String, status: Int, requestId: String?) {
        // Tests and previews end requests at will; nothing of theirs is a problem to report.
        guard !CrashReporter.isTestRun, shouldSend(route: route, status: status),
              let apiBaseURL, var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false),
              let token = tokenProvider(), !token.isEmpty else { return }
        components.percentEncodedPath = "/api/v1/client-problems"
        components.query = nil
        guard let url = components.url else { return }
        var body: [String: Any] = [
            "route": route,
            "status": status,
            "build": (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0",
            "platform": "ios",
            "at": ISO8601DateFormatter().string(from: now())
        ]
        if let requestId { body["requestId"] = requestId }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let session = self.session
        Task.detached(priority: .utility) { _ = try? await session.data(for: request) }
    }
}
