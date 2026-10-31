import Foundation

/// What the room list knew about your reading of a room when you opened it (Carter, 10-31: "when you click you scroll
/// back to last time you read anything … like discord"): how many messages you have not read, the first of them, and
/// how far the server holds you have read.
public struct RoomReadMark: Hashable, Sendable {
    public let unreadCount: Int
    public let firstUnreadSequenceId: Int64?
    public let lastReadSequenceId: Int64?

    public init(unreadCount: Int, firstUnreadSequenceId: Int64?, lastReadSequenceId: Int64?) {
        self.unreadCount = max(unreadCount, 0)
        self.firstUnreadSequenceId = firstUnreadSequenceId.flatMap { $0 > 0 ? $0 : nil }
        self.lastReadSequenceId = lastReadSequenceId.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Where the room opens: the first unread message, when there is one to open at.
    public var opensAt: Int64? {
        guard unreadCount > 0, let first = firstUnreadSequenceId else { return nil }
        // A first unread at or behind what you have read is a stale count: nothing to open at.
        if let lastRead = lastReadSequenceId, first <= lastRead { return nil }
        return first
    }
}

/// Where a room opens, decided once its newest page has loaded.
public enum RoomOpening: Equatable, Sendable {
    /// At its latest messages, as it always has: nothing unread, or nothing to place the unread line at.
    case latest
    /// At the unread line, before this message, which the loaded rows hold.
    case unreadLine(Int64)
    /// At the unread line, before this message, further back than the newest page: the room opens on the window
    /// around it instead, and newer messages load as you scroll down.
    case unreadWindow(Int64)

    /// - Parameters:
    ///   - mark: what the room list knew when the room was opened.
    ///   - focus: a message the room was opened for (a link or notification). It decides where the room opens; the
    ///     unread line still shows when the loaded rows hold it, and nothing further back is loaded for it.
    ///   - oldestLoaded, newestLoaded: the loaded rows' first and last messages.
    ///   - hasMoreOlder: messages exist before the loaded rows.
    public static func choose(
        mark: RoomReadMark?,
        focus: Int64?,
        oldestLoaded: Int64?,
        newestLoaded: Int64?,
        hasMoreOlder: Bool
    ) -> RoomOpening {
        guard let first = mark?.opensAt, let oldest = oldestLoaded, let newest = newestLoaded else { return .latest }
        // Newer than every message loaded: not a message the room shows (a notice), so there is no line to draw.
        guard first <= newest else { return .latest }
        if first >= oldest || !hasMoreOlder { return .unreadLine(first) }
        return focus == nil ? .unreadWindow(first) : .latest
    }
}

/// How far you have read a room, told to the server forward only and at most once every `interval` (the server keeps
/// the furthest it is told, so a late or repeated request is harmless; this keeps them few). Pure: the room's
/// coordinator runs the timers and the requests.
public struct RoomReadCursor: Equatable, Sendable {
    /// The furthest position the server holds: what the room list said when the room opened, then each it took.
    public private(set) var confirmed: Int64
    /// The furthest position read and not yet sent.
    public private(set) var pending: Int64?
    /// The position on its way to the server.
    public private(set) var inFlight: Int64?
    /// When the last request went out.
    private var lastSentAt: TimeInterval?
    /// Failed requests in a row: each one doubles the wait before the next.
    private var failures = 0

    /// At most one request this often.
    public static let interval: TimeInterval = 2
    /// The longest wait after failures in a row.
    public static let longestWait: TimeInterval = 60

    public init(confirmed: Int64? = nil) {
        self.confirmed = max(confirmed ?? 0, 0)
    }

    /// The furthest position read, sent or confirmed.
    public var furthest: Int64 { max(confirmed, inFlight ?? 0, pending ?? 0) }

    /// You have read the room through `sequence`. Forward only: a position at or behind the furthest one changes
    /// nothing. Whether it moved.
    @discardableResult
    public mutating func read(through sequence: Int64) -> Bool {
        guard sequence > furthest else { return false }
        pending = sequence
        return true
    }

    /// What to do next.
    public enum Step: Equatable, Sendable {
        /// Nothing to send, or a request is on its way (its answer asks again).
        case idle
        /// Send this position now.
        case send(Int64)
        /// Ask again after this long: the last request went out less than `interval` ago (longer after failures).
        case wait(TimeInterval)
    }

    /// What to do at `now`. A send is recorded as on its way: answer it with `sent(_:)` or `failed(_:retryable:)`.
    public mutating func next(at now: TimeInterval) -> Step {
        guard inFlight == nil, let position = pending else { return .idle }
        if let lastSentAt {
            let gap = failures == 0
                ? Self.interval
                : min(Self.interval * pow(2, Double(failures)), Self.longestWait)
            let elapsed = now - lastSentAt
            // A clock set back (elapsed below zero) never parks the send for as long as it moved.
            if elapsed >= 0, elapsed < gap { return .wait(gap - elapsed) }
        }
        inFlight = position
        pending = nil
        lastSentAt = now
        return .send(position)
    }

    /// The room is closing: what is read and not yet sent goes now, whatever the interval or a request on its way.
    public mutating func flush(at now: TimeInterval) -> Int64? {
        guard let position = pending else { return nil }
        inFlight = position
        pending = nil
        lastSentAt = now
        return position
    }

    /// The server took `sequence`.
    public mutating func sent(_ sequence: Int64) {
        if inFlight == sequence { inFlight = nil }
        confirmed = max(confirmed, sequence)
        failures = 0
        if let position = pending, position <= confirmed { pending = nil }
    }

    /// Sending `sequence` failed. A failure worth retrying (no connection, the server busy) keeps it waiting, unless
    /// something further is already on its way or waiting, and makes the next wait longer; any other drops it.
    public mutating func failed(_ sequence: Int64, retryable: Bool) {
        if inFlight == sequence { inFlight = nil }
        guard retryable else { return }
        failures += 1
        if sequence > max(confirmed, inFlight ?? 0) { pending = max(pending ?? 0, sequence) }
    }
}
