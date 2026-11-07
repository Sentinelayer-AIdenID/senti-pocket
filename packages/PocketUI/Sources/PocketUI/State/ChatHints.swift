import Foundation
#if canImport(Combine)
import Combine

/// Small, account-scoped tips. Only the banner observes this object; showing or dismissing a tip never redraws
/// the chat's messages, composer, or the app root.
@MainActor
public final class ChatHints: ObservableObject {
    public enum Tip: String, CaseIterable, Codable, Sendable {
        case mention
        case messageActions
        case moveToFolder

        public var text: String {
            switch self {
            case .mention: return "Tip: type @ to ask a specific agent"
            case .messageActions: return "Tip: long-press a message to reply, copy or react"
            case .moveToFolder: return "Tip: long-press a chat to move it into a folder"
            }
        }

        var limit: Int { self == .mention ? 3 : 1 }
    }

    public enum Context: Equatable, Sendable {
        case chat(hasAgents: Bool, isEmpty: Bool, isFocused: Bool)
        case folders(hasFolders: Bool)

        fileprivate func allows(_ tip: Tip) -> Bool {
            switch (self, tip) {
            case (.chat(let hasAgents, let isEmpty, let isFocused), .mention):
                return hasAgents && isEmpty && isFocused
            case (.chat, .messageActions): return true
            case (.folders(let hasFolders), .moveToFolder): return hasFolders
            default: return false
            }
        }
    }

    public struct Presentation: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let anchor: UUID
        public let tip: Tip
    }

    @Published public private(set) var current: Presentation?

    private struct Progress: Codable {
        var shown: [String: Int] = [:]
        var dismissed: Set<String> = []
    }

    private struct Surface {
        let context: Context
        let visible: Bool
        func allows(_ tip: Tip) -> Bool { visible && context.allows(tip) }
    }

    private let defaults: UserDefaults
    private var accountId: String?
    private var progress = Progress()
    private var surfaces: [UUID: Surface] = [:]
    private var anchors: [UUID] = []
    private var pending: [UUID: Set<Tip>] = [:]

    public init(accountId: String? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        setAccount(accountId)
    }

    /// The id from the signed-in account, never a username, token, or a shared fallback. Until that read succeeds,
    /// no tip is consumed or persisted. An account change drops the old account's visible tip and opportunities.
    public func setAccount(_ accountId: String?) {
        let next = accountId.flatMap { $0.isEmpty ? nil : $0 }
        guard self.accountId != next else { return }
        self.accountId = next
        current = nil
        pending.removeAll()
        progress = next.flatMap { id in
            guard let data = defaults.data(forKey: Self.key(id)), data.count <= 4_096 else { return nil }
            return try? JSONDecoder().decode(Progress.self, from: data)
        } ?? Progress()
        for anchor in anchors {
            if let surface = surfaces[anchor] { offer(anchor, surface: surface, previous: nil) }
        }
        presentNext()
    }

    /// Called only from appearance/change handlers. A qualifying empty-and-focused interval is one opportunity,
    /// even if presence refreshes or the view redraws many times during it.
    public func update(anchor: UUID, context: Context, visible: Bool = true) {
        let previous = surfaces[anchor]
        let surface = Surface(context: context, visible: visible)
        if previous == nil { anchors.append(anchor) }
        surfaces[anchor] = surface
        pending[anchor] = Set((pending[anchor] ?? []).filter { surface.allows($0) })
        offer(anchor, surface: surface, previous: previous)
        if let current, current.anchor == anchor, !surface.allows(current.tip) { self.current = nil }
        // Mentioning is useful at the instant the empty box is focused. It replaces a first-chat tip, never a
        // second banner alongside it. The first-chat tip has already been seen and does not come back.
        if let current, current.anchor == anchor, current.tip != .mention,
           pending[anchor]?.contains(.mention) == true, canShow(.mention) {
            self.current = nil
        }
        presentNext()
    }

    public func remove(anchor: UUID) {
        surfaces.removeValue(forKey: anchor)
        pending.removeValue(forKey: anchor)
        anchors.removeAll { $0 == anchor }
        if current?.anchor == anchor { current = nil }
        presentNext()
    }

    /// A stale button from an old tip (or account) cannot dismiss the new one. Close consumes only this showing;
    /// "Don't show again" remembers this kind of tip for this account on this device.
    public func dismiss(_ presentation: Presentation, permanently: Bool) {
        guard current == presentation else { return }
        if permanently {
            progress.dismissed.insert(presentation.tip.rawValue)
            save()
        }
        current = nil
        presentNext()
    }

    private func offer(_ anchor: UUID, surface: Surface, previous: Surface?) {
        for tip in Tip.allCases where surface.allows(tip) && previous?.allows(tip) != true {
            pending[anchor, default: []].insert(tip)
        }
    }

    private func canShow(_ tip: Tip) -> Bool {
        accountId != nil && !progress.dismissed.contains(tip.rawValue)
            && max(0, progress.shown[tip.rawValue] ?? 0) < tip.limit
    }

    private func presentNext() {
        guard accountId != nil, current == nil else { return }
        // The focused-box tip comes first; within each kind, the most recently opened visible surface wins.
        for tip in Tip.allCases {
            for anchor in anchors.reversed() {
                guard let surface = surfaces[anchor], surface.allows(tip), pending[anchor]?.contains(tip) == true else { continue }
                pending[anchor]?.remove(tip)
                guard canShow(tip) else { continue }
                progress.shown[tip.rawValue] = max(0, progress.shown[tip.rawValue] ?? 0) + 1
                save()
                current = Presentation(id: UUID(), anchor: anchor, tip: tip)
                return
            }
        }
    }

    private func save() {
        guard let accountId, let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: Self.key(accountId))
    }

    private static func key(_ accountId: String) -> String {
        "pocket.chat-hints.v1." + Data(accountId.utf8).base64EncodedString()
    }
}
#endif
