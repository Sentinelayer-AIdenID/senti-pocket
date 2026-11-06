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
    private static var landings = 0
    private static var landingsMoved = 0
    private static var largestSnap: CGFloat = 0
    private static var landedAt: [String] = []
    private static var focused: [String] = []
    private static var shortLandings = 0
    private static var retries = 0
    private static var gaveUp = 0

    /// Test seams (DEBUG builds only; none in a release build): placed follows that move nothing, and how the room's
    /// one retry of such a follow goes, so the hosted tests can make a follow chain stop short at will.
    public enum InjectedRetry: Sendable {
        /// The retry moves nothing either: the room gives up, and the arrow shows.
        case movesNothing
        /// The retry lands above the end (ten rows up): it must not be taken for the reader leaving.
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

    /// The room's own scroll to its end landed at `offset` (its content's very end at `contentEnd`): UIKit put the list
    /// the last `snap` points to where the bottom marker rests, at once. Main thread only.
    public static func listLanded(snap: CGFloat, at offset: CGFloat, contentEnd: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        guard counting else { return }
        landings &+= 1
        largestSnap = max(largestSnap, abs(snap))
        landedAt.append("\(Int(offset.rounded()))/\(Int(contentEnd.rounded()))")
    }

    /// In the frames after a landing, the list moved `moved` points in all, ending at `offset` (it must be none: a
    /// SwiftUI scroll that moved the list after UIKit's built every row of the room). Main thread only.
    public static func listSettled(moved: CGFloat, at offset: CGFloat) {
        lock.lock()
        defer { lock.unlock() }
        guard counting else { return }
        if moved > 0.5 { landingsMoved &+= 1 }
        landedAt.append("settled \(Int(offset.rounded())) moved \(Int(moved.rounded()))")
    }

    /// Where the landings landed and settled, since `start()` (the offset, the content's very end).
    public static var landingPlaces: [String] {
        lock.lock()
        defer { lock.unlock() }
        return landedAt
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
        landings = 0
        landingsMoved = 0
        largestSnap = 0
        landedAt = []
        focused = []
        shortLandings = 0
        retries = 0
        gaveUp = 0
        lock.unlock()
    }
}
