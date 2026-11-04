import CoreGraphics

/// Where the reader is in a room, read from the scroll view's own geometry (iOS 18 and later, `RoomChatView`).
///
/// Reading up a busy room, people were moved by arriving messages and taken to the bottom by their own sends, with no
/// say in it (Carter, #61581). So:
/// - "at the bottom" is exact: the end of the room within `atBottomDistance` of the bottom of the screen. It is not a
///   1-point marker at the end of a lazy list, which the list drew while it was still out of sight under the composer;
/// - only the list moving up takes the reader away from the bottom. The end moving away from a reader who is there (a
///   message arriving, a row growing, the keyboard rising) is followed;
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

    /// What a new reading says about the reader.
    public enum Change: Equatable, Sendable {
        case none
        /// The end of the room came into view: the reader is at the bottom.
        case endInView
        /// The list moved up and the end is out of view: the reader left the bottom.
        case leftBottom
        /// The end moved further away while the list did not move up: a reader at the bottom follows it there.
        case endMovedAway
    }

    /// Movement under half a point is layout rounding, not the list moving.
    static let still: CGFloat = 0.5

    public static func change(from old: Reading, to new: Reading) -> Change {
        if new.endInView { return old.endInView ? .none : .endInView }
        if new.offset < old.offset - still { return .leftBottom }
        if new.distanceToEnd > old.distanceToEnd + still { return .endMovedAway }
        return .none
    }
}

/// The jump button's words: an arrow, and how many messages arrived since the reader left the bottom (Carter, #61581:
/// tell him what came, and let him decide).
public enum RoomJumpToLatest {
    /// More than this shows as "99+".
    public static let largestCount = 99

    /// "12 new", "99+ new", or nil with nothing new (the plain arrow).
    public static func badge(newCount: Int) -> String? {
        guard newCount > 0 else { return nil }
        return newCount > largestCount ? "\(largestCount)+ new" : "\(newCount) new"
    }

    /// What VoiceOver reads.
    public static func accessibilityLabel(newCount: Int) -> String {
        switch newCount {
        case ..<1: return "Jump to latest"
        case 1: return "1 new message, jump to latest"
        case ...largestCount: return "\(newCount) new messages, jump to latest"
        default: return "More than \(largestCount) new messages, jump to latest"
        }
    }
}
