import Foundation

/// Whether the reader is at the bottom of the room, settled from the bottom marker coming into view and leaving it.
///
/// The marker reports during layout. Carter's freezes on build 17 (#56316, #56340) wrote the reader's place right
/// there: the room redrew, the redraw moved the marker by a point, the marker wrote the place back, and the main thread
/// went round that loop until iOS ended the app (664,848 row draws in 40 s, the last action each time readerAtBottom).
/// So the marker only reports here, and the place changes on a later turn of the run loop, once the report has held:
/// - a report undone before it lands changes nothing;
/// - leaving the bottom must hold for `leaveDelay`; coming back lands on the next turn;
/// - more than `flapLimit` changes within `flapWindow` stop all changes for `holdTime`, keeping the last settled place,
///   and say so once, for the freeze recorder.
public struct RoomBottomSettle: Equatable, Sendable {
    /// The place the room shows and the coordinator knows.
    public private(set) var atBottom: Bool
    /// The marker's last report (on screen or not); nil before its first.
    public private(set) var markerShown: Bool?
    /// Changes are stopped until this time, after too many in a row.
    public private(set) var heldUntil: TimeInterval?
    /// Counts the marker's reports and the room's own decisions: a check lands only if nothing came after the report
    /// that scheduled it.
    private var reports = 0
    /// When the last changes landed, within the last `flapWindow`.
    private var changes: [TimeInterval] = []

    /// How long the marker must stay gone before the reader counts as away from the bottom.
    public static let leaveDelay: TimeInterval = 0.1
    /// More changes than this within `flapWindow` is the room flapping, not a reader scrolling.
    public static let flapLimit = 10
    public static let flapWindow: TimeInterval = 1
    /// How long changes stop once the room flaps.
    public static let holdTime: TimeInterval = 1

    public init(atBottom: Bool = true) {
        self.atBottom = atBottom
    }

    /// A check to run later, for the report that scheduled it.
    public struct Check: Equatable, Sendable {
        let report: Int
        /// How long to wait before running it: 0 for the next turn of the run loop (coming back to the bottom), or
        /// `leaveDelay` (leaving it).
        public let after: TimeInterval
    }

    /// What a check decided.
    public enum Landing: Equatable, Sendable {
        /// Nothing changes.
        case none
        /// The reader's place changed: show it and tell the coordinator.
        case changed(Bool)
        /// The room flapped: nothing lands until `until`, when the marker's latest report is checked again
        /// (`landLatest`). Said once per hold.
        case held(until: TimeInterval)
    }

    /// The marker came into view or left it. Nothing changes now, since this runs during layout: the check to schedule,
    /// or nil when the report agrees with the settled place (a change undone before it landed is dropped here).
    public mutating func marker(shown: Bool) -> Check? {
        reports &+= 1
        markerShown = shown
        guard shown != atBottom else { return nil }
        return Check(report: reports, after: shown ? 0 : Self.leaveDelay)
    }

    /// A scheduled check: the marker's report lands if nothing came after it and it still differs from the settled
    /// place.
    public mutating func land(_ check: Check, at now: TimeInterval) -> Landing {
        guard check.report == reports else { return .none }
        return landLatest(at: now)
    }

    /// The marker's latest report lands, whatever scheduled the check: what runs when a hold ends.
    public mutating func landLatest(at now: TimeInterval) -> Landing {
        guard let shown = markerShown, shown != atBottom else { return .none }
        if let heldUntil, now < heldUntil { return .none }
        heldUntil = nil
        changes.removeAll { now - $0 >= Self.flapWindow }
        guard changes.count < Self.flapLimit else {
            changes.removeAll()
            heldUntil = now + Self.holdTime
            return .held(until: now + Self.holdTime)
        }
        changes.append(now)
        atBottom = shown
        return .changed(shown)
    }

    /// The room's own decision, outside layout (it opened at the unread line, the reader was taken to a message, a
    /// send brings them down): it takes effect at once, and the marker's earlier reports, landed or waiting, no longer
    /// count. Whether the place changed.
    @discardableResult
    public mutating func set(_ atBottom: Bool) -> Bool {
        reports &+= 1
        markerShown = nil
        guard atBottom != self.atBottom else { return false }
        self.atBottom = atBottom
        return true
    }
}
