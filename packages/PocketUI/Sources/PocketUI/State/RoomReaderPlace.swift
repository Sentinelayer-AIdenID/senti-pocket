import CoreGraphics

/// Where the reader is in a room, read from the scroll view's own geometry (iOS 18 and later, `RoomChatView`).
///
/// Reading up a busy room, people were moved by arriving messages and taken to the bottom by their own sends, with no
/// say in it (Carter, #61581). So:
/// - "at the bottom" is exact: the end of the room within `atBottomDistance` of the bottom of the screen. It is not a
///   1-point marker at the end of a lazy list, which the list drew while it was still out of sight under the composer;
/// - only the list moving up takes the reader away from the bottom, measured from where it was the last time the end was
///   in view, by any movement at all (a coast near its end moves a third of a point a frame, under the half point the
///   room once took for rounding). The end moving away from a reader who is there (a message arriving, a row growing,
///   the keyboard rising) is followed, and until the end is back in view the list moving up is the room settling its
///   rows, not the reader, unless the reader is moving it or it moves further up than settling ever does;
/// - a reader away from the bottom is never moved, and the jump button says how many messages arrived meanwhile.
public enum RoomReaderPlace {
    /// The end of the room closer than this to the bottom of the screen is the reader at the bottom.
    public static let atBottomDistance: CGFloat = 24

    /// One reading of the scroll view, in its own points.
    public struct Reading: Equatable, Sendable {
        /// How far the end of the room is below the bottom of what can be read (negative when pulled past it).
        public let distanceToEnd: CGFloat
        /// How far the list is scrolled from its top.
        public let offset: CGFloat

        public init(distanceToEnd: CGFloat, offset: CGFloat) {
            self.distanceToEnd = distanceToEnd
            self.offset = offset
        }

        /// The end of the room is in view.
        public var endInView: Bool { distanceToEnd < RoomReaderPlace.atBottomDistance }
    }

    /// What a reading says about the reader.
    public enum Change: Equatable, Sendable {
        case none
        /// The end of the room came into view: the reader is at the bottom.
        case endInView
        /// The list moved up from where it was at the bottom, and the end is out of view: the reader left the bottom.
        case leftBottom
        /// The same, but not by the reader's hand (dragging the list, or its coast): it counts once a later reading
        /// still shows it, on the next frame. SwiftUI lays a list out several times within one frame, and one pass can
        /// show it a little up for a moment.
        case mayHaveLeft
        /// The end is out of view while the list did not move up: a reader at the bottom follows it there.
        case endMovedAway
    }

    /// A difference this small in where the list is scrolled is the same place (arithmetic, not movement). A list moves
    /// at least a pixel at a time: a third of a point on the phone.
    static let samePlace: CGFloat = 0.01

    /// While arrivals push the end below, SwiftUI settling the lazy list's rows moved the list up 15 and 35 points
    /// (measured, 60 messages a second). A scroll the reader makes without touching the list moves it about a page:
    /// VoiceOver's three-finger scroll, a tap on the status bar, a keyboard's Page Up. The list moving up further than
    /// this from the furthest down it has been since the end was in view is the reader, however it moved.
    public static let settlingReach: CGFloat = 120

    /// A reading as the room acts on it: the room takes a new reading only when this changes (`RoomChatView`), not
    /// with every point the list moves.
    public enum Sight: Equatable, Sendable {
        /// The end of the room is in view.
        case endInView
        /// The end is out of view, and the list moved up from where it was the last time the end was in view.
        case movedUp
        /// The end is out of view, and the list did not move up: the end moved away (or the reader was elsewhere).
        case endBelow
    }

    /// Which of the scroll view's readings the room takes (acts on, once the frame is done): one that shows something
    /// other than the last one taken, not every point the list moves. A follow to the bottom sets the last one aside,
    /// so where it lands is taken whatever it shows: a follow that goes by the heights the list estimates for rows it
    /// has not drawn can stop short with the end still below (102 to 436 points short in a burst at 60 a second),
    /// which looks like the reading that made the follow, and would never be followed again.
    public struct Taking: Equatable, Sendable {
        /// What the last reading taken showed; nil once a follow set it aside, until the next is taken.
        public private(set) var lastTaken: Sight?

        public init() {}

        /// Whether a reading that shows `sight` is taken.
        public func takes(_ sight: Sight) -> Bool { sight != lastTaken }

        /// A reading was taken.
        public mutating func took(_ sight: Sight) { lastTaken = sight }

        /// A follow to the bottom was made: where it lands is taken, whatever it shows.
        public mutating func followMade() { lastTaken = nil }
    }

    /// The room's own scroll to its end (a follow, the jump button) and the moment just after it lands, while SwiftUI
    /// settles the rows it measured on its way and moves the list by itself (up to 186 pt at once in a burst, in CI):
    /// the list moving up then is not the reader unless their hand is on it (`Tracker.see`, `ownScroll`). The moment
    /// ends at the earlier of `stillFrames` still frames after the scroll landed and `limit` after it started (warden),
    /// so a page up not by touch just after it (VoiceOver, a keyboard's Page Up) still leaves the bottom.
    public struct OwnScroll: Equatable, Sendable {
        public static let limit: TimeInterval = 1.5
        public static let stillFrames = 2
        private var started: TimeInterval?
        private var landed = false
        private var still = 0

        public init() {}

        /// The room's own scroll started (or goes on: the first start counts for `limit`).
        public mutating func start(at time: TimeInterval) {
            if started == nil { started = time }
            landed = false
            still = 0
        }

        /// It landed.
        public mutating func land() {
            landed = true
            still = 0
        }

        /// The reader took the list: the moment is over.
        public mutating func end() {
            started = nil
            landed = false
            still = 0
        }

        /// A frame after it landed: the list moved in it, or not.
        public mutating func frame(moved: Bool) {
            guard landed else { return }
            still = moved ? 0 : still + 1
        }

        /// Whether a reading at `time` is still in the moment.
        public mutating func exempts(at time: TimeInterval) -> Bool {
            guard let started else { return false }
            guard time - started < Self.limit, !(landed && still >= Self.stillFrames) else {
                end()
                return false
            }
            return true
        }
    }

    /// The reader's place, kept from reading to reading. Readings are seen while the list is laid out (`see`, which
    /// only notes where the list was the last time the end was in view) and taken once the frame is done (`read`).
    public struct Tracker: Equatable, Sendable {
        /// The reader is at the bottom.
        public private(set) var atBottom: Bool
        /// Where the list was the last time the end was in view: leaving the bottom is measured from here, not from the
        /// last frame (a coast that ends 24 to 45 points up moves too little from one frame to the next to count).
        public private(set) var bottomOffset: CGFloat?
        /// The end went out of view without the list moving up (a message arriving, a row growing). Until it is in view
        /// again, the list moving up is not the reader leaving: while a burst arrives faster than the room follows,
        /// SwiftUI settles the lazy list's rows and moves the list up by itself, 15 and 35 points at a time at 60
        /// messages a second, and a reader taken for gone was never followed again. The reader moving the list
        /// (dragging it, or its coast) still leaves, and so does the list moving up further than `settlingReach`.
        public private(set) var endPushedDown = false
        /// The last reading read showed the list moved up, not by the reader's hand (`Change.mayHaveLeft`).
        public private(set) var leaveSeen = false
        /// The furthest down the list has been since the end was last in view (the room's follows move it down).
        public private(set) var deepestOffset: CGFloat?

        public init(atBottom: Bool = true) {
            self.atBottom = atBottom
        }

        /// The room's own decision about the reader's place (it opened at the unread line, the reader was taken to a
        /// message, the latest is shown). Put at the bottom by the room, the list is on its way there: where it was
        /// before is no longer where it left from.
        public mutating func set(atBottom: Bool) {
            self.atBottom = atBottom
            if atBottom {
                bottomOffset = nil
                deepestOffset = nil
            }
        }

        /// What a reading is, noting where the list is while the end is in view. `readerMoving`: the reader is
        /// dragging the list, or it is coasting from their drag. `ownScroll`: the room's own scroll to its end is on its
        /// way or settling (`OwnScroll`): the list moving then is not the reader unless their hand is on it, and where
        /// it is becomes where leaving is measured from.
        public mutating func see(_ reading: Reading, readerMoving: Bool = false, ownScroll: Bool = false) -> Sight {
            if reading.endInView {
                bottomOffset = reading.offset
                deepestOffset = reading.offset
                endPushedDown = false
                return .endInView
            }
            if ownScroll, !readerMoving {
                deepestOffset = reading.offset
                if bottomOffset != nil { bottomOffset = reading.offset }
                endPushedDown = true
                return .endBelow
            }
            let deepest = max(deepestOffset ?? reading.offset, reading.offset)
            deepestOffset = deepest
            // Further up than the room's settling ever moves it: the reader, scrolling without touching the list.
            if deepest - reading.offset > RoomReaderPlace.settlingReach { return .movedUp }
            guard let bottomOffset else {
                // Put at the bottom by the room, with the end not yet in view since: the reader moving the list then is
                // not followed against their hand.
                if readerMoving { return .movedUp }
                endPushedDown = true
                return .endBelow
            }
            if reading.offset < bottomOffset - RoomReaderPlace.samePlace, readerMoving || !endPushedDown {
                return .movedUp
            }
            endPushedDown = true
            return .endBelow
        }

        /// What `reading` changes. `mayBeAtBottom` is false while the end in view is not the live room's bottom (a
        /// window further back) or a message the reader was taken to holds them.
        public mutating func read(_ reading: Reading, mayBeAtBottom: Bool = true, readerMoving: Bool = false,
                                  ownScroll: Bool = false) -> Change {
            let sight = see(reading, readerMoving: readerMoving, ownScroll: ownScroll)
            let seenBefore = leaveSeen
            leaveSeen = false
            switch sight {
            case .endInView:
                guard !atBottom, mayBeAtBottom else { return .none }
                atBottom = true
                return .endInView
            case .movedUp:
                guard atBottom else { return .none }
                guard readerMoving || seenBefore else {
                    leaveSeen = true
                    return .mayHaveLeft
                }
                atBottom = false
                return .leftBottom
            case .endBelow:
                return atBottom ? .endMovedAway : .none
            }
        }
    }
}

/// The jump button's words: an arrow, and how many messages arrived since the reader left the bottom (Carter, #61581:
/// tell him what came, and let him decide). With messages waiting it takes the reader to the first of them, as the web
/// room's does; with none, to the latest.
public enum RoomJumpToLatest {
    /// More than this shows as "99+".
    public static let largestCount = 99

    /// "12 new", "99+ new", or nil with nothing new (the plain arrow).
    public static func badge(newCount: Int) -> String? {
        guard newCount > 0 else { return nil }
        return newCount > largestCount ? "\(largestCount)+ new" : "\(newCount) new"
    }

    /// What VoiceOver reads (the web room's words).
    public static func accessibilityLabel(newCount: Int) -> String {
        switch newCount {
        case ..<1: return "Jump to latest"
        case 1: return "1 new message, jump to the first one"
        case ...largestCount: return "\(newCount) new messages, jump to the first one"
        default: return "More than \(largestCount) new messages, jump to the first one"
        }
    }

    /// What VoiceOver says when messages arrive below a reader up the room: "3 new messages".
    public static func arrivalAnnouncement(newCount: Int) -> String? {
        guard newCount > 0 else { return nil }
        switch newCount {
        case 1: return "1 new message"
        case ...largestCount: return "\(newCount) new messages"
        default: return "More than \(largestCount) new messages"
        }
    }
}
