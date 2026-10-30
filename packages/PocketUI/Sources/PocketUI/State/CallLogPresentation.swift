import Foundation

/// One call in "Calls & briefings" (Carter, 10-30: "there should be an upcoming call event or past ones like when I
/// called yall and the details I asked for"): a voice room you started, or a ring to or from your phone.
public struct CallLogRow: Identifiable, Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        /// You called (a voice room, or a ring you made).
        case outgoing
        /// You were called.
        case incoming
    }

    public let id: String
    public let direction: Direction
    /// "pocket-forge", "pocket-forge and claude-warden", "Meeting", or for a ring the other side.
    public let title: String
    public let roomTitle: String
    public let startedAt: Date?
    /// "2 min 40 s · 7 turns", "Missed", "Declined", "In progress" …
    public let detail: String
    public let isMissed: Bool
    public let isOngoing: Bool
    /// What the agents said the call decided, each by its author.
    public let summaries: [Summary]
    /// The call's measured timings, as the end message gave them.
    public let timings: String?
    /// Why a ring was made.
    public let reason: String?
    public let hasTranscript: Bool
    /// Where the call is in its room, to open it there.
    public let canOpen: Bool

    public struct Summary: Equatable, Sendable {
        public let author: String
        public let text: String

        public init(author: String, text: String) {
            self.author = author
            self.text = text
        }
    }

    public init(id: String, direction: Direction, title: String, roomTitle: String, startedAt: Date?, detail: String,
                isMissed: Bool = false, isOngoing: Bool = false, summaries: [Summary] = [], timings: String? = nil,
                reason: String? = nil, hasTranscript: Bool = false, canOpen: Bool = true) {
        self.id = id
        self.direction = direction
        self.title = title
        self.roomTitle = roomTitle
        self.startedAt = startedAt
        self.detail = detail
        self.isMissed = isMissed
        self.isOngoing = isOngoing
        self.summaries = summaries
        self.timings = timings
        self.reason = reason
        self.hasTranscript = hasTranscript
        self.canOpen = canOpen
    }
}

public struct CallLogState: Equatable, Sendable {
    public var rows: [CallLogRow]
    public var isLoading: Bool
    /// False until the server has the call log (an older server): the screen says so instead of an empty list.
    public var isAvailable: Bool
    public var canLoadMore: Bool
    public var notice: String?

    public init(rows: [CallLogRow] = [], isLoading: Bool = false, isAvailable: Bool = true, canLoadMore: Bool = false,
                notice: String? = nil) {
        self.rows = rows
        self.isLoading = isLoading
        self.isAvailable = isAvailable
        self.canLoadMore = canLoadMore
        self.notice = notice
    }
}

public enum CallLogIntent: Equatable, Sendable {
    case refresh
    case loadMore
    /// Open the call in its room, at the message that ended it.
    case open(id: String)
    /// Read the call's summaries aloud.
    case listen(id: String)
    case close
}
