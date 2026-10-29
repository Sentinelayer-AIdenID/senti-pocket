import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts

// The Respawn mint service: the boxes ("lives") an agent runs on, and each one's flight record, source-bound to
// sentinelayer-web `src/lib/mintApi.ts` (GET /api/mint/lives?sessionId=, GET /api/mint/lives/<id>/flight). The
// service is its own origin; every call carries the person's Senti token, which it verifies against the API and
// admits allowlisted users only. Decoded tolerantly, field by field.

/// One box an agent runs on in a room.
public struct MintLife: Equatable, Identifiable, Sendable {
    public let id: String
    public let agentName: String
    public let model: String
    /// booting, probing, ready, working, capturing, destroyed, lost, or anything newer (shown as text).
    public let phase: String
    public let bornAt: String
    public let expiresAt: String
    public let jobDescription: String?
    public let ticketId: String?
    public let ticketTitle: String?
    public let consoleURL: URL?

    /// Still running: everything but destroyed and lost.
    public var isActive: Bool { !["destroyed", "lost"].contains(phase.lowercased()) }

    public init(id: String, agentName: String, model: String, phase: String, bornAt: String = "", expiresAt: String = "",
                jobDescription: String? = nil, ticketId: String? = nil, ticketTitle: String? = nil, consoleURL: URL? = nil) {
        self.id = id
        self.agentName = agentName
        self.model = model
        self.phase = phase
        self.bornAt = bornAt
        self.expiresAt = expiresAt
        self.jobDescription = jobDescription
        self.ticketId = ticketId
        self.ticketTitle = ticketTitle
        self.consoleURL = consoleURL
    }

    init?(json: JSONValue) {
        guard let id = json["lifeId"]?.stringValue, !id.isEmpty, id.utf8.count <= 128 else { return nil }
        let console = json["consoleUrl"]?.stringValue.flatMap(URL.init(string:))
        self.init(
            id: id,
            agentName: json["agentName"]?.stringValue ?? "agent",
            model: json["model"]?.stringValue ?? "",
            phase: json["phase"]?.stringValue ?? "",
            bornAt: json["bornAt"]?.stringValue ?? "",
            expiresAt: json["expiresAt"]?.stringValue ?? "",
            jobDescription: json["job"]?["description"]?.stringValue,
            ticketId: json["ticket"]?["id"]?.stringValue,
            ticketTitle: json["ticket"]?["title"]?.stringValue,
            // Only an https console link is ever offered to open.
            consoleURL: console?.scheme?.lowercased() == "https" ? console : nil
        )
    }
}

/// What a box has been thinking and doing, from its flight record: newest last.
public struct MintFlightRecord: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public let at: String
        public let text: String
        /// For a command: its exit code once it finished.
        public let exitCode: Int?

        public init(at: String, text: String, exitCode: Int? = nil) {
            self.at = at
            self.text = text
            self.exitCode = exitCode
        }
    }

    /// The agent's own account of what it is doing, in its words.
    public let narration: [Line]
    /// Commands it ran, newest last.
    public let commands: [Line]
    public let posts: Int
    public let phase: String?
    public let lastActivity: String?
    public let expiresAt: String?
    public let doneSummary: String?

    public init(narration: [Line] = [], commands: [Line] = [], posts: Int = 0, phase: String? = nil,
                lastActivity: String? = nil, expiresAt: String? = nil, doneSummary: String? = nil) {
        self.narration = narration
        self.commands = commands
        self.posts = posts
        self.phase = phase
        self.lastActivity = lastActivity
        self.expiresAt = expiresAt
        self.doneSummary = doneSummary
    }

    /// The newest entries kept for the phone.
    public static let keptLines = 40

    public init(json: JSONValue) {
        let narration = (json["thinking"]?["narration"]?.arrayValue ?? []).compactMap { entry -> Line? in
            guard let text = entry["text"]?.stringValue, !text.isEmpty else { return nil }
            return Line(at: entry["at"]?.stringValue ?? "", text: text)
        }
        let commands = (json["tools"]?["list"]?.arrayValue ?? []).compactMap { entry -> Line? in
            guard let cmd = entry["cmd"]?.stringValue, !cmd.isEmpty else { return nil }
            return Line(at: entry["at"]?.stringValue ?? "", text: cmd, exitCode: entry["exitCode"]?.intValue.map { Int(clamping: $0) })
        }
        self.init(
            narration: Array(narration.suffix(Self.keptLines)),
            commands: Array(commands.suffix(Self.keptLines)),
            posts: Int(clamping: json["room"]?["posts"]?.intValue ?? 0),
            phase: json["time"]?["phase"]?.stringValue,
            lastActivity: json["time"]?["lastActivity"]?.stringValue,
            expiresAt: json["time"]?["expiresAt"]?.stringValue,
            doneSummary: json["time"]?["doneSummary"]?.stringValue
        )
    }
}

public enum MintError: Error, Equatable, Sendable {
    case notConfigured
    case reauthenticationRequired
    /// The service does not admit this account (it is allowlisted).
    case forbidden
    case unavailable
}

/// The reads the Flight record needs.
public protocol MintReading: Sendable {
    func roomLives(sessionId: String) async throws -> [MintLife]
    func flight(lifeId: String) async throws -> MintFlightRecord
}

public final class HTTPMintClient: MintReading, @unchecked Sendable {
    public static let defaultBaseURL = URL(string: "https://sl-mint.eastus.cloudapp.azure.com")

    private let baseURL: URL?
    private let urlSession: URLSession
    private let tokenProvider: @Sendable () -> String?

    public init(baseURL: URL? = HTTPMintClient.defaultBaseURL, urlSession: URLSession = .shared,
                tokenProvider: @escaping @Sendable () -> String?) {
        // The person's Senti token goes to an https origin only.
        self.baseURL = baseURL.flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        self.urlSession = urlSession
        self.tokenProvider = tokenProvider
    }

    var baseURLForTesting: URL? { baseURL }

    public func roomLives(sessionId: String) async throws -> [MintLife] {
        guard !sessionId.isEmpty, sessionId.utf8.count <= 256 else { throw MintError.notConfigured }
        let json = try await get(path: "/api/mint/lives", query: [URLQueryItem(name: "sessionId", value: sessionId)])
        return (json["lives"]?.arrayValue ?? []).compactMap(MintLife.init(json:))
    }

    public func flight(lifeId: String) async throws -> MintFlightRecord {
        guard !lifeId.isEmpty, lifeId.utf8.count <= 128,
              lifeId.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else {
            throw MintError.notConfigured
        }
        return MintFlightRecord(json: try await get(path: "/api/mint/lives/\(lifeId)/flight", query: []))
    }

    static func request(baseURL: URL, path: String, query: [URLQueryItem], token: String) -> URLRequest? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func get(path: String, query: [URLQueryItem]) async throws -> JSONValue {
        guard let baseURL else { throw MintError.notConfigured }
        guard let token = tokenProvider(), !token.isEmpty else { throw MintError.reauthenticationRequired }
        guard let request = Self.request(baseURL: baseURL, path: path, query: query, token: token) else {
            throw MintError.notConfigured
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw MintError.unavailable
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300:
            break
        case 401:
            throw MintError.reauthenticationRequired
        case 403:
            throw MintError.forbidden
        default:
            throw MintError.unavailable
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw MintError.unavailable }
        return json
    }
}
