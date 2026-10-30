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
        if let model, let lab = match(model.lowercased()) { return lab }
        let name = id.lowercased()
        if name.hasPrefix("ds-") { return .deepseek }
        if name.hasPrefix("astra-") { return .openai }
        return match(name) ?? .other
    }

    private static func match(_ text: String) -> AgentLab? {
        let rules: [(AgentLab, [String])] = [
            (.anthropic, ["claude", "opus", "sonnet", "haiku", "fable"]),
            (.openai, ["gpt", "codex", "chatgpt", "openai", "astra"]),
            (.deepseek, ["deepseek"]),
            (.google, ["gemini"]),
            (.moonshot, ["kimi", "moonshot"]),
            (.xai, ["grok"]),
            (.zhipu, ["glm"])
        ]
        for (lab, words) in rules where words.contains(where: text.contains) { return lab }
        return nil
    }

    /// Who is here, grouped by lab: how many agents, and whether any of them is active (not idle) now.
    public struct Group: Equatable, Identifiable, Sendable {
        public var id: AgentLab { lab }
        public let lab: AgentLab
        public let count: Int
        public let isWorking: Bool
    }

    /// One agent here, with its lab and whether it is working now.
    public struct Present: Equatable, Identifiable, Sendable {
        public let id: String
        public let lab: AgentLab
        public let isWorking: Bool
    }

    /// Each agent here once, working ones first, then by name (Carter, #55506: "just having all the logos in the
    /// room ... have a max number on the screen and if that exceeds it we just put a group number").
    public static func present(_ people: [RoomChatPresence.Person], models: [String: String]) -> [Present] {
        var seen = Set<String>()
        return people.filter { !$0.isHuman && seen.insert($0.id.lowercased()).inserted }
            .map { Present(id: $0.id, lab: of(id: $0.id, model: models[$0.id.lowercased()]), isWorking: !$0.isIdle) }
            .sorted { ($0.isWorking ? 0 : 1, $0.id.lowercased()) < ($1.isWorking ? 0 : 1, $1.id.lowercased()) }
    }

    public static func groups(present: [RoomChatPresence.Person], models: [String: String]) -> [Group] {
        var counts: [AgentLab: (count: Int, working: Bool)] = [:]
        var seen = Set<String>()
        for person in present where !person.isHuman && seen.insert(person.id.lowercased()).inserted {
            let lab = of(id: person.id, model: models[person.id.lowercased()])
            let current = counts[lab] ?? (0, false)
            counts[lab] = (current.count + 1, current.working || !person.isIdle)
        }
        return counts.map { Group(lab: $0.key, count: $0.value.count, isWorking: $0.value.working) }
            .sorted { $0.lab < $1.lab }
    }
}
