#if canImport(SwiftUI)
import SwiftUI

/// Tells when a view of the room's list comes into view and when it leaves it.
///
/// From iOS 18 the list holds every row of its window at once (`RoomRowWindow`): a row is built whether it is on screen
/// or not, so its appearing says nothing. It is in view once `threshold` of it shows in the list: a message 2 points
/// into view is not read and sends no receipt, and a photo below the screen asks for no preview. Before iOS 18 the list
/// is lazy and builds the rows it shows: appearing is coming into view, as it always was.
struct RoomSeen: ViewModifier {
    /// How much of a message must show for it to count as seen: a sliver is not seen, and a message up to five screens
    /// tall (a long one at the largest text size) still is.
    static let messageThreshold = 0.2

    let threshold: Double
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .onScrollVisibilityChange(threshold: threshold) { action($0) }
                // Let go of by the list (a page further on, another room): out of view.
                .onDisappear { action(false) }
        } else {
            content
                .onAppear { action(true) }
                .onDisappear { action(false) }
        }
    }
}

extension View {
    /// Calls `action` with true when this view of the room's list comes into view, and false when it leaves it
    /// (`RoomSeen`).
    func roomSeen(threshold: Double = 0.5, _ action: @escaping (Bool) -> Void) -> some View {
        modifier(RoomSeen(threshold: threshold, action: action))
    }
}
#endif
