import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

// Direct messages in a room (Carter's ask: message someone privately from their avatar). Tapping an avatar opens
// a profile card with Message; a direct message is the room screen with a header for whom it is with; and the side
// panel nests each one under the room it was opened from.

/// Someone whose profile card can open: who, the name to show, and whether they are an agent.
public struct RoomProfileTarget: Identifiable, Equatable, Hashable, Sendable {
    /// The id their messages carry: `human-<login>` for a person, the agent's own id for an agent.
    public let senderId: String
    public let name: String
    public let isAgent: Bool

    public var id: String { senderId.lowercased() }

    public init(senderId: String, name: String, isAgent: Bool) {
        self.senderId = senderId
        self.name = name.replacingOccurrences(of: "human-", with: "", options: .anchored)
        self.isAgent = isAgent
    }
}

public enum RoomProfile {
    /// Whether tapping `senderId`'s avatar opens a profile card: never on yourself, never on the room's own voices
    /// (`senti`, the orchestrator and the ticket keeper, which the server refuses as it refuses you), and never on
    /// someone without an id.
    public static func opens(senderId: String, ownAuthorIds: Set<String>) -> Bool {
        let id = senderId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty, !RoomChatQuiet.isRoomVoice(id), id != "human-" else { return false }
        return !ownAuthorIds.contains { $0.lowercased() == id }
    }
}

/// What tapping an avatar does in a room where profiles open (direct messages on). Put in the environment by the room
/// screen; absent, avatars are not buttons and the online ring opens the people list as before.
public struct RoomProfileOpener: Equatable {
    public let ownAuthorIds: Set<String>
    private let open: (RoomProfileTarget) -> Void

    /// Two openers for the same you are the same: the room screen makes a new one each time it draws, and every avatar
    /// reads it, so an opener that never compared equal would draw every avatar again with every message. Its action
    /// only sets the screen's own state, which every copy of the screen shares.
    public static func == (lhs: RoomProfileOpener, rhs: RoomProfileOpener) -> Bool {
        lhs.ownAuthorIds == rhs.ownAuthorIds
    }

    public init(ownAuthorIds: Set<String>, open: @escaping (RoomProfileTarget) -> Void) {
        self.ownAuthorIds = ownAuthorIds
        self.open = open
    }

    /// The card for `target`, unless it is yourself or the room's voice. Returns whether it opened.
    @discardableResult
    public func callAsFunction(_ target: RoomProfileTarget) -> Bool {
        guard RoomProfile.opens(senderId: target.senderId, ownAuthorIds: ownAuthorIds) else { return false }
        open(target)
        return true
    }

    public func opens(_ senderId: String) -> Bool {
        RoomProfile.opens(senderId: senderId, ownAuthorIds: ownAuthorIds)
    }

    /// A room's opener: only where direct messages are on, and only once the room knows who you are (your mention
    /// handles, `alex` for `human-alex`), so your own avatar is never a button. Otherwise nil: avatars stay pictures.
    public static func forRoom(directMessagesOn: Bool, ownMentionHandles: Set<String>,
                               open: @escaping (RoomProfileTarget) -> Void) -> RoomProfileOpener? {
        guard directMessagesOn else { return nil }
        let own = Set(ownMentionHandles.filter { $0 != "all" }.map { "human-\($0)" })
        guard !own.isEmpty else { return nil }
        return RoomProfileOpener(ownAuthorIds: own, open: open)
    }
}

#if canImport(SwiftUI)
private struct RoomProfileOpenerKey: EnvironmentKey {
    static let defaultValue: RoomProfileOpener? = nil
}

public extension EnvironmentValues {
    /// Opens a profile card from an avatar; nil where profiles do not open.
    var roomProfileOpener: RoomProfileOpener? {
        get { self[RoomProfileOpenerKey.self] }
        set { self[RoomProfileOpenerKey.self] = newValue }
    }
}
#endif

/// A profile card: who, the rooms you share, and what you can do.
public struct RoomProfileCardState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The direct message is being opened.
        case opening
        /// Something to say under the buttons (a refusal, a failure).
        case notice(String)
    }

    public let target: RoomProfileTarget
    /// Titles of the rooms you share, as far as the phone knows: the server's list once a direct message exists, else
    /// the room you are in.
    public let sharedRooms: [String]
    public let canMessage: Bool
    public let canBlock: Bool
    public let phase: Phase

    public init(target: RoomProfileTarget, sharedRooms: [String], canMessage: Bool, canBlock: Bool = false,
                phase: Phase = .idle) {
        self.target = target
        self.sharedRooms = sharedRooms
        self.canMessage = canMessage
        self.canBlock = canBlock
        self.phase = phase
    }

    /// What every refusal reads as: the server answers blocked, off and unknown alike, and so does the card.
    public static func refusal(name: String) -> String {
        "You can't message \(name) right now."
    }
}

/// How the top of a direct message is laid out: `compact` is one line, "From <room> ›" and a "Memory: Off" pill that
/// opens the switch; `expanded` shows whom it is with, the "Shared room" chip and the switch with its note.
public enum DirectRoomHeaderStyle: String, Equatable, Sendable {
    case compact
    case expanded
}

/// The top of a direct message: whom it is with, the room you share, and for an agent, whether it may use this chat
/// there. Every word it shows comes from here (`texts`).
public struct DirectRoomHeaderState: Equatable, Sendable {
    public struct MemorySwitch: Equatable, Sendable {
        public let roomId: String
        public let roomTitle: String
        /// The server's value. Off until you turn it on; the app never sets it by itself.
        public let isOn: Bool
        public let isSaving: Bool
    }

    public let name: String
    public let isAgent: Bool
    /// The room you share, opened by its chip: the one the direct message started from, else one you share now.
    public let sharedRoomId: String?
    public let sharedRoomTitle: String?
    /// Only for an agent, and only once the server has said what it is.
    public let memory: MemorySwitch?
    public let notice: String?

    public init(name: String, isAgent: Bool, sharedRoomId: String?, sharedRoomTitle: String?, memory: MemorySwitch?,
                notice: String? = nil) {
        self.name = name
        self.isAgent = isAgent
        self.sharedRoomId = sharedRoomId
        self.sharedRoomTitle = sharedRoomTitle
        self.memory = memory
        self.notice = notice
    }

    /// Under the name in the expanded header.
    public var subtitle: String { isAgent ? "Direct message · agent" : "Direct message" }

    /// The expanded header's chip back to the room.
    public var sharedRoomChip: String? { sharedRoomTitle.map { "Shared room: \($0)" } }

    /// The compact header's chip back to the room (drawn with a chevron after it).
    public var fromChip: String? { sharedRoomTitle.map { "From \($0)" } }

    /// The compact header's pill: the server's value of the switch, which a tap opens.
    public var memoryPill: String? { memory.map { "Memory: \($0.isOn ? "On" : "Off")" } }

    /// The switch's label asks, so it never reads as already on: "Let <agent> use this chat in <room>".
    public var memoryLabel: String? { memory.map { "Let \(name) use this chat in \($0.roomTitle)" } }

    /// The one short line under the switch, saying what the value now means.
    public var memoryNote: String? {
        memory.map { memory in
            memory.isOn
                ? "On: \(name) can use this chat when it works in \(memory.roomTitle)."
                : "Off: \(name) can't see this chat anywhere else."
        }
    }

    /// Every word the header can show, in either layout. It says whom the chat is with, where it came from and what the
    /// switch does: never what the other side is doing (no contract field backs "notified" or "typing").
    public var texts: [String] {
        [name, subtitle, sharedRoomChip, fromChip, memoryPill, memoryLabel, memoryNote, notice].compactMap { $0 }
    }

    /// - Parameters:
    ///   - origin: the room the direct message started from, as the room list or the server names it.
    ///   - mutual: the rooms you share now, from the server.
    ///   - memoryShare: the server's switches by room id; nil before the server has answered (no switch is shown).
    public static func make(
        name: String,
        isAgent: Bool,
        origin: (id: String, title: String)?,
        mutual: [(id: String, title: String)],
        memoryShare: [String: Bool]?,
        isSaving: Bool,
        notice: String? = nil
    ) -> DirectRoomHeaderState {
        let shared = origin ?? mutual.first
        var memory: MemorySwitch?
        if isAgent, let shared, let memoryShare {
            memory = MemorySwitch(roomId: shared.id, roomTitle: shared.title, isOn: memoryShare[shared.id] ?? false,
                                  isSaving: isSaving)
        }
        return DirectRoomHeaderState(name: name, isAgent: isAgent, sharedRoomId: shared?.id,
                                     sharedRoomTitle: shared?.title, memory: memory, notice: notice)
    }
}
