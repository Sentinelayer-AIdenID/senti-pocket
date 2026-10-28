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
    public let reactions: RoomChatReactions?
    public let attachments: [RoomAttachmentChip]
    /// Who has viewed this revision, once the room has read it.
    public let views: RoomChatViews?

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
        views: RoomChatViews? = nil
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

    public let chips: [Chip]
    /// "Acked by a, b, c +N" (web parity: three names, sorted).
    public let ackedBy: String?
    /// "Working: a, b".
    public let working: String?
    public let replyCount: Int
    public let isPinned: Bool

    public init(chips: [Chip] = [], ackedBy: String? = nil, working: String? = nil, replyCount: Int = 0, isPinned: Bool = false) {
        self.chips = chips
        self.ackedBy = ackedBy
        self.working = working
        self.replyCount = replyCount
        self.isPinned = isPinned
    }

    public var isEmpty: Bool { chips.isEmpty && ackedBy == nil && working == nil && replyCount == 0 && !isPinned }

    /// Builds the line from raw counts and actors, in the web order and wording.
    public static func make(
        counts: [String: Int],
        actorsByType: [String: [String]],
        activeOwners: [String],
        likedByViewer: Bool,
        dislikedByViewer: Bool,
        replyCount: Int,
        isPinned: Bool
    ) -> RoomChatReactions {
        let order = ["ack", "like", "dislike", "disregard"]
        let chips = order.compactMap { type -> Chip? in
            guard let count = counts[type], count > 0 else { return nil }
            let mine = (type == "like" && likedByViewer) || (type == "dislike" && dislikedByViewer)
            return Chip(type: type, count: count, isMine: mine)
        }
        return RoomChatReactions(
            chips: chips,
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

/// A message you sent that the room has not echoed back yet.
public struct RoomChatPendingRow: Equatable, Identifiable, Sendable {
    public enum Status: Equatable, Sendable {
        case sending
        /// Accepted by Senti; waiting for the room to show it.
        case sent
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

    public init(
        id: String,
        authorName: String,
        isHuman: Bool,
        isOwn: Bool,
        text: String,
        date: Date?,
        isEdited: Bool,
        views: RoomChatViews? = nil
    ) {
        self.id = id
        self.authorName = authorName
        self.isHuman = isHuman
        self.isOwn = isOwn
        self.text = text
        self.date = date
        self.isEdited = isEdited
        self.views = views
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

    public init(
        parent: RoomChatMessageRow,
        replies: [RoomChatReplyRow],
        pending: [RoomChatPendingRow] = [],
        isLoading: Bool = false,
        failureText: String? = nil,
        canReply: Bool = false,
        maximumReplyLength: Int? = nil
    ) {
        self.parent = parent
        self.replies = replies
        self.pending = pending
        self.isLoading = isLoading
        self.failureText = failureText
        self.canReply = canReply
        self.maximumReplyLength = maximumReplyLength
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

    public init(
        sequenceId: Int64,
        replies: [RoomChatReplyRow],
        pending: [RoomChatPendingRow] = [],
        isLoading: Bool = false,
        failureText: String? = nil,
        canReply: Bool = false,
        maximumReplyLength: Int? = nil
    ) {
        self.sequenceId = sequenceId
        self.replies = replies
        self.pending = pending
        self.isLoading = isLoading
        self.failureText = failureText
        self.canReply = canReply
        self.maximumReplyLength = maximumReplyLength
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
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let have = formatter.string(from: NSNumber(value: count)) ?? String(count)
        let limit = formatter.string(from: NSNumber(value: maximumLength)) ?? String(maximumLength)
        return "Too long to send: \(have) of \(limit) characters."
    }
}

/// Everything the room screen renders, built from the coordinator's timeline in one pure step.
public struct RoomChatPresentationState: Equatable, Sendable {
    public let sessionId: String
    public let title: String
    public let rows: [RoomChatRow]
    public let isLoadingInitial: Bool
    public let canLoadOlder: Bool
    public let isLoadingOlder: Bool
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
    public let thread: RoomChatThreadState?
    /// Counts links whose message could not be loaded (more than ten pages back, not a chat row, or gone). Each
    /// increase takes the reader to the latest messages.
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

    /// Same-author rows closer together than this share one header.
    public static let groupingWindow: TimeInterval = 5 * 60

    public init(
        sessionId: String,
        title: String,
        messages: [RoomChatMessageInput],
        ownAuthorIds: Set<String> = [],
        unreadDividerSequence: Int64? = nil,
        unreadCount: Int = 0,
        isLoadingInitial: Bool = false,
        canLoadOlder: Bool = false,
        isLoadingOlder: Bool = false,
        connection: RoomConnectionState = .connecting,
        composingAgents: [String] = [],
        failure: SessionLoadFailure? = nil,
        pending: [RoomChatPendingRow] = [],
        composer: RoomComposerState = .hidden,
        canReact: Bool = false,
        thread threadInput: RoomChatThreadInput? = nil,
        focusFallbackCount: Int = 0,
        focusSequenceId: Int64? = nil,
        mentionCandidates: [MentionCandidate] = [],
        breakouts: [String: RoomBreakoutCard] = [:],
        attachmentPreviews: [String: Data] = [:],
        presence: RoomChatPresence? = nil,
        calendar: Calendar = .current
    ) {
        self.sessionId = sessionId
        self.title = title
        self.isLoadingInitial = isLoadingInitial
        self.canLoadOlder = canLoadOlder
        self.isLoadingOlder = isLoadingOlder
        self.unreadCount = max(unreadCount, 0)
        self.connection = connection
        self.composingAgents = composingAgents
        self.failure = failure
        self.ownMentionHandles = RoomChatPresentationState.mentionHandles(forOwnAuthorIds: ownAuthorIds)
        let protectedFailure = failure?.suppressesProtectedContent == true
        self.pending = protectedFailure ? [] : pending
        self.composer = protectedFailure ? .hidden : composer
        self.canReact = protectedFailure ? false : canReact
        self.focusFallbackCount = focusFallbackCount
        self.focusSequenceId = protectedFailure ? nil : focusSequenceId
        self.mentionCandidates = protectedFailure ? [] : mentionCandidates
        self.breakouts = protectedFailure ? [:] : breakouts
        self.attachmentPreviews = protectedFailure ? [:] : attachmentPreviews
        self.presence = protectedFailure ? nil : presence

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
        let ordered = messages.sorted { $0.sequenceId < $1.sequenceId }
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
            if let divider = unreadDividerSequence, !placedDivider, input.sequenceId >= divider {
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
                views: input.views
            )))
            if input.kind == .message, let date = input.date {
                run = (input.authorId, date)
            } else {
                run = nil
            }
        }
        self.rows = rows
        if let threadInput, !protectedFailure,
           let parent = rows.lazy.compactMap({ row -> RoomChatMessageRow? in
               if case .message(let message) = row, message.sequenceId == threadInput.sequenceId { return message }
               return nil
           }).first {
            self.thread = RoomChatThreadState(
                parent: parent,
                replies: threadInput.replies,
                pending: threadInput.pending,
                isLoading: threadInput.isLoading,
                failureText: threadInput.failureText,
                canReply: threadInput.canReply,
                maximumReplyLength: threadInput.maximumReplyLength
            )
        } else {
            self.thread = nil
        }
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

/// What the room screen can ask for.
public enum RoomChatIntent: Equatable, Sendable {
    case loadOlder
    case readerAtBottom(Bool)
    case retry
    case jumpToMessage(sequenceId: Int64)
    case sendMessage(text: String)
    case retrySend(clientId: String)
    case discardSend(clientId: String)
    case react(sequenceId: Int64, type: String)
    case openThread(sequenceId: Int64)
    case closeThread
    case sendReply(sequenceId: Int64, text: String)
    /// The view brought `focusSequenceId` into view.
    case focusHandled
    /// Open a breakout started from this room (the screen navigates; the room keeps running).
    case openBreakout(childSessionId: String)
    /// Open a file attached to a message, full size.
    case openAttachment(attachmentId: String)
    /// An image attachment came into view: load its small preview if it has none.
    case attachmentAppeared(attachmentId: String)
    /// A message (by event id) or a reply (by action id) came on screen or left it, for read receipts.
    case messageOnScreen(id: String, isOnScreen: Bool)
    case replyOnScreen(id: String, isOnScreen: Bool)
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
