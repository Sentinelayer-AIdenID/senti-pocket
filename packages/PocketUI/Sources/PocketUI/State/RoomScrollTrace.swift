import Foundation

/// When the room takes its scroll view's readings (`RoomChatView`). A reading is seen while the list is laid out; if the
/// room acted on it there (a follow, the reader's place), the list would change again in the same frame, and SwiftUI
/// warns ("tried to update multiple times per frame"). So a reading is only kept there, and taken when the screen next
/// draws a frame. This counts, once started, the readings taken, and those taken while the scroll view's geometry was
/// being read (always none). Read by the hosted `RoomReaderStaysPutTests`; nothing is counted until they start it.
public enum RoomScrollTrace {
    private static let lock = NSLock()
    private static var counting = false
    private static var readingGeometry = false
    private static var taken = 0
    private static var takenWhileReading = 0

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

    /// Readings taken since `start()`, and those taken while the geometry was being read.
    public static func snapshot() -> (taken: Int, takenWhileReading: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (taken, takenWhileReading)
    }

    /// Starts counting from nothing (tests).
    public static func start() {
        lock.lock()
        counting = true
        taken = 0
        takenWhileReading = 0
        lock.unlock()
    }
}
