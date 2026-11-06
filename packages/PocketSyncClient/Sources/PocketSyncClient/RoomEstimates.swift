import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts

// The estimate step: priced options before any work starts (the API's estimate contract, draft 2 with its contract
// answers, ticket bc6c291f). What the phone reads of it, and every field name it reads or sends, are here and only
// here, so a renamed field is a change to this file alone:
// - a room offers "Get an estimate" when its read says `features.estimates: true`;
// - asking: `POST /api/v1/sessions/{id}/estimates {goal, sourceSequenceId}`; reading:
//   `GET /api/v1/sessions/{id}/estimates/{estimateId}`; picking: `POST .../estimates/{estimateId}/pick {optionId}`,
//   where a second pick is 409 `ESTIMATE_ALREADY_PICKED` with the first pick;
// - the room shows a card for a `session_estimate_card` event, from the summary in its payload, until the whole
//   estimate is read;
// - your plan is saved with `PATCH /api/v1/auth/me {claudePlan | chatgptPlan}`.
// The phone never prices anything: it shows what the server measured, and nothing where the server measured nothing.

/// Where an estimate stands (`status`).
public enum RoomEstimateStatus: String, Equatable, Sendable {
    case ready, picked, expired, failed
}

/// How an option's judge is paid for (`judge.billing`).
public enum RoomEstimateBilling: String, Equatable, Sendable {
    /// From the person's own plan (Claude, or ChatGPT for Codex): the cost leaves the judge out.
    case plan
    /// Per token, and in the cost.
    case perToken = "per_token"
    /// No judge.
    case none
}

/// Whose plan a plan-billed judge uses.
public enum RoomEstimatePlanKind: String, Equatable, Sendable {
    case claude, chatgpt
}

/// A plan you said you are on, as the API takes it (`claudePlan`, `chatgptPlan`).
public struct RoomEstimatePlanAnswer: Equatable, Sendable {
    public let kind: RoomEstimatePlanKind
    /// One of `choices(for: kind)`.
    public let plan: String

    public init?(kind: RoomEstimatePlanKind, plan: String) {
        guard Self.choices(for: kind).contains(where: { $0.value == plan }) else { return nil }
        self.kind = kind
        self.plan = plan
    }

    /// The plans the API takes for each kind, with what the phone calls them.
    public static func choices(for kind: RoomEstimatePlanKind) -> [(value: String, title: String)] {
        switch kind {
        case .claude: return [("pro", "Pro"), ("max5", "Max 5x"), ("max20", "Max 20x")]
        case .chatgpt: return [("plus", "Plus"), ("pro", "Pro"), ("team", "Team")]
        }
    }

    var field: String { kind == .claude ? "claudePlan" : "chatgptPlan" }
}

/// One option as the room's event sums it up (`payload.options[]`).
public struct RoomEstimateOptionSummary: Equatable, Sendable {
    public let id: String
    public let label: String
    /// Nil when nothing it needs is measured: shown as no basis yet, never as $0.
    public let lowUsd: Double?
    public let highUsd: Double?
    public let judgeBilling: RoomEstimateBilling?

    public init(id: String, label: String, lowUsd: Double? = nil, highUsd: Double? = nil,
                judgeBilling: RoomEstimateBilling? = nil) {
        self.id = id
        self.label = label
        self.lowUsd = lowUsd
        self.highUsd = highUsd
        self.judgeBilling = judgeBilling
    }
}

/// What a `session_estimate_card` event carries: enough to draw the card before the whole estimate is read.
public struct RoomEstimateSummary: Equatable, Sendable {
    public let estimateId: String
    public let status: RoomEstimateStatus
    public let suggested: String?
    /// The public handle of whoever asked: they may pick, with the room's owners and admins.
    public let askedBy: String?
    /// The message the estimate was asked on.
    public let sourceSequenceId: Int64?
    public let options: [RoomEstimateOptionSummary]

    public init(estimateId: String, status: RoomEstimateStatus = .ready, suggested: String? = nil,
                askedBy: String? = nil, sourceSequenceId: Int64? = nil, options: [RoomEstimateOptionSummary]) {
        self.estimateId = estimateId
        self.status = status
        self.suggested = suggested
        self.askedBy = askedBy
        self.sourceSequenceId = sourceSequenceId
        self.options = options
    }

    /// The room event type that carries an estimate's card.
    public static let eventType = "session_estimate_card"

    /// From the event's payload. Nil without an estimate id, a known status or a single readable option: the card
    /// would have nothing to show.
    init?(payload: JSONValue) {
        guard let estimateId = RoomEstimateWire.identifier(payload["estimateId"]),
              let status = payload["status"]?.stringValue.flatMap(RoomEstimateStatus.init(rawValue:)) else { return nil }
        let options = (payload["options"]?.arrayValue ?? []).compactMap { option -> RoomEstimateOptionSummary? in
            guard let id = RoomEstimateWire.text(option["id"], limit: 64),
                  let label = RoomEstimateWire.text(option["label"], limit: 200) else { return nil }
            return RoomEstimateOptionSummary(
                id: id,
                label: label,
                lowUsd: RoomEstimateWire.amount(option["lowUsd"]),
                highUsd: RoomEstimateWire.amount(option["highUsd"]),
                judgeBilling: option["judgeBilling"]?.stringValue.flatMap(RoomEstimateBilling.init(rawValue:))
            )
        }
        guard !options.isEmpty else { return nil }
        self.init(
            estimateId: estimateId,
            status: status,
            suggested: RoomEstimateWire.text(payload["suggested"], limit: 64),
            askedBy: RoomEstimateWire.text(payload["askedBy"], limit: 120),
            sourceSequenceId: payload["sourceSequenceId"]?.intValue.flatMap { $0 > 0 ? $0 : nil },
            options: options
        )
    }
}

/// The whole estimate (`GET .../estimates/{estimateId}`).
public struct RoomEstimate: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public let id: String
        public let label: String
        /// `claude_subscription`, `api_key`, `codex` or `none`.
        public let judgeKind: String?
        public let judgeBilling: RoomEstimateBilling?
        /// Nil when nothing it needs is measured (`cost: null`): no basis yet, never $0.
        public let lowUsd: Double?
        public let highUsd: Double?
        /// Tickets with no measured basis, left out of the cost.
        public let unpricedTickets: Int
        /// What it covers ("box compute", "judge tokens").
        public let covers: [String]
        public let judgeTokensLow: Int64?
        public let judgeTokensHigh: Int64?
        /// Whose plan a plan-billed judge uses (`planUsage.plan`).
        public let plan: RoomEstimatePlanKind?
        /// The share of the person's weekly limit, when the server knows their plan.
        public let weeklyLimitPercentLow: Double?
        public let weeklyLimitPercentHigh: Double?
        public let lowMinutes: Int64?
        public let highMinutes: Int64?
        public let expectedRounds: Int64?
        public let maxRounds: Int64?
        public let caveats: [String]

        public init(id: String, label: String, judgeKind: String? = nil, judgeBilling: RoomEstimateBilling? = nil,
                    lowUsd: Double? = nil, highUsd: Double? = nil, unpricedTickets: Int = 0, covers: [String] = [],
                    judgeTokensLow: Int64? = nil, judgeTokensHigh: Int64? = nil, plan: RoomEstimatePlanKind? = nil,
                    weeklyLimitPercentLow: Double? = nil, weeklyLimitPercentHigh: Double? = nil,
                    lowMinutes: Int64? = nil, highMinutes: Int64? = nil, expectedRounds: Int64? = nil,
                    maxRounds: Int64? = nil, caveats: [String] = []) {
            self.id = id
            self.label = label
            self.judgeKind = judgeKind
            self.judgeBilling = judgeBilling
            self.lowUsd = lowUsd
            self.highUsd = highUsd
            self.unpricedTickets = unpricedTickets
            self.covers = covers
            self.judgeTokensLow = judgeTokensLow
            self.judgeTokensHigh = judgeTokensHigh
            self.plan = plan
            self.weeklyLimitPercentLow = weeklyLimitPercentLow
            self.weeklyLimitPercentHigh = weeklyLimitPercentHigh
            self.lowMinutes = lowMinutes
            self.highMinutes = highMinutes
            self.expectedRounds = expectedRounds
            self.maxRounds = maxRounds
            self.caveats = caveats
        }

        /// Whose plan a judge billed to a plan uses: the plan the estimate names, else ChatGPT for Codex and Claude
        /// for a Claude subscription.
        public var planKind: RoomEstimatePlanKind? {
            guard judgeBilling == .plan else { return nil }
            if let plan { return plan }
            switch judgeKind ?? "" {
            case "codex": return .chatgpt
            case "claude_subscription": return .claude
            default: return nil
            }
        }

        init?(json option: JSONValue) {
            guard let id = RoomEstimateWire.text(option["id"], limit: 64),
                  let label = RoomEstimateWire.text(option["label"], limit: 200) else { return nil }
            let judge = option["judge"] ?? .null
            let cost = option["cost"] ?? .null
            let usage = option["planUsage"] ?? .null
            let time = option["time"] ?? .null
            let rounds = option["rounds"] ?? .null
            // A cost needs both ends; one without them is nothing measured.
            let low = RoomEstimateWire.amount(cost["lowUsd"])
            let high = RoomEstimateWire.amount(cost["highUsd"])
            let priced = low != nil && high != nil
            self.init(
                id: id,
                label: label,
                judgeKind: RoomEstimateWire.text(judge["kind"], limit: 40),
                judgeBilling: judge["billing"]?.stringValue.flatMap(RoomEstimateBilling.init(rawValue:)),
                lowUsd: priced ? low : nil,
                highUsd: priced ? high : nil,
                unpricedTickets: Int(cost["unpricedTickets"]?.intValue.map { min(max($0, 0), 999) } ?? 0),
                covers: RoomEstimateWire.texts(cost["covers"]),
                judgeTokensLow: RoomEstimateWire.count(usage["judgeTokensLow"]),
                judgeTokensHigh: RoomEstimateWire.count(usage["judgeTokensHigh"]),
                plan: RoomEstimateWire.planKind(usage["plan"]),
                weeklyLimitPercentLow: RoomEstimateWire.percent(usage["weeklyLimitPercentLow"]),
                weeklyLimitPercentHigh: RoomEstimateWire.percent(usage["weeklyLimitPercentHigh"]),
                lowMinutes: RoomEstimateWire.count(time["lowMinutes"]),
                highMinutes: RoomEstimateWire.count(time["highMinutes"]),
                expectedRounds: RoomEstimateWire.count(rounds["expected"]),
                maxRounds: RoomEstimateWire.count(rounds["max"]),
                caveats: RoomEstimateWire.texts(option["caveats"])
            )
        }
    }

    public let estimateId: String
    public let goal: String
    public let options: [Option]
    public let suggested: String?
    public let status: RoomEstimateStatus
    /// Why it failed, in plain words.
    public let failureReason: String?
    public let askedBy: String?
    public let pickedOptionId: String?
    /// The public handle of whoever picked.
    public let pickedBy: String?
    public let basisMeasuredAt: String?
    public let basisSources: [String]

    public init(estimateId: String, goal: String = "", options: [Option], suggested: String? = nil,
                status: RoomEstimateStatus = .ready, failureReason: String? = nil, askedBy: String? = nil,
                pickedOptionId: String? = nil, pickedBy: String? = nil, basisMeasuredAt: String? = nil,
                basisSources: [String] = []) {
        self.estimateId = estimateId
        self.goal = goal
        self.options = options
        self.suggested = suggested
        self.status = status
        self.failureReason = failureReason
        self.askedBy = askedBy
        self.pickedOptionId = pickedOptionId
        self.pickedBy = pickedBy
        self.basisMeasuredAt = basisMeasuredAt
        self.basisSources = basisSources
    }

    /// From the read. Nil without an estimate id or a known status; a failed estimate may have no options.
    public init?(json: JSONValue) {
        guard let estimateId = RoomEstimateWire.identifier(json["estimateId"]),
              let status = json["status"]?.stringValue.flatMap(RoomEstimateStatus.init(rawValue:)) else { return nil }
        let options = (json["options"]?.arrayValue ?? []).compactMap(Option.init(json:))
        guard status == .failed || !options.isEmpty else { return nil }
        let basis = json["basis"] ?? .null
        self.init(
            estimateId: estimateId,
            goal: String((json["goal"]?.stringValue ?? "").prefix(RoomEstimateWire.goalLimit)),
            options: options,
            suggested: RoomEstimateWire.text(json["suggested"], limit: 64),
            status: status,
            failureReason: RoomEstimateWire.text(json["failureReason"], limit: 500),
            askedBy: RoomEstimateWire.text(json["askedBy"], limit: 120),
            pickedOptionId: RoomEstimateWire.text(json["pickedOptionId"], limit: 64),
            pickedBy: RoomEstimateWire.text(json["pickedBy"], limit: 120),
            basisMeasuredAt: RoomEstimateWire.text(basis["measuredAt"], limit: 40),
            basisSources: RoomEstimateWire.texts(basis["sources"])
        )
    }
}

/// What a pick did.
public enum RoomEstimatePick: Equatable, Sendable {
    /// The work started with the option picked.
    case started
    /// Someone picked first (409 `ESTIMATE_ALREADY_PICKED`): their pick, as far as the answer names it.
    case alreadyPicked(optionId: String?, by: String?)
}

public enum RoomEstimateError: Error, Equatable {
    /// The room offers no estimates (it is off), or the estimate is gone.
    case unavailable
    /// Not yours to do: only whoever asked, or the room's owners and admins, pick.
    case notAllowed
    /// Too many estimates asked for in the hour.
    case rateLimited(retryAfterSeconds: Int?)
    case reauthenticationRequired
    /// The API refused what was sent.
    case rejected
    /// The network, or the server: try again.
    case retryable
    case invalidData
}

/// Estimates in a room, as the signed-in person. A protocol so the room is testable without a network.
public protocol RoomEstimating: Sendable {
    /// Asks for an estimate of `goal` (the message's text). The card arrives as a room event.
    func requestEstimate(sessionId: String, goal: String, sourceSequenceId: Int64?) async throws
    func estimate(sessionId: String, estimateId: String) async throws -> RoomEstimate
    func pick(sessionId: String, estimateId: String, optionId: String) async throws -> RoomEstimatePick
    /// Saves the plan you said you are on, so the estimate can show the share of your weekly limit.
    func savePlan(_ answer: RoomEstimatePlanAnswer) async throws
}

public final class HTTPRoomEstimatesClient: RoomEstimating, @unchecked Sendable {
    private let request: PersonalRequest

    public init(apiBaseURL: URL?, urlSession: URLSession, tokenProvider: @escaping @Sendable () -> String?) {
        request = PersonalRequest(apiBaseURL: apiBaseURL, urlSession: urlSession, tokenProvider: tokenProvider)
    }

    public func requestEstimate(sessionId: String, goal: String, sourceSequenceId: Int64?) async throws {
        let goal = String(goal.trimmingCharacters(in: .whitespacesAndNewlines).prefix(RoomEstimateWire.goalLimit))
        guard PersonalRequest.isIdentifier(sessionId), !goal.isEmpty else { throw RoomEstimateError.rejected }
        var body: [String: Any] = ["goal": goal]
        if let sourceSequenceId, sourceSequenceId > 0 { body["sourceSequenceId"] = sourceSequenceId }
        _ = try await send("POST", Self.path(sessionId), body: body)
    }

    public func estimate(sessionId: String, estimateId: String) async throws -> RoomEstimate {
        guard PersonalRequest.isIdentifier(sessionId), PersonalRequest.isIdentifier(estimateId) else {
            throw RoomEstimateError.rejected
        }
        guard let estimate = try await send("GET", Self.path(sessionId) + [estimateId]).flatMap(RoomEstimate.init(json:))
        else { throw RoomEstimateError.invalidData }
        return estimate
    }

    public func pick(sessionId: String, estimateId: String, optionId: String) async throws -> RoomEstimatePick {
        guard PersonalRequest.isIdentifier(sessionId), PersonalRequest.isIdentifier(estimateId),
              (1...64).contains(optionId.utf8.count) else { throw RoomEstimateError.rejected }
        do {
            _ = try await send("POST", Self.path(sessionId) + [estimateId, "pick"], body: ["optionId": optionId])
            return .started
        } catch AlreadyPicked.answer(let json) {
            let holder = RoomEstimateWire.pickHolder(json)
            return .alreadyPicked(optionId: RoomEstimateWire.text(holder?["pickedOptionId"], limit: 64),
                                  by: RoomEstimateWire.text(holder?["pickedBy"], limit: 120))
        }
    }

    public func savePlan(_ answer: RoomEstimatePlanAnswer) async throws {
        _ = try await send("PATCH", ["api", "v1", "auth", "me"], body: [answer.field: answer.plan])
    }

    private static func path(_ sessionId: String) -> [String] {
        ["api", "v1", "sessions", sessionId, "estimates"]
    }

    /// A 409 that is a first pick, carried out of `send` to `pick`.
    private enum AlreadyPicked: Error {
        case answer(JSONValue?)
    }

    private func send(_ method: String, _ path: [String], body: [String: Any]? = nil) async throws -> JSONValue? {
        let answer: PersonalRequest.Answer
        do {
            answer = try await request.send(method, path, body: body)
        } catch PersonalRequest.Failure.notLoggedIn {
            throw RoomEstimateError.reauthenticationRequired
        } catch PersonalRequest.Failure.invalidRequest {
            throw RoomEstimateError.rejected
        } catch PersonalRequest.Failure.notConfigured {
            throw RoomEstimateError.unavailable
        } catch {
            throw RoomEstimateError.retryable
        }
        switch answer.status {
        case 200..<300: return answer.json
        case 401: throw RoomEstimateError.reauthenticationRequired
        case 403: throw RoomEstimateError.notAllowed
        case 404, 410: throw RoomEstimateError.unavailable
        case 409 where RoomEstimateWire.errorCode(answer.json) == "ESTIMATE_ALREADY_PICKED":
            throw AlreadyPicked.answer(answer.json)
        case 429: throw RoomEstimateError.rateLimited(retryAfterSeconds: answer.retryAfter)
        case 408, 425, 500..<600: throw RoomEstimateError.retryable
        default: throw RoomEstimateError.rejected
        }
    }
}

extension RoomFeatures {
    /// The room offers estimates (`features.estimates: true`); absent, or anything but true, is off.
    static func offersEstimates(_ room: JSONValue) -> Bool {
        room["features"]?["estimates"]?.boolValue == true
    }
}

/// How the estimate contract's values are read: lengths are capped, and a number that cannot be one is no number.
enum RoomEstimateWire {
    static let goalLimit = 2_000

    static func identifier(_ value: JSONValue?) -> String? {
        guard let id = value?.stringValue, PersonalRequest.isIdentifier(id) else { return nil }
        return id
    }

    static func text(_ value: JSONValue?, limit: Int) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return String(text.prefix(limit))
    }

    static func texts(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).prefix(20).compactMap { text($0, limit: 300) }
    }

    /// Dollars: finite and not negative.
    static func amount(_ value: JSONValue?) -> Double? {
        guard let amount = value?.doubleValue, amount.isFinite, amount >= 0, amount < 1_000_000 else { return nil }
        return amount
    }

    /// A share of a weekly limit, in percent.
    static func percent(_ value: JSONValue?) -> Double? {
        guard let percent = value?.doubleValue, percent.isFinite, (0...1_000).contains(percent) else { return nil }
        return percent
    }

    /// Tokens, minutes or rounds: whole and not negative.
    static func count(_ value: JSONValue?) -> Int64? {
        guard let count = value?.intValue, count >= 0 else { return nil }
        return count
    }

    static func planKind(_ value: JSONValue?) -> RoomEstimatePlanKind? {
        switch value?.stringValue ?? "" {
        case "claude_subscription", "claude": return .claude
        case "chatgpt": return .chatgpt
        default: return nil
        }
    }

    static func errorCode(_ json: JSONValue?) -> String? {
        json?["error"]?["code"]?.stringValue ?? json?["code"]?.stringValue ?? json?["detail"]?["code"]?.stringValue
    }

    /// Where a 409 names the first pick: beside the error, inside it, or as the estimate itself.
    static func pickHolder(_ json: JSONValue?) -> JSONValue? {
        let holders = [json?["estimate"], json?["error"]?["details"], json?["detail"], json?["error"], json]
        return holders.compactMap { $0 }.first { $0["pickedOptionId"]?.stringValue != nil }
    }
}
