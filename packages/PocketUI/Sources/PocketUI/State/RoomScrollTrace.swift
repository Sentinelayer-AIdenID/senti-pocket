import Foundation

/// When the room takes its scroll view's readings (`RoomChatView`). A reading is seen while the list is laid out; if the
/// room acted on it there (a follow, the reader's place), the list would change again in the same frame, and SwiftUI
/// warns ("tried to update multiple times per frame"). So a reading is only kept, and taken when the screen next
/// draws a frame. This counts, once started, the readings taken, those taken while the scroll view's geometry was
/// being read (always none), and the follows to the bottom made. Read by the hosted `RoomReaderStaysPutTests`; nothing
/// is counted until they start it.
public enum RoomScrollTrace {
    private static let lock = NSLock()
    private static var counting = false
    private static var readingGeometry = false
    private static var taken = 0
    private static var takenWhileReading = 0
    private static var follows = 0
    private static var landings = 0
    private static var landingsMoved = 0
    private static var largestSnap: CGFloat = 0
    private static var focused: [String] = []

    /// The scroll view's geometry is read: `body` runs while the list is laid out. Main thread only.
    public static func whileReadingGeometry(_ body: () -> Void) {
        lock.lock()
        let wasReading = readingGeometry
        readingGeometry = true
        lock.unlock()
        body()
        lock.lock()
        readingGeometry = wasReading
        lock.unlock()
    }

    /// A kept reading was taken. Main thread only.
    public static func readingTaken() {
        lock.lock()
        defer { lock.unlock() }
        guard counting else { return }
        taken &+= 1
        if readingGeometry { takenWhileReading &+= 1 }
    }

    /// The room scrolled to its bottom to follow it. Main thread only.
    public static func followMade() {
        lock.lock()
        defer { lock.unlock() }
        guard counting else { return }
        follows &+= 1
    }

    /// The room's own scroll to its end landed: UIKit put the list the last `snap` points to where the bottom marker
    /// rests, at once, and SwiftUI's scroll to the marker after it moved the list by `swiftUIMoved` points (it must be
    /// none: one that moved the list after UIKit's scroll built every row of the room). Main thread only.
    public static func listLanded(snap: CGFloat, swiftUIMoved: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        guard counting else { return }
        landings &+= 1
        largestSnap = max(largestSnap, abs(snap))
        if abs(swiftUIMoved) > 0.5 { landingsMoved &+= 1 }
    }

    /// VoiceOver's focus was put on a row after the room's own scroll. Main thread only.
    public static func voiceOverFocused(on rowId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard counting else { return }
        focused.append(rowId)
    }

    /// Landings of the room's own scroll since `start()`, those SwiftUI's scroll moved after UIKit's, the largest
    /// step put at once where one landed, and the rows VoiceOver's focus was put on.
    public static var listLandings: (all: Int, movedBySwiftUI: Int, largestSnap: CGFloat, voiceOverFocus: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (landings, landingsMoved, largestSnap, focused)
    }

    /// Readings taken since `start()`, and those taken while the geometry was being read.
    public static func snapshot() -> (taken: Int, takenWhileReading: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (taken, takenWhileReading)
    }

    /// Follows to the bottom made since `start()`.
    public static var followsMade: Int {
        lock.lock()
        defer { lock.unlock() }
        return follows
    }

    /// Starts counting from nothing (tests).
    public static func start() {
        lock.lock()
        counting = true
        taken = 0
        takenWhileReading = 0
        follows = 0
        landings = 0
        landingsMoved = 0
        largestSnap = 0
        focused = []
        lock.unlock()
    }
}
