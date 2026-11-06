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
    private static var retries = 0
    private static var gaveUp = 0

    /// Test seams (DEBUG builds only; none in a release build): placed follows that move nothing, and how the room's
    /// one retry of such a follow goes, so the hosted tests can make a follow chain stop short at will.
    public enum InjectedRetry: Sendable {
        /// The retry moves nothing either: the room gives up, and the arrow shows.
        case movesNothing
        /// The retry lands far above the end (at the room's first row): it must not be taken for the reader leaving.
        case landsAbove
    }

    #if DEBUG
    public static var followMovesNothing = false
    public static var injectedRetry: InjectedRetry?
    #else
    public static let followMovesNothing = false
    public static let injectedRetry: InjectedRetry? = nil
    #endif

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

    /// The room tried a follow that moved nothing once more. Main thread only.
    public static func stallRetried() {
        lock.lock()
        defer { lock.unlock() }
        guard counting else { return }
        retries &+= 1
    }

    /// The room gave up on a follow chain that moved nothing, and no longer says the reader is at the bottom. Main
    /// thread only.
    public static func followGaveUp() {
        lock.lock()
        defer { lock.unlock() }
        guard counting else { return }
        gaveUp &+= 1
    }

    /// Retries and give-ups since `start()`.
    public static var stalls: (retries: Int, gaveUp: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (retries, gaveUp)
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
        retries = 0
        gaveUp = 0
        lock.unlock()
    }
}
