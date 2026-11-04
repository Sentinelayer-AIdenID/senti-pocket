import Foundation

/// When the room takes its scroll view's readings (`RoomChatView`). A reading is seen while the list is laid out; if the
/// room acted on it there (a follow, the reader's place), the list would change again in the same frame, and SwiftUI
/// warns ("tried to update multiple times per frame"). So a reading is queued there and taken on a later turn of the
/// run loop; this counts the readings taken, and those taken in the turn that queued them (always none). Read by the
/// hosted `RoomReaderStaysPutTests`.
public enum RoomScrollTrace {
    private static let lock = NSLock()
    private static var turn = 0
    private static var turnArmed = false
    private static var queuedIn: Int?
    private static var taken = 0
    private static var takenInTheirTurn = 0

    /// A reading was queued. Main thread only.
    public static func readingQueued() {
        lock.lock()
        queuedIn = currentTurn()
        lock.unlock()
    }

    /// A queued reading was taken. Main thread only.
    public static func readingTaken() {
        lock.lock()
        taken &+= 1
        if let queuedIn, queuedIn == currentTurn() { takenInTheirTurn &+= 1 }
        queuedIn = nil
        lock.unlock()
    }

    /// Readings taken so far, and those taken in the turn of the run loop that queued them.
    public static func snapshot() -> (taken: Int, takenInTheirTurn: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (taken, takenInTheirTurn)
    }

    /// Starts counting again (tests).
    public static func reset() {
        lock.lock()
        taken = 0
        takenInTheirTurn = 0
        queuedIn = nil
        lock.unlock()
    }

    /// This turn of the run loop: a number that moves on once the main queue next runs. Called with the lock held.
    private static func currentTurn() -> Int {
        if !turnArmed {
            turnArmed = true
            DispatchQueue.main.async {
                lock.lock()
                turn &+= 1
                turnArmed = false
                lock.unlock()
            }
        }
        return turn
    }
}
