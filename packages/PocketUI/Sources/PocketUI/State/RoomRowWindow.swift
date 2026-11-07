import Foundation

/// What `RoomRowWindow` reads of a row of the room.
protocol RoomWindowRow {
    /// The row's id in the list: what a scroll to it targets.
    var windowId: String { get }
    /// The sequence of the room's message the row is; nil for a day, the unread line, or a reply shown in the room (it
    /// carries its message's sequence). The room's messages are in sequence order, so a window kept by them finds its
    /// place again once a row it was kept by is gone.
    var windowSequence: Int64? { get }
}

extension RoomChatRow: RoomWindowRow {
    var windowId: String { id }

    var windowSequence: Int64? {
        guard case .message(let message) = self, !message.isInlineReply else { return nil }
        return message.sequenceId
    }
}

/// Which of the room's rows its list holds, where the list holds every row it shows at once (`RoomChatView`, iOS 18 and
/// later). A lazy list placing a room's rows by estimated heights is where the room froze, and where it went blank
/// after Jump to latest; a list that holds its rows has measured every one of them, but it must not hold the whole
/// room. So it holds a window: the newest `opening` rows when the room opens, `step` more as the reader reaches its top
/// or its bottom, and never more than `most`, letting go of rows at the end away from the reader.
///
/// The window is kept by its first and last messages, by sequence, never by place: rows loading above it, arriving
/// below it, or taken away (deleted, folded into another) leave it on the same messages, or on the nearest ones. It
/// starts with the rows just above its first message (its day, the unread line, replies shown at their time). Its last
/// is nil while it runs to the room's newest row, so arrivals join it.
struct RoomRowWindow: Equatable, Sendable {
    /// Rows the list holds when the room opens, or is put back at its newest.
    static let opening = 80
    /// Rows shown at once as the reader reaches the top or the bottom of the window.
    static let step = 40
    /// The most rows the list holds.
    static let most = 160
    /// Rows held above a message the room is taken to (a link, a search result, a pin); the rest of `opening` is below.
    static let aboveMessage = 10
    /// Rows held above the unread line when the room opens at it.
    static let aboveLine = 20

    /// The first message held, by sequence; nil until the window is held (`holding`).
    private(set) var first: Int64?
    /// The last message held, by sequence; nil: up to the room's newest row.
    private(set) var last: Int64?
    /// A row the window is put around before it is held, found by id each time the rows are read.
    private var target: String?
    private var above = 0

    /// The newest `opening` rows, until held.
    init() {}

    /// The window around the row with `id`, `above` rows over it, until held. Found by id when the rows are read, so
    /// a row the room has only just loaded is found.
    static func around(_ id: String, above: Int) -> RoomRowWindow {
        var window = RoomRowWindow()
        window.target = id
        window.above = max(above, 0)
        return window
    }

    /// Kept by its own messages.
    var isHeld: Bool { first != nil }

    /// The window holding `range` of `rows`, kept from its first message to its last, or to the newest row when the
    /// range reaches it. A range with no message in it holds nothing: the newest rows.
    static func holding<Row: RoomWindowRow>(_ range: Range<Int>, of rows: [Row]) -> RoomRowWindow {
        let range = range.clamped(to: 0..<rows.count)
        var window = RoomRowWindow()
        guard let start = range.first(where: { rows[$0].windowSequence != nil }) else { return window }
        window.first = rows[start].windowSequence
        if range.upperBound < rows.count, let end = range.last(where: { rows[$0].windowSequence != nil }) {
            window.last = rows[end].windowSequence
        }
        return window
    }

    /// The same rows, kept by their messages from now on.
    func held<Row: RoomWindowRow>(in rows: [Row]) -> RoomRowWindow {
        Self.holding(range(in: rows), of: rows)
    }

    /// The rows held, as a range of `rows`: never more than `most`. A window running to the newest row that has grown
    /// past it keeps its first rows (the reader's), and the newest wait below (`isFull`).
    func range<Row: RoomWindowRow>(in rows: [Row]) -> Range<Int> {
        let count = rows.count
        guard count > 0 else { return 0..<0 }
        if !isHeld, let target, let index = rows.firstIndex(where: { $0.windowId == target }) {
            let from = max(0, index - above)
            let start = (from..<count).first(where: { rows[$0].windowSequence != nil }) ?? index
            let lower = min(Self.leading(start, in: rows), index)
            return lower..<min(count, max(lower + Self.opening, index + 1))
        }
        guard let first, let found = rows.firstIndex(where: { ($0.windowSequence ?? .min) >= first }) else {
            return Self.newest(in: rows)
        }
        let lower = Self.leading(found, in: rows)
        var upper = count
        if let last, let end = rows.lastIndex(where: { ($0.windowSequence ?? .max) <= last }) {
            upper = end + 1
        }
        return lower..<min(max(upper, lower + 1), count, lower + Self.most)
    }

    /// The window reaches the room's newest row: arrivals join it, and its bottom is the room's.
    func reachesNewest<Row: RoomWindowRow>(in rows: [Row]) -> Bool {
        range(in: rows).upperBound == rows.count
    }

    /// Running to the newest row, it has grown to `most`: rows arriving now wait below it.
    func isFull<Row: RoomWindowRow>(in rows: [Row]) -> Bool {
        isHeld && last == nil && !reachesNewest(in: rows)
    }

    /// A page shown: the window after it, and the row the reader stays on (nil when nothing on screen moves).
    struct Page: Equatable, Sendable {
        let window: RoomRowWindow
        let keep: String?
    }

    /// `step` more rows above, letting go of rows at the bottom past `most`. The reader stays on the first message they
    /// had, at the top of the screen. Nil when the window already starts at the room's first row.
    func older<Row: RoomWindowRow>(in rows: [Row]) -> Page? {
        let shown = range(in: rows)
        guard !shown.isEmpty, shown.lowerBound > 0 else { return nil }
        // The window starts with the rows above its first message, so the row above it is a message.
        let from = max(0, shown.lowerBound - Self.step)
        guard let start = (from..<shown.lowerBound).first(where: { rows[$0].windowSequence != nil }) else { return nil }
        let lower = Self.leading(start, in: rows)
        let upper = min(shown.upperBound, lower + Self.most)
        let keep = shown.first(where: { rows[$0].windowSequence != nil }).map { rows[$0].windowId }
        return Page(window: Self.holding(lower..<upper, of: rows), keep: keep)
    }

    /// `step` more rows below, letting go of rows at the top past `most`. Only then does the reader need keeping, on
    /// the last message they had, at the bottom of the screen: rows added below move nothing. Nil when the window
    /// reaches the room's newest row.
    func newer<Row: RoomWindowRow>(in rows: [Row]) -> Page? {
        let shown = range(in: rows)
        guard !shown.isEmpty, shown.upperBound < rows.count else { return nil }
        let reach = min(rows.count, shown.upperBound + Self.step)
        let end = (shown.upperBound..<reach).last(where: { rows[$0].windowSequence != nil })
            ?? (reach..<rows.count).first(where: { rows[$0].windowSequence != nil })
        let upper = end.map { $0 + 1 } ?? rows.count
        var lower = shown.lowerBound
        if upper - lower > Self.most,
           let start = ((upper - Self.most)..<upper).first(where: { rows[$0].windowSequence != nil }) {
            lower = Self.leading(start, in: rows)
        }
        let keep = lower > shown.lowerBound
            ? shown.last(where: { rows[$0].windowSequence != nil }).map { rows[$0].windowId } : nil
        return Page(window: Self.holding(lower..<upper, of: rows), keep: keep)
    }

    /// The newest `opening` rows, from a message.
    private static func newest<Row: RoomWindowRow>(in rows: [Row]) -> Range<Int> {
        let from = max(0, rows.count - opening)
        let start = (from..<rows.count).first(where: { rows[$0].windowSequence != nil }) ?? from
        return leading(start, in: rows)..<rows.count
    }

    /// Where a window whose first message is in row `start` starts: with the rows above it back to the message before
    /// (its day, the unread line, replies shown at their time), or from the room's first row.
    private static func leading<Row: RoomWindowRow>(_ start: Int, in rows: [Row]) -> Int {
        var index = min(start, rows.count)
        while index > 0, rows[index - 1].windowSequence == nil { index -= 1 }
        return index
    }
}
