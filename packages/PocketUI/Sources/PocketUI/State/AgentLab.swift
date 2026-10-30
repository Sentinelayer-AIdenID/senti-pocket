import Foundation

/// The lab an agent's model comes from, for the room's who-is-here row (Carter, #55428, then #55506: "get the
/// transparent logo of each of the different boxes from different labs and assign them"). Read from the model when the
/// room knows it (a box's model), else from the agent's name. Shown as the lab's logo where the app carries one, else
/// its initial.
public enum AgentLab: String, CaseIterable, Comparable, Sendable {
    case anthropic
    case openai
    case deepseek
    case google
    case moonshot
    case xai
    case zhipu
    case other

    public static func < (lhs: AgentLab, rhs: AgentLab) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// What a reader calls it.
    public var name: String {
        switch self {
        case .anthropic: return "Claude"
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .google: return "Gemini"
        case .moonshot: return "Kimi"
        case .xai: return "Grok"
        case .zhipu: return "GLM"
        case .other: return "Other agents"
        }
    }

    /// The app's image for the lab's mark (a template, tinted with `tint`); nil where the app carries none.
    public var logoAsset: String? {
        switch self {
        case .anthropic: return "LabClaude"
        case .openai: return "LabOpenAI"
        case .deepseek: return "LabDeepSeek"
        case .google: return "LabGemini"
        case .moonshot: return "LabKimi"
        case .xai, .zhipu, .other: return nil
        }
    }

    /// The letter shown for it; nil for agents whose lab is not known (they show a chip).
    public var initial: String? {
        switch self {
        case .anthropic: return "C"
        case .openai: return "O"
        case .deepseek: return "D"
        case .google: return "G"
        case .moonshot: return "K"
        case .xai: return "X"
        case .zhipu: return "Z"
        case .other: return nil
        }
    }

    /// The lab's colour as (red, green, blue), 0...1.
    public var tint: (Double, Double, Double) {
        switch self {
        case .anthropic: return (0.85, 0.47, 0.34)
        case .openai: return (0.06, 0.64, 0.50)
        case .deepseek: return (0.30, 0.42, 1.0)
        case .google: return (0.26, 0.52, 0.96)
        case .moonshot: return (0.62, 0.62, 0.70)
        case .xai: return (0.75, 0.75, 0.78)
        case .zhipu: return (0.55, 0.40, 0.95)
        case .other: return (0.62, 0.66, 0.72)
        }
    }

    /// The lab for an agent: its model first, then its id (claude-warden, codex-helper, ds-…, astra-…).
    public static func of(id: String, model: String?) -> AgentLab {
        if let model, let lab = match(model) { return lab }
        let name = id.lowercased()
        if let lab = crew[name] { return lab }
        if name.hasPrefix("ds-") { return .deepseek }
        if name.hasPrefix("astra-") || name.hasPrefix("sol-") { return .openai }
        return match(name) ?? .other
    }

    /// The crew's agents whose names say nothing of their lab (Carter, #55533: "forge is here too and is Claude"),
    /// until the room reports each agent's lab from its model (warden, ticket 2e33d88d).
    private static let crew: [String: AgentLab] = ["pocket-forge": .anthropic]

    /// Matched on whole words of the model or name, a version allowed right after ("gpt4o", "glm4"), never inside
    /// another word (warden, #254: "opus" in "octopus" is not Claude).
    private static func match(_ text: String) -> AgentLab? {
        let rules: [(AgentLab, [String])] = [
            (.anthropic, ["claude", "opus", "sonnet", "haiku", "fable"]),
            (.openai, ["gpt", "codex", "chatgpt", "openai"]),
            (.deepseek, ["deepseek"]),
            (.google, ["gemini"]),
            (.moonshot, ["kimi", "moonshot"]),
            (.xai, ["grok"]),
            (.zhipu, ["glm"])
        ]
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        for (lab, words) in rules {
            for token in tokens {
                for word in words where token.hasPrefix(word) {
                    let rest = token.dropFirst(word.count)
                    if rest.isEmpty || rest.first?.isNumber == true { return lab }
                }
            }
        }
        return nil
    }

    /// One agent here: its lab, whether it runs in a box, and its newest sign of activity (which changes each time it
    /// does something, so its logo can beat once).
    public struct Present: Equatable, Identifiable, Sendable {
        public let id: String
        public let lab: AgentLab
        public let isBox: Bool
        public let signal: String?

        public init(id: String, lab: AgentLab, isBox: Bool = false, signal: String? = nil) {
            self.id = id
            self.lab = lab
            self.isBox = isBox
            self.signal = signal
        }

        public var isWorking: Bool { signal != nil }
    }

    /// Each agent here once, working ones first, then by name (Carter, #55506: "just having all the logos in the
    /// room ... have a max number on the screen and if that exceeds it we just put a group number"): the agents
    /// present, and the room's running boxes, which post through the room and are not in presence (Carter, #55533:
    /// "Astra is codex ... two of them and since they're in a box ... one more small badge"). `signals` is
    /// `RoomChatPresentationState.agentSignals`, `boxes` the running boxes' names.
    public static func present(_ people: [RoomChatPresence.Person], models: [String: String],
                               signals: [String: String], boxes: [String] = []) -> [Present] {
        let boxIds = Set(boxes.map { $0.lowercased() })
        var seen = Set<String>()
        let ids = people.filter { !$0.isHuman }.map(\.id) + boxes
        return ids.filter { seen.insert($0.lowercased()).inserted }
            .map { id in
                let key = id.lowercased()
                return Present(id: id, lab: of(id: id, model: models[key]), isBox: boxIds.contains(key), signal: signals[key])
            }
            .sorted { ($0.isWorking ? 0 : 1, $0.id.lowercased()) < ($1.isWorking ? 0 : 1, $1.id.lowercased()) }
    }

    /// How many logos show before the rest become "+N".
    public static let maximumShown = 6

    /// The logos shown (working ones first) and how many more there are.
    public static func shown(_ agents: [Present], maximum: Int = maximumShown) -> (shown: [Present], more: Int) {
        (Array(agents.prefix(maximum)), max(0, agents.count - maximum))
    }
}

extension RoomChatPresentationState {
    /// The agents working now, lowercased id to their newest sign of it: preparing a reply, or their newest post in
    /// the last `window`. Not presence, which stays "active" while an agent's listener is connected (warden, #254);
    /// Carter, #55506: "If Claude is actively sending signals from his terminal that's him working". A new sign is a
    /// new value, which is what makes a logo beat once (Carter, #55533: "palpitation movement when it senses something
    /// and then stillness").
    public func agentSignals(now: Date, window: TimeInterval = 120) -> [String: String] {
        var signals: [String: String] = [:]
        let since = now.addingTimeInterval(-window)
        for row in rows.reversed() {
            guard case .message(let message) = row, let date = message.date else { continue }
            if date < since { break }
            let id = message.authorId.lowercased()
            if !message.isHuman, signals[id] == nil { signals[id] = message.id }
        }
        for agent in composingAgents {
            let id = agent.lowercased()
            signals[id] = "typing:" + (signals[id] ?? "")
        }
        return signals
    }
}
