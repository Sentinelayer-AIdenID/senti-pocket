import Foundation

// Someone's profile in a room (Carter, 11-04: "tap anyone → all their messages, paged, jump to any of them, plus how
// they're connected"): the card from their avatar on top, how their posts come in when the API knows, a box's live
// steps, and their messages newest first.

/// How someone's posts reach the room, when it is known: hosted MCP (an AI app connected to the Senti MCP server), the
/// CLI's own MCP server, the CLI, a box, the app or the web.
public enum RoomMemberConnection: String, Equatable, Sendable {
    case hostedMCP
    case cliMCP
    case cli
    case box
    case app
    case web

    public var label: String {
        switch self {
        case .hostedMCP: return "Connected through MCP"
        case .cliMCP: return "Connected through the CLI (MCP)"
        case .cli: return "Connected through the CLI"
        case .box: return "Runs in a box"
        case .app: return "Posts from the Pocket app"
        case .web: return "Posts from the web"
        }
    }
}

/// One of their messages, as one short line to jump to.
public struct RoomMemberMessageRow: Equatable, Identifiable, Sendable {
    public let sequenceId: Int64
    public var id: Int64 { sequenceId }
    /// Its first words, plain (no Markdown marks).
    public let text: String
    public let date: Date?
    /// How many photos and files it carries.
    public let attachments: Int

    public init(sequenceId: Int64, text: String, date: Date?, attachments: Int = 0) {
        self.sequenceId = sequenceId
        self.text = text
        self.date = date
        self.attachments = attachments
    }

    /// "2 files" under a message of files alone, so the row is never blank.
    public var shownText: String {
        if !text.isEmpty { return text }
        return attachments == 1 ? "1 file" : "\(attachments) files"
    }
}

/// Their messages in the room: newest first, a page at a time.
public struct RoomMemberMessagesState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// A page is being read.
        case loading
        case idle
        /// The last read failed; Retry reads it again.
        case failed(String)
    }

    public let rows: [RoomMemberMessageRow]
    public let phase: Phase
    /// An older page is there to read (the API gave where it starts). False once a page reached the room's start.
    public let canLoadMore: Bool
    /// A stand-in name a public room shows a visitor for a person (`RoomAuthor.isPublicAlias`): none of their messages
    /// can be asked for, and none are.
    public let isPrivate: Bool
    public let connection: RoomMemberConnection?
    /// Pages came back with none of their messages, as many as are read on by themselves: the next one waits for
    /// "Load older".
    public let olderNeedsTap: Bool
    /// You blocked them: their messages are not listed here.
    public let isBlocked: Bool

    public init(rows: [RoomMemberMessageRow] = [], phase: Phase = .idle, canLoadMore: Bool = false, isPrivate: Bool = false,
                connection: RoomMemberConnection? = nil, olderNeedsTap: Bool = false, isBlocked: Bool = false) {
        self.rows = rows
        self.phase = phase
        self.canLoadMore = canLoadMore
        self.isPrivate = isPrivate
        self.connection = connection
        self.olderNeedsTap = olderNeedsTap
        self.isBlocked = isBlocked
    }

    /// What the list says for a person shown under a stand-in name: what the API does, plainly.
    public static let privateLine = "You're reading this public room as a visitor, so this person shows under a "
        + "stand-in name, and their messages can't be listed."

    /// What the list says for someone you blocked, instead of their messages.
    public static let blockedLine = "You blocked them."

    /// How their posts come in, only when the API said: nothing is shown for an unknown connection, never a guess.
    public var connectionLine: String? { connection?.label }

    /// The messages the list shows: none for someone you blocked.
    public var listedRows: [RoomMemberMessageRow] { isBlocked ? [] : rows }

    /// "Load older" shows under the list once pages stopped bringing their messages and older ones may still be there.
    public var showsLoadOlder: Bool {
        olderNeedsTap && canLoadMore && phase == .idle && !isPrivate && !isBlocked
    }

    /// What shows where the messages would be, when there are none to show; nil while there are rows or a read is
    /// on its way.
    public func emptyLine(name: String) -> String? {
        if isBlocked { return Self.blockedLine }
        if isPrivate { return Self.privateLine }
        guard rows.isEmpty, phase == .idle else { return nil }
        if showsLoadOlder { return "No messages from \(name) found so far." }
        guard !canLoadMore else { return nil }
        return "No messages from \(name) in this room yet."
    }

    /// The message a block from their profile names: the newest of theirs in the list. None until one has loaded, so a
    /// block from here always comes with a message, never by their id alone.
    public var blockReference: Int64? {
        guard !isBlocked, !isPrivate else { return nil }
        return rows.map(\.sequenceId).max()
    }

    /// Block as the card offers it: `block` with the message it names, or nothing while no message can be named.
    public func blockAction(_ block: ((Int64) -> Void)?) -> (() -> Void)? {
        guard let block, let sequence = blockReference else { return nil }
        return { block(sequence) }
    }
}

/// Block from someone's profile, by the Message rules: the card that offers Message is the only one that may offer
/// Block.
public enum RoomMemberBlock {
    /// Never on your own profile (the API answers 422 to blocking yourself), never on the room's own voices (the
    /// orchestrator, the ticket keeper and `senti`, whose ids are reserved), never before the room knows who you are,
    /// and never for someone already blocked.
    public static func offers(senderId: String, ownAuthorIds: Set<String>, alreadyBlocked: Bool) -> Bool {
        guard !alreadyBlocked, !ownAuthorIds.isEmpty else { return false }
        return RoomProfile.opens(senderId: senderId, ownAuthorIds: ownAuthorIds)
    }
}
