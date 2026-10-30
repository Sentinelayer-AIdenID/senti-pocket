import Foundation

/// Everything waiting on your decision, across your rooms (Carter, 10-30: "Where do you find 'waiting on you' thing
/// list for decisions?"; ticket 931e1d2e). The same list and count as the web, oldest first so nothing rots; one tap
/// answers where the ask offers choices, and an answer anywhere clears it everywhere.
public struct WaitingOnYouRow: Identifiable, Equatable, Sendable {
    /// The ticket the decision is asked in.
    public let id: String
    public let roomId: String
    public let roomTitle: String
    public let title: String
    public let question: String
    /// The answers offered; empty for an open question.
    public let options: [String]
    /// A free answer is allowed besides the options.
    public let custom: Bool
    public let askedAt: Date?
    /// Who asked, as the room names them.
    public let askedBy: String?
    /// This ask, not just its ticket: a ticket that asks again is a new ask, with its own words (warden, #271).
    public let askKey: String

    public init(id: String, roomId: String, roomTitle: String, title: String, question: String, options: [String],
                custom: Bool, askedAt: Date?, askedBy: String?, askKey: String? = nil) {
        self.askKey = askKey ?? id
        self.id = id
        self.roomId = roomId
        self.roomTitle = roomTitle
        self.title = title
        self.question = question
        self.options = options
        self.custom = custom
        self.askedAt = askedAt
        self.askedBy = askedBy
    }

    /// Answered in words: an open question, or "Custom" beside the options.
    public var takesWords: Bool { options.isEmpty || custom }
}

public struct WaitingOnYouState: Equatable, Sendable {
    public var rows: [WaitingOnYouRow]
    /// Everything waiting, beyond what is listed too: the side panel's badge.
    public var total: Int
    public var isLoading: Bool
    /// False until the server has the list (an older server): the side panel then leaves it out.
    public var isAvailable: Bool
    /// Asks whose answer is on its way.
    public var sending: Set<String>
    public var notice: String?

    public init(rows: [WaitingOnYouRow] = [], total: Int = 0, isLoading: Bool = false, isAvailable: Bool = false,
                sending: Set<String> = [], notice: String? = nil) {
        self.rows = rows
        self.total = total
        self.isLoading = isLoading
        self.isAvailable = isAvailable
        self.sending = sending
        self.notice = notice
    }
}

public enum WaitingOnYouIntent: Equatable, Sendable {
    /// Answer an ask: one of its choices, or "Custom" with words, or an open question's words as the choice.
    case answer(id: String, choice: String, detail: String)
    /// Open the ask's ticket in its room.
    case open(id: String)
    case refresh
}
