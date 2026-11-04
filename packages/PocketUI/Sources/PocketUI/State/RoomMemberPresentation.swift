import Foundation

// Someone's profile in a room (Carter, 11-04: "tap anyone → all their messages, paged, jump to any of them, plus how
// they're connected"): the card from their avatar on top, how their posts come in when the API knows, a box's live
// steps, and their messages newest first.

/// How someone's posts reach the room, when the API knows: MCP, a box, the app, the web or the command line.
public enum RoomMemberConnection: String, Equatable, Sendable {
    case mcp
    case box
    case app
    case web
    case cli

    public var label: String {
        switch self {
        case .mcp: return "Connected through MCP"
        case .box: return "Runs in a box"
        case .app: return "Posts from the Pocket app"
        case .web: return "Posts from the web"
        case .cli: return "Posts from the command line"
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
    /// A person as a public room shows them to a reader outside it: their messages are private, and none are asked for.
    public let isPrivate: Bool
    public let connection: RoomMemberConnection?

    public init(rows: [RoomMemberMessageRow] = [], phase: Phase = .idle, canLoadMore: Bool = false, isPrivate: Bool = false,
                connection: RoomMemberConnection? = nil) {
        self.rows = rows
        self.phase = phase
        self.canLoadMore = canLoadMore
        self.isPrivate = isPrivate
        self.connection = connection
    }

    /// What a public room says about a person's messages, instead of an empty list.
    public static let privateLine = "Messages from people are private in public rooms"

    /// How their posts come in, only when the API said: nothing is shown for an unknown connection, never a guess.
    public var connectionLine: String? { connection?.label }

    /// What shows where the messages would be, when there are none to show; nil while there are rows or a read is
    /// on its way.
    public func emptyLine(name: String) -> String? {
        if isPrivate { return Self.privateLine }
        guard rows.isEmpty, phase == .idle, !canLoadMore else { return nil }
        return "No messages from \(name) in this room yet."
    }
}
