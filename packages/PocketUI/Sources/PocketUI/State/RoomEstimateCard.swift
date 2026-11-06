import Foundation

/// An estimate's card in the room: priced options before any work starts, each with what it would cost, how long it
/// would take and how its judge is paid for, and one suggested. It shows only what the server measured: an option with
/// nothing measured says "No basis yet", never $0, and tickets left out of a cost are counted, never hidden. The app
/// fills it from the room's event and then from the whole estimate; every word on the card is made here.
public struct RoomEstimateCard: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Only the room's summary so far: the rest of the card is on its way.
        case loading
        case ready
        case picked(optionLabel: String, by: String, byYou: Bool)
        case expired
        case failed(reason: String)
    }

    /// How an option's judge is paid for.
    public enum Billing: Equatable, Sendable {
        /// From the person's own plan: Claude's, or ChatGPT's for Codex.
        case plan(PlanKind)
        /// Per token, and in the cost.
        case perToken
        case none
    }

    public enum PlanKind: String, Equatable, Sendable {
        case claude, chatgpt

        public var title: String { self == .claude ? "Claude" : "ChatGPT" }
    }

    /// Asked once, of whoever asked for the estimate, while a plan-billed judge can only show tokens.
    public struct PlanQuestion: Equatable, Sendable {
        public let kind: PlanKind
        /// The plans to choose from, as the API takes them and as the card says them.
        public let choices: [Choice]

        public struct Choice: Equatable, Sendable, Identifiable {
            public let value: String
            public let title: String
            public var id: String { value }

            public init(value: String, title: String) {
                self.value = value
                self.title = title
            }
        }

        public init(kind: PlanKind, choices: [Choice]) {
            self.kind = kind
            self.choices = choices
        }

        public var question: String { "Which \(kind.title) plan are you on?" }
    }

    public struct Option: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        /// Nil when nothing it needs is measured.
        public let lowUsd: Double?
        public let highUsd: Double?
        /// Tickets left out of the cost, with no measured basis.
        public let unpricedTickets: Int
        public let billing: Billing?
        public let judgeTokensLow: Int64?
        public let judgeTokensHigh: Int64?
        /// The share of the person's weekly limit, sent only when the server knows their plan.
        public let weeklyLimitPercentLow: Double?
        public let weeklyLimitPercentHigh: Double?
        public let lowMinutes: Int64?
        public let highMinutes: Int64?
        public let expectedRounds: Int64?
        public let maxRounds: Int64?
        public let caveats: [String]
        public let isSuggested: Bool

        public init(id: String, label: String, lowUsd: Double? = nil, highUsd: Double? = nil, unpricedTickets: Int = 0,
                    billing: Billing? = nil, judgeTokensLow: Int64? = nil, judgeTokensHigh: Int64? = nil,
                    weeklyLimitPercentLow: Double? = nil, weeklyLimitPercentHigh: Double? = nil,
                    lowMinutes: Int64? = nil, highMinutes: Int64? = nil, expectedRounds: Int64? = nil,
                    maxRounds: Int64? = nil, caveats: [String] = [], isSuggested: Bool = false) {
            self.id = id
            self.label = label
            self.lowUsd = lowUsd
            self.highUsd = highUsd
            self.unpricedTickets = max(0, unpricedTickets)
            self.billing = billing
            self.judgeTokensLow = judgeTokensLow
            self.judgeTokensHigh = judgeTokensHigh
            self.weeklyLimitPercentLow = weeklyLimitPercentLow
            self.weeklyLimitPercentHigh = weeklyLimitPercentHigh
            self.lowMinutes = lowMinutes
            self.highMinutes = highMinutes
            self.expectedRounds = expectedRounds
            self.maxRounds = maxRounds
            self.caveats = caveats
            self.isSuggested = isSuggested
        }

        /// "$6–$14", "$6–$14 · +2 not priced", or "No basis yet" when nothing is measured: never $0 for a cost
        /// nobody measured.
        public var costText: String {
            guard let range = RoomEstimateWords.dollars(lowUsd, highUsd) else { return "No basis yet" }
            return unpricedTickets > 0 ? "\(range) · +\(unpricedTickets) not priced" : range
        }

        /// "40 min–2 h"; nil without a measured time.
        public var timeText: String? {
            RoomEstimateWords.minutes(lowMinutes, highMinutes)
        }

        /// "About 2 review rounds, up to 3".
        public var roundsText: String? {
            guard let expected = expectedRounds, expected > 0 else { return nil }
            let rounds = expected == 1 ? "About 1 review round" : "About \(expected) review rounds"
            guard let most = maxRounds, most > expected else { return rounds }
            return "\(rounds), up to \(most)"
        }

        /// How its judge is paid for. A plan-billed judge shows the share of the weekly limit only when the server sent
        /// it for a plan it knows; otherwise the tokens it would use.
        public var billingText: String? {
            switch billing {
            case .plan(let kind):
                let plan = "Judge uses your \(kind.title) plan"
                if let percent = RoomEstimateWords.percents(weeklyLimitPercentLow, weeklyLimitPercentHigh) {
                    return "\(plan): about \(percent) of your weekly limit"
                }
                if let tokens = RoomEstimateWords.tokens(judgeTokensLow, judgeTokensHigh) {
                    return "\(plan): \(tokens) tokens"
                }
                return plan
            case .perToken:
                return "Judge paid per token, in the cost"
            case .some(Billing.none), nil:
                return nil
            }
        }

        /// What VoiceOver reads for the option, as one element: its label, cost, time, then "suggested".
        public var accessibilityLabel: String {
            var parts = [label, RoomEstimateWords.spoken(costText)]
            if let timeText { parts.append(RoomEstimateWords.spoken(timeText)) }
            if isSuggested { parts.append("suggested") }
            return parts.joined(separator: ", ")
        }
    }

    public let estimateId: String
    public let options: [Option]
    public let status: Status
    /// "Based on pilot 3 tickets and benchmark 20 tickets, measured 2026-11-06".
    public let basisLine: String?
    /// Whoever asked, or the room's owners and admins, may pick (the server checks it too).
    public let canPick: Bool
    /// Whoever asked, or the room's owners and admins, may ask again once it expired or failed.
    public let canAskAgain: Bool
    /// A pick or an ask on its way.
    public let isBusy: Bool
    /// What just happened to it ("Someone picked first").
    public let notice: String?
    public let planQuestion: PlanQuestion?
    /// The option picked, once one is.
    public let pickedOptionId: String?
    /// The message it was asked on: the card shows in that message's thread, and the message carries a chip. Nil shows
    /// the card in the room itself.
    public let sourceSequenceId: Int64?
    /// Where its latest event sits in the room, for order.
    public let order: Int64

    public init(estimateId: String, options: [Option], status: Status, basisLine: String? = nil, canPick: Bool = false,
                canAskAgain: Bool = false, isBusy: Bool = false, notice: String? = nil,
                planQuestion: PlanQuestion? = nil, pickedOptionId: String? = nil, sourceSequenceId: Int64? = nil,
                order: Int64 = 0) {
        self.estimateId = estimateId
        self.options = options
        self.status = status
        self.basisLine = basisLine
        self.canPick = canPick && status == .ready
        self.canAskAgain = canAskAgain
        self.isBusy = isBusy
        self.notice = notice
        self.planQuestion = planQuestion
        self.pickedOptionId = pickedOptionId
        self.sourceSequenceId = sourceSequenceId
        self.order = order
    }

    /// The chip on the message it was asked on, which opens the thread the card is in.
    public var chipText: String {
        switch status {
        case .loading, .ready: return "Estimate ready"
        case .picked: return "Estimate picked"
        case .expired: return "Estimate expired"
        case .failed: return "Estimate failed"
        }
    }

    /// Always on the card: it is a range from measured runs, not a price.
    public static let notAQuote = "Estimate, not a quote"

    /// The line under the options, for where it stands.
    public var statusText: String? {
        switch status {
        case .loading: return "Getting the whole estimate…"
        case .ready: return canPick ? nil : "Waiting for whoever asked to pick one."
        case .picked(let label, let by, let byYou): return byYou ? "You picked \(label)." : "\(by) picked \(label)."
        case .expired: return "This estimate expired."
        case .failed(let reason): return reason.isEmpty ? "This estimate could not be made." : reason
        }
    }

    /// "Based on pilot 3 tickets and benchmark 20 tickets, measured 2026-11-06"; nil when the server named no basis.
    public static func basisLine(sources: [String], measuredAt: String?) -> String? {
        guard !sources.isEmpty else { return measuredAt.map { "Measured \($0)" } }
        let list = sources.count == 1 ? sources[0]
            : sources.dropLast().joined(separator: ", ") + " and " + (sources.last ?? "")
        return "Based on \(list)" + (measuredAt.map { ", measured \($0)" } ?? "")
    }

    /// Whether this viewer may pick: whoever asked (`askedBy`, a public handle), or the room's owners and admins.
    /// Anyone else sees the card, never the buttons.
    public static func mayPick(askedBy: String?, ownHandles: Set<String>, role: String?) -> Bool {
        if ["owner", "admin"].contains(role?.lowercased() ?? "") { return true }
        guard let asker = askedBy?.lowercased(), !asker.isEmpty else { return false }
        let own = Set(ownHandles.flatMap { handle -> [String] in
            let lowered = handle.lowercased()
            return lowered.hasPrefix("human-") ? [lowered, String(lowered.dropFirst("human-".count))] : [lowered]
        })
        return own.contains(asker) || own.contains("human-" + asker)
    }
}

extension RoomChatPresentationState {
    /// The estimate cards asked on a message, oldest first: its thread shows them.
    public func estimates(askedOn sequenceId: Int64) -> [RoomEstimateCard] {
        estimates.values.filter { $0.sourceSequenceId == sequenceId }.sorted { $0.order < $1.order }
    }

    /// The chip on a message whose estimate is in its thread ("Estimate ready"); nil when none was asked on it.
    public func estimateChip(on sequenceId: Int64) -> String? {
        estimates(askedOn: sequenceId).last?.chipText
    }
}

/// The numbers on an estimate card, in words.
enum RoomEstimateWords {
    /// "$6", "$6.50", "$6–$14"; nil unless both ends are there.
    static func dollars(_ low: Double?, _ high: Double?) -> String? {
        guard let low, let high else { return nil }
        let lower = min(low, high), upper = max(low, high)
        let from = money(lower), to = money(upper)
        return from == to ? from : "\(from)–\(to)"
    }

    static func money(_ amount: Double) -> String {
        let cents = (amount * 100).rounded()
        if cents.truncatingRemainder(dividingBy: 100) == 0 { return "$\(Int(cents / 100))" }
        return String(format: "$%.2f", cents / 100)
    }

    /// "40 min", "1.5 h", "40 min–2 h"; nil unless both ends are there.
    static func minutes(_ low: Int64?, _ high: Int64?) -> String? {
        guard let low, let high else { return nil }
        let from = duration(min(low, high)), to = duration(max(low, high))
        return from == to ? from : "\(from)–\(to)"
    }

    static func duration(_ minutes: Int64) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        let rounded = (hours * 2).rounded() / 2
        return rounded == rounded.rounded() ? "\(Int(rounded)) h" : String(format: "%.1f h", rounded)
    }

    /// "3–8%", "under 1%"; nil unless both ends are there.
    static func percents(_ low: Double?, _ high: Double?) -> String? {
        guard let low, let high else { return nil }
        func whole(_ value: Double) -> String { value < 1 ? "under 1" : "\(Int(value.rounded()))" }
        let from = whole(min(low, high)), to = whole(max(low, high))
        return from == to ? "\(from)%" : "\(from)–\(to)%"
    }

    /// "120k–300k", "1.2M"; nil unless both ends are there.
    static func tokens(_ low: Int64?, _ high: Int64?) -> String? {
        guard let low, let high else { return nil }
        let from = count(min(low, high)), to = count(max(low, high))
        return from == to ? from : "\(from)–\(to)"
    }

    static func count(_ value: Int64) -> String {
        switch value {
        case 1_000_000...:
            let millions = (Double(value) / 100_000).rounded() / 10
            return millions == millions.rounded() ? "\(Int(millions))M" : String(format: "%.1fM", millions)
        case 1_000...: return "\(Int((Double(value) / 1_000).rounded()))k"
        default: return "\(value)"
        }
    }

    /// The card's words as VoiceOver should say them: a range is "to", "min" is "minutes", "h" is "hours".
    static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: "–", with: " to ")
            .replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: " min", with: " minutes")
            .replacingOccurrences(of: " h", with: " hours")
    }
}
