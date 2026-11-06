import Combine
import Foundation
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// What the room-list tests share: a window to host a list in, the steps that count the items it builds, and the rooms
/// they open. LazyListBuildTests (gating) and LazyListKnownFlakyTests (not gating, ticket 9d7d62f1) both use it. It
/// holds no tests of its own: a test here would run in both classes, and the guard
/// (scripts/ios/known_flaky_guard.py) fails if one appears.
@MainActor
class LazyListTestCase: XCTestCase {
    var window: UIWindow?

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

    /// The most passes over its rows an open, a room put in another's place, or the first update after either may
    /// make: the most measured was 3 (1,212 rows built in a room of 404).
    static let passesAtMost = 4

    /// Waits until the room's list rests at its bottom: its last row in view, nothing scrolling, and its size and place
    /// unchanged for half a second (at most 10 s). A list that drifted up from its bottom (its rows above measured
    /// taller than estimated) is put back there first, as the reader at the bottom sees it.
    func settleAtBottom(file: StaticString = #filePath, line: UInt = #line) {
        guard let scroll = window.flatMap({ Self.list(in: $0) }) else { return XCTFail("no list in the window") }
        let end = Date().addingTimeInterval(10)
        var steady = 0
        var last = (scroll.contentSize.height, scroll.contentOffset.y)
        while Date() < end, steady < 5 {
            if abs(scroll.contentOffset.y - Self.bottomOffset(of: scroll)) > 1, !scroll.isDragging, !scroll.isDecelerating {
                scroll.setContentOffset(CGPoint(x: 0, y: Self.bottomOffset(of: scroll)), animated: false)
            }
            pump(0.1)
            let now = (scroll.contentSize.height, scroll.contentOffset.y)
            let atBottom = abs(scroll.contentOffset.y - Self.bottomOffset(of: scroll)) <= 1
            steady = atBottom && now == last && !scroll.isDecelerating ? steady + 1 : 0
            last = now
        }
        XCTAssertGreaterThanOrEqual(steady, 5, "the room rests at its bottom before an update is measured",
                                    file: file, line: line)
    }

    /// Does `change`, then runs the main run loop until nothing has been built or drawn for a second (at most 15 s): the
    /// list has finished laying out and the main thread is idle again. The items built in that time are counted and
    /// returned.
    @discardableResult
    func step(_ name: String, rows: Int, list: RenderTrace.List, most: Int? = LazyListTestCase.mostBuiltPerStep,
              file: StaticString = #filePath, line: UInt = #line, _ change: () -> Void) -> Int {
        let before = RenderTrace.builtCount(list)
        let started = Date()
        change()
        let idle = quiet { [RenderTrace.builtCount(list), RenderTrace.snapshot().draws] }
        let built = RenderTrace.builtCount(list) - before
        print("LAZYLIST \(list) \(name): \(built) of \(rows) built, idle after "
            + "\(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        XCTAssertTrue(idle, "\(name): the list was still building after 15 s", file: file, line: line)
        if let most {
            XCTAssertLessThanOrEqual(built, most, "\(name): built \(built) of \(rows) items, not only those it shows",
                                     file: file, line: line)
        }
        return built
    }

    /// Runs the main run loop until `activity` has not moved for a second; false if it still moved after 15 s.
    func quiet(_ activity: () -> [Int]) -> Bool {
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

    func host<Content: View>(_ view: Content) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        self.window = window
    }

    /// The content offset at which the list shows its last row.
    static func bottomOffset(of scroll: UIScrollView) -> CGFloat {
        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
    }

    /// The tallest scroll view in the window: the room's list.
    static func list(in view: UIView) -> UIScrollView? {
        var found = view as? UIScrollView
        for child in view.subviews {
            if let inner = list(in: child), inner.contentSize.height > (found?.contentSize.height ?? 0) { found = inner }
        }
        return found
    }

    func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }

    final class Room: ObservableObject {
        @Published var state: RoomChatPresentationState
        /// What the room asked of its coordinator.
        var intents: [RoomChatIntent] = []
        init(_ state: RoomChatPresentationState) { self.state = state }
    }

    struct RoomHost: View {
        @ObservedObject var room: Room
        var body: some View {
            NavigationStack { RoomChatView(state: room.state) { room.intents.append($0) } }
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
}
