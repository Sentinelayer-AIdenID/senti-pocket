import Foundation
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// Carter's freezes on build 17 (#56316, #56340): the room drew its rows without end until iOS ended the app, once just
/// after a voice call began over a room of review packets, once just after a room opened and the one before it closed.
/// These host the room as the app does, in a window on the simulator, with a room like his, and go through both. The
/// room must settle: its rows drawn a bounded number of times, and the main thread free to run a timer throughout.
///
/// On the simulator the room settled through both before the fix as well: the loop needs the phone's own geometry, a
/// marker within a point of the edge. These guard the two transitions; `RoomBottomSettleTests` pins the settling itself.
@MainActor
final class RoomBottomFlapTests: XCTestCase {
    private var window: UIWindow?
    private let watch = MainThreadStuckWatch()

    /// The room, its rows and the parts of the app around it that change at a call or a room switch.
    private final class Room: ObservableObject {
        @Published private(set) var state: RoomChatPresentationState
        @Published var shows = true
        @Published var key = 0
        @Published var covered = false
        @Published var drawerOpen = false
        private(set) var inputs: [RoomChatMessageInput]
        private var loading = false
        /// The coordinator's side of the reader's place: arrivals while away are unread, and coming back clears them.
        private var atBottom = true
        private var unread = 0
        private var divider: Int64?
        private(set) var placeChanges = 0
        /// Every time the room told its place, changed or not.
        private(set) var placeReports = 0
        static let own: Set<String> = ["human-mrrcarter"]

        init(_ inputs: [RoomChatMessageInput]) {
            self.inputs = inputs
            state = RoomChatPresentationState(sessionId: "flap", title: "Review room", messages: [])
            publish()
        }

        func send(_ intent: RoomChatIntent) {
            guard case .readerAtBottom(let value) = intent else { return }
            placeReports += 1
            guard value != atBottom else { return }
            placeChanges += 1
            atBottom = value
            if value, unread > 0 || divider != nil {
                unread = 0
                divider = nil
                publish()
            }
        }

        func arrive(_ more: [RoomChatMessageInput]) {
            inputs += more
            let others = more.filter { !Self.own.contains($0.authorId.lowercased()) }
            if !atBottom, let first = others.first {
                unread += others.count
                divider = min(divider ?? first.sequenceId, first.sequenceId)
            }
            publish()
        }

        /// Another room on screen: a new list, loading first, as the app's room swap does.
        func open(_ rows: [RoomChatMessageInput]) {
            key += 1
            inputs = rows
            atBottom = true
            unread = 0
            divider = nil
            loading = true
            publish()
        }

        func finishLoading() {
            loading = false
            publish()
        }

        func publish() {
            state = RoomChatPresentationState(
                sessionId: "flap-\(key)",
                title: "Review room",
                messages: loading ? [] : inputs,
                ownAuthorIds: Self.own,
                unreadDividerSequence: divider,
                unreadCount: unread,
                isLoadingInitial: loading,
                canLoadOlder: true,
                connection: .live,
                composer: RoomComposerState(canPost: true, disabledReason: nil),
                canReact: true,
                canPin: true
            )
        }
    }

    /// The room in a navigation stack under the side panel's card, as `SentiPocketApp` shows it.
    private struct Host: View {
        @ObservedObject var room: Room

        var body: some View {
            ZStack(alignment: .leading) {
                Color.gray.opacity(0.2)
                NavigationStack {
                    Group {
                        if room.shows {
                            RoomChatView(state: room.state) { room.send($0) }
                                .id(room.key)
                        } else {
                            Text("Rooms")
                        }
                    }
                    .toolbar { ToolbarItem(placement: .navigationBarLeading) { Image(systemName: "line.3.horizontal") } }
                }
                .environment(\.roomIsCovered, room.covered || room.drawerOpen)
                .scaleEffect(room.drawerOpen ? 0.9 : 1, anchor: .leading)
                .offset(x: room.drawerOpen ? 300 : 0)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: room.drawerOpen)
        }
    }

    // MARK: - The rooms

    private static let start = Date(timeIntervalSince1970: 1_793_000_000)

    private static func input(_ seq: Int64, _ author: String, _ text: String, voice: Bool = false) -> RoomChatMessageInput {
        let date = start.addingTimeInterval(Double(seq - 56_000) * 20)
        return RoomChatMessageInput(
            id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: author, authorName: author,
            isHuman: author.hasPrefix("human-"), text: text, timestamp: ISO8601DateFormatter().string(from: date),
            date: date, isVoiceTurn: voice
        )
    }

    /// A review packet like the 70 in Carter's room: addressed to another agent (so a quiet row), a JSON header of about
    /// 700 characters on its first line, then up to a few hundred short lines, about 9.5 KB in all. Made up: no room's
    /// words are in this repository.
    private static func packet(_ part: Int) -> String {
        var header = "@aneta-claude REVIEW_PACKET {\"packet\":\"flap-test-packet\",\"message_part\":\"\(part)/70\""
        while header.count < 690 { header += ",\"key_\(header.count)\":\"value \(header.count % 89)\"" }
        var lines = [header + ","]
        var size = header.count
        var index = 0
        let wanted = [34, 48, 170, 230, 360][part % 5]
        while size < 9_400, lines.count < wanted || size < 3_000 {
            let line = "  \"field_\(index)\": \"\(String(repeating: "x", count: (index * 7) % 60))\","
            lines.append(line)
            size += line.count + 1
            index += 1
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// The room as it was at the call: agents' notes, the orchestrator's costs, 70 review packets, a long contract that
    /// is not background (it shows its start and a card), and Carter's own messages.
    private static func reviewRoom() -> [RoomChatMessageInput] {
        var rows: [RoomChatMessageInput] = []
        var seq: Int64 = 56_200
        func add(_ author: String, _ text: String) {
            seq += 1
            rows.append(input(seq, author, text))
        }
        for note in 0..<8 {
            add("respawn-orchestrator", "[cost] flap-box-\(note % 3): $\(12 + note).64 est over \(140 + note) calls")
            add("claude-warden", "@gpt-astra-carter Review note \(note): " + String(repeating: "a finding ", count: 12 + note * 9))
            add("pocket-forge", "@human-mrrcarter " + String(repeating: "a status line ", count: 8 + note * 7))
        }
        for part in 1...70 { add("gpt-astra-carter", packet(part)) }
        add("aneta-claude", "CONTRACT\n" + Array(repeating: "- a clause about what the review covers", count: 120).joined(separator: "\n"))
        add("human-mrrcarter", "@aneta-claude what does the packet say about the scope?")
        add("claude-warden", "@human-mrrcarter A short answer.")
        return rows
    }

    /// Carter's main room: mostly the orchestrator's one-line notices, boxes starting, and short notes.
    private static func mainRoom() -> [RoomChatMessageInput] {
        var rows: [RoomChatMessageInput] = []
        var seq: Int64 = 55_800
        func add(_ author: String, _ text: String) {
            seq += 1
            rows.append(input(seq, author, text))
        }
        for line in 0..<80 {
            switch line % 8 {
            case 0: add("respawn-orchestrator", "checkpoint refused for life \(String(line * 7919, radix: 16))")
            case 3: add("claude-warden", "@astra-box-\(line) " + String(repeating: "deploy note ", count: 10 + line % 30))
            case 5: add("human-mrrcarter", "A note from the phone \(line).")
            case 6: add("pocket-forge", "@human-mrrcarter " + String(repeating: "an update ", count: 6 + line % 40))
            default: add("respawn-orchestrator", "[cost] astra-box-\(line % 5): $\(line).30 est over \(line * 3) calls")
            }
        }
        return rows
    }

    // MARK: - Running it

    private func host(_ room: Room) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 5
        window.rootViewController = UIHostingController(rootView: Host(room: room))
        window.makeKeyAndVisible()
        self.window = window
        watch.start()
    }

    private func close() {
        watch.stop()
        VoiceCallWindow.shared.hide()
        window?.isHidden = true
        window = nil
        pump(0.4)
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }

    /// Does `step`, then runs the main run loop for `seconds`: the rows may be drawn at most `maximumDraws` times, and a
    /// 50 ms timer must keep firing (a room redrawing without end never lets it fire at all; a busy simulator still lets
    /// it fire a quarter of the time).
    private func settles(_ name: String, seconds: TimeInterval = 1.5, maximumDraws: Int = 5_000,
                         file: StaticString = #filePath, line: UInt = #line, _ step: () -> Void) {
        watch.phase(name)
        let fires = FireCount()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in fires.add() }
        let before = RenderTrace.snapshot().draws
        step()
        pump(seconds)
        timer.invalidate()
        let draws = RenderTrace.snapshot().draws - before
        let expected = Int(seconds / 0.05)
        XCTAssertLessThan(draws, maximumDraws, "\(name): the rows were drawn \(draws) times", file: file, line: line)
        XCTAssertGreaterThanOrEqual(fires.value, expected / 4, "\(name): the main thread stopped answering", file: file, line: line)
    }

    /// #56316: Carter was at the bottom of a room of review packets and started a call. Its window came over the room,
    /// the room was covered, the call's message arrived and folded into its card, the agent answered, and he hung up.
    func test_a_call_starting_over_a_room_of_review_packets_lets_the_room_settle() throws {
        let rows = Self.reviewRoom()
        let room = Room(rows)
        try host(room)
        defer { close() }
        settles("open") {}
        let last = rows.last?.sequenceId ?? 0
        settles("the call begins", seconds: 2) {
            _ = VoiceCallWindow.shared.show(Color.black.ignoresSafeArea())
            room.covered = true
            room.arrive([Self.input(last + 1, "human-mrrcarter", VoiceCallMarkers.start(
                caller: "mrrcarter", agents: ["pocket-forge"], meeting: false))])
        }
        settles("the agent answers") {
            room.arrive([Self.input(last + 2, "pocket-forge", "Hello, I'm here.", voice: true)])
        }
        settles("more packets arrive") {
            room.arrive((1...6).map { Self.input(last + 2 + Int64($0), "gpt-astra-carter", Self.packet(70 + $0)) })
        }
        settles("hang up") {
            VoiceCallWindow.shared.hide()
            room.covered = false
        }
    }

    /// #56340: from the side panel Carter opened another room; it loaded while the panel closed, and the room before it
    /// closed. Then the room is closed too.
    func test_a_room_opened_from_the_side_panel_then_closed_lets_the_room_settle() throws {
        let room = Room(Self.reviewRoom())
        try host(room)
        defer { close() }
        settles("open") {}
        settles("the side panel opens", seconds: 1) { room.drawerOpen = true }
        settles("another room is picked", seconds: 0.5) {
            room.open(Self.mainRoom())
            room.drawerOpen = false
        }
        settles("it loads", seconds: 2) { room.finishLoading() }
        settles("back to the packets", seconds: 2) {
            room.open(Self.reviewRoom())
            room.finishLoading()
        }
        let reports = room.placeReports
        settles("the room closes") { room.shows = false }
        XCTAssertEqual(room.placeReports, reports, "a closing room never tells the coordinator its place (#56340)")
    }

    /// What made the loop: the marker leaving view wrote the reader's place in the same layout pass. It now lands only
    /// once the marker has stayed gone (`RoomBottomSettle.leaveDelay`), never in the pass that moved it.
    func test_the_marker_leaving_view_never_writes_the_place_in_that_layout_pass() throws {
        let room = Room(Self.reviewRoom())
        try host(room)
        defer { close() }
        settles("open") {}
        let scroll = try XCTUnwrap(window.flatMap { Self.list(in: $0) }, "the room's list")
        let changes = room.placeChanges
        settles("scrolled up", seconds: 0.05) {
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentOffset.y - 400)), animated: false)
        }
        XCTAssertEqual(room.placeChanges, changes, "not in the pass that moved the marker")
        pump(0.4)
        XCTAssertEqual(room.placeChanges, changes + 1, "once it has stayed gone, the reader is away from the bottom")
    }

    /// The room's list: the tallest scroll view in the window.
    private static func list(in view: UIView) -> UIScrollView? {
        var found = view as? UIScrollView
        for child in view.subviews {
            if let inner = list(in: child), inner.contentSize.height > (found?.contentSize.height ?? 0) { found = inner }
        }
        return found
    }
}

/// A 50 ms timer's fires, counted on the main thread.
private final class FireCount: @unchecked Sendable {
    private(set) var value = 0
    func add() { value += 1 }
}

/// A room that redraws without end never returns to the run loop, so no assertion could run: this watches from a
/// background queue and ends the test run with what it saw once the main thread has been stuck for `limit` seconds.
private final class MainThreadStuckWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var beat = Date()
    private var name = ""
    private var drawsAtPhase = 0
    private var timer: DispatchSourceTimer?
    static let limit: TimeInterval = 8

    func start() {
        lock.lock()
        beat = Date()
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func phase(_ name: String) {
        lock.lock()
        self.name = name
        beat = Date()
        drawsAtPhase = RenderTrace.snapshot().draws
        lock.unlock()
    }

    private func tick() {
        lock.lock()
        let stuck = Date().timeIntervalSince(beat)
        let phase = name
        let draws = RenderTrace.snapshot().draws - drawsAtPhase
        lock.unlock()
        if stuck > Self.limit {
            fatalError("The room never settled after \"\(phase)\": the main thread was stuck \(Int(stuck)) s, "
                + "with \(draws) row draws (Carter's freeze, #56316).")
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.beat = Date()
            self.lock.unlock()
        }
    }
}
