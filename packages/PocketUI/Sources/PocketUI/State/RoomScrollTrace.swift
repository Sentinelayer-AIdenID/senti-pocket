import Foundation

/// When the room takes its scroll view's readings (`RoomChatView`). A reading is seen while the list is laid out; if the
/// room acted on it there (a follow, the reader's place), the list would change again in the same frame, and SwiftUI
/// warns ("tried to update multiple times per frame"). So a reading is only kept, and taken when the screen next
/// draws a frame. This counts, once started, the readings taken, those taken while the scroll view's geometry was
/// being read (always none), the follows to the bottom made, and the follows' landings found short of the end that were
/// taken only because the follow set the last reading aside. Read by the hosted `RoomReaderStaysPutTests`; nothing is
/// counted until they start it.
public enum RoomScrollTrace {
    private static let lock = NSLock()
    private static var counting = false
    private static var readingGeometry = false
    private static var taken = 0
    private static var takenWhileReading = 0
    private static var follows = 0
    private static var shortLandings = 0

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

    /// A follow's landing showed the end still below, the same as the reading before the follow: it was taken only
    /// because the follow set that reading aside, and is followed again. Main thread only.
    public static func shortLandingRetaken() {
        lock.lock()
        defer { lock.unlock() }
        guard counting else { return }
        shortLandings &+= 1
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

    /// Follows' landings short of the end, taken again since `start()` (`shortLandingRetaken`).
    public static var shortLandingsRetaken: Int {
        lock.lock()
        defer { lock.unlock() }
        return shortLandings
    }

    /// Starts counting from nothing (tests).
    public static func start() {
        lock.lock()
        counting = true
        taken = 0
        takenWhileReading = 0
        follows = 0
        shortLandings = 0
        lock.unlock()
    }
}
