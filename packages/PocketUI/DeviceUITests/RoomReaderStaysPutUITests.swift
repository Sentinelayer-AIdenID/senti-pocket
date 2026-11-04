#if os(iOS) && canImport(XCTest)
import CoreFoundation
import UIKit
import XCTest

/// Someone reading up a room is never moved: not while a fast burst arrives (agents' messages, the orchestrator's cost
/// lines, background lines, repeated notices folding into one row, checkpoints, joins), and not when they send. Someone
/// at the very bottom keeps following. Rows above them changing height (edits, reactions, a thread's newest reply moving
/// down, receipts) still push what they read down the screen: measured too, and expected to fail until it is held. Measured on screen in the app's `-PocketRoomBurstPreview` room: where what is being read is
/// drawn, read from the screen's pixels through the whole burst, may not change by more than `tolerance`. Each kind of
/// row is also sent alone to a reader a couple of lines up, to tell which kinds move them.
final class RoomReaderStaysPutUITests: XCTestCase {
    /// The preview's `RoomPreviewBurst`: its signal, its newest history row and the burst's last message.
    private static let signal = "com.plexaura.sentipocket.preview.burst"
    private static let newestHistory = "pocket.room.message.1080"
    private static let lastArrival = "pocket.room.message.1110"
    private static let firstArrival = "pocket.room.message.1081"
    /// The mixed burst's thirty rows hold 26 messages (the other four are checkpoints and joins): what the arrow counts.
    private static let mixedMessages = 26
    /// Thirty rows 0.3 s apart, and time after the last for its row to settle.
    private static let burstTime: TimeInterval = 9 + 4
    private static let tolerance: CGFloat = 2

    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: - Each kind of row alone, a couple of lines up

    /// A couple of lines up: the end of the room about 60 points under the composer's top, past the bottom's 24 points,
    /// where the old bottom marker still counted as in view.
    private static let coupleOfLines: CGFloat = 60

    func test_near_the_bottom_agents_messages_move_nothing() throws {
        let app = launch(kind: "messages")
        scrollUntilTheEndIsBelow(app, points: Self.coupleOfLines)
        try readerStaysPut(app, case: "near-messages") { Self.beginBurst() }
    }

    func test_near_the_bottom_the_orchestrators_cost_lines_move_nothing() throws {
        let app = launch(kind: "cost")
        scrollUntilTheEndIsBelow(app, points: Self.coupleOfLines)
        try readerStaysPut(app, case: "near-cost-lines") { Self.beginBurst() }
    }

    func test_near_the_bottom_background_lines_move_nothing() throws {
        let app = launch(kind: "quiet")
        scrollUntilTheEndIsBelow(app, points: Self.coupleOfLines)
        try readerStaysPut(app, case: "near-background-lines") { Self.beginBurst() }
    }

    func test_near_the_bottom_a_notice_repeating_into_one_row_moves_nothing() throws {
        let app = launch(kind: "repeats")
        scrollUntilTheEndIsBelow(app, points: Self.coupleOfLines)
        try readerStaysPut(app, case: "near-repeats") { Self.beginBurst() }
    }

    func test_near_the_bottom_checkpoints_and_joins_move_nothing() throws {
        let app = launch(kind: "system")
        scrollUntilTheEndIsBelow(app, points: Self.coupleOfLines)
        try readerStaysPut(app, case: "near-checkpoints-joins") { Self.beginBurst() }
    }

    // MARK: - Every kind together

    func test_near_the_bottom_every_kind_together_moves_nothing() throws {
        let app = launch(kind: "arrivals")
        scrollUntilTheEndIsBelow(app, points: Self.coupleOfLines)
        try readerStaysPut(app, case: "near-every-kind") { Self.beginBurst() }
    }

    /// A few lines up: the end of the room about 120 points under the composer's top.
    func test_a_reader_a_few_lines_up_stays_put_through_a_burst() throws {
        let app = launch(kind: "arrivals")
        scrollUntilTheEndIsBelow(app, points: 120)
        try readerStaysPut(app, case: "few-lines-up") { Self.beginBurst() }
    }

    func test_a_reader_half_a_screen_up_stays_put_through_a_burst() throws {
        let app = launch(kind: "arrivals")
        scrollUp(app, screens: 0.5)
        try readerStaysPut(app, case: "half-screen-up") { Self.beginBurst() }
    }

    func test_a_reader_three_screens_up_stays_put_through_a_burst_and_the_arrow_counts_it() throws {
        let app = launch(kind: "arrivals")
        scrollUp(app, screens: 3)
        try readerStaysPut(app, case: "three-screens-up") { Self.beginBurst() }
        let label = readScreen(app)?.jumpLabel
        print("READER-STAYS-PUT three-screens-up arrow=\(label ?? "none")")
        XCTAssertEqual(label, "\(Self.mixedMessages) new messages, jump to the first one", "the arrow says how many arrived")
    }

    // MARK: - Rows above changing height: not held yet

    /// The burst with rows above the reader changing height while it arrives: two edits above (each four lines longer),
    /// reactions coming to rows above, a thread's newest reply moving its row from up the room to the bottom, receipts.
    /// The room does not hold the reader's place against these yet, so this is expected to fail; it records by how much
    /// they move the reader. (SwiftUI's own `scrollPosition(id:)` held it at 0 points, but opening the keyboard from up
    /// the room then left the list blank and moved it, so it is not used.)
    func test_rows_above_changing_height_half_a_screen_up() throws {
        let app = launch(kind: "mixed")
        scrollUp(app, screens: 0.5)
        XCTExpectFailure("rows above the reader changing height still move what they read: not held yet")
        try readerStaysPut(app, case: "rows-above-half-screen-up") { Self.beginBurst() }
    }

    func test_rows_above_changing_height_three_screens_up() throws {
        let app = launch(kind: "mixed")
        scrollUp(app, screens: 3)
        XCTExpectFailure("rows above the reader changing height still move what they read: not held yet")
        try readerStaysPut(app, case: "rows-above-three-screens-up") { Self.beginBurst() }
    }

    func test_sending_from_up_the_room_keeps_the_reader_where_they_are() throws {
        let app = launch()
        scrollUp(app, screens: 1.5)
        let composer = app.descendants(matching: .any)["pocket.room.composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let beforeKeyboard = Drawn(XCUIScreen.main.screenshot())
        composer.tap()
        composer.typeText("Sent from up the room.")
        pause(1.5)
        if let beforeKeyboard {
            keep(beforeKeyboard.shot, as: "send-keyboard-0-before")
            keep(XCUIScreen.main.screenshot(), as: "send-keyboard-1-up")
        }
        if let beforeKeyboard {
            let strips = beforeKeyboard.busiestStrips(from: Self.stripFrom, to: Self.stripTo)
            let moved = Drawn(XCUIScreen.main.screenshot())?.shift(of: strips, in: beforeKeyboard, within: Self.searched)
            print("READER-STAYS-PUT send keyboard-moved=\(moved.map { String(format: "%.1f", $0) } ?? "out of reach")")
        }
        try readerStaysPut(app, case: "send-from-up", watch: 4) {
            app.descendants(matching: .any)["pocket.room.send"].tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["pocket.room.jumpToLatest"].exists,
                      "the reader is still up the room: the arrow shows")
    }

    // MARK: - The arrow goes to the first new message

    /// Three screens up, the burst arrives; the arrow takes the reader to the first message that arrived, read from its
    /// top under the New messages line (as the web room's does), not to the latest, so none of what arrived is skipped.
    /// The count is taken: the arrow is plain, and a second tap goes on to the latest.
    func test_the_arrow_goes_to_the_first_new_message_then_to_the_latest() throws {
        let app = launch(kind: "arrivals")
        scrollUp(app, screens: 3)
        Self.beginBurst()
        pause(Self.burstTime)
        let arrow = app.descendants(matching: .any)["pocket.room.jumpToLatest"]
        XCTAssertTrue(arrow.waitForExistence(timeout: 10))
        keep(XCUIScreen.main.screenshot(), as: "arrow-0-before-tap")
        arrow.tap()
        pause(1.5)
        keep(XCUIScreen.main.screenshot(), as: "arrow-1-after-tap")
        let screen = try XCTUnwrap(readScreen(app), "the app could be read")
        let line = app.descendants(matching: .any)["pocket.room.unreadDivider"]
        let first = screen.messages[Self.firstArrival]
        print("READER-STAYS-PUT arrow first-tap line=\(line.exists ? "\(line.frame.minY)" : "absent") "
            + "first=\(first.map { "\($0.minY)" } ?? "absent") last=\(screen.messages[Self.lastArrival] != nil) "
            + "arrow=\(screen.jumpLabel ?? "none") band=\(screen.top)...\(screen.bottom)")
        XCTAssertTrue(line.exists, "the New messages line is there")
        if line.exists {
            XCTAssertGreaterThanOrEqual(line.frame.minY, screen.top, "the line is in view")
            XCTAssertLessThan(line.frame.minY, screen.top + (screen.bottom - screen.top) / 2, "near the top of the screen")
        }
        let firstInView = first.map { $0.minY >= screen.top && $0.minY < screen.bottom } ?? false
        XCTAssertTrue(firstInView, "the first message that arrived is in view, from its top")
        XCTAssertEqual(screen.jumpLabel, "Jump to latest", "the count is taken; the arrow goes on to the latest")

        arrow.tap()
        pause(1.5)
        keep(XCUIScreen.main.screenshot(), as: "arrow-2-second-tap")
        let after = try XCTUnwrap(readScreen(app), "the app could be read")
        print("READER-STAYS-PUT arrow second-tap newest-visible=\(after.newestVisible() ?? "none") "
            + "arrow=\(after.jumpLabel ?? "none")")
        XCTAssertEqual(after.newestVisible(), Self.lastArrival, "the second tap goes to the latest")
    }

    // MARK: - A slow coast a little way up

    /// At the bottom, the reader drags the list up slowly, about 50 points at 10 points a second (a sixth of a point a
    /// frame at 60 Hz, a third of a point now and then once rounded to the screen's pixels, like the end of a gentle
    /// coast), and lets go; then messages arrive. The reader is away from the bottom and stays where they are.
    func test_a_slow_drag_a_little_way_up_then_arrivals_move_nothing() throws {
        let app = launch(kind: "messages")
        let screen = try XCTUnwrap(readScreen(app), "the app could be read")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: app.frame.midX, dy: screen.top + (screen.bottom - screen.top) * 0.3))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 60)),
                   withVelocity: XCUIGestureVelocity(rawValue: 10), thenHoldForDuration: 0)
        pause(1.5)
        let after = try XCTUnwrap(readScreen(app), "the app could be read")
        print("READER-STAYS-PUT slow-drag end-below=\(after.endBelow) arrow=\(after.jumpLabel ?? "none")")
        try readerStaysPut(app, case: "slow-drag-up") { Self.beginBurst() }
    }

    func test_a_reader_at_the_bottom_follows_the_burst() {
        let app = launch()
        Self.beginBurst()
        let end = Date().addingTimeInterval(Self.burstTime)
        while Date() < end {
            if let screen = readScreen(app) {
                print("READER-STAYS-PUT at-bottom t=\(String(format: "%.1f", Self.burstTime - end.timeIntervalSinceNow)) "
                    + "newest-visible=\(screen.newestVisible() ?? "none") arrow=\(screen.jumpLabel ?? "none")")
            }
            pause(0.3)
        }
        guard let screen = readScreen(app) else { return XCTFail("the app could not be read") }
        let last = screen.messages[Self.lastArrival]
        let lowest = screen.rows.values.map(\.maxY).max() ?? 0
        print("READER-STAYS-PUT at-bottom final newest-visible=\(screen.newestVisible() ?? "none") "
            + "last=\(last.map { "\($0.minY)...\($0.maxY)" } ?? "absent") lowest-row=\(lowest) "
            + "visible=\(screen.top)...\(screen.bottom)")
        XCTAssertEqual(screen.newestVisible(), Self.lastArrival, "the burst's last message is the newest in view")
        if let last {
            XCTAssertLessThanOrEqual(last.maxY, screen.bottom + 2, "its bottom is in view, above the composer")
            XCTAssertEqual(last.maxY, lowest, accuracy: 0.5, "nothing below it")
            XCTAssertGreaterThanOrEqual(last.maxY, screen.bottom - 40, "at the very bottom of the room")
        }
        XCTAssertNil(screen.jumpLabel, "still at the bottom: no arrow")
    }

    // MARK: - Measuring

    /// Notes strips of what is drawn at the top of the reading band (the top message in view), does `action`, then
    /// measures for `watch` seconds where those strips are on the screen: the top message may not move by more than
    /// `tolerance`, nor leave the screen. Rows below it may grow (a reaction, a receipt) and push what is under them down;
    /// the top message stays. The movement is the median of the strips' movements, so one strip whose own row changes is
    /// outvoted. The measuring reads the screen's own pixels and asks the app nothing: in some states an accessibility
    /// snapshot of the room takes more than 30 seconds (at master as at this change), which would leave the burst
    /// unmeasured. A second before `action` is measured too, so a room still moving on its own is told apart from one
    /// moved by the action.
    private func readerStaysPut(_ app: XCUIApplication, case name: String, watch: TimeInterval = burstTime,
                                _ action: () -> Void) throws {
        if let start = readScreen(app) {
            print("READER-STAYS-PUT \(name) top=\(start.topMessage()?.id ?? "none") end-below=\(start.endBelow) "
                + "arrow-before=\(start.jumpLabel ?? "none")")
        }
        let reference = try XCTUnwrap(Drawn(XCUIScreen.main.screenshot()), "the screen could be read")
        let strips = reference.busiestStrips(from: Self.stripFrom, to: Self.stripTo)
        var before: CGFloat = 0
        let controlEnd = Date().addingTimeInterval(1)
        while Date() < controlEnd {
            let shift = Drawn(XCUIScreen.main.screenshot())?.shift(of: strips, in: reference, within: Self.searched)
            before = max(before, abs(shift ?? .greatestFiniteMagnitude))
            pause(0.2)
        }
        print("READER-STAYS-PUT \(name) strips=\(strips.map { "\($0.lowerBound)" }.joined(separator: ",")) px "
            + "still-before=\(String(format: "%.1f", before))")
        XCTAssertLessThanOrEqual(before, Self.tolerance, "\(name): the room was still moving before the burst")
        keep(reference.shot, as: "\(name)-0-before")
        action()
        var moved: CGFloat = 0
        var unmatched = 0
        var unmatchedInARow = 0
        var longestUnmatched = 0
        var samples = 0
        var keptMoved = false
        let end = Date().addingTimeInterval(watch)
        while Date() < end {
            defer { pause(0.1) }
            guard let drawn = Drawn(XCUIScreen.main.screenshot()) else { continue }
            samples += 1
            if let dy = drawn.shift(of: strips, in: reference, within: Self.searched) {
                unmatchedInARow = 0
                moved = max(moved, abs(dy))
                print("READER-STAYS-PUT \(name) sample=\(samples) dy=\(String(format: "%.1f", dy))")
                if abs(dy) > Self.tolerance, !keptMoved {
                    keptMoved = true
                    keep(drawn.shot, as: "\(name)-moved-\(samples)")
                }
            } else {
                unmatched += 1
                unmatchedInARow += 1
                longestUnmatched = max(longestUnmatched, unmatchedInARow)
                print("READER-STAYS-PUT \(name) sample=\(samples) what was read is drawn nowhere within \(Self.searched) "
                    + "points")
                keep(drawn.shot, as: "\(name)-unmatched-\(samples)")
            }
        }
        keep(XCUIScreen.main.screenshot(), as: "\(name)-9-after")
        print("READER-STAYS-PUT \(name) RESULT max-moved=\(String(format: "%.1f", moved)) "
            + "unmatched=\(unmatched)/\(samples) longest-unmatched-run=\(longestUnmatched)")
        XCTAssertGreaterThan(samples, 5, "\(name): measured through it")
        // A sample can catch the navigation bar's edge effect or a row's own content changing over the strips (a
        // screenshot is kept for each); a room that moved shows as a measured movement, or as what was read being gone
        // from the screen sample after sample.
        XCTAssertLessThan(longestUnmatched, 3, "\(name): what was being read left the screen")
        XCTAssertLessThanOrEqual(moved, Self.tolerance, "\(name): what was being read moved \(moved) points")
    }

    /// Where the strips read are chosen: the top of the reading band, under the navigation bar (points from the top of
    /// the screen), on the left, clear of the people floating at the top center.
    private static let stripFrom: CGFloat = 120
    private static let stripTo: CGFloat = 230
    /// How far a moved strip is looked for, up or down.
    private static let searched: CGFloat = 600

    /// What is drawn, as one signature per pixel row: the brightness of 24 slices of the left third of the screen (the
    /// people float at the top center, the jump button sits on the right).
    private struct Drawn {
        let shot: XCUIScreenshot
        let rows: [[Int]]
        /// Pixels per point.
        let scale: CGFloat
        static let slices = 24

        init?(_ shot: XCUIScreenshot) {
            self.shot = shot
            guard let image = shot.image.cgImage else { return nil }
            let width = image.width, height = image.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let drew: Bool = data.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drew else { return nil }
            scale = CGFloat(width) / UIScreen.main.bounds.width
            let usable = width * 35 / 100
            var rows: [[Int]] = []
            rows.reserveCapacity(height)
            data.withUnsafeBufferPointer { pixels in
                for y in 0..<height {
                    var signature = [Int](repeating: 0, count: Self.slices)
                    let base = y * width * 4
                    var x = 0
                    while x < usable {
                        let i = base + x * 4
                        signature[x * Self.slices / usable] += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
                        x += 2
                    }
                    rows.append(signature)
                }
            }
            self.rows = rows
        }

        /// Up to three 16-point strips between `from` and `to` (points), apart, whose rows differ most: text, not plain
        /// background.
        func busiestStrips(from: CGFloat, to: CGFloat) -> [Range<Int>] {
            let height = Int(16 * scale)
            var candidates: [(range: Range<Int>, score: Int)] = []
            var start = Int(from * scale)
            while start + height <= min(Int(to * scale), rows.count) {
                var score = 0
                for y in start..<(start + height) {
                    let row = rows[y]
                    score += (row.max() ?? 0) - (row.min() ?? 0)
                    if y > start { score += zip(row, rows[y - 1]).reduce(0) { $0 + abs($1.0 - $1.1) } }
                }
                candidates.append((start..<(start + height), score))
                start += Int(4 * scale)
            }
            var chosen: [Range<Int>] = []
            for candidate in candidates.sorted(by: { $0.score > $1.score }) where candidate.score > 0 {
                guard chosen.allSatisfy({ !$0.overlaps(candidate.range) }) else { continue }
                chosen.append(candidate.range)
                if chosen.count == 3 { break }
            }
            return chosen.sorted { $0.lowerBound < $1.lowerBound }
        }

        /// How far, in points, what `reference` drew in `strips` moved in this drawing: the median of the strips' own
        /// movements, or nil when half of them or more are drawn nowhere within `within` points.
        func shift(of strips: [Range<Int>], in reference: Drawn, within: CGFloat) -> CGFloat? {
            let found = strips.compactMap { shift(of: $0, in: reference, within: within) }.sorted()
            guard !strips.isEmpty, found.count * 2 > strips.count else { return nil }
            return found[found.count / 2]
        }

        /// How far, in points, the strip `strip` of `reference` moved in this drawing: the nearest offset within `within`
        /// points where it is drawn again, or nil when it is not.
        func shift(of strip: Range<Int>, in reference: Drawn, within: CGFloat) -> CGFloat? {
            let limit = Int(within * scale)
            let allowed = strip.count * Self.slices * 6
            var best = Int.max
            var bestOffset = 0
            for step in 0...(2 * limit) {
                let offset = step.isMultiple(of: 2) ? step / 2 : -(step + 1) / 2
                guard strip.lowerBound + offset >= 0, strip.upperBound + offset <= rows.count else { continue }
                var error = 0
                for y in strip {
                    let a = reference.rows[y], b = rows[y + offset]
                    for k in 0..<Self.slices { error += abs(a[k] - b[k]) }
                    if error >= best { break }
                }
                if error < best {
                    best = error
                    bestOffset = offset
                    if error == 0 { break }
                }
            }
            return best <= allowed ? CGFloat(bestOffset) / scale : nil
        }
    }

    /// What is on screen, from one snapshot of the app: each row's frame, the band between the navigation bar and the
    /// composer where messages are read, and the jump button's label.
    private struct Screen {
        var messages: [String: CGRect] = [:]
        /// Messages, the thread replies shown in the room, background lines and checkpoints.
        var rows: [String: CGRect] = [:]
        var top: CGFloat = 0
        var bottom: CGFloat = .greatestFiniteMagnitude
        var jumpLabel: String?

        /// The highest message with some of it in view (its top edge may be under the navigation bar: its y is still
        /// where it is on screen).
        func topMessage() -> (id: String, frame: CGRect)? {
            messages.filter { $0.value.maxY > top + 10 && $0.value.minY < bottom - 10 }
                .min { $0.value.minY < $1.value.minY }
                .map { ($0.key, $0.value) }
        }

        /// The lowest row with any of it in view.
        func newestVisible() -> String? {
            rows.filter { $0.value.maxY > top && $0.value.minY < bottom }
                .max { $0.value.minY < $1.value.minY }?.key
        }

        /// How far the lowest row drawn ends below what can be read (negative: above the composer).
        var endBelow: CGFloat { (rows.values.map(\.maxY).max() ?? 0) - bottom }
    }

    /// One snapshot of the app, or nil when it could not be taken (a loaded machine times out now and then).
    private func readScreen(_ app: XCUIApplication) -> Screen? {
        let root: XCUIElementSnapshot
        do {
            root = try app.snapshot()
        } catch {
            print("READER-STAYS-PUT the app could not be read: \(error)")
            return nil
        }
        var screen = Screen()
        var stack = [root]
        while let node = stack.popLast() {
            let id = node.identifier
            if id.hasPrefix("pocket.room.message.") {
                screen.messages[id] = node.frame
                screen.rows[id] = node.frame
            } else if id.hasPrefix("pocket.room.reply.") || id.hasPrefix("pocket.room.quiet.")
                        || id.hasPrefix("pocket.room.checkpoint.") {
                screen.rows[id] = node.frame
            } else if id == "pocket.room.composer" {
                screen.bottom = min(screen.bottom, node.frame.minY)
            } else if id == "pocket.room.jumpToLatest" {
                screen.jumpLabel = node.label
            }
            if node.elementType == .navigationBar { screen.top = max(screen.top, node.frame.maxY) }
            stack.append(contentsOf: node.children)
        }
        guard !screen.messages.isEmpty, screen.bottom < .greatestFiniteMagnitude else {
            print("READER-STAYS-PUT the app was read without \(screen.messages.isEmpty ? "messages" : "the composer")")
            return nil
        }
        return screen
    }

    // MARK: - Driving the app

    private func launch(kind: String = "mixed") -> XCUIApplication {
        let app = XCUIApplication()
        // The burst waits for this test's signal; the long fallback only ends a run whose signal never arrived.
        app.launchArguments = ["-PocketRoomBurstPreview", "-PocketRoomBurstAfter", "600", "-PocketRoomBurstKind", kind]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)[Self.newestHistory].waitForExistence(timeout: 90), "the room opened")
        // The open's scroll, receipts, reactions and the thread's reply land.
        pause(4)
        return app
    }

    /// One slow drag of `points`, with a hold at the end so the list does not coast.
    private func drag(_ app: XCUIApplication, from screen: Screen, points: CGFloat) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let from = origin.withOffset(CGVector(dx: app.frame.midX, dy: screen.top + (screen.bottom - screen.top) * 0.2))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: points)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// About `screens` heights of the reading band up.
    private func scrollUp(_ app: XCUIApplication, screens: CGFloat) {
        guard let screen = readScreen(app) else { return XCTFail("the app could not be read") }
        let height = screen.bottom - screen.top
        print("READER-STAYS-PUT scroll-up \(screens) screens: before, the end is \(screen.endBelow) below the band")
        var remaining = height * screens
        while remaining > 1 {
            let step = min(remaining, height * 0.5)
            drag(app, from: screen, points: step)
            remaining -= step
        }
        // The reader's place settles.
        pause(1.5)
        print("READER-STAYS-PUT scroll-up \(screens) screens: after, the end is \(readScreen(app)?.endBelow ?? .nan) below")
    }

    /// Small drags until the end of the room is at least `points` below what can be read.
    private func scrollUntilTheEndIsBelow(_ app: XCUIApplication, points: CGFloat) {
        for _ in 0..<4 {
            guard let screen = readScreen(app) else { continue }
            print("READER-STAYS-PUT scroll-up: the end is \(screen.endBelow) below the band")
            if screen.endBelow >= points { break }
            drag(app, from: screen, points: points - screen.endBelow + 12)
            pause(1)
        }
        pause(1)
    }

    /// Keeps a screenshot on the Mac, beside the lane's logs, when the simulator says where its home is.
    private func keep(_ shot: XCUIScreenshot, as name: String) {
        guard let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return }
        let url = URL(fileURLWithPath: home).appendingPathComponent("scroll-out/shot-\(name).png")
        try? shot.pngRepresentation.write(to: url)
    }

    private static func beginBurst() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(signal as CFString), nil, nil, true)
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
#endif
