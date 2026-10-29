import Foundation
import PocketContracts

/// One room row as the app hands it to PocketUI. The app maps its sync-layer rows into this so PocketUI stays
/// independent of the transport package.
public struct RoomChatMessageInput: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case message
        case checkpoint
        case memberJoined
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
        date: Date? = nil
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

/// Whether the composer can post, and why not when it cannot.
public struct RoomComposerState: Equatable, Sendable {
    public let canPost: Bool
    public let disabledReason: String?
    /// The longest message the API accepts, in characters; nil when there is no known limit.
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
        let count = draft.trimmingCharacters(in: .whitespacesAndNewlines).count
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

        // Protected content never renders beside an auth or access failure.
        guard failure?.suppressesProtectedContent != true else {
            self.rows = []
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
                showsHeader: !continuesRun
            )))
            if input.kind == .message, let date = input.date {
                run = (input.authorId, date)
            } else {
                run = nil
            }
        }
        self.rows = rows
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
}

/// Link policy for chat text, matching the web (`safeLinkUrl.ts`): only http(s) links and in-app paths are
/// tappable. Anything else (tel:, sms:, custom app schemes, javascript:) is shown as plain text.
public enum RoomLinkPolicy {
    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "https" || scheme == "http" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }
}
