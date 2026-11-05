import Foundation
import PocketContracts

/// One room row as the app hands it to PocketUI. The app maps its sync-layer rows into this so PocketUI stays
/// independent of the transport package.
public struct RoomChatMessageInput: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case message
        case checkpoint
        case memberJoined
        /// A breakout started here; its card comes from `RoomChatPresentationState.breakouts`.
        case breakoutOpened(childSessionId: String)
        /// A breakout's published outcome.
        case breakoutOutcome(RoomBreakoutOutcomeCard)
    }

    public let id: String
    public let sequenceId: Int64
    public let kind: Kind
    public let authorId: String
    public let authorName: String
    public let isHuman: Bool
    public let text: String
    public let timestamp: String
    public let replyToSequenceId: Int64?
    public let isEdited: Bool
    /// Parsed `timestamp`. Callers that render many rows pass a cached value; otherwise it is parsed here.
    public let date: Date?
    public var reactions: RoomChatReactions?
    public let attachments: [RoomAttachmentChip]
    /// Who has viewed this revision, once the room has read it.
    public let views: RoomChatViews?
    /// For a threaded reply shown in the room at its own time: the reply's own action id. Its `sequenceId` is the
    /// message it answers, so everything the row does to itself keys on this id instead.
    public let inlineReplyId: String?
    public var isInlineReply: Bool { inlineReplyId != nil }
    /// Agents' "working on" lines about this message, oldest first.
    public let work: [RoomChatWorkLine]
    /// A turn spoken in a voice room (`channel: "voice"`).
    public let isVoiceTurn: Bool
    /// A checkpoint's summary.
    public let checkpointSummary: String?

    public init(
        id: String,
        sequenceId: Int64,
        kind: Kind,
        authorId: String,
        authorName: String,
        isHuman: Bool,
        text: String,
        timestamp: String,
        replyToSequenceId: Int64? = nil,
        isEdited: Bool = false,
        date: Date? = nil,
        reactions: RoomChatReactions? = nil,
        attachments: [RoomAttachmentChip] = [],
        views: RoomChatViews? = nil,
        inlineReplyId: String? = nil,
        work: [RoomChatWorkLine] = [],
        isVoiceTurn: Bool = false,
        checkpointSummary: String? = nil
    ) {
        self.id = id
        self.sequenceId = sequenceId
        self.kind = kind
        self.authorId = authorId
        self.authorName = authorName
        self.isHuman = isHuman
        self.text = text
        self.timestamp = timestamp
        self.replyToSequenceId = replyToSequenceId
        self.isEdited = isEdited
        self.date = date ?? ParsedSessionTimestamp(timestamp).date
        self.reactions = reactions
        self.attachments = attachments
        self.views = views
        self.inlineReplyId = inlineReplyId
        self.work = work
        self.isVoiceTurn = isVoiceTurn
        self.checkpointSummary = checkpointSummary
    }
}

/// One "working on" line under a message: who, what they said, and whether it is still live.
public struct RoomChatWorkLine: Equatable, Identifiable, Sendable {
    public let id: String
    public let actorId: String
    public let text: String
    public let at: Date?
    /// Not done, and newer than the room's staleness window.
    public let isLive: Bool

    public init(id: String, actorId: String, text: String, at: Date?, isLive: Bool) {
        self.id = id
        self.actorId = actorId
        self.text = text
        self.at = at
        self.isLive = isLive
    }
}

/// What shows under a message: reaction chips, who acknowledged it, who is working on it, and its reply count.
public struct RoomChatReactions: Equatable, Sendable {
    public struct Chip: Equatable, Identifiable, Sendable {
        public var id: String { type }
        public let type: String
        public let count: Int
        /// You placed this reaction (like and dislike only; the API reports it per viewer).
        public let isMine: Bool

        public init(type: String, count: Int, isMine: Bool) {
            self.type = type
            self.count = count
            self.isMine = isMine
        }

        public var symbol: String {
            switch type {
            case "ack": return "checkmark.circle"
            case "like": return "hand.thumbsup"
            case "dislike": return "hand.thumbsdown"
            case "disregard": return "eye.slash"
            case "pin": return "pin"
            default: return "circle"
            }
        }

        public var label: String {
            switch type {
            case "ack": return "Ack"
            case "like": return "Like"
            case "dislike": return "Dislike"
            case "disregard": return "Disregard"
            default: return type.capitalized
            }
        }
    }

    /// An emoji reaction: the emoji, how many reacted with it, and whether you did.
    public struct EmojiChip: Equatable, Identifiable, Sendable {
        public var id: String { emoji }
        public let emoji: String
        public let count: Int
        public let isMine: Bool

        public init(emoji: String, count: Int, isMine: Bool) {
            self.emoji = emoji
            self.count = count
            self.isMine = isMine
        }

        /// What VoiceOver reads: "👍 3, you reacted. Double-tap to remove". What a tap does is said only when you
        /// can react.
        public func accessibilityLabel(canReact: Bool) -> String {
            let said = "\(emoji) \(count)" + (isMine ? ", you reacted" : "")
            guard canReact else { return said }
            return said + (isMine ? ". Double-tap to remove" : ". Double-tap to add yours")
        }
    }

    public let chips: [Chip]
    /// Emoji reactions after the chips, in the order they were first used.
    public var emojiChips: [EmojiChip]
    /// "Acked by a, b, c +N" (web parity: three names, sorted).
    public let ackedBy: String?
    /// "Working: a, b".
    public let working: String?
    public let replyCount: Int
    public let isPinned: Bool

    /// The most emoji reactions shown under one message (the API's limit).
    public static let emojiLimit = 20

    public init(chips: [Chip] = [], emojiChips: [EmojiChip] = [], ackedBy: String? = nil, working: String? = nil,
                replyCount: Int = 0, isPinned: Bool = false) {
        self.chips = chips
        self.emojiChips = emojiChips
        self.ackedBy = ackedBy
        self.working = working
        self.replyCount = replyCount
        self.isPinned = isPinned
    }

    public var isEmpty: Bool {
        chips.isEmpty && emojiChips.isEmpty && ackedBy == nil && working == nil && replyCount == 0 && !isPinned
    }

    /// Builds the line from raw counts and actors, in the web order and wording, then at most `emojiLimit` emoji
    /// reactions.
    public static func make(
        counts: [String: Int],
        actorsByType: [String: [String]],
        activeOwners: [String],
        likedByViewer: Bool,
        dislikedByViewer: Bool,
        replyCount: Int,
        isPinned: Bool,
        emoji: [EmojiChip] = []
    ) -> RoomChatReactions {
        let order = ["ack", "like", "dislike", "disregard"]
        let chips = order.compactMap { type -> Chip? in
            guard let count = counts[type], count > 0 else { return nil }
            let mine = (type == "like" && likedByViewer) || (type == "dislike" && dislikedByViewer)
            return Chip(type: type, count: count, isMine: mine)
        }
        return RoomChatReactions(
            chips: chips,
            emojiChips: Array(emoji.prefix(emojiLimit)),
            ackedBy: names(actorsByType["ack"] ?? [], prefix: "Acked by"),
            working: names(activeOwners, prefix: "Working:"),
            replyCount: replyCount,
            isPinned: isPinned
        )
    }

    static func names(_ ids: [String], prefix: String) -> String? {
        let unique = Array(Set(ids)).sorted()
        guard !unique.isEmpty else { return nil }
        let shown = unique.prefix(3).map { $0.hasPrefix("human-") ? String($0.dropFirst(6)) : $0 }
        let rest = unique.count - shown.count
        return "\(prefix) \(shown.joined(separator: ", "))" + (rest > 0 ? " +\(rest)" : "")
    }
}

public enum RoomConnectionState: Equatable, Sendable {
    case connecting
    case live
    case reconnecting
    case paused

    public var label: String {
        switch self {
        case .connecting: return "Connecting"
        case .live: return "Live"
        case .reconnecting: return "Reconnecting"
        case .paused: return "Paused"
        }
    }
}

public struct RoomChatMessageRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let sequenceId: Int64
    public let kind: RoomChatMessageInput.Kind
    public let authorId: String
    public let authorName: String
    public let isHuman: Bool
    public let isOwn: Bool
    public let text: String
    public let date: Date?
    public let replyToSequenceId: Int64?
    public let isEdited: Bool
    /// False when this row continues a run by the same author within a few minutes, so the name is not repeated.
    public let showsHeader: Bool
    public let reactions: RoomChatReactions?
    public let attachments: [RoomAttachmentChip]
    public let views: RoomChatViews?
    /// A threaded reply shown at its own time: its own action id. Tapping it opens its thread.
    public var inlineReplyId: String?
    public var isInlineReply: Bool { inlineReplyId != nil }
    /// What a reply answers, when that message is loaded: "author: its first line".
    public var replyContext: String?
    /// Agents' "working on" lines about this message.
    public var work: [RoomChatWorkLine] = []
    /// The last message of its author's run (the next row is someone else, a header or nothing): it carries the
    /// action row and the time.
    public var endsRun: Bool = true
    /// The room changes hands here, a person after an agent or an agent after a person: a wider break with the time
    /// above it (Carter, #55014).
    public var startsTurn: Bool = false
    /// A voice room folded into this row (its start message): the whole call as one card.
    public var call: VoiceCallCard?
    /// For a reply shown in the room: its thread so far. Only the newest reply of a thread is shown, at its own time.
    public var trail: RoomChatTrail?
    /// The same notice again and again from one agent (only the numbers changed): shown once, the newest, with how
    /// many it stands for.
    public var repeats: Int = 1
    /// The stack of alike notices this one belongs to (its first notice's id), folded or opened.
    public var repeatStack: String?
    /// Its stack is opened, and this is the stack's first notice: it offers to fold the stack again.
    public var foldsRepeats: Bool = false
    /// A checkpoint's summary, for its sheet.
    public var checkpointSummary: String?
    /// Background chatter not addressed to you (the orchestrator, the ticket keeper, boxes and agents talking to each
    /// other): one small muted line that opens in place (Carter, #55014).
    public var isQuiet: Bool = false
    /// A box's launch line, collapsed to the box's name and status; its thread holds what the box said.
    public var box: RoomBoxThread?
    /// Files posted as base64 parts in this message's thread, shown with it: on the thread's root, or on its newest
    /// part when the root is not loaded.
    public var files: [RoomChatFileCard] = []
    /// This post is a part of a file posted as base64 (the thread's root sequence): folded behind the file's card.
    public var filePartOf: Int64?
}

public enum RoomChatRow: Equatable, Identifiable, Sendable {
    case dayHeader(id: String, label: String)
    case unreadDivider
    case message(RoomChatMessageRow)

    public var id: String {
        switch self {
        case .dayHeader(let id, _): return "day:\(id)"
        case .unreadDivider: return "unread-divider"
        case .message(let row): return "msg:\(row.id)"
        }
    }
}

/// Where a room's list opens (`RoomChatPresentationState.openPosition(reopening:)`).
public enum RoomOpenPosition: Equatable, Sendable {
    /// At its newest messages.
    case latest
    /// At the unread line, with a little of what came before it above.
    case unreadLine
    /// At a message it was opened for (a link or a notification), which the room brings into view itself.
    case message(Int64)
}

/// A message you sent that the room has not echoed back yet.
public struct RoomChatPendingRow: Equatable, Identifiable, Sendable {
    public enum Status: Equatable, Sendable {
        case sending
        /// Accepted by Senti; waiting for the room to show it.
        case sent
        /// Accepted, and shown in the room's latest messages, below an older stretch the reader is reading (after a
        /// search or a pin, or a room opened far back): "Sent · ↓ latest" until the latest messages are loaded here,
        /// so the message never seems to vanish and is never sent twice.
        case sentBelow
        case failed(reason: String, canRetry: Bool)
    }

    public var id: String { clientId }
    public let clientId: String
    /// The full text, always: retry and edit use it.
    public let text: String
    public let status: Status

    /// What the row shows: very long text is cut for display only.
    public var displayText: String {
        text.count > 2_000 ? String(text.prefix(280)) + "…" : text
    }

    public init(clientId: String, text: String, status: Status) {
        self.clientId = clientId
        self.text = text
        self.status = status
    }
}

/// One reply in an open thread.
public struct RoomChatReplyRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let authorName: String
    public let isHuman: Bool
    public let isOwn: Bool
    public let text: String
    public let date: Date?
    public let isEdited: Bool
    /// Who has viewed this revision, once the room has read it.
    public let views: RoomChatViews?
    /// The handle a reply to this reply mentions: the login for a person, the id for an agent.
    public let authorHandle: String
    /// Set when this answers another reply rather than the message.
    public let parentReplyId: String?
    /// How far it is indented in the thread (0 answers the message; capped so deep threads stay readable).
    public var depth: Int = 0
    /// Reactions on this reply: like, dislike and acknowledge counts and whether they are yours.
    public let reactions: RoomChatReactions?
    /// This reply is a part of a file posted as base64 (the thread's root sequence): folded behind the file's card.
    public var filePartOf: Int64?
    /// Its photos and files, shown as a message's are.
    public let attachments: [RoomAttachmentChip]

    public init(
        id: String,
        authorName: String,
        isHuman: Bool,
        isOwn: Bool,
        text: String,
        date: Date?,
        isEdited: Bool,
        views: RoomChatViews? = nil,
        authorHandle: String = "",
        parentReplyId: String? = nil,
        reactions: RoomChatReactions? = nil,
        attachments: [RoomAttachmentChip] = []
    ) {
        self.id = id
        self.authorName = authorName
        self.isHuman = isHuman
        self.isOwn = isOwn
        self.text = text
        self.date = date
        self.isEdited = isEdited
        self.views = views
        self.authorHandle = authorHandle.isEmpty ? authorName : authorHandle
        self.parentReplyId = parentReplyId
        self.reactions = reactions
        self.attachments = attachments
    }

    /// The deepest indent a thread shows; deeper replies sit at this depth, under their parent.
    public static let maximumDepth = 3

    /// Replies ordered as a tree: each reply right after the one it answers (oldest first among siblings), with its
    /// depth. A reply whose parent is not in the thread is treated as answering the message.
    public static func nested(_ replies: [RoomChatReplyRow]) -> [RoomChatReplyRow] {
        let ids = Set(replies.map(\.id))
        var children: [String: [RoomChatReplyRow]] = [:]
        var roots: [RoomChatReplyRow] = []
        for reply in replies {
            if let parent = reply.parentReplyId, parent != reply.id, ids.contains(parent) {
                children[parent, default: []].append(reply)
            } else {
                roots.append(reply)
            }
        }
        var ordered: [RoomChatReplyRow] = []
        var seen = Set<String>()
        func visit(_ reply: RoomChatReplyRow, depth: Int) {
            guard seen.insert(reply.id).inserted else { return }
            var row = reply
            row.depth = min(depth, maximumDepth)
            ordered.append(row)
            for child in children[reply.id] ?? [] { visit(child, depth: depth + 1) }
        }
        for root in roots { visit(root, depth: 0) }
        // A cycle leaves replies unvisited: show them at the top level rather than lose them.
        for reply in replies where !seen.contains(reply.id) { visit(reply, depth: 0) }
        return ordered
    }
}

/// The open thread sheet: the parent message, its replies (oldest first), and your replies still being sent.
public struct RoomChatThreadState: Equatable, Sendable {
    public let parent: RoomChatMessageRow
    public let replies: [RoomChatReplyRow]
    public let pending: [RoomChatPendingRow]
    public let isLoading: Bool
    public let failureText: String?
    public let canReply: Bool
    /// The longest reply the API accepts, in characters; nil when there is no known limit.
    public let maximumReplyLength: Int?
    /// The reply the thread was opened at (a reply notification): brought into view and marked.
    public let focusReplyId: String?

    public init(
        parent: RoomChatMessageRow,
        replies: [RoomChatReplyRow],
        pending: [RoomChatPendingRow] = [],
        isLoading: Bool = false,
        failureText: String? = nil,
        canReply: Bool = false,
        maximumReplyLength: Int? = nil,
        focusReplyId: String? = nil
    ) {
        self.parent = parent
        self.replies = replies
        self.pending = pending
        self.isLoading = isLoading
        self.failureText = failureText
        self.canReply = canReply
        self.maximumReplyLength = maximumReplyLength
        self.focusReplyId = focusReplyId
    }

    /// Why this reply cannot be sent as it is, or nil. A reply over the limit stays in the reply box.
    public func replyLengthProblem(for draft: String) -> String? {
        RoomComposerState(canPost: canReply, disabledReason: nil, maximumLength: maximumReplyLength).lengthProblem(for: draft)
    }
}

/// What the coordinator knows about the open thread; the state builder attaches the parent row it rendered.
public struct RoomChatThreadInput: Equatable, Sendable {
    public let sequenceId: Int64
    public let replies: [RoomChatReplyRow]
    public let pending: [RoomChatPendingRow]
    public let isLoading: Bool
    public let failureText: String?
    public let canReply: Bool
    public let maximumReplyLength: Int?
    /// The reply the thread was opened at, if any.
    public let focusReplyId: String?

    public init(
        sequenceId: Int64,
        replies: [RoomChatReplyRow],
        pending: [RoomChatPendingRow] = [],
        isLoading: Bool = false,
        failureText: String? = nil,
        canReply: Bool = false,
        maximumReplyLength: Int? = nil,
        focusReplyId: String? = nil
    ) {
        self.sequenceId = sequenceId
        self.replies = replies
        self.pending = pending
        self.isLoading = isLoading
        self.failureText = failureText
        self.canReply = canReply
        self.maximumReplyLength = maximumReplyLength
        self.focusReplyId = focusReplyId
    }
}

/// Whether the composer can post, and why not when it cannot.
public struct RoomComposerState: Equatable, Sendable {
    public let canPost: Bool
    public let disabledReason: String?
    /// The longest message the API accepts, in Unicode code points (the API counts them); nil when there is no
    /// known limit.
    public let maximumLength: Int?

    public static let enabled = RoomComposerState(canPost: true, disabledReason: nil)
    public static let hidden = RoomComposerState(canPost: false, disabledReason: nil)

    public init(canPost: Bool, disabledReason: String?, maximumLength: Int? = nil) {
        self.canPost = canPost
        self.disabledReason = disabledReason
        self.maximumLength = maximumLength
    }

    /// Why this draft cannot be sent as it is, or nil. A draft over the limit stays in the composer (nothing is
    /// cleared and no failed row appears), so the writer can shorten it.
    public func lengthProblem(for draft: String) -> String? {
        guard let maximumLength else { return nil }
        let count = draft.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        guard count > maximumLength else { return nil }
        return "Too long to send: \(count.formatted(.number)) of \(maximumLength.formatted(.number)) characters."
    }

    /// How long a long draft is, counted as the limit counts (Carter, #54900); nil while it is short.
    public func lengthNote(for draft: String, from threshold: Int = 200) -> String? {
        let count = draft.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        guard count >= threshold else { return nil }
        // A formatter per call was the costliest part of a redraw while typing a long draft (ticket 7674d10b).
        let have = count.formatted(.number)
        guard let maximumLength else { return "\(have) characters" }
        return "\(have) of \(maximumLength.formatted(.number)) characters"
    }
}

/// Everything the room screen renders, built from the coordinator's timeline in one pure step.
public struct RoomChatPresentationState: Equatable, Sendable {
    public let sessionId: String
    /// Where the composer keeps its unsent text (`RoomComposerDraft.savedKey(sessionId:account:)`), or nil to keep none.
    public let draftKey: String?
    public let title: String
    public let rows: [RoomChatRow]
    public let isLoadingInitial: Bool
    /// Something the room has to tell you once (an edit that did not save).
    public let notice: String?
    public let canLoadOlder: Bool
    public let isLoadingOlder: Bool
    /// The rows are a window further back (a jump to an old message): newer messages load as the reader scrolls
    /// down, and "Jump to latest" returns to the live room.
    public let canLoadNewer: Bool
    public let isLoadingNewer: Bool
    /// The live room holds more rows than a jump to the bottom should cross: Jump to latest keeps only the newest
    /// rows first, then goes down at once (a long jump froze the app on 10-30).
    public let jumpDownKeepsLatest: Bool
    public let unreadCount: Int
    public let connection: RoomConnectionState
    /// Agent ids currently preparing a reply (from the stream's `agent_composing` controls).
    public let composingAgents: [String]
    public let failure: SessionLoadFailure?
    /// Mention handles that mean "you" (`@<your handle>` and `@all`), highlighted more strongly in message text.
    public let ownMentionHandles: Set<String>
    /// Your sent messages the room has not echoed yet, shown after the timeline.
    public let pending: [RoomChatPendingRow]
    public let composer: RoomComposerState
    /// Whether you can react (ack, like, dislike): any member, including a viewer, when actions are wired.
    public let canReact: Bool
    /// Whether the emoji picker is offered: emoji reactions are on in this build, you can react, and the room has not
    /// refused them.
    public let canAddEmoji: Bool
    public let thread: RoomChatThreadState?
    /// Counts links whose message could not be loaded (before the start of the room, or the room could not be
    /// read). Each increase takes the reader to the latest messages.
    public let focusFallbackCount: Int
    /// A message to bring into view and highlight once (opened from a notification or link).
    public let focusSequenceId: Int64?
    /// Who the composer can @-mention, in suggestion order.
    public let mentionCandidates: [MentionCandidate]
    /// Breakout cards by child room id, as this viewer may see them.
    public let breakouts: [String: RoomBreakoutCard]
    /// Small image previews by attachment id, loaded as their messages come into view.
    public let attachmentPreviews: [String: Data]
    /// Who is here now; nil until the room has asked.
    public let presence: RoomChatPresence?
    /// The room's pinned messages, newest pin first.
    public let pinned: [RoomChatPinned]
    /// The leaderboard sheet is open (see `leaderboardSheet`).
    public let leaderboardOpen: Bool
    /// You may pin and unpin (contributors and up).
    public let canPin: Bool
    /// How many messages the room can pin at once.
    public let pinLimit: Int
    /// You may rename the room: its owner, outside a breakout (the API's rule).
    public let canRename: Bool
    /// You may invite people: the room's owner or an admin, outside a breakout.
    public let canInvite: Bool
    /// A short summary of a thread, by its parent's sequence, shown on the room's row for it before it is opened
    /// (Carter, #55474: "I wish I had the summarized here at top level before I even open the thread").
    public let threadSummaries: [Int64: SummaryReading]

    /// Same-author rows closer together than this share one header.
    public static let groupingWindow: TimeInterval = 5 * 60

    /// The rows with no emoji reactions.
    static func withoutEmoji(_ inputs: [RoomChatMessageInput]) -> [RoomChatMessageInput] {
        inputs.map { input in
            var input = input
            input.reactions?.emojiChips = []
            return input
        }
    }

    public init(
        sessionId: String,
        title: String,
        messages: [RoomChatMessageInput],
        ownAuthorIds: Set<String> = [],
        unreadDividerSequence: Int64? = nil,
        unreadCount: Int = 0,
        isLoadingInitial: Bool = false,
        notice: String? = nil,
        canLoadOlder: Bool = false,
        isLoadingOlder: Bool = false,
        canLoadNewer: Bool = false,
        isLoadingNewer: Bool = false,
        jumpDownKeepsLatest: Bool = false,
        connection: RoomConnectionState = .connecting,
        composingAgents: [String] = [],
        failure: SessionLoadFailure? = nil,
        pending: [RoomChatPendingRow] = [],
        composer: RoomComposerState = .hidden,
        canReact: Bool = false,
        canAddEmoji: Bool = false,
        emojiReactions: Bool = false,
        thread threadInput: RoomChatThreadInput? = nil,
        focusFallbackCount: Int = 0,
        focusSequenceId: Int64? = nil,
        mentionCandidates: [MentionCandidate] = [],
        breakouts: [String: RoomBreakoutCard] = [:],
        attachmentPreviews: [String: Data] = [:],
        presence: RoomChatPresence? = nil,
        pinned: [RoomChatPinned] = [],
        leaderboardOpen: Bool = false,
        canPin: Bool = false,
        pinLimit: Int = 10,
        canRename: Bool = false,
        canInvite: Bool = false,
        threadSummaries: [Int64: SummaryReading] = [:],
        replies: [RoomChatMessageInput] = [],
        expandedRepeats: Set<String> = [],
        files: [Int64: [RoomChatFileCard]] = [:],
        fileParts: [String: Int64] = [:],
        draftKey: String? = nil,
        calendar: Calendar = .current
    ) {
        // Emoji reactions show only in a build that turns them on (`RoomEmojiReactions`), and never on a reply shown
        // in the room: they are not read for replies, so one there could be neither seen nor taken back.
        let messages = emojiReactions ? messages : Self.withoutEmoji(messages)
        let replies = Self.withoutEmoji(replies)
        self.sessionId = sessionId
        self.draftKey = draftKey
        self.title = title
        self.isLoadingInitial = isLoadingInitial
        self.notice = notice
        self.canLoadOlder = canLoadOlder
        self.isLoadingOlder = isLoadingOlder
        self.canLoadNewer = canLoadNewer
        self.isLoadingNewer = isLoadingNewer
        self.jumpDownKeepsLatest = jumpDownKeepsLatest
        self.unreadCount = max(unreadCount, 0)
        self.connection = connection
        self.composingAgents = composingAgents
        self.failure = failure
        self.ownMentionHandles = RoomChatPresentationState.mentionHandles(forOwnAuthorIds: ownAuthorIds)
        let protectedFailure = failure?.suppressesProtectedContent == true
        self.pending = protectedFailure ? [] : pending
        self.composer = protectedFailure ? .hidden : composer
        self.canReact = protectedFailure ? false : canReact
        self.canAddEmoji = protectedFailure ? false : emojiReactions && canAddEmoji
        self.focusFallbackCount = focusFallbackCount
        self.focusSequenceId = protectedFailure ? nil : focusSequenceId
        self.mentionCandidates = protectedFailure ? [] : mentionCandidates
        self.breakouts = protectedFailure ? [:] : breakouts
        self.attachmentPreviews = protectedFailure ? [:] : attachmentPreviews
        self.presence = protectedFailure ? nil : presence
        self.pinned = protectedFailure ? [] : pinned
        self.leaderboardOpen = protectedFailure ? false : leaderboardOpen
        self.canPin = protectedFailure ? false : canPin
        self.pinLimit = max(1, pinLimit)
        self.canRename = protectedFailure ? false : canRename
        self.canInvite = protectedFailure ? false : canInvite
        self.threadSummaries = protectedFailure ? [:] : threadSummaries

        // Protected content never renders beside an auth or access failure.
        guard failure?.suppressesProtectedContent != true else {
            self.rows = []
            self.thread = nil
            return
        }

        var rows: [RoomChatRow] = []
        var lastDay: DateComponents?
        var run: (authorId: String, date: Date)?
        var placedDivider = false
        let ownHandles = RoomChatPresentationState.mentionHandles(forOwnAuthorIds: ownAuthorIds)
        // A box's thread starts collapsed (warden, at Carter's #54962): its launch line is one line with the box's name
        // and status, and what is said in the thread stays there, unless it is said to you.
        let launches = RoomBoxThread.launches(in: messages)
        var boxReplies: [Int64: [RoomChatMessageInput]] = [:]
        let roomReplies = replies.filter { reply in
            guard launches[reply.sequenceId] != nil else { return true }
            boxReplies[reply.sequenceId, default: []].append(reply)
            return ChatReferences.mentionHandles(in: reply.text).contains(where: ownHandles.contains)
        }
        let endedBoxes = RoomBoxThread.endedBoxes(in: messages)
        // A voice room's turns fold into one card on the message that started it.
        let folded = VoiceCallCard.fold(Self.interleave(
            messages: messages.sorted { $0.sequenceId < $1.sequenceId },
            replies: roomReplies
        ))
        // A thread shows once, as its newest reply, so a busy thread is one line that moves down as it grows.
        let trails = RoomChatTrail.fold(folded.kept)
        // An agent's notice that repeats with only its numbers changing (a retry counter) is one row.
        let repeated = RoomChatRepeats.fold(trails.kept, expanded: expandedRepeats, keep: focusSequenceId)
        let ordered = repeated.kept
        let unreadLineRow = unreadDividerSequence.flatMap { line in
            Self.unreadLineRowId(line: line, shown: ordered, messages: messages, cards: folded.cards,
                                 canLoadOlder: canLoadOlder)
        }
        let parents = Dictionary(
            messages.map { ($0.sequenceId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Threads you started or answered: what is said in them is said to you.
        let ownIds = Set(ownAuthorIds.map { $0.lowercased() })
        let yourThreads = Set(
            messages.filter { ownIds.contains($0.authorId.lowercased()) }.map(\.sequenceId)
                + replies.filter { ownIds.contains($0.authorId.lowercased()) }.map(\.sequenceId)
        )
        for input in ordered {
            if let date = input.date {
                let day = calendar.dateComponents([.year, .month, .day], from: date)
                if day != lastDay {
                    rows.append(.dayHeader(
                        id: "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)",
                        label: RoomChatPresentationState.dayLabel(for: date, calendar: calendar)
                    ))
                    lastDay = day
                    run = nil   // a new day always repeats the author header
                }
            }
            if let unreadLineRow, !placedDivider, input.id == unreadLineRow {
                rows.append(.unreadDivider)
                placedDivider = true
                run = nil
            }
            let continuesRun: Bool
            if input.kind == .message,
               let run,
               run.authorId == input.authorId,
               let now = input.date,
               now.timeIntervalSince(run.date) >= 0,
               now.timeIntervalSince(run.date) < Self.groupingWindow {
                continuesRun = true
            } else {
                continuesRun = false
            }
            rows.append(.message(RoomChatMessageRow(
                id: input.id,
                sequenceId: input.sequenceId,
                kind: input.kind,
                authorId: input.authorId,
                authorName: input.authorName,
                isHuman: input.isHuman,
                isOwn: ownAuthorIds.contains(input.authorId.lowercased()),
                text: input.text,
                date: input.date,
                replyToSequenceId: input.replyToSequenceId,
                isEdited: input.isEdited,
                showsHeader: !continuesRun,
                reactions: input.reactions.flatMap { $0.isEmpty ? nil : $0 },
                attachments: input.attachments,
                views: input.views,
                inlineReplyId: input.inlineReplyId,
                replyContext: input.replyToSequenceId.flatMap { parents[$0] }.map(Self.replyContext(for:)),
                work: input.isInlineReply ? [] : input.work,
                call: folded.cards[input.id],
                trail: trails.trails[input.id],
                repeats: repeated.counts[input.id] ?? 1,
                repeatStack: repeated.stacks[input.id],
                foldsRepeats: repeated.stacks[input.id] == input.id && expandedRepeats.contains(input.id),
                checkpointSummary: input.checkpointSummary,
                // A box's launch line is its own collapsed line, never background.
                isQuiet: folded.cards[input.id] == nil && (input.isInlineReply || launches[input.sequenceId] == nil)
                    && RoomChatQuiet.isQuiet(
                        input,
                        ownHandles: ownHandles,
                        inYourThread: yourThreads.contains(input.isInlineReply ? input.sequenceId : (input.replyToSequenceId ?? -1))
                    ),
                box: input.isInlineReply ? nil : launches[input.sequenceId].map { launch in
                    RoomBoxThread(launch: launch, replies: boxReplies[input.sequenceId] ?? [],
                                  isEnded: endedBoxes.contains(launch.name.lowercased()))
                }
            )))
            if input.kind == .message, let date = input.date {
                run = (input.authorId, date)
            } else {
                run = nil
            }
        }
        // A message ends its run unless the next row is the same author's message without a header.
        for index in rows.indices {
            guard case .message(var current) = rows[index] else { continue }
            if index + 1 < rows.count, case .message(let next) = rows[index + 1], !next.showsHeader,
               next.authorId == current.authorId {
                current.endsRun = false
                rows[index] = .message(current)
            }
        }
        // A turn starts where a person follows an agent or an agent follows a person. A day, the unread line, a
        // checkpoint or a call card is a break of its own, so the next message never starts a turn there.
        var lastIsHuman: Bool?
        for index in rows.indices {
            guard case .message(var current) = rows[index], current.kind == .message, current.call == nil else {
                lastIsHuman = nil
                continue
            }
            // Background chatter and box lines show as one small line: they neither start a turn nor end one.
            if current.isQuiet || current.box != nil { continue }
            if let lastIsHuman, lastIsHuman != current.isHuman {
                current.startsTurn = true
                rows[index] = .message(current)
            }
            lastIsHuman = current.isHuman
        }
        if !protectedFailure, !files.isEmpty || !fileParts.isEmpty {
            rows = Self.placingFiles(files, parts: fileParts, in: rows)
        }
        self.rows = rows
        if let threadInput, !protectedFailure,
           case .message(let parent)? = Self.messageRow(in: rows, for: threadInput.sequenceId) {
            self.thread = RoomChatThreadState(
                parent: parent,
                replies: RoomChatReplyRow.nested(threadInput.replies).map { reply in
                    var reply = reply
                    reply.filePartOf = fileParts[reply.id]
                    return reply
                },
                pending: threadInput.pending,
                isLoading: threadInput.isLoading,
                failureText: threadInput.failureText,
                canReply: threadInput.canReply,
                maximumReplyLength: threadInput.maximumReplyLength,
                focusReplyId: threadInput.focusReplyId
            )
        } else {
            self.thread = nil
        }
    }

    /// Which shown row the unread line goes before: the first that holds a message at or after the line. A call's
    /// card holds the turns folded into it, so a first unread spoken in a call puts the line before its card, as the
    /// web does (the line would otherwise land after the call, or nowhere when the call is the room's last row). A line
    /// before every row loaded, while older messages are not loaded, has no place among these rows yet: none.
    static func unreadLineRowId(
        line: Int64,
        shown: [RoomChatMessageInput],
        messages: [RoomChatMessageInput],
        cards: [String: VoiceCallCard],
        canLoadOlder: Bool
    ) -> String? {
        var cardsHoldingUnread: Set<String> = []
        if !cards.isEmpty {
            let unread = Set(messages.lazy.filter { $0.sequenceId >= line }.map(\.id))
            for (id, card) in cards where card.turns.contains(where: { unread.contains($0.id) }) {
                cardsHoldingUnread.insert(id)
            }
        }
        guard let index = shown.firstIndex(where: { $0.sequenceId >= line || cardsHoldingUnread.contains($0.id) })
        else { return nil }
        if index == 0, canLoadOlder, line < shown[index].sequenceId { return nil }
        return shown[index].id
    }

    /// Where the room opens (`RoomChatView`): at the message it was opened for (a link or a notification); else at
    /// the unread line when its rows hold one, where you stopped reading; else at its newest messages, as it always
    /// has. Put back at its newest rows (a send, or Jump to latest, from up a long history), it opens at the newest
    /// whatever the line: that is what was asked.
    public func openPosition(reopening: Bool) -> RoomOpenPosition {
        if let focusSequenceId { return .message(focusSequenceId) }
        if !reopening, rows.contains(.unreadDivider) { return .unreadLine }
        return .latest
    }

    /// Files posted as base64 parts: each part is marked (a message by its id, a reply by its own), and each thread's
    /// cards go on its root message, or, when the root is not loaded, on its newest part shown.
    static func placingFiles(_ files: [Int64: [RoomChatFileCard]], parts: [String: Int64],
                             in rows: [RoomChatRow]) -> [RoomChatRow] {
        var rows = rows
        var placed = Set<Int64>()
        var newestPart: [Int64: Int] = [:]
        for index in rows.indices {
            guard case .message(var row) = rows[index] else { continue }
            if let thread = parts[row.inlineReplyId ?? row.id] {
                row.filePartOf = thread
                newestPart[thread] = index
            }
            if !row.isInlineReply, let cards = files[row.sequenceId] {
                row.files = cards
                placed.insert(row.sequenceId)
            }
            rows[index] = .message(row)
        }
        for (thread, index) in newestPart where !placed.contains(thread) {
            guard let cards = files[thread], case .message(var row) = rows[index] else { continue }
            row.files = cards
            rows[index] = .message(row)
        }
        return rows
    }

    /// Messages in sequence order with replies placed at their own time: each reply goes after the messages that
    /// came before it. A reply without a time goes after its message.
    static func interleave(messages: [RoomChatMessageInput], replies: [RoomChatMessageInput]) -> [RoomChatMessageInput] {
        guard !replies.isEmpty else { return messages }
        let timed = replies.sorted { ($0.date ?? .distantFuture, $0.id) < ($1.date ?? .distantFuture, $1.id) }
        var result: [RoomChatMessageInput] = []
        result.reserveCapacity(messages.count + replies.count)
        var next = 0
        for message in messages {
            if let at = message.date {
                while next < timed.count, let replyAt = timed[next].date, replyAt < at {
                    result.append(timed[next])
                    next += 1
                }
            }
            result.append(message)
        }
        result.append(contentsOf: timed[next...])
        return result
    }

    /// "author: first line" of the message a reply answers, kept short. Reads only up to that line's end: the
    /// message can be a 27,000-character packet, and this runs for every reply on every update.
    static func replyContext(for parent: RoomChatMessageInput) -> String {
        let body = parent.text.drop { $0.isNewline }
        let line = String(body.firstIndex(where: \.isNewline).map { body[..<$0] } ?? body)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let snippet = trimmed.count > 70 ? String(trimmed.prefix(70)) + "…" : trimmed
        return "\(parent.authorName): \(snippet)"
    }

    /// The row of the message with this sequence: never a reply shown in the room under the same sequence.
    public func messageRow(for sequenceId: Int64) -> RoomChatRow? { Self.messageRow(in: rows, for: sequenceId) }

    static func messageRow(in rows: [RoomChatRow], for sequenceId: Int64) -> RoomChatRow? {
        rows.first { row in
            if case .message(let message) = row { return !message.isInlineReply && message.sequenceId == sequenceId }
            return false
        }
    }

    /// A pin belongs to its message: a reply shown in the room is never marked by its message's pin.
    public func isPinned(_ row: RoomChatMessageRow) -> Bool {
        !row.isInlineReply && pinned.contains { $0.sequenceId == row.sequenceId }
    }

    /// The room's leaderboard (see `RoomChatPinned.leaderboard(among:)`). Rooms that keep one (a scoreboard of who
    /// is helping most, pinned and edited as the scores change) show a Leaderboard button under the room's title
    /// that opens it; any other room shows none.
    public var leaderboard: RoomChatPinned? { RoomChatPinned.leaderboard(among: pinned) }

    /// The leaderboard sheet while it is open and the room keeps a board: the board read from the pinned message
    /// (again at each edit, so the open list follows the standings), a line while its text is still being read, or
    /// "Board unavailable" when no row in it can be read. Never the message's raw text.
    public var leaderboardSheet: RoomChatLeaderboardSheet? {
        guard leaderboardOpen, let pin = leaderboard else { return nil }
        let content: RoomChatLeaderboardSheet.Content
        if let board = pin.board {
            content = .board(board)
        } else {
            content = pin.text.isEmpty ? .loading : .unavailable
        }
        return RoomChatLeaderboardSheet(sequenceId: pin.sequenceId, content: content)
    }

    public var lastMessageId: String? {
        for row in rows.reversed() {
            if case .message(let message) = row { return message.id }
        }
        return nil
    }

    public var firstMessageId: String? {
        for row in rows {
            if case .message(let message) = row { return message.id }
        }
        return nil
    }

    public var isEmpty: Bool { lastMessageId == nil && pending.isEmpty }

    /// `human-mrrcarter` is mentioned as `@mrrcarter`; `@all` mentions everyone, including you.
    static func mentionHandles(forOwnAuthorIds ids: Set<String>) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var handles: Set<String> = ["all"]
        for id in ids {
            let lowered = id.lowercased()
            handles.insert(lowered.hasPrefix("human-") ? String(lowered.dropFirst("human-".count)) : lowered)
        }
        return handles
    }

    static func dayLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter.string(from: date)
    }
}

/// The ids of what the room reads aloud, so the row being read can show it.
public enum RoomReadAloud {
    public static func message(_ sequenceId: Int64) -> String { "msg:\(sequenceId)" }
    public static func reply(_ id: String) -> String { "reply:\(id)" }
    /// A thread's summary on one row, by the sequence id of the message the thread answers (Carter, on #55474: "a
    /// voice version of the summary"). The row is in it, so only the row being read shows stop.
    public static func summary(_ threadSequenceId: Int64, row: String) -> String { "summary:\(threadSequenceId):\(row)" }

    /// The thread whose summary an id reads, if it reads one.
    public static func summaryThread(_ id: String) -> Int64? {
        let parts = id.split(separator: ":", maxSplits: 2)
        guard parts.count == 3, parts[0] == "summary" else { return nil }
        return Int64(parts[1])
    }
}

/// A thread as the room shows it: how many replies, who wrote them (newest first), and the newest answer is the row.
public struct RoomChatTrail: Equatable, Sendable {
    public let count: Int
    public let authors: [String]
    /// The room's own receipt in the thread (the ticket keeper's "Tickets for this message"), first line only, when an
    /// answer is the row instead: it shows as a small chip under the answer, never in its place (Carter, #58637).
    public let receipt: String?

    public init(count: Int, authors: [String], receipt: String? = nil) {
        self.count = count
        self.authors = authors
        self.receipt = receipt
    }

    /// "4 replies · claude-warden, pocket-forge and 1 more".
    public var label: String {
        let replies = "\(count) \(count == 1 ? "reply" : "replies")"
        guard !authors.isEmpty else { return replies }
        let shown = authors.prefix(2).joined(separator: ", ")
        let more = authors.count > 2 ? " and \(authors.count - 2) more" : ""
        return "\(replies) · \(shown)\(more)"
    }

    /// Keeps each thread's newest answer where it is (at its own time) and drops the other replies, so a thread is one
    /// row; that row says how many replies and who. The room's own receipts (the ticket keeper's) are never the row
    /// while someone has answered: they came last under Carter's message and hid the answer to him (#58637). Messages
    /// are untouched.
    public static func fold(_ inputs: [RoomChatMessageInput]) -> (kept: [RoomChatMessageInput], trails: [String: RoomChatTrail]) {
        var newest: [Int64: Int] = [:]
        var newestAnswer: [Int64: Int] = [:]
        var groups: [Int64: [RoomChatMessageInput]] = [:]
        for (index, input) in inputs.enumerated() where input.isInlineReply {
            let thread = input.replyToSequenceId ?? input.sequenceId
            newest[thread] = index
            if !isReceipt(input) { newestAnswer[thread] = index }
            groups[thread, default: []].append(input)
        }
        guard !groups.isEmpty else { return (inputs, [:]) }
        var kept: [RoomChatMessageInput] = []
        kept.reserveCapacity(inputs.count)
        var trails: [String: RoomChatTrail] = [:]
        for (index, input) in inputs.enumerated() {
            guard input.isInlineReply else {
                kept.append(input)
                continue
            }
            let thread = input.replyToSequenceId ?? input.sequenceId
            guard (newestAnswer[thread] ?? newest[thread]) == index, let group = groups[thread] else { continue }
            let answered = newestAnswer[thread] != nil
            var authors: [String] = []
            for reply in group.reversed() where !authors.contains(reply.authorName) {
                if answered, isReceipt(reply) { continue }
                authors.append(reply.authorName)
            }
            let receipt = answered
                ? group.last(where: isReceipt).map { RoomChatQuiet.line($0.text) } : nil
            trails[input.id] = RoomChatTrail(count: group.count, authors: authors, receipt: receipt)
            kept.append(input)
        }
        return (kept, trails)
    }

    /// The room's own bookkeeping in a thread: the orchestrator's and the ticket keeper's lines. Senti's answers are
    /// answers.
    public static func isReceipt(_ reply: RoomChatMessageInput) -> Bool {
        RoomChatQuiet.systemAuthors.contains(reply.authorId.lowercased())
    }
}

/// Runs of the same notice from one agent, where only the numbers change ("remains queued after 105 failed relay
/// attempts", then 107, then 109): the run shows as its newest message with a count. People's messages, replies, and
/// anything with different words are never folded.
public enum RoomChatRepeats {
    /// The words of a message with its numbers taken out, the part that must match.
    static func shape(_ text: String) -> String {
        // Each run of digits becomes one "#", by hand: this runs for every pair of neighbouring notices on every update.
        var shaped = ""
        shaped.reserveCapacity(text.count)
        var inNumber = false
        for character in text {
            if character.isASCII, character.isNumber {
                if !inNumber { shaped.append("#") }
                inNumber = true
            } else {
                shaped.append(character)
                inNumber = false
            }
        }
        return shaped
    }

    /// A notice that may stand in for others like it: an agent's plain message with nothing of its own. One with
    /// attachments, reactions or a thread always shows (warden: folding must never hide what differs).
    static func isFoldable(_ input: RoomChatMessageInput) -> Bool {
        !input.isHuman && !input.isInlineReply && input.kind == .message && input.text.count >= 24
            && input.attachments.isEmpty && (input.reactions?.isEmpty ?? true)
    }

    /// Folds each run of alike notices into its newest, counting them. A run is a stack, named by its first notice:
    /// an opened stack (`expanded`) shows every notice, and a run holding `keep` (a message being opened from a link)
    /// is never folded. `stacks` names the stack of every notice in one.
    public static func fold(_ inputs: [RoomChatMessageInput], expanded: Set<String> = [], keep: Int64? = nil)
        -> (kept: [RoomChatMessageInput], counts: [String: Int], stacks: [String: String]) {
        var kept: [RoomChatMessageInput] = []
        kept.reserveCapacity(inputs.count)
        var counts: [String: Int] = [:]
        var stacks: [String: String] = [:]
        for input in inputs {
            if let last = kept.last, isFoldable(input), isFoldable(last), input.authorId == last.authorId,
               shape(input.text) == shape(last.text), input.text != last.text {
                let stack = stacks[last.id] ?? last.id
                stacks[last.id] = stack
                stacks[input.id] = stack
                if expanded.contains(stack) || input.sequenceId == keep || last.sequenceId == keep {
                    kept.append(input)
                } else {
                    counts[input.id] = (counts[last.id] ?? 1) + 1
                    counts[last.id] = nil
                    kept[kept.count - 1] = input
                }
                continue
            }
            kept.append(input)
        }
        return (kept, counts, stacks)
    }
}

/// What in the room is background (Carter, #55014): said by the orchestrator or the ticket keeper, by a box (its
/// signed speech), or by an agent to other agents, and not to you. Said to you means it mentions you or @all, or it
/// is in a thread you started or answered. People are never background.
public enum RoomChatQuiet {
    /// The room's own voices: costs, mints, relay notices, ticket filing and "working on" lines.
    static let systemAuthors: Set<String> = ["respawn-orchestrator", "ticket-keeper"]

    /// The room's own voices, which never answer a call: the orchestrator's costs and mints, the ticket keeper, and
    /// Senti's own notices ("sam answered ada-agent's call").
    public static func isRoomVoice(_ authorId: String) -> Bool {
        let key = authorId.lowercased()
        return systemAuthors.contains(key) || key == "senti"
    }
    /// The signature a box's relayed speech ends with.
    static let boxSignature = "⟂ speech"

    public static func isQuiet(_ input: RoomChatMessageInput, ownHandles: Set<String>, inYourThread: Bool) -> Bool {
        guard !input.isHuman, input.kind == .message, !inYourThread else { return false }
        let mentioned = ChatReferences.mentionHandles(in: input.text)
        if mentioned.contains(where: ownHandles.contains) { return false }
        if systemAuthors.contains(input.authorId.lowercased()) || input.text.contains(boxSignature) { return true }
        // An agent speaking to other agents by name.
        return !mentioned.isEmpty
    }

    /// The line a quiet row shows: its first line of text, without Markdown's marks or a box's signature.
    ///
    /// A quiet row asks for its line on every render, so the expressions are compiled once and each text's line is
    /// remembered: compiling them per call showed up on the main thread in the watchdog's stack (Carter, 10-30).
    ///
    /// The line is cut at `lineCharacters`: it shows on one line, and the room measures every row it draws. The
    /// review packets in the build-17 freeze were quiet rows whose first line was a 700-character JSON header.
    public static func line(_ text: String) -> String {
        if let known = lineCache.object(forKey: text as NSString) { return known as String }
        let unsigned = RoomBoxThread.unsigned(text)
        let first = unsigned.split(whereSeparator: \.isNewline).first.map(String.init) ?? unsigned
        var line = first
        for (expression, template) in lineRules {
            line = expression.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: template)
        }
        line = line.trimmingCharacters(in: .whitespaces)
        if line.count > lineCharacters { line = String(line.prefix(lineCharacters)) + "…" }
        lineCache.setObject(line as NSString, forKey: text as NSString)
        return line
    }

    /// The most of a quiet line kept: far more than one line on a phone shows, and as much as a thread's summary reads
    /// of each reply (`ThreadSummaries.maximumLineLength`).
    public static let lineCharacters = 280

    private static let lineRules: [(NSRegularExpression, String)] = [
        (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),
        (#"[*`]+"#, ""),
        (#"^[#>\s]+"#, "")
    ].compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }

    private static let lineCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2_000
        return cache
    }()
}

/// A box's thread, collapsed (warden, at Carter's #54962). The respawn orchestrator's launch line ("🚀 Minted <name> …
/// (life <id>)", respawn `bridge.ts`) shows as one line with the box's name and status; a tap opens the thread, where
/// everything the box said is.
public struct RoomBoxThread: Equatable, Sendable {
    public struct Launch: Equatable, Sendable {
        public let name: String
        public let model: String?
        public let ticketTitle: String?
        public let lifeId: String
    }

    public let launch: Launch
    /// Its final cost line was posted ("[cost] final: <name>: …"): the box has ended.
    public let isEnded: Bool
    /// How much was said in its thread.
    public let replies: Int
    public let newestAuthor: String?
    public let newestLine: String?
    public let newestAt: Date?

    public var name: String { launch.name }

    /// What the line says after the name: what was said last in the thread (by whom, when it was not the box), and
    /// "finished" once the box has ended.
    public var status: String {
        let last = newestLine.map { line -> String in
            guard let author = newestAuthor, author.lowercased() != name.lowercased() else { return line }
            return "\(author): \(line)"
        }
        if isEnded { return last.map { "finished · \($0)" } ?? "finished" }
        return last ?? launch.ticketTitle ?? "starting"
    }

    public init(launch: Launch, replies: [RoomChatMessageInput], isEnded: Bool) {
        self.launch = launch
        self.isEnded = isEnded
        self.replies = replies.count
        let newest = replies.max { ($0.date ?? .distantPast, $0.id) < ($1.date ?? .distantPast, $1.id) }
        newestAuthor = newest?.authorName
        newestLine = newest.map { RoomChatQuiet.line($0.text) }
        newestAt = newest?.date
    }

    /// A box's speech without the relay's signature ("⟂ speech …").
    static func unsigned(_ text: String) -> String {
        guard let range = text.range(of: RoomChatQuiet.boxSignature) else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let launchPattern =
        #"^🚀 Minted ([A-Za-z0-9_.-]+)(?: on (\S+))?(?: for ticket \S+(?: \((.*?)\))?)?: its own machine \(life ([0-9a-f]{12})\)"#

    /// Compiled once: every room update reads every orchestrator line for launches.
    private static let launchExpression = try? NSRegularExpression(pattern: launchPattern)

    /// The orchestrator's launch line, parsed.
    public static func launch(_ text: String) -> Launch? {
        guard text.hasPrefix("🚀 Minted "), let regex = launchExpression,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        guard let name = group(1), let lifeId = group(4) else { return nil }
        return Launch(name: name, model: group(2), ticketTitle: group(3), lifeId: lifeId)
    }

    /// The room's launch lines, by their sequence.
    static func launches(in messages: [RoomChatMessageInput]) -> [Int64: Launch] {
        var found: [Int64: Launch] = [:]
        for message in messages where message.kind == .message && message.authorId.lowercased() == "respawn-orchestrator" {
            if let launch = launch(message.text) { found[message.sequenceId] = launch }
        }
        return found
    }

    /// The boxes whose final cost line was posted, by lowercased name.
    static func endedBoxes(in messages: [RoomChatMessageInput]) -> Set<String> {
        let prefix = "[cost] final: "
        var ended = Set<String>()
        for message in messages where message.authorId.lowercased() == "respawn-orchestrator" && message.text.hasPrefix(prefix) {
            let rest = message.text.dropFirst(prefix.count)
            if let colon = rest.firstIndex(of: ":") { ended.insert(rest[..<colon].lowercased()) }
        }
        return ended
    }
}

/// A checkpoint's summary as the web shows it: the overview, cut where the digest's lists begin (the web's
/// `checkpointOverview`), so it reads as what the room discussed, not as verified work.
public enum CheckpointText {
    static let markers = [
        "\n\nCovered sequence range:", "\nCovered sequence range:",
        "\n\nReported work (unverified):", "\nReported work (unverified):",
        "\n\nWork completed:", "\nWork completed:"
    ]

    public static func overview(_ summary: String) -> String {
        var end = summary.endIndex
        for marker in markers {
            if let range = summary.range(of: marker), range.lowerBound > summary.startIndex, range.lowerBound < end {
                end = range.lowerBound
            }
        }
        return String(summary[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What Listen says: the title, then the overview.
    public static func spoken(title: String, summary: String?) -> String {
        let overview = summary.map(overview) ?? ""
        return overview.isEmpty ? "Checkpoint. \(title)" : "Checkpoint. \(title).\n\n\(overview)"
    }
}

/// One option in a row's long-press menu, and what it asks the room for.
public struct RoomRowOption: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case reply, thread, listen, like, dislike, acknowledge, emoji, pin, edit, copy
    }

    public let kind: Kind
    public let title: String
    public let symbol: String
    /// What it asks the room for; nil for what the view does itself (Copy, and the sheets it opens).
    public let intent: RoomChatIntent?
    public var isEnabled = true

    public var id: Kind { kind }
}

extension RoomChatMessageRow {
    /// What reads this row aloud. A reply shown in the room is read as itself, never as the message it answers.
    public var readAloudId: String {
        inlineReplyId.map(RoomReadAloud.reply) ?? RoomReadAloud.message(sequenceId)
    }

    /// The thread whose summary this row shows: a box line's own thread, or the thread a reply in the room is in.
    public var summaryThreadId: Int64? {
        if box != nil { return sequenceId }
        return isInlineReply ? replyToSequenceId : nil
    }

    /// What reads this row's thread summary aloud.
    public var summaryReadAloudId: String? {
        summaryThreadId.map { RoomReadAloud.summary($0, row: id) }
    }

    /// What a reply written to this row sends: into its thread, answering this reply when the row is one.
    public func replyIntent(_ text: String) -> RoomChatIntent {
        if let inlineReplyId { return .sendReplyToReply(sequenceId: sequenceId, replyId: inlineReplyId, text: text) }
        return .sendReply(sequenceId: sequenceId, text: text)
    }

    /// Its identifier for VoiceOver and UI tests: a reply shown in the room has its own.
    public var accessibilityId: String {
        inlineReplyId.map { "pocket.room.reply.\($0)" } ?? "pocket.room.message.\(sequenceId)"
    }

    /// What a reaction on this row sends. A reply shown in the room shares its message's sequence, so it reacts to
    /// the reply itself (the API takes it as `targetActionId`): a like on a reply never lands on the message it answers.
    public func reaction(_ type: String) -> RoomChatIntent {
        if let inlineReplyId { return .reactToReply(sequenceId: sequenceId, replyId: inlineReplyId, type: type) }
        return .react(sequenceId: sequenceId, type: type)
    }

    /// Your emoji reaction on this row (on the reply itself for a reply shown in the room), added or taken back.
    public func emojiReaction(_ emoji: String, isOn: Bool) -> RoomChatIntent {
        .setEmojiReaction(sequenceId: sequenceId, replyId: inlineReplyId, emoji: emoji, isOn: isOn)
    }

    /// What tapping an emoji chip sends: takes your reaction back when it is yours, else adds yours.
    public func emojiToggle(_ chip: RoomChatReactions.EmojiChip) -> RoomChatIntent {
        emojiReaction(chip.emoji, isOn: !chip.isMine)
    }

    /// The long-press menu, in order. A message's options act on the message. A reply shown in the room answers
    /// itself, opens its thread, reads itself aloud, reacts to itself and copies itself; it has no pin.
    public func options(canReply: Bool, canReact: Bool, canPin: Bool, isPinned: Bool, pinsFull: Bool,
                        canEdit: Bool = false, canAddEmoji: Bool = false) -> [RoomRowOption] {
        var options: [RoomRowOption] = []
        if canReply {
            // Written right in the room's box, and it goes to the thread (Carter, #55074): the view starts it.
            options.append(RoomRowOption(kind: .reply, title: "Reply", symbol: "arrowshape.turn.up.left", intent: nil))
        }
        options += [
            RoomRowOption(kind: .thread, title: "Open thread",
                          symbol: "bubble.left.and.bubble.right", intent: .openThread(sequenceId: sequenceId)),
            // Always "Listen": a context menu can show content from before the reading started, so Stop is the
            // speaker button on the row being read.
            RoomRowOption(kind: .listen, title: "Listen", symbol: "speaker.wave.2",
                          intent: .readAloud(id: readAloudId, text: text))
        ]
        if canReact {
            let liked = reactions?.chips.contains { $0.type == "like" && $0.isMine } == true
            let disliked = reactions?.chips.contains { $0.type == "dislike" && $0.isMine } == true
            options.append(RoomRowOption(kind: .like, title: liked ? "Remove like" : "Like",
                                         symbol: liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                                         intent: reaction(liked ? "unlike" : "like")))
            options.append(RoomRowOption(kind: .dislike, title: disliked ? "Remove dislike" : "Dislike",
                                         symbol: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                                         intent: reaction(disliked ? "undislike" : "dislike")))
            options.append(RoomRowOption(kind: .acknowledge, title: "Acknowledge", symbol: "checkmark.circle",
                                         intent: reaction("ack")))
        }
        // The view opens the emoji picker; a reply shown in the room takes no emoji reactions.
        if canAddEmoji, !isInlineReply {
            options.append(RoomRowOption(kind: .emoji, title: "Add reaction", symbol: "face.smiling", intent: nil))
        }
        if canPin, !isInlineReply {
            options.append(RoomRowOption(
                kind: .pin,
                title: isPinned ? "Unpin" : (pinsFull ? "Pinned messages are full" : "Pin"),
                symbol: isPinned ? "pin.slash" : "pin",
                intent: .setPinned(sequenceId: sequenceId, isPinned: !isPinned),
                isEnabled: isPinned || !pinsFull
            ))
        }
        // Your own words can be edited (the view asks for the new text).
        if canEdit, isOwn, kind == .message {
            options.append(RoomRowOption(kind: .edit, title: "Edit", symbol: "pencil", intent: nil))
        }
        options.append(RoomRowOption(kind: .copy, title: "Copy text", symbol: "doc.on.doc", intent: nil))
        return options
    }
}

/// What the room screen can ask for.
public enum RoomChatIntent: Equatable, Sendable {
    /// Your own message, with new text.
    case editMessage(sequenceId: Int64, text: String)
    /// Your own reply (in a thread, or shown in the room), with new text.
    case editReply(sequenceId: Int64, replyId: String, text: String)
    /// Close the room's notice.
    case dismissNotice
    case loadOlder
    /// The reader reached the bottom of a window further back: load the next newer page.
    case loadNewer
    /// Leave a window further back for the live room (the newest messages).
    case jumpToLatest
    /// The composer's "+": open the room's tickets (straight into a new ticket when `filing`), or its search.
    case openTickets(filing: Bool)
    case openSearch
    case readerAtBottom(Bool)
    /// The bottom marker flapped, so the reader's place was held still for a moment: for the freeze recorder, with how
    /// many rows the room had and its longest message's length, never what it says.
    case bottomFlapHeld(rows: Int, longestText: Int)
    /// Send was tapped, before the box empties: for the freeze recorder, since the room hears of the send only on the
    /// next turn of the run loop and a freeze in the update that empties the box left no step (build 07, #58648).
    /// How long the text is, never what it says.
    case sendTapped(characters: Int)
    case retry
    case jumpToMessage(sequenceId: Int64)
    case sendMessage(text: String)
    case retrySend(clientId: String)
    case discardSend(clientId: String)
    case react(sequenceId: Int64, type: String)
    case openThread(sequenceId: Int64)
    case closeThread
    /// The room's leaderboard, as a list in a sheet.
    case openLeaderboard
    case closeLeaderboard
    case sendReply(sequenceId: Int64, text: String)
    /// A reply to a reply in a thread (it nests under it).
    case sendReplyToReply(sequenceId: Int64, replyId: String, text: String)
    /// Like, dislike, unlike, undislike or acknowledge a reply in a thread.
    case reactToReply(sequenceId: Int64, replyId: String, type: String)
    /// Add your emoji reaction to a message, or to a reply shown in the room (`replyId`), or take it back.
    case setEmojiReaction(sequenceId: Int64, replyId: String?, emoji: String, isOn: Bool)
    /// The view brought `focusSequenceId` into view.
    case focusHandled
    /// Open a breakout started from this room (the screen navigates; the room keeps running).
    case openBreakout(childSessionId: String)
    /// Open a file attached to a message, full size.
    case openAttachment(attachmentId: String)
    /// Share a file attached to a message (save it to Files, or send it to another app).
    case shareAttachment(attachmentId: String)
    /// Read a message or reply aloud from the start, the text its row shows. The room screen reads.
    case readAloud(id: String, text: String)
    /// Stop reading aloud.
    case stopReadingAloud
    /// A photo or video attachment came into view: load its small preview if it has none.
    case attachmentAppeared(attachmentId: String)
    /// A message (by event id) or a reply (by action id) came on screen or left it, for read receipts.
    case messageOnScreen(id: String, isOnScreen: Bool)
    /// Pin a message for the whole room, or unpin it.
    case setPinned(sequenceId: Int64, isPinned: Bool)
    case replyOnScreen(id: String, isOnScreen: Bool)
    /// Open a stack of alike notices to see each one, or fold it again.
    case toggleRepeats(stack: String)
    /// The people list opened: the room screen refreshes which boxes still run.
    case peopleOpened
    /// The room's owner gave it a new name (`RoomTitle.cleaned` already applied).
    case renameRoom(title: String)
    /// Open the invite sheet (a share link, or an invite by email or username).
    case openInvite
    /// The reader is about to jump to the bottom of a long loaded history: keep only the newest rows first.
    case keepLatestForJumpDown
    /// The jump button took the reader to the first new message: the count is taken, the line stays.
    case newMessagesShown
    /// The reader is about to go to the first new message from up a long loaded history: keep the rows from just above
    /// that line on, as for the jump down.
    case keepFromNewMessagesLine
}

/// A room's name as the API takes it (`SessionTitlePayload`, `_normalize_session_title`): control characters out,
/// runs of white space one space, up to 80 characters, and not starting like a Markdown line ("# ", "> ", "* ",
/// "- "), which the API refuses as a message body pasted in as a name.
public enum RoomTitle {
    public static let maximumLength = 80

    /// The name to send, or nil when the API would refuse it.
    public static func cleaned(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: \.isWhitespace).map { word in
            String(String.UnicodeScalarView(word.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        }
        let name = words.filter { !$0.isEmpty }.joined(separator: " ")
        guard !name.isEmpty, name.count <= maximumLength, name.lowercased() != "null" else { return nil }
        let markdownStarts = ["# ", "## ", "### ", "#### ", "##### ", "###### ", ">", "*", "- "]
        return markdownStarts.contains(where: name.hasPrefix) ? nil : name
    }
}

/// A pinned message in the room's strip.
public struct RoomChatPinned: Equatable, Identifiable, Sendable {
    public var id: Int64 { sequenceId }
    public let sequenceId: Int64
    /// The message's first line, or "Message #N" when its text is not known yet.
    public let snippet: String
    public let pinnedBy: String
    /// The message's whole text at its newest edit; empty while it is not known. A leaderboard's rows come from it.
    public let text: String
    /// The text read as a leaderboard, once per revision; nil when it isn't one.
    public let board: RoomLeaderboard?

    public init(sequenceId: Int64, snippet: String, pinnedBy: String, text: String = "", board: RoomLeaderboard? = nil) {
        self.sequenceId = sequenceId
        self.snippet = snippet
        self.pinnedBy = pinnedBy
        self.text = text
        self.board = board
    }

    /// The mark a leaderboard's text starts with.
    public static let leaderboardMark: Unicode.Scalar = "🏆"

    /// A pin whose text starts with the trophy: the room's leaderboard. Compared by its first scalar, so the mark
    /// followed by an emoji variation selector counts too.
    public var isLeaderboard: Bool { snippet.unicodeScalars.first == Self.leaderboardMark }

    /// The room's leaderboard among its pins (newest first): the newest pin whose text starts with the trophy and
    /// reads as a board, so a trophy announcement never hides the board; with none that reads, the newest trophy pin
    /// (its sheet says the board is unavailable). Who posted a pin plays no part, and the sheet doesn't say: the
    /// poster line is removed until the server provides a verified poster.
    public static func leaderboard(among pins: [RoomChatPinned]) -> RoomChatPinned? {
        let trophies = pins.filter(\.isLeaderboard)
        return trophies.first { $0.board != nil } ?? trophies.first
    }
}

/// The open leaderboard: the board's message, and what the sheet shows of it.
public struct RoomChatLeaderboardSheet: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// The pinned message's text is still being read.
        case loading
        case board(RoomLeaderboard)
        /// Not one row of the message could be read: the sheet offers the message itself instead.
        case unavailable
    }

    public let sequenceId: Int64
    public let content: Content

    public init(sequenceId: Int64, content: Content) {
        self.sequenceId = sequenceId
        self.content = content
    }
}

/// A request to put a failed message's text back into the composer. Each request is distinct, so editing the same
/// text twice still restores it.
public struct RoomComposerRestore: Equatable, Sendable {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// How restored text joins what is already being typed: it fills an empty composer, and otherwise follows the
/// current draft on a new line, so nothing typed since is lost.
public enum RoomComposerDraft {
    public static func restoring(_ text: String, into draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : draft + "\n" + text
    }

    /// What "File as a ticket" posts: the words, marked as a ticket request so the room's ticket keeper files them
    /// (it replies with the ticket's link). Already marked text is left as it is.
    public static func ticketRequest(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("🎫") ? trimmed : "🎫 Ticket: \(trimmed)"
    }

    /// A paste this long is held as an attachment above the field (Carter, #55006), not poured into it.
    /// Carter (10-30): "when I paste a long text it should be much longer before it becomes an attachment".
    public static let pastedBlockLength = 4_000

    /// The block of text that went into the draft at once, when it is long enough to be a paste: what the draft
    /// becomes without it, and the block. Typing and dictation add a little at a time and never come here.
    public static func pastedBlock(from old: String, to new: String, minimum: Int = pastedBlockLength)
        -> (draft: String, block: String)? {
        // Every keystroke asks; a paste of `minimum` characters adds at least that many UTF-8 bytes, so a keystroke
        // is answered without copying the draft (a long draft made typing lag, ticket 7674d10b).
        guard new.utf8.count - old.utf8.count >= minimum else { return nil }
        let oldChars = Array(old)
        let newChars = Array(new)
        guard newChars.count - oldChars.count >= minimum else { return nil }
        var prefix = 0
        while prefix < oldChars.count, oldChars[prefix] == newChars[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldChars.count - prefix, oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }
        let inserted = String(newChars[prefix..<(newChars.count - suffix)])
        guard inserted.count >= minimum else { return nil }
        // A paste over a selection replaced it: the draft keeps what was there.
        return (String(oldChars), inserted)
    }

    /// Where a room's unsent text is kept on the phone, for one account: another account signing in here (after a
    /// forced sign-in, say) never sees or sends it (warden, #298 review).
    public static func savedKey(sessionId: String, account: String) -> String { savedKeyPrefix + account + "|" + sessionId }
    /// The key from before drafts were kept per account: no one can tell whose it is, so it is only ever removed.
    public static func savedKey(sessionId: String) -> String { savedKeyPrefix + sessionId }
    static let savedKeyPrefix = "pocket.draft."

    /// How long a sent text stays saved: long enough for it to be on its way.
    public static let savedAfterSend: TimeInterval = 8

    /// Whether what is in the box is the text just sent coming back (the keyboard writing it back after the box was
    /// emptied): the whole text, or its end of at least three characters. A first keystroke ("I", "a") is new typing
    /// (warden, #262).
    public static func isWrittenBack(_ text: String, sent: String) -> Bool {
        let back = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = sent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !back.isEmpty else { return false }
        return back == whole || (back.count >= 3 && whole.hasSuffix(back))
    }

    /// Whether a change to the box is the text just sent coming back: it lands in one change straight into the emptied
    /// box (`previous` is empty), as the whole sent text or its end. Typing grows from a first keystroke, so a new word
    /// that happens to end the sent text is never taken for it (#298 review).
    public static func isWrittenBack(_ text: String, sent: String, after previous: String) -> Bool {
        previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isWrittenBack(text, sent: sent)
    }

    /// Once a send is confirmed (or given up), its saved text goes, unless newer text was saved since (warden, #262:
    /// a crash just after a delivered send must not bring the text back to be sent twice).
    public static func forgetSaved(sessionId: String, sent: String, in defaults: UserDefaults = .standard) {
        forgetSaved(key: savedKey(sessionId: sessionId), sent: sent, in: defaults)
    }

    /// `forgetSaved` for the text kept under `key` (`savedKey(sessionId:account:)`).
    public static func forgetSaved(key: String, sent: String, in defaults: UserDefaults = .standard) {
        guard let saved = defaults.string(forKey: key) else { return }
        let kept = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        let gone = sent.trimmingCharacters(in: .whitespacesAndNewlines)
        if kept == gone || gone.contains(kept) { defaults.removeObject(forKey: key) }
    }

    /// Every room's saved text, on sign-out: the next person on the phone does not see it. Thread replies' saved text
    /// (`RoomReplyDrafts`) sits under the same prefix and goes with it.
    public static func forgetAllSaved(in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(savedKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// A held block put back into the message as text (Carter, 10-30: "click on a text that became attachment to add
    /// to it or unattach it"): after what was typed, a blank line apart.
    public static func unattaching(_ block: String, into draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? block : draft + "\n\n" + block
    }

    /// What is sent: the typed words, then each held block, a blank line apart.
    public static func outgoing(_ draft: String, blocks: [String]) -> String {
        ([draft.trimmingCharacters(in: .whitespacesAndNewlines)] + blocks)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

/// After a send, the text the keyboard wrote back into the emptied box, if it did. The send's delayed cleanup empties
/// exactly that text, unchanged, and nothing else: words typed since are kept (#298 review).
public struct RoomComposerWriteBack: Equatable {
    public private(set) var text: String?

    public init() {}

    /// A new send: nothing written back yet.
    public mutating func sent() { text = nil }

    /// The box changed from `previous` to `new`; `sent` is the text just sent while it is still fresh (nil after).
    public mutating func changed(from previous: String, to new: String, sent: String?) {
        if let sent, RoomComposerDraft.isWrittenBack(new, sent: sent, after: previous) {
            text = new
        } else {
            text = nil
        }
    }

    /// Whether the delayed cleanup empties the box holding `current`.
    public func clears(_ current: String) -> Bool { text.map { $0 == current } ?? false }
}

/// A message too long to read in the room shows its start and a card that opens the whole of it (Carter, #55006).
public enum LongMessage {
    /// Folded from 1,000 characters: the 11-04 freezes came right after sends of 1,342 and 1,486 characters, which drew
    /// in full under the old 1,500.
    public static let characters = 1_000
    public static let lines = 30
    static let previewLines = 8
    static let previewCharacters = 600

    public static func isLong(_ text: String) -> Bool {
        text.count > characters || text.split(separator: "\n", omittingEmptySubsequences: false).count > lines
    }

    /// The start of the message: its first lines, cut at a line end, with a code block it cuts into closed again.
    public static func preview(_ text: String) -> String {
        var kept: [Substring] = []
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if kept.count >= previewLines || (count + line.count > previewCharacters && !kept.isEmpty) { break }
            kept.append(line)
            count += line.count + 1
        }
        var preview = kept.joined(separator: "\n")
        if preview.count > previewCharacters { preview = String(preview.prefix(previewCharacters)) }
        if preview.components(separatedBy: "```").count % 2 == 0 { preview += "\n```" }
        return preview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a long message shows (its preview, and its length for the card), or nil for one shown whole: what a row's
    /// body asks on every redraw. Each answer reads the whole text, so it is kept per text (Carter's 08:06 freeze on
    /// build 2026103005 stopped in `preview`'s split, inside a row's body).
    public static func shown(_ text: String) -> (preview: String, characters: Int)? {
        let key = text as NSString
        if let known = memo.object(forKey: key) { return known.value }
        let value = isLong(text) ? (preview(text), text.count) : nil
        memo.setObject(Shown(value), forKey: key)
        return value
    }

    private final class Shown {
        let value: (preview: String, characters: Int)?
        init(_ value: (preview: String, characters: Int)?) { self.value = value }
    }

    private static let memo: NSCache<NSString, Shown> = {
        let cache = NSCache<NSString, Shown>()
        cache.countLimit = 2_000
        return cache
    }()
}

/// How a failed row keeps its text. Edit puts it back into the composer, so it needs one; when posting is refused
/// (a viewer, or a room you no longer belong to) there is none, so the row offers Copy and stays.
public enum RoomPendingRecovery: Equatable, Sendable {
    case edit
    case copy

    public init(canPost: Bool) {
        self = canPost ? .edit : .copy
    }
}

/// Link policy for chat text, matching the web (`safeLinkUrl.ts`): http(s) links to a real host, and in-app paths
/// (`/dashboard/sessions/...`), which open on the Senti web origin as the web resolves them. Protocol-relative
/// (`//host`) and backslash (`/\host`) paths, control characters, credentials and every other scheme (tel:, sms:,
/// custom app schemes, javascript:) are shown as plain text.
public enum RoomLinkPolicy {
    /// Where an in-app path opens.
    public static let webOrigin = URL(string: "https://sentinelayer.com")

    public static func isAllowed(_ url: URL) -> Bool {
        resolved(url) != nil
    }

    /// The absolute URL a tap opens, or nil when the link is not tappable.
    public static func resolved(_ url: URL) -> URL? {
        let raw = url.absoluteString
        guard !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        if let scheme = url.scheme?.lowercased() {
            guard scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { return nil }
            return url
        }
        guard raw.hasPrefix("/"), !raw.hasPrefix("//"), !raw.hasPrefix("/\\") else { return nil }
        return webOrigin.flatMap { URL(string: raw, relativeTo: $0)?.absoluteURL }
    }
}

/// A thread's unsent reply, kept on the phone as the room's own box keeps its text (`RoomComposerDraft`): under the
/// room's key for this account, per thread, and per reply when it answers one. Written once typing pauses
/// (`RoomDraftDebouncer`), restored when the thread opens (a new room screen, a relaunch), and let go only once the server
/// has the reply (`forgetSent`), never on a failed send (Carter lost a half-written reply on the web when new replies
/// folded in, #61872). An account keeps at most `limit` of them across its rooms (the one written longest ago goes
/// first), and one not written for `lifetime` is gone.
public struct RoomReplyDrafts {
    /// The room's own saved-text key (`RoomComposerDraft.savedKey(sessionId:account:)`).
    public let base: String
    private let defaults: UserDefaults
    private let now: () -> Date

    /// The most reply drafts one account keeps on the phone.
    public static let limit = 50
    /// How long a reply draft is kept after it was last written: 14 days.
    public static let lifetime: TimeInterval = 14 * 24 * 60 * 60

    public init(base: String, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.base = base
        self.defaults = defaults
        self.now = now
    }

    /// The reply a thread's box answers when it sends: the one chosen, else the one restored text answered, whose row
    /// may not have loaded yet (so an early send still answers it, never the message instead); nil answers the message.
    public static func answering(chosen: String?, restoring: String?) -> String? {
        chosen ?? restoring
    }

    /// Where the reply to `thread` (or to its reply `reply`) is kept.
    public func key(thread: Int64, reply: String?) -> String {
        base + "|thread." + String(thread) + (reply.map { "|reply." + $0 } ?? "")
    }

    /// Which reply the thread's saved text answers, when it answers one.
    private func answeringKey(thread: Int64) -> String { base + "|thread." + String(thread) + "|answering" }

    /// Every reply draft the account keeps, in any room, with when it was last written (seconds since 1970). `base` is
    /// `pocket.draft.<account>|<room>`: the account is what comes before the room.
    private var indexKey: String {
        let prefix = RoomComposerDraft.savedKeyPrefix
        let rest = base.hasPrefix(prefix) ? String(base.dropFirst(prefix.count)) : base
        let account = rest.range(of: "|", options: .backwards).map { String(rest[..<$0.lowerBound]) } ?? rest
        return "pocket.replyDrafts." + account
    }

    private var index: [String: Double] {
        get { defaults.dictionary(forKey: indexKey) as? [String: Double] ?? [:] }
        nonmutating set {
            if newValue.isEmpty { defaults.removeObject(forKey: indexKey) } else { defaults.set(newValue, forKey: indexKey) }
        }
    }

    /// Keeps what is in the thread's reply box. The box answers one thing at a time, so the text moves with it: saved
    /// under the reply it answers now, and gone from where it was before. An empty box keeps nothing.
    public func save(_ text: String, thread: Int64, reply: String?) {
        let previous = defaults.string(forKey: answeringKey(thread: thread))
        if previous != reply { drop(key(thread: thread, reply: previous)) }
        let current = key(thread: thread, reply: reply)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drop(current)
            defaults.removeObject(forKey: answeringKey(thread: thread))
        } else {
            defaults.set(text, forKey: current)
            if let reply {
                defaults.set(reply, forKey: answeringKey(thread: thread))
            } else {
                defaults.removeObject(forKey: answeringKey(thread: thread))
            }
            written(current)
        }
    }

    /// What the thread's box held when it was last written, and the reply it answered; nil when nothing was kept, or
    /// what was kept is older than `lifetime`.
    public func restore(thread: Int64) -> (text: String, reply: String?)? {
        let reply = defaults.string(forKey: answeringKey(thread: thread))
        let current = key(thread: thread, reply: reply)
        if let written = index[current], now().timeIntervalSince1970 - written > Self.lifetime {
            drop(current)
            return nil
        }
        guard let text = defaults.string(forKey: current),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (text, reply)
    }

    /// The server has the reply: its saved text goes, unless newer text was saved since (`RoomComposerDraft.forgetSaved`).
    public func forgetSent(_ sent: String, thread: Int64, reply: String?) {
        let current = key(thread: thread, reply: reply)
        RoomComposerDraft.forgetSaved(key: current, sent: sent, in: defaults)
        guard defaults.string(forKey: current) == nil else { return }
        index[current] = nil
        if reply != nil, defaults.string(forKey: answeringKey(thread: thread)) == reply {
            defaults.removeObject(forKey: answeringKey(thread: thread))
        }
    }

    /// Notes `key` as written now, then lets go of what is past `lifetime` and, past `limit`, the ones written longest
    /// ago.
    private func written(_ key: String) {
        let at = now().timeIntervalSince1970
        var kept = index
        kept[key] = at
        let expired = kept.filter { at - $0.value > Self.lifetime }.map(\.key)
        for gone in expired { kept[gone] = nil }
        let overflow = kept.count > Self.limit
            ? kept.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
                .prefix(kept.count - Self.limit).map(\.key)
            : []
        for gone in overflow { kept[gone] = nil }
        index = kept
        for gone in expired + overflow { remove(gone) }
    }

    /// Takes one draft off the phone and out of the account's list.
    private func drop(_ key: String) {
        remove(key)
        var kept = index
        guard kept[key] != nil else { return }
        kept[key] = nil
        index = kept
    }

    /// A draft's text, and its thread's note of the reply it answered when that note is about it.
    private func remove(_ key: String) {
        defaults.removeObject(forKey: key)
        guard let marker = key.range(of: "|reply.", options: .backwards) else { return }
        let answering = String(key[..<marker.lowerBound]) + "|answering"
        if defaults.string(forKey: answering) == String(key[marker.upperBound...]) {
            defaults.removeObject(forKey: answering)
        }
    }
}

/// Writes a moment after the last change instead of on every keystroke: `schedule` replaces what is waiting, and
/// `flush` writes it at once (the thread closing, a reply being sent). Used on the main thread.
public final class RoomDraftDebouncer {
    /// How long typing pauses before the text is written.
    public static let delay: TimeInterval = 0.3
    private let delay: TimeInterval
    private var pending: (() -> Void)?
    private var work: DispatchWorkItem?

    public init(delay: TimeInterval = RoomDraftDebouncer.delay) {
        self.delay = delay
    }

    /// `write` runs once typing has paused for `delay`, unless another write replaces it first.
    public func schedule(_ write: @escaping () -> Void) {
        work?.cancel()
        pending = write
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Writes what is waiting now, if anything is.
    public func flush() {
        work?.cancel()
        work = nil
        let write = pending
        pending = nil
        write?()
    }
}
