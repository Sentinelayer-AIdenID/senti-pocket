import Foundation

/// How many times the room's message rows have been drawn, and which was drawn last: read from the app's main-thread
/// watch while the main thread is stuck (build 14's freeze after coming back with the side panel open: its stack
/// was inside a row's drawing). A stall with thousands of row draws is the room redrawing itself over and over; one
/// with a handful is one slow piece of work.
public enum RenderTrace {
    private static let lock = NSLock()
    private static var draws = 0
    private static var last: Int64 = 0
    private static var ticks: [String: Int] = [:]
    private static var lastIntent = ""

    /// One row drawn (its body evaluated).
    public static func row(_ sequenceId: Int64) {
        lock.lock()
        draws &+= 1
        last = sequenceId
        lock.unlock()
    }

    /// One update from a named part of the app (a coordinator publishing, a screen drawn). Carter's build 16 freeze
    /// (10-30 23:30) drew rows 176,832 times in 20 s; these say which part kept updating.
    public static func tick(_ source: String) {
        lock.lock()
        ticks[source, default: 0] &+= 1
        lock.unlock()
    }

    /// The last action the room took, by its name only (never its text).
    public static func intent(_ name: String) {
        lock.lock()
        lastIntent = String(name.prefix(40))
        lock.unlock()
    }

    /// Row draws so far and the last row drawn; safe from any thread.
    public static func snapshot() -> (draws: Int, lastRow: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (draws, last)
    }

    /// Updates by part so far, and the last action; safe from any thread.
    public static func sources() -> (ticks: [String: Int], lastIntent: String) {
        lock.lock()
        defer { lock.unlock() }
        return (ticks, lastIntent)
    }

    /// The parts that updated most between two readings, busiest first: "room 58,940, room screen 58,940".
    public static func busiest(from start: [String: Int], to now: [String: Int], top: Int = 3) -> String? {
        let deltas = now.map { ($0.key, $0.value - (start[$0.key] ?? 0)) }.filter { $0.1 > 0 }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        guard !deltas.isEmpty else { return nil }
        let format = { (value: Int) in value.formatted(.number.locale(Locale(identifier: "en_US"))) }
        return deltas.prefix(top).map { "\($0.0) \(format($0.1))" }.joined(separator: ", ")
    }
}
