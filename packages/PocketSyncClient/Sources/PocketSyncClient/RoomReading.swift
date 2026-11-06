import Foundation

/// What the room list knew about your reading of a room when you opened it, so the room opens where you stopped
/// reading: how many messages you have not read, the first of them, and how far the server holds you have read.
public struct RoomReadMark: Hashable, Sendable {
    public let unreadCount: Int
    public let firstUnreadSequenceId: Int64?
    public let lastReadSequenceId: Int64?

    public init(unreadCount: Int, firstUnreadSequenceId: Int64?, lastReadSequenceId: Int64?) {
        self.unreadCount = max(unreadCount, 0)
        self.firstUnreadSequenceId = firstUnreadSequenceId.flatMap { $0 > 0 ? $0 : nil }
        self.lastReadSequenceId = lastReadSequenceId.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Where the room opens: the first unread message, when there is one to open at. The count includes thread
    /// replies, which have no place in the room of their own: with only replies unread there is no first unread
    /// message, and the room opens at its latest.
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
    /// At the unread line, before this message, further back than the newest page: the room pages back to it, as the
    /// web does (up to five pages in all), then opens at the line. Further back than that, the room opens on the
    /// window around it, as a link does, and newer messages load as you scroll down.
    case unreadFurtherBack(Int64)

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
        return focus == nil ? .unreadFurtherBack(first) : .latest
    }
}

/// What the server answered when told how far you have read a room (`PUT /sessions/{id}/read-cursor`).
public struct RoomReadReceipt: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Your badge cursor moved, or the thread replies so far now count as read.
        case recorded
        /// The server already held this position or a later one, and nothing was left to catch up: nothing changed.
        case unchanged
        /// Only your own signed-in session moves your badge; the server read the room and moved nothing.
        case notRecorded
    }

    /// The server's answer when the credential is not the person's own signed-in session.
    public static let requiresSignedInSession = "read_cursor_requires_signed_in_session"

    public let outcome: Outcome
    /// The furthest position the server holds for you, when it said.
    public let lastReadSequenceId: Int64?
    /// Nothing the badge counts is left after the position, thread replies included.
    public let caughtUp: Bool

    public init(outcome: Outcome, lastReadSequenceId: Int64? = nil, caughtUp: Bool = false) {
        self.outcome = outcome
        self.lastReadSequenceId = lastReadSequenceId.flatMap { $0 > 0 ? $0 : nil }
        self.caughtUp = outcome == .notRecorded ? false : caughtUp
    }

    /// Read from a successful answer's body: `{ok, updated, lastReadSequenceId, actorKind, actorId, caughtUp}`, or
    /// `updated: false` with no actor and a `reason` when the credential cannot move the badge. A body without those
    /// fields (an older server) counts as recorded, as any success did before.
    public init(body: Data?) {
        guard let body, !body.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            self.init(outcome: .recorded)
            return
        }
        let reason = object["reason"] as? String
        let updated = object["updated"] as? Bool
        let actorKind = object["actorKind"] as? String
        let lastRead = (object["lastReadSequenceId"] as? NSNumber)?.int64Value
        let caughtUp = object["caughtUp"] as? Bool ?? false
        let outcome: Outcome
        if reason == Self.requiresSignedInSession || (updated == false && actorKind == nil && reason != nil) {
            outcome = .notRecorded
        } else if updated == false {
            outcome = .unchanged
        } else {
            outcome = .recorded
        }
        self.init(outcome: outcome, lastReadSequenceId: lastRead, caughtUp: caughtUp)
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
    /// The position waiting is one the server may hold already, sent again for the thread replies (`readAgain`).
    private var again = false
    /// The request on its way is such a repeat.
    private var inFlightIsAgain = false

    /// At most one request this often, as the web sends them (sentinelayer-api #1078; the route allows 120 a minute).
    public static let interval: TimeInterval = 1.5
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

    /// Thread replies have no place in the room of their own: the server counts them read when it is told a position
    /// with nothing unread after it, the same position again included. So, at the bottom with replies unread, the
    /// furthest position (or `sequence`, if further) goes again, once, on the same interval as any other.
    public mutating func readAgain(through sequence: Int64) {
        pending = max(furthest, sequence)
        again = true
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
        inFlightIsAgain = again
        pending = nil
        again = false
        lastSentAt = now
        return .send(position)
    }

    /// The room is closing: what is read and not yet sent goes now, whatever the interval or a request on its way.
    public mutating func flush(at now: TimeInterval) -> Int64? {
        guard let position = pending else { return nil }
        inFlight = position
        inFlightIsAgain = again
        pending = nil
        again = false
        lastSentAt = now
        return position
    }

    /// The server took `sequence`, and holds `serverHolds` (its furthest for you) when it said.
    public mutating func sent(_ sequence: Int64, serverHolds: Int64? = nil) {
        if inFlight == sequence { inFlight = nil }
        confirmed = max(confirmed, sequence, serverHolds ?? 0)
        failures = 0
        if let position = pending, position <= confirmed, !again { pending = nil }
    }

    /// Sending `sequence` failed. A failure worth retrying (no connection, the server busy) keeps it waiting, unless
    /// something further is already on its way or waiting, and makes the next wait longer; any other drops it. A
    /// repeat for the thread replies waits again too, unless a newer position is waiting, which reads them as well.
    public mutating func failed(_ sequence: Int64, retryable: Bool) {
        let wasAgain = inFlight == sequence && inFlightIsAgain
        if inFlight == sequence { inFlight = nil }
        guard retryable else { return }
        failures += 1
        if sequence > max(confirmed, inFlight ?? 0) {
            pending = max(pending ?? 0, sequence)
        } else if wasAgain, pending == nil {
            pending = sequence
            again = true
        }
    }
}
