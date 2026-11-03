import Foundation

/// How many times the room's message rows have been drawn, and which was drawn last: read from the app's main-thread
/// watch while the main thread is stuck (build 14's freeze after coming back with the side panel open: its stack
/// was inside a row's drawing). A stall with thousands of row draws is the room redrawing itself over and over; one
/// with a handful is one slow piece of work.
public enum RenderTrace {
    private static let lock = NSLock()
    private static var draws = 0
    private static var last: Int64 = 0

    /// One row drawn (its body evaluated).
    public static func row(_ sequenceId: Int64) {
        lock.lock()
        draws &+= 1
        last = sequenceId
        lock.unlock()
    }

    /// Row draws so far and the last row drawn; safe from any thread.
    public static func snapshot() -> (draws: Int, lastRow: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (draws, last)
    }
}
