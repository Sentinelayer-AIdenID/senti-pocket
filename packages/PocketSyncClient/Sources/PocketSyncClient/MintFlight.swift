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
    /// The room it works in.
    public let sessionId: String?
    /// What it has cost so far, in dollars.
    public let costUsd: Double?
    /// Its observed working time, and whether that record is exact (server-observed turns, fully scanned).
    public let workingSeconds: Double?
    public let workingIsExact: Bool
    /// When its machine ended.
    public let endedAt: String?

    /// Phases in which a box no longer runs. The service treats killed like destroyed (the web's `ENDED_PHASES`).
    public static let endedPhases: Set<String> = ["destroyed", "killed", "lost"]

    /// Still running: not destroyed, killed or lost.
    public var isActive: Bool { !Self.endedPhases.contains(phase.lowercased()) }

    public init(id: String, agentName: String, model: String, phase: String, bornAt: String = "", expiresAt: String = "",
                jobDescription: String? = nil, ticketId: String? = nil, ticketTitle: String? = nil, consoleURL: URL? = nil,
                sessionId: String? = nil, costUsd: Double? = nil, workingSeconds: Double? = nil, workingIsExact: Bool = false,
                endedAt: String? = nil) {
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
        self.sessionId = sessionId
        self.costUsd = costUsd
        self.workingSeconds = workingSeconds
        self.workingIsExact = workingIsExact
        self.endedAt = endedAt
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
            consoleURL: console?.scheme?.lowercased() == "https" ? console : nil,
            sessionId: json["sessionId"]?.stringValue,
            costUsd: Self.cost(json),
            workingSeconds: json["timing"]?["working"]?["seconds"]?.doubleValue.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            workingIsExact: json["timing"]?["working"]?["coverage"]?.stringValue == "stream_turns"
                && json["timing"]?["working"]?["quality"]?.stringValue == "exact",
            endedAt: json["timing"]?["allocation"]?["endAt"]?.stringValue
        )
    }

    /// The web's `mintCostUsd`: the first of totalCostUsd, costUsd, totalCost and cost, here or under `usage`.
    static func cost(_ json: JSONValue, depth: Int = 0) -> Double? {
        for key in ["totalCostUsd", "costUsd", "totalCost", "cost"] {
            if let value = json[key]?.doubleValue, value.isFinite { return value }
        }
        guard depth == 0, let usage = json["usage"] else { return nil }
        return cost(usage, depth: 1)
    }
}

/// What every box of one room adds up to, listed or not (`respawn.room-totals/1`), source-bound to sentinelayer-web
/// `parseRoomTotals`.
public struct MintRoomTotals: Equatable, Sendable {
    public let lifeCount: Int
    /// Boxes no longer running: destroyed, killed or lost.
    public let endedCount: Int
    public let firstBornAt: String?
    /// The latest recorded end (destroyed, else expiry).
    public let lastEndAt: String?
    /// Every recorded working time, added: a minimum unless `exactLives` equals `lifeCount`.
    public let workingSeconds: Double
    /// Boxes whose working time is exact, with their time and cost: the only ones a cost comparison may use.
    public let exactLives: Int
    public let exactWorkingSeconds: Double
    public let exactCostUsd: Double
    /// Every box's cost, added.
    public let costUsd: Double

    public init(lifeCount: Int, endedCount: Int, firstBornAt: String?, lastEndAt: String?, workingSeconds: Double,
                exactLives: Int, exactWorkingSeconds: Double, exactCostUsd: Double, costUsd: Double) {
        self.lifeCount = lifeCount
        self.endedCount = endedCount
        self.firstBornAt = firstBornAt
        self.lastEndAt = lastEndAt
        self.workingSeconds = workingSeconds
        self.exactLives = exactLives
        self.exactWorkingSeconds = exactWorkingSeconds
        self.exactCostUsd = exactCostUsd
        self.costUsd = costUsd
    }

    /// Only when every field is well formed: anything else is read as absent, never as zero.
    public init?(json: JSONValue?) {
        guard let json, json["schema"]?.stringValue == "respawn.room-totals/1" else { return nil }
        func count(_ key: String) -> Int? {
            guard let value = json[key]?.intValue, value >= 0, value <= 9_007_199_254_740_991 else { return nil }
            return Int(value)
        }
        func amount(_ key: String) -> Double? {
            guard let value = json[key]?.doubleValue, value.isFinite, value >= 0 else { return nil }
            return value
        }
        // nil when malformed; .some(nil) for an explicit null.
        func instant(_ key: String) -> String?? {
            switch json[key] {
            case .null?: return .some(nil)
            case .string(let text)? where ParsedSessionTimestamp(text).date != nil: return .some(text)
            default: return nil
            }
        }
        guard let lives = count("lifeCount"), let ended = count("endedCount"), let exact = count("exactLives"),
              let working = amount("workingSeconds"), let exactWorking = amount("exactWorkingSeconds"),
              let exactCost = amount("exactCostUsd"), let cost = amount("costUsd"),
              let firstBorn = instant("firstBornAt"), let lastEnd = instant("lastEndAt"),
              ended <= lives, exact <= lives else { return nil }
        self.init(lifeCount: lives, endedCount: ended, firstBornAt: firstBorn, lastEndAt: lastEnd, workingSeconds: working,
                  exactLives: exact, exactWorkingSeconds: exactWorking, exactCostUsd: exactCost, costUsd: cost)
    }
}

/// One room's boxes as the mint lists them, with the room's totals, source-bound to sentinelayer-web
/// `listRoomMintLives` and `useRoomLives`.
public struct MintRoomLives: Equatable, Sendable {
    /// This room's boxes only: a mint that ignores the room filter lists everyone's, so the list is filtered here too.
    public let lives: [MintLife]
    /// The mint left the room's oldest boxes out of its list.
    public let truncated: Bool
    /// Nil from a mint that does not send them.
    public let totals: MintRoomTotals?
    /// Another room's box was in the list: the mint ignored the room filter.
    public let fleetList: Bool

    public init(lives: [MintLife], truncated: Bool = false, totals: MintRoomTotals? = nil, fleetList: Bool = false) {
        self.lives = lives
        self.truncated = truncated
        self.totals = totals
        self.fleetList = fleetList
    }

    public init(json: JSONValue, sessionId: String) {
        let all = (json["lives"]?.arrayValue ?? []).compactMap(MintLife.init(json:))
        self.init(
            lives: all.filter { $0.sessionId == sessionId },
            truncated: json["timingSummary"]?["truncated"]?.boolValue == true,
            totals: MintRoomTotals(json: json["roomTotals"]),
            fleetList: all.contains { $0.sessionId != sessionId }
        )
    }
}

/// The room's Flight record figures as the web shows them (sentinelayer-web `FlightRecord.tsx` and `roomWorkMetrics`;
/// Carter, 10-27: "even $80/hr"): boxes minted, active and finished; agent hours worked; days saved against one
/// engineer at 8 hours a day; and the cost, with its share of what engineers at $80 an hour would cost.
public struct MintRoomSummary: Equatable, Sendable {
    public static let engineerRateUsd = 80.0
    public static let engineerHoursPerDay = 8.0

    public let minted: Int
    public let active: Int
    public var finished: Int { minted - active }
    /// The counts and the cost are minimums: the mint cut its list and sent no totals.
    public let listCut: Bool
    /// The room's total cost; nil when a listed box has no cost.
    public let costUsd: Double?
    /// The observed working hours, added; a minimum when `workIsPartial`.
    public let workingHours: Double
    public let workIsPartial: Bool
    /// False when no box has a working record yet, so no hours are shown rather than "at least 0".
    public let workKnown: Bool
    /// Engineer days for the same hours, minus the days the room has run; never below zero, and nil when the room's
    /// span is unknown (its oldest boxes are missing from the list).
    public let savedDays: Double?
    public let elapsedDays: Double
    /// The cost as a percent of engineers at $80 an hour over the boxes with a known cost and an exact record.
    public let costPercent: Double?
    public let pricedLives: Int

    public init(room: MintRoomLives, now: Date) {
        let lives = room.lives
        let totals = room.totals
        minted = totals?.lifeCount ?? lives.count
        active = totals.map { $0.lifeCount - $0.endedCount } ?? lives.filter(\.isActive).count
        listCut = room.truncated && totals == nil
        let costs = lives.map(\.costUsd)
        let listedCost: Double? = !lives.isEmpty && costs.allSatisfy { $0 != nil } ? costs.reduce(0) { $0 + ($1 ?? 0) } : nil
        costUsd = totals?.costUsd ?? listedCost
        let hasLives = totals.map { $0.lifeCount > 0 } ?? !lives.isEmpty

        let seconds: Double
        let partial: Bool
        let firstBorn: Date?
        let lastEnd: Date?
        let running: Bool
        let pricedSeconds: Double
        let pricedCost: Double
        let priced: Int
        if let totals {
            seconds = totals.workingSeconds
            partial = totals.exactLives < totals.lifeCount
            firstBorn = totals.firstBornAt.flatMap { ParsedSessionTimestamp($0).date }
            lastEnd = totals.lastEndAt.flatMap { ParsedSessionTimestamp($0).date }
            running = totals.endedCount < totals.lifeCount
            pricedSeconds = totals.exactWorkingSeconds
            pricedCost = totals.exactCostUsd
            priced = totals.exactLives
        } else {
            var total = 0.0
            var incomplete = room.truncated
            var earliest: Date?
            var latest: Date?
            var anyRunning = false
            var exactSeconds = 0.0
            var exactCost = 0.0
            var exactCount = 0
            for life in lives {
                // An incomplete record still counts toward the minimum, never as exact.
                let complete = life.workingIsExact ? life.workingSeconds : nil
                if complete == nil { incomplete = true }
                total += life.workingSeconds ?? 0
                if let complete, let cost = life.costUsd {
                    exactSeconds += complete
                    exactCost += cost
                    exactCount += 1
                }
                if let born = ParsedSessionTimestamp(life.bornAt).date { earliest = min(earliest ?? born, born) }
                if life.isActive { anyRunning = true }
                let ended = life.endedAt.flatMap { ParsedSessionTimestamp($0).date } ?? ParsedSessionTimestamp(life.expiresAt).date
                if let ended { latest = max(latest ?? ended, ended) }
            }
            seconds = total
            partial = incomplete
            firstBorn = earliest
            lastEnd = latest
            running = anyRunning
            pricedSeconds = exactSeconds
            pricedCost = exactCost
            priced = exactCount
        }
        workingHours = seconds / 3600
        workIsPartial = partial
        workKnown = hasLives && (workingHours > 0 || !partial)
        let engineerDays = workingHours / Self.engineerHoursPerDay
        // A finished room's span stops at its last box's end, so its time saved does not shrink as days pass.
        let spanEnd: Date
        if let lastEnd, !running { spanEnd = min(now, lastEnd) } else { spanEnd = now }
        elapsedDays = firstBorn.map { max(0, spanEnd.timeIntervalSince($0) / 86_400) } ?? 0
        savedDays = listCut ? nil : max(0, engineerDays - elapsedDays)
        pricedLives = priced
        let engineerCost = pricedSeconds / 3600 * Self.engineerRateUsd
        costPercent = engineerCost > 0 ? pricedCost / engineerCost * 100 : nil
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
    /// No machine is free to start an agent on right now (the service said so).
    case capacity
    /// The service refused the request as it stands (a reason it gave, when it gave one).
    case refused(String?)
}

/// A model an agent can be started on (sentinelayer-web `MintModel`), with the efforts it offers.
public struct MintModel: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let note: String?
    /// none, low, medium, high, xhigh; empty when the model takes no effort setting.
    public let efforts: [String]
    public let defaultEffort: String?

    public init(id: String, label: String, note: String? = nil, efforts: [String] = [], defaultEffort: String? = nil) {
        self.id = id
        self.label = label
        self.note = note
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty else { return nil }
        let known = ["none", "low", "medium", "high", "xhigh"]
        let efforts = (json["efforts"]?.arrayValue ?? []).compactMap(\.stringValue).filter(known.contains)
        let preferred = json["defaultEffort"]?.stringValue
        self.init(
            id: id,
            label: json["label"]?.stringValue ?? id,
            note: json["note"]?.stringValue,
            efforts: efforts,
            defaultEffort: preferred.flatMap { efforts.contains($0) ? $0 : nil }
        )
    }
}

/// Start an agent on its own machine in a room (sentinelayer-web `MintUpRequest`), optionally for a ticket.
public struct MintUpRequest: Equatable, Sendable {
    public let model: String
    public let effort: String?
    public let jobDescription: String
    public let sessionId: String
    public let agentName: String?
    public let ticketId: String?
    public let ticketTitle: String?

    public init(model: String, effort: String? = nil, jobDescription: String, sessionId: String, agentName: String? = nil,
                ticketId: String? = nil, ticketTitle: String? = nil) {
        self.model = model
        self.effort = effort
        self.jobDescription = jobDescription
        self.sessionId = sessionId
        self.agentName = agentName
        self.ticketId = ticketId
        self.ticketTitle = ticketTitle
    }

    /// The body the service reads: empty optional fields are left out.
    public var body: [String: Any] {
        var body: [String: Any] = ["model": model, "jobDescription": jobDescription, "sessionId": sessionId]
        if let effort { body["effort"] = effort }
        if let agentName, !agentName.isEmpty { body["agentName"] = agentName }
        if let ticketId { body["ticket"] = ["id": ticketId, "title": ticketTitle ?? ""] }
        return body
    }
}

/// The agent that started: its box, its name in the room, and its read-only console.
public struct MintUpResponse: Equatable, Sendable {
    public let lifeId: String
    public let agentName: String
    public let sessionId: String
    public let phase: String
    public let consoleURL: URL?

    public init(lifeId: String, agentName: String, sessionId: String, phase: String, consoleURL: URL?) {
        self.lifeId = lifeId
        self.agentName = agentName
        self.sessionId = sessionId
        self.phase = phase
        self.consoleURL = consoleURL
    }

    init?(json: JSONValue) {
        guard let lifeId = json["lifeId"]?.stringValue, !lifeId.isEmpty,
              let agentName = json["agentName"]?.stringValue, !agentName.isEmpty else { return nil }
        let console = json["consoleUrl"]?.stringValue.flatMap(URL.init(string:))
        self.init(
            lifeId: lifeId,
            agentName: agentName,
            sessionId: json["sessionId"]?.stringValue ?? "",
            phase: json["phase"]?.stringValue ?? "",
            consoleURL: console?.scheme?.lowercased() == "https" ? console : nil
        )
    }
}

/// The reads the Flight record needs.
public protocol MintReading: Sendable {
    func roomLives(sessionId: String) async throws -> [MintLife]
    func flight(lifeId: String) async throws -> MintFlightRecord
    /// The room's boxes with the room's totals.
    func roomSnapshot(sessionId: String) async throws -> MintRoomLives
}

extension MintReading {
    /// A reader without totals: its list as it is.
    public func roomSnapshot(sessionId: String) async throws -> MintRoomLives {
        MintRoomLives(lives: try await roomLives(sessionId: sessionId))
    }
}

/// Starting agents (sentinelayer-web `listMintModels`, `mintAgent`): the models, and an agent on one of them.
public protocol MintStarting: Sendable {
    func models() async throws -> [MintModel]
    func startAgent(_ request: MintUpRequest) async throws -> MintUpResponse
}

public final class HTTPMintClient: MintReading, MintStarting, @unchecked Sendable {
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
        try await roomSnapshot(sessionId: sessionId).lives
    }

    public func roomSnapshot(sessionId: String) async throws -> MintRoomLives {
        guard !sessionId.isEmpty, sessionId.utf8.count <= 256 else { throw MintError.notConfigured }
        let json = try await get(path: "/api/mint/lives", query: [URLQueryItem(name: "sessionId", value: sessionId)])
        return MintRoomLives(json: json, sessionId: sessionId)
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

    public func models() async throws -> [MintModel] {
        let json = try await get(path: "/api/mint/models", query: [])
        return (json["models"]?.arrayValue ?? []).compactMap(MintModel.init(json:))
    }

    /// Booting a machine takes a while: the web waits up to three minutes.
    public func startAgent(_ request: MintUpRequest) async throws -> MintUpResponse {
        let json = try await get(path: "/api/mint/up", query: [], method: "POST", body: request.body, timeout: 180)
        guard let started = MintUpResponse(json: json) else { throw MintError.unavailable }
        return started
    }

    private func get(path: String, query: [URLQueryItem], method: String = "GET", body: [String: Any]? = nil,
                     timeout: TimeInterval = 30) async throws -> JSONValue {
        guard let baseURL else { throw MintError.notConfigured }
        guard let token = tokenProvider(), !token.isEmpty else { throw MintError.reauthenticationRequired }
        guard var request = Self.request(baseURL: baseURL, path: path, query: query, token: token) else {
            throw MintError.notConfigured
        }
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw MintError.unavailable
        }
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300:
            break
        case 401:
            throw MintError.reauthenticationRequired
        case 403:
            throw MintError.forbidden
        case 429:
            throw MintError.capacity
        case 400, 409, 422:
            throw MintError.refused(json?["error"]?.stringValue ?? json?["message"]?.stringValue)
        default:
            throw MintError.unavailable
        }
        guard let json else { throw MintError.unavailable }
        return json
    }
}
