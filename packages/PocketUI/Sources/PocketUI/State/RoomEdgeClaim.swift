#if canImport(SwiftUI)
import SwiftUI

/// A drag from the screen's left edge that the app's side panel has taken: it opens the panel, the room following the
/// finger (Carter, 11-06). A room row's swipe to reply leaves such a drag alone. Told, never watched: a row reads it
/// only while a drag goes, so taking or letting go of a drag draws nothing.
public final class RoomEdgeClaim {
    public var isClaimed = false

    public init() {}
}

private struct RoomEdgeClaimKey: EnvironmentKey {
    static let defaultValue: RoomEdgeClaim? = nil
}

public extension EnvironmentValues {
    /// The side panel's claim on a drag from the left edge; nil where there is no side panel.
    var roomEdgeClaim: RoomEdgeClaim? {
        get { self[RoomEdgeClaimKey.self] }
        set { self[RoomEdgeClaimKey.self] = newValue }
    }
}

/// Whether a drag on a room row is its swipe to reply: a mostly sideways drag to the right, never one that starts on a
/// strip of photos (it scrolls the strip, #336), nor one the side panel's left edge has taken (`RoomEdgeClaim`).
public enum RoomRowSwipe {
    public static func tracks(translation: CGSize, start: CGPoint, sideScrolls: [CGRect], edgeClaimed: Bool) -> Bool {
        !edgeClaimed && translation.width > 0 && abs(translation.width) > abs(translation.height) * 1.8
            && !sideScrolls.contains(where: { $0.contains(start) })
    }
}
#endif
