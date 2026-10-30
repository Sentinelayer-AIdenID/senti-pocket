import Foundation

/// Where each logo sits in who is here (Carter, 10-30: "Make it start curving around 6 and allow it to for a full
/// circumference from there that goes all the way to the back ... you can scroll that circle to see who's here or it
/// scrolls by itself, it's endless and can add as many as possible"). Up to `arcLimit` logos sit on a gentle arc around
/// the online count; past that they go round a full ring that turns, the front ones large and bright, the back ones
/// small and dim.
public enum PresenceRingLayout {
    /// Up to this many sit on the arc; more go round the ring.
    public static let arcLimit = 6
    /// The angle between neighbours on the arc, in radians.
    public static let arcStep = 20.0 * Double.pi / 180

    public struct Spot: Equatable, Sendable {
        /// Across, from the middle, in points.
        public let x: Double
        /// Up or down from the middle, in points: the back of the ring sits higher.
        public let y: Double
        /// 1 at the very front, -1 at the very back.
        public let depth: Double
        public let scale: Double
        public let opacity: Double
    }

    public static func isRing(_ count: Int) -> Bool { count > arcLimit }

    /// How far across the ring or arc reaches.
    public static func radius(_ count: Int) -> Double { isRing(count) ? 62 : 84 }

    /// Where item `index` of `count` sits. On the arc the online count takes the middle slot, so the logos sit either
    /// side of it; on the ring they go round it, turned by `rotation` (radians).
    public static func spot(index: Int, count: Int, rotation: Double) -> Spot {
        let angle: Double
        let radius = Self.radius(count)
        if isRing(count) {
            angle = rotation + 2 * Double.pi * Double(index) / Double(count)
        } else {
            let middle = count / 2
            let slot = index < middle ? index : index + 1
            angle = (Double(slot) - Double(middle)) * arcStep
        }
        let depth = cos(angle)
        let nearness = (depth + 1) / 2
        let y = isRing(count) ? -(1 - nearness) * 18 + 8 * nearness : -(1 - depth) * 24
        return Spot(x: radius * sin(angle), y: y, depth: depth, scale: 0.55 + 0.45 * nearness,
                    opacity: 0.3 + 0.7 * nearness)
    }

    /// The item at the front of the ring, for the tick as each one passes (nil on the arc, which does not turn).
    public static func frontIndex(count: Int, rotation: Double) -> Int? {
        guard isRing(count) else { return nil }
        let step = 2 * Double.pi / Double(count)
        let turns = Int((-rotation / step).rounded())
        return ((turns % count) + count) % count
    }
}
