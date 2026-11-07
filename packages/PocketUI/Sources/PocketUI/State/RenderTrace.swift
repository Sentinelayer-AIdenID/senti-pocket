import Foundation

/// How many times the room's message rows have been drawn, and which was drawn last: read from the app's main-thread
/// watch while the main thread is stuck (build 14's freeze after coming back with the side panel open: its stack
/// was inside a row's drawing). A stall with thousands of row draws is the room redrawing itself over and over; one
/// with a handful is one slow piece of work.
///
/// Also how many items of the app's long lists were built (the room's rows, the side panel's rooms): a lazy list builds
/// the items it shows, and one that builds every item it holds at each layout pass is walking the whole list.
public enum RenderTrace {
    /// A long list whose items are counted as they are built.
    public enum List: Sendable {
        /// The room's timeline: one item per row of the room.
        case roomRow
        /// The side panel's rooms and direct messages.
        case sidePanel
        /// The room's own view, its body: a keystroke in a thread must never draw it again.
        case roomBody
        /// A thread's list of replies, its body: a keystroke in the thread's box must never draw it again.
        case threadList
        /// One reply of a thread built.
        case threadReply
    }

    /// A test sets this to have the thread's reply list say why SwiftUI drew it (`_printChanges`), in its log.
    public static var explainsThreadList = false

    private static let lock = NSLock()
    private static var draws = 0
    private static var last: Int64 = 0
    private static var builtRoomRows = 0
    private static var builtSidePanel = 0
    private static var builtRoomBodies = 0
    private static var builtThreadLists = 0
    private static var builtThreadReplies = 0
    /// The thread replies built since `resetThreadReplies()`, by id: a lazy list builds only those in sight.
    private static var threadRepliesBuilt: Set<String> = []
    private static var furthestStrip = -1

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

    /// One item of `list` built (its content made by the list's loop).
    public static func built(_ list: List) {
        lock.lock()
        switch list {
        case .roomRow: builtRoomRows &+= 1
        case .sidePanel: builtSidePanel &+= 1
        case .roomBody: builtRoomBodies &+= 1
        case .threadList: builtThreadLists &+= 1
        case .threadReply: builtThreadReplies &+= 1
        }
        lock.unlock()
    }

    /// Thread reply `id` built (and counted as a `.threadReply`).
    public static func builtThreadReply(_ id: String) {
        lock.lock()
        builtThreadReplies &+= 1
        threadRepliesBuilt.insert(id)
        lock.unlock()
    }

    /// The thread replies built since `resetThreadReplies()`; safe from any thread.
    public static func threadRepliesBuiltSinceReset() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return threadRepliesBuilt
    }

    /// Starts `threadRepliesBuiltSinceReset()` again from none.
    public static func resetThreadReplies() {
        lock.lock()
        threadRepliesBuilt = []
        lock.unlock()
    }

    /// Photo `index` (from 0) of a room's strip of photos built: a strip builds the photos in sight, and one that builds
    /// every photo it holds, to show or to measure them, reaches its last.
    public static func builtStripPhoto(_ index: Int) {
        lock.lock()
        furthestStrip = max(furthestStrip, index)
        lock.unlock()
    }

    /// The furthest strip photo built since `resetStripPhotos()` (from 0), or -1 when none was; safe from any thread.
    public static func furthestStripPhoto() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return furthestStrip
    }

    /// Starts `furthestStripPhoto()` again from none.
    public static func resetStripPhotos() {
        lock.lock()
        furthestStrip = -1
        lock.unlock()
    }

    /// Items of `list` built so far; safe from any thread.
    public static func builtCount(_ list: List) -> Int {
        lock.lock()
        defer { lock.unlock() }
        switch list {
        case .roomRow: return builtRoomRows
        case .sidePanel: return builtSidePanel
        case .roomBody: return builtRoomBodies
        case .threadList: return builtThreadLists
        case .threadReply: return builtThreadReplies
        }
    }
}
