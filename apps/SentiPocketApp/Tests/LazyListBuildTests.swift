import Combine
import Foundation
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// The room's rows and the side panel's rooms are lazy lists: each builds the items it shows, never every item it holds.
///
/// Carter's phone froze three times (11-04 23:38 and 11-05 08:06, build 2026110310) with its main thread stuck for 12 to
/// 13.5 s inside a lazy list's placement, going through the list's items one by one: an item that could make a varying
/// number of views (a room with its direct messages under it, a message with its turn break or file cards, a folded
/// file part with none) made the list build every item, on screen or not, at every layout pass, to count them. These
/// tests count the items built when a list opens and when it is laid out again, with a room or a panel several times
/// longer than the screen: the items on screen and a few around them, not the whole list.
@MainActor
final class LazyListBuildTests: XCTestCase {
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "pocket.drawer.foldedFolders")
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        pump(0.4)
        UserDefaults.standard.removeObject(forKey: "pocket.drawer.foldedFolders")
        super.tearDown()
    }

    /// The most items a list may build in one step: a screen holds fewer than 20 rooms or rows, at any text size, and a
    /// lazy list builds a few beyond it. The lists below hold 400 rows and 300 rooms. Measured on the build Mac: 8 to 38
    /// a step once the lists are one view per item; 300 to 1,209 a step before, every item of the list or more.
    static let mostBuiltPerStep = 80

    // MARK: - The room

    func test_the_room_builds_only_the_rows_it_shows_as_it_opens_and_as_it_is_laid_out_again() throws {
        let room = Room(Self.room(rows: 400))
        try host(RoomHost(room: room))
        let rows = room.state.rows.count
        XCTAssertGreaterThan(rows, 400, "the room holds 400 messages, their day and file rows")

        // Opening at its newest rows, the list may go through its rows once to find its end; never again after that.
        step("open", rows: rows, list: .roomRow, most: rows + Self.mostBuiltPerStep) {}
        // The room drawn again with nothing changed: its screen's body runs again at every draw of the root.
        step("drawn again, nothing changed", rows: rows, list: .roomRow) { room.objectWillChange.send() }
        step("drawn again, nothing changed, twice", rows: rows, list: .roomRow) { room.objectWillChange.send() }
        // A message arrives, and another.
        step("an arrival", rows: rows, list: .roomRow) { room.state = Self.room(rows: 401) }
        step("another arrival", rows: rows, list: .roomRow) { room.state = Self.room(rows: 402) }
        // Another room put on screen in its place, as a room picked from the side panel: an open again.
        step("another room", rows: rows, list: .roomRow, most: 300 + Self.mostBuiltPerStep) {
            room.state = Self.room(rows: 300, id: "other")
        }
        step("drawn again, nothing changed, in the other room", rows: rows, list: .roomRow) {
            room.objectWillChange.send()
        }
    }

    /// A message that is a part of a file posted as base64 folds behind the file's card and shows nothing. It keeps its
    /// row and its id, and takes no height and no space between rows: the room with it is exactly as tall as the room
    /// without it.
    func test_a_folded_file_part_takes_no_height_and_no_space() throws {
        let withPart = try contentHeight(of: Self.fileRoom(withFirstPart: true))
        let withoutPart = try contentHeight(of: Self.fileRoom(withFirstPart: false))
        print("LAZYLIST folded part: room \(withPart) pt tall with it, \(withoutPart) pt without")
        XCTAssertGreaterThan(withPart, 100, "the room was laid out")
        XCTAssertEqual(withPart, withoutPart, accuracy: 0.5, "the folded part adds no height and no spacing")
        let state = Self.fileRoom(withFirstPart: true)
        let ids = state.rows.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "every row has its own id")
        XCTAssertTrue(state.rows.contains { row in
            if case .message(let message) = row { return message.id == "part-1" && message.filePartOf == 99 }
            return false
        }, "the folded part keeps its row")
    }

    // MARK: - A scroll to a row finds it by the loop's own id

    /// The rows carry no `.id` of their own: every scroll to a row (a focused message, a held row, the place kept as
    /// older rows load) finds it by the loop's id, `RoomChatRow.id`. Opened at a message far up a room of 400, the room
    /// is there, far from its bottom (where it would be had the scroll found nothing), and it stays there while
    /// messages arrive below (the held row, scrolled to again at every change of the rows).
    func test_a_room_opened_at_a_message_far_up_goes_there_and_holds_it_while_messages_arrive() throws {
        let room = Room(Self.room(rows: 400, focus: 60))
        try host(RoomHost(room: room))
        XCTAssertTrue(quiet { [RenderTrace.builtCount(.roomRow), RenderTrace.snapshot().draws] })
        let scroll = try XCTUnwrap(window.flatMap { Self.list(in: $0) }, "the room's list")
        let away = Self.bottomOffset(of: scroll) - scroll.contentOffset.y
        print("LAZYLIST focused message: \(Int(away)) pt above the bottom of \(Int(scroll.contentSize.height))")
        XCTAssertGreaterThan(away, 3 * scroll.bounds.height, "at the message, far up the room")
        XCTAssertTrue(room.intents.contains(.focusHandled), "the room was told the message is in view")
        let held = scroll.contentOffset.y
        room.state = Self.room(rows: 402, focus: 60)
        XCTAssertTrue(quiet { [RenderTrace.builtCount(.roomRow), RenderTrace.snapshot().draws] })
        let moved = abs(scroll.contentOffset.y - held)
        print("LAZYLIST held message: moved \(Int(moved)) pt as two messages arrived")
        XCTAssertLessThan(moved, scroll.bounds.height / 2, "the held message stays in view as messages arrive below")
    }

    /// Scrolled to the top, the room asks for older messages; when they load above, the row that was at the top is
    /// scrolled back to the top (by its loop id), so the reader's place does not jump to the oldest loaded message.
    func test_older_messages_loading_above_keep_the_reader_at_the_row_they_were_reading() throws {
        let room = Room(Self.room(rows: 200, first: 201, canLoadOlder: true))
        try host(RoomHost(room: room))
        XCTAssertTrue(quiet { [RenderTrace.builtCount(.roomRow), RenderTrace.snapshot().draws] })
        let scroll = try XCTUnwrap(window.flatMap { Self.list(in: $0) }, "the room's list")
        // Up to the top, a screen at a time, as a reader does, until the room asks for older messages.
        let deadline = Date().addingTimeInterval(15)
        while !room.intents.contains(.loadOlder), Date() < deadline {
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentOffset.y - scroll.bounds.height)),
                                    animated: false)
            pump(0.1)
        }
        XCTAssertTrue(room.intents.contains(.loadOlder), "at the top the room asks for older messages")
        room.state = Self.room(rows: 400, first: 1)
        XCTAssertTrue(quiet { [RenderTrace.builtCount(.roomRow), RenderTrace.snapshot().draws] })
        print("LAZYLIST older loaded: \(Int(scroll.contentOffset.y)) pt from the top")
        XCTAssertGreaterThan(scroll.contentOffset.y, 3 * scroll.bounds.height,
                             "the row read before is still at the top, with the older messages above it")
    }

    // MARK: - The side panel

    func test_the_side_panel_builds_only_the_rooms_it_shows_as_it_opens_and_as_its_rooms_change() throws {
        let panel = Panel(rooms: Self.panelRooms(), folders: Self.folders)
        try host(PanelHost(panel: panel))
        let lines = panel.rooms.count
        XCTAssertEqual(lines, 300, "the panel lists 240 rooms and 60 direct messages")

        step("open", rows: lines, list: .sidePanel) {}
        // The panel's poll lands: a room further down had a message and moves to the top, unread counts change.
        step("its rooms change", rows: lines, list: .sidePanel) { panel.rooms = Self.panelRooms(moved: 150, unread: 3) }
        // Down the panel, looking for a room: the rooms above are not on screen.
        step("scrolled down the panel", rows: lines, list: .sidePanel) { scrollToEnd() }
        step("its rooms change down the panel", rows: lines, list: .sidePanel) {
            panel.rooms = Self.panelRooms(moved: 90, unread: 7)
        }
        step("drawn again, nothing changed", rows: lines, list: .sidePanel) { panel.objectWillChange.send() }
        step("a folder folds", rows: lines, list: .sidePanel) {
            UserDefaults.standard.set("folder-2", forKey: "pocket.drawer.foldedFolders")
        }
    }

    // MARK: - Measuring

    /// Scrolls the window's list to its end, as a reader does looking for a room far down.
    private func scrollToEnd() {
        guard let scroll = window.flatMap({ Self.list(in: $0) }) else { return XCTFail("no list in the window") }
        let end = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, end)), animated: false)
    }

    /// Does `change`, then runs the main run loop until nothing has been built or drawn for a second (at most 15 s): the
    /// list has finished laying out and the main thread is idle again. The items built in that time are counted.
    private func step(_ name: String, rows: Int, list: RenderTrace.List, most: Int = LazyListBuildTests.mostBuiltPerStep,
                      file: StaticString = #filePath, line: UInt = #line, _ change: () -> Void) {
        let before = RenderTrace.builtCount(list)
        let started = Date()
        change()
        let idle = quiet { [RenderTrace.builtCount(list), RenderTrace.snapshot().draws] }
        let built = RenderTrace.builtCount(list) - before
        print("LAZYLIST \(list) \(name): \(built) of \(rows) built, idle after "
            + "\(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        XCTAssertTrue(idle, "\(name): the list was still building after 15 s", file: file, line: line)
        XCTAssertLessThanOrEqual(built, most, "\(name): built \(built) of \(rows) items, not only those it shows",
                                 file: file, line: line)
    }

    /// Runs the main run loop until `activity` has not moved for a second; false if it still moved after 15 s.
    private func quiet(_ activity: () -> [Int]) -> Bool {
        let end = Date().addingTimeInterval(15)
        var last = activity()
        var quietSince = Date()
        while Date() < end {
            pump(0.1)
            let now = activity()
            if now != last {
                last = now
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) >= 1 {
                return true
            }
        }
        return false
    }

    private func host<Content: View>(_ view: Content) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        self.window = window
    }

    /// The height of the room's list once laid out, all of it on screen.
    private func contentHeight(of state: RoomChatPresentationState) throws -> CGFloat {
        try host(RoomHost(room: Room(state)))
        XCTAssertTrue(quiet { [RenderTrace.builtCount(.roomRow), RenderTrace.snapshot().draws] })
        let scroll = try XCTUnwrap(window.flatMap { Self.list(in: $0) }, "the room's list")
        let height = scroll.contentSize.height
        window?.isHidden = true
        window = nil
        pump(0.2)
        return height
    }

    /// The content offset at which the list shows its last row.
    private static func bottomOffset(of scroll: UIScrollView) -> CGFloat {
        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
    }

    /// The tallest scroll view in the window: the room's list.
    private static func list(in view: UIView) -> UIScrollView? {
        var found = view as? UIScrollView
        for child in view.subviews {
            if let inner = list(in: child), inner.contentSize.height > (found?.contentSize.height ?? 0) { found = inner }
        }
        return found
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }

    // MARK: - The lists

    private final class Room: ObservableObject {
        @Published var state: RoomChatPresentationState
        /// What the room asked of its coordinator.
        var intents: [RoomChatIntent] = []
        init(_ state: RoomChatPresentationState) { self.state = state }
    }

    private struct RoomHost: View {
        @ObservedObject var room: Room
        var body: some View {
            NavigationStack { RoomChatView(state: room.state) { room.intents.append($0) } }
        }
    }

    private final class Panel: ObservableObject {
        @Published var rooms: [PocketSidePanel.Room]
        let folders: [RoomFolderItem]
        init(rooms: [PocketSidePanel.Room], folders: [RoomFolderItem]) {
            self.rooms = rooms
            self.folders = folders
        }
    }

    private struct PanelHost: View {
        @ObservedObject var panel: Panel
        var body: some View {
            PocketSidePanel(rooms: panel.rooms, currentRoomId: "room-001", unreadNotifications: 3, waitingOnYou: 2,
                            accountName: "Alex", theme: .constant(.system), onSelectRoom: { _ in }, onAllRooms: {},
                            onNotifications: {}, onCalls: {}, onActivity: {}, onSettings: {}, onNewRoom: {},
                            folders: panel.folders, onFolder: { _ in })
                .frame(width: 286)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A room of `rows` messages over three days: agents and a person taking turns, some long, every tenth a file
    /// posted as three base64 parts (two fold away, the newest carries the file's card). Made-up words only.
    static func room(rows: Int, id: String = "room", first: Int = 1, focus: Int64? = nil,
                     canLoadOlder: Bool = false) -> RoomChatPresentationState {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var files: [Int64: [RoomChatFileCard]] = [:]
        var parts: [String: Int64] = [:]
        var messages: [RoomChatMessageInput] = []
        let stamp = ISO8601DateFormatter()
        let agents = ["review-agent", "build-agent", "plan-agent"]
        for index in first...(first + rows - 1) {
            let seq = Int64(index)
            let author = index % 7 == 0 ? "human-alex" : agents[index % 3]
            let date = start.addingTimeInterval(Double(index) * 650)
            var text = "Message \(index)."
            if index % 5 == 0 {
                text = "Message \(index), long enough to wrap: " + String(repeating: "a note about the build ", count: 8)
            }
            if index % 10 >= 7 {
                let thread = Int64(index - index % 10 + 9)
                parts["evt-\(id)-\(index)"] = thread
                if index % 10 == 9 {
                    let card = RoomChatFileCard(thread: thread, name: "pack-\(index).zip", author: author, sha256: nil,
                                                verified: nil, status: "parts missing", partsTotal: 3, partPosts: 3,
                                                previewable: false)
                    files[seq] = [card]
                }
            }
            messages.append(RoomChatMessageInput(id: "evt-\(id)-\(index)", sequenceId: seq, kind: .message,
                                                 authorId: author, authorName: author,
                                                 isHuman: author.hasPrefix("human-"), text: text,
                                                 timestamp: stamp.string(from: date), date: date))
        }
        return RoomChatPresentationState(sessionId: id, title: "Room", messages: messages, ownAuthorIds: ["human-alex"],
                                         canLoadOlder: canLoadOlder, connection: .live,
                                         composer: RoomComposerState(canPost: true, disabledReason: nil),
                                         canReact: true, focusSequenceId: focus, files: files, fileParts: parts)
    }

    /// A short room with a file posted in two parts at the top level: the newest part carries the card, the first folds
    /// away. Without the first part, the same room otherwise.
    static func fileRoom(withFirstPart: Bool) -> RoomChatPresentationState {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        func input(_ id: String, _ seq: Int64, _ text: String) -> RoomChatMessageInput {
            let date = start.addingTimeInterval(Double(seq) * 20)
            return RoomChatMessageInput(id: id, sequenceId: seq, kind: .message, authorId: "review-agent",
                                        authorName: "review-agent", isHuman: false, text: text,
                                        timestamp: ISO8601DateFormatter().string(from: date), date: date)
        }
        var messages = [input("first", 1, "The file follows.")]
        var parts = ["part-2": Int64(99)]
        if withFirstPart {
            messages.append(input("part-1", 2, "part 1 of 2"))
            parts["part-1"] = 99
        }
        messages += [input("part-2", 3, "part 2 of 2"), input("last", 4, "That was the file.")]
        let card = RoomChatFileCard(thread: 99, name: "pack.zip", author: "review-agent", sha256: nil, verified: nil,
                                    status: "parts missing", partsTotal: 2, partPosts: 2, previewable: false)
        return RoomChatPresentationState(sessionId: "files", title: "Room", messages: messages, connection: .live,
                                         files: [99: [card]], fileParts: parts)
    }

    static let folders = (0..<5).map { RoomFolderItem(id: "folder-\($0)", name: "Folder \($0)", position: $0) }

    /// 240 rooms, a third of them in five folders, and 60 direct messages, two in three under the room they were opened
    /// from; most recent first. `moved` is put first, as a room that just had a message; every `unread`th has unread.
    static func panelRooms(moved: Int? = nil, unread: Int = 5) -> [PocketSidePanel.Room] {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var rooms: [PocketSidePanel.Room] = []
        for index in 0..<240 {
            let id = String(format: "room-%03d", index)
            let subtitle: String? = index % 3 == 0 ? "What room \(index) is about, in a sentence." : nil
            let ago = Double(index) * 600
            let unreadCount: Int = index % unread == 0 ? index % 9 : 0
            let activity = RoomListActivity(humansOnline: index % 2, agentsOnline: index % 4, unread: unreadCount)
            let folder: String? = index % 3 == 1 ? "folder-\(index % 5)" : nil
            rooms.append(PocketSidePanel.Room(id: id, title: "Room \(index)", subtitle: subtitle,
                                              lastActivity: start.addingTimeInterval(-ago), activity: activity,
                                              folderId: folder))
        }
        for index in 0..<60 {
            let id = String(format: "dm-%03d", index)
            let ago = Double(index) * 900 + 300
            let unreadCount: Int = index % 4 == 0 ? 2 : 0
            let activity = RoomListActivity(humansOnline: 0, agentsOnline: 0, unread: unreadCount)
            let origin: String? = index % 3 == 2 ? nil : String(format: "room-%03d", index * 4)
            let direct = PocketSidePanel.Direct(name: "Agent \(index)", isAgent: index % 3 != 0, originRoomId: origin)
            rooms.append(PocketSidePanel.Room(id: id, title: "Agent \(index)", subtitle: nil,
                                              lastActivity: start.addingTimeInterval(-ago), activity: activity,
                                              direct: direct))
        }
        if let moved, let index = rooms.firstIndex(where: { $0.id == String(format: "room-%03d", moved) }) {
            rooms.insert(rooms.remove(at: index), at: 0)
        }
        return rooms
    }
}
