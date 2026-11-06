#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import PocketUI

/// Read aloud puts a speaker mark on the message it reads. Carter's phone (build 2026110501) stopped for 19 s right
/// after Read aloud in a room of replies to replies, deep in nested stack layout, placing a secondary layer (an overlay)
/// by its alignment. These measure what one Read aloud costs as a message nests deeper (block quotes inside block quotes, as
/// replies quoting replies make), on the room itself and on a counted copy of the same nesting, and require the cost to
/// grow no faster than the nesting.
final class ReadAloudLayoutTests: XCTestCase {
    // MARK: - The room itself

    /// One agent message whose text nests block quotes `depth` deep, each with a paragraph and a list under it, read
    /// aloud in the room: the pass that puts the mark on it is timed. The deepest may cost about as many times the
    /// shallowest as it is deeper (with room for noise), and no pass may take a second.
    func test_reading_a_message_aloud_costs_no_more_than_its_nesting_in_the_room() throws {
        var seconds: [Int: Double] = [:]
        for depth in [1, 3, 5, 7] {
            let state = Self.room([Self.agentMessage(1, text: Self.nestedQuotes(depth))])
            seconds[depth] = try readAloudPass(state, reading: [1]).max() ?? 0
            print("READALOUD room depth \(depth): \(Int((seconds[depth] ?? 0) * 1000)) ms")
        }
        for depth in [1, 3, 5, 7] {
            XCTAssertLessThan(seconds[depth] ?? 0, 1,
                              "depth \(depth): Read aloud laid the message out in under a second")
        }
        let base = max(seconds[1] ?? 0, 0.002)
        XCTAssertLessThanOrEqual(seconds[7] ?? 0, base * 7 * 3 + 0.05,
                                 "7 deep costs no more than about 7 times 1 deep: it grows with the nesting, not faster")
    }

    /// A room shaped like Carter's (about 75 rows: agents' long Markdown with lists, tables, code and quotes, and
    /// replies to replies folded into threads), each of the first 10 rows read aloud in turn: no pass takes a second.
    func test_reading_aloud_in_a_room_of_replies_to_replies_never_takes_a_second() throws {
        let inputs = Self.carterShapedRoom()
        let state = Self.room(inputs)
        XCTAssertGreaterThanOrEqual(state.rows.count, 70, "a room of about 75 rows")
        print("READALOUD Carter-shaped room: \(state.rows.count) rows")
        let sequences = state.rows.compactMap { row -> Int64? in
            if case .message(let message) = row { return message.sequenceId }
            return nil
        }
        let passes = try readAloudPass(state, reading: Array(sequences.prefix(10)))
        print("READALOUD Carter-shaped room: \(passes.map { Int($0 * 1000) }) ms")
        XCTAssertLessThan(passes.max() ?? 0, 1, "every Read aloud pass in the room laid out in under a second")
    }

    // MARK: - The same nesting, counted

    /// Where the mark goes, compared on a counted copy of the room's nesting (each quote level counts the times it is
    /// sized, placed or asked for an alignment): the mark laid over the message by its top-trailing corner (as the room
    /// does), centred over it, or aligned inside a plain layer over the message (asking nothing of the message's
    /// stacks); and no mark. Reported for comparison; the counter must see the levels it counts.
    func test_where_the_mark_goes_counted_on_a_copy_of_the_nesting() {
        var calls: [Variant: [Int: Int]] = [:]
        for variant in Variant.allCases {
            for depth in [1, 3, 5, 7] {
                let (count, seconds) = countedPass(variant, depth: depth)
                calls[variant, default: [:]][depth] = count
                print("READALOUD counted \(variant) depth \(depth): \(count) layout calls, \(Int(seconds * 1000)) ms")
            }
        }
        XCTAssertGreaterThan(calls[.topTrailingOverlay]?[7] ?? 0, 0, "the counter sees the levels it counts")
    }

    // MARK: - Measuring the room

    private final class RoomModel: ObservableObject {
        let state: RoomChatPresentationState
        @Published var reading: String?
        init(_ state: RoomChatPresentationState) { self.state = state }
    }

    private struct RoomHost: View {
        @ObservedObject var model: RoomModel
        var body: some View {
            RoomChatView(state: model.state, readingAloudId: model.reading) { _ in }
                .frame(width: 402, height: 874)
        }
    }

    /// The room laid out, then each of `reading` read aloud in turn: the seconds from setting it to the room laid out
    /// again, for each.
    private func readAloudPass(_ state: RoomChatPresentationState, reading: [Int64]) throws -> [Double] {
        let model = RoomModel(state)
        let host = NSHostingView(rootView: RoomHost(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 402, height: 874), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pump(0.5)
        let rows = state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
        var passes: [Double] = []
        for sequence in reading {
            let row = try XCTUnwrap(rows.first { $0.sequenceId == sequence })
            let start = CFAbsoluteTimeGetCurrent()
            model.reading = row.readAloudId
            settle(host)
            passes.append(CFAbsoluteTimeGetCurrent() - start)
            model.reading = nil
            settle(host)
        }
        window.contentView = nil
        return passes
    }

    /// Runs the main run loop and lays the view out, three times: the update the change asked for and its layout.
    private func settle(_ view: NSView) {
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            view.layoutSubtreeIfNeeded()
        }
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }

    // MARK: - Measuring the counted copy

    enum Variant: String, CaseIterable, CustomStringConvertible {
        /// No mark at all.
        case none
        /// Over the message by its top-trailing corner, as the room does: `.overlay(alignment: .topTrailing)`.
        case topTrailingOverlay
        /// Centred over the message: `.overlay { }`.
        case centredOverlay
        /// Aligned inside a plain layer over the message, so nothing asks the message for an alignment.
        case plainLayer

        var description: String { rawValue }
    }

    private final class MarkModel: ObservableObject {
        @Published var shown = false
    }

    private struct CountedMessage: View {
        let variant: Variant
        let depth: Int
        @ObservedObject var model: MarkModel

        var body: some View {
            switch variant {
            case .none:
                message
            case .topTrailingOverlay:
                message.overlay(alignment: .topTrailing) { if model.shown { mark } }
            case .centredOverlay:
                message.overlay { if model.shown { mark } }
            case .plainLayer:
                message.overlay {
                    Color.clear.overlay(alignment: .topTrailing) { if model.shown { mark } }
                }
            }
        }

        private var message: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("plan-agent").font(.subheadline.weight(.semibold))
                    Text("2:04 PM").font(.caption)
                    Spacer(minLength: 0)
                }
                CountingLayout { QuoteNest(depth: depth) }
                HStack(spacing: 16) {
                    Image(systemName: "doc.on.doc")
                    Image(systemName: "speaker.wave.2")
                    Image(systemName: "arrowshape.turn.up.left")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }

        private var mark: some View {
            Image(systemName: "speaker.wave.2.fill")
                .frame(width: 44, height: 44, alignment: .topTrailing)
                .padding(4)
        }
    }

    /// A block quote with a paragraph and a list under it, `depth` deep, each level counted, as `ChatMarkdownView` lays
    /// out a quote: a bar beside the quote's own blocks.
    private struct QuoteNest: View {
        let depth: Int

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Level \(depth): a paragraph long enough to wrap onto a second line in a row of the room.")
                    if depth > 1 { CountingLayout { QuoteNest(depth: depth - 1) } }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text("A point under it, also long enough to wrap onto a second line.")
                    }
                    .padding(.leading, 16)
                }
            }
        }
    }

    /// Counts each time a level is sized, placed or asked for an alignment, and passes it all to its one view.
    private struct CountingLayout: Layout {
        nonisolated(unsafe) static var calls = 0

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            Self.calls += 1
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            Self.calls += 1
            subviews.first?.place(at: bounds.origin, proposal: proposal)
        }

        func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                               subviews: Subviews, cache: inout ()) -> CGFloat? {
            Self.calls += 1
            return subviews.first?.dimensions(in: proposal)[explicit: guide].map { $0 + bounds.minX }
        }

        func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                               subviews: Subviews, cache: inout ()) -> CGFloat? {
            Self.calls += 1
            return subviews.first?.dimensions(in: proposal)[explicit: guide].map { $0 + bounds.minY }
        }
    }

    /// The counted message laid out without its mark, then with it: the layout calls and seconds of that pass.
    private func countedPass(_ variant: Variant, depth: Int) -> (Int, Double) {
        let model = MarkModel()
        let host = NSHostingView(rootView: CountedMessage(variant: variant, depth: depth, model: model)
            .frame(width: 402, alignment: .topLeading))
        host.frame = NSRect(x: 0, y: 0, width: 402, height: 2_000)
        host.layoutSubtreeIfNeeded()
        pump(0.05)
        CountingLayout.calls = 0
        let start = CFAbsoluteTimeGetCurrent()
        model.shown = true
        settle(host)
        return (CountingLayout.calls, CFAbsoluteTimeGetCurrent() - start)
    }

    // MARK: - Rooms

    static func room(_ inputs: [RoomChatMessageInput]) -> RoomChatPresentationState {
        RoomChatPresentationState(sessionId: "room", title: "Room", messages: inputs, ownAuthorIds: ["human-alex"],
                                  connection: .live, composer: RoomComposerState(canPost: true, disabledReason: nil),
                                  canReact: true)
    }

    static func agentMessage(_ sequence: Int64, text: String, author: String = "plan-agent") -> RoomChatMessageInput {
        let date = Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence) * 60)
        return RoomChatMessageInput(id: "m\(sequence)", sequenceId: sequence, kind: .message, authorId: author,
                                    authorName: author, isHuman: author.hasPrefix("human-"), text: text,
                                    timestamp: "", date: date)
    }

    static func reply(_ sequence: Int64, to thread: Int64, text: String, author: String) -> RoomChatMessageInput {
        let date = Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence) * 60)
        return RoomChatMessageInput(id: "r\(sequence)", sequenceId: sequence, kind: .message, authorId: author,
                                    authorName: author, isHuman: author.hasPrefix("human-"), text: text,
                                    timestamp: "", replyToSequenceId: thread, date: date,
                                    inlineReplyId: "00000000-0000-4000-8000-\(String(format: "%012lld", sequence))")
    }

    /// Block quotes `depth` deep, each level with a paragraph and a two-level list.
    static func nestedQuotes(_ depth: Int) -> String {
        var lines: [String] = []
        for level in 0..<depth {
            let prefix = String(repeating: "> ", count: level)
            lines.append(prefix + "Level \(level + 1): what the reply before said, quoted, long enough to wrap a line.")
            lines.append(prefix)
            lines.append(prefix + "- a point it made, also long enough to wrap onto a second line")
            lines.append(prefix + "  - and a point under that one")
            lines.append(prefix)
        }
        lines.append("And the answer to all of it, below the quotes.")
        return lines.joined(separator: "\n")
    }

    /// About 75 rows: agents' long Markdown (headings, lists four levels deep, a table, code, quotes three deep) and
    /// threads whose replies answer replies, each quoting the one before (so the newest quotes three deep).
    static func carterShapedRoom() -> [RoomChatMessageInput] {
        let agents = ["claude-warden", "pocket-forge", "plan-agent"]
        let long = """
        ## Where it stands

        - The build is out
          - two fixes in it
            - the side panel
              - and the room's rows
        - One thing left

        | Step | State |
        | --- | --- |
        | Build | done |
        | Review | open |

        ```
        let rows = state.rows.count
        ```

        > > > What was asked first, quoted three deep.
        > > What was said to that.
        > And the answer before this one.

        That is all for now.
        """
        // A thread folds into one row (its newest answer, with the trail), so 38 messages and their threads make about
        // 76 rows.
        var inputs: [RoomChatMessageInput] = []
        var sequence: Int64 = 1
        for thread in 0..<38 {
            let root = sequence
            inputs.append(agentMessage(root, text: long, author: agents[thread % 3]))
            sequence += 1
            var quoted = "the first answer"
            for turn in 0..<3 {
                let author = turn % 2 == 0 ? "human-alex" : agents[(thread + turn) % 3]
                let quote = "> " + quoted.replacingOccurrences(of: "\n", with: "\n> ")
                let text = quote + "\n\nAnswer \(turn + 1) to that, in a few words."
                inputs.append(reply(sequence, to: root, text: text, author: author))
                quoted = text
                sequence += 1
            }
        }
        return inputs
    }
}
#endif
