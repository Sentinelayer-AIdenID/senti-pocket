import Foundation
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// Jump to latest from far up a long room: the room keeps only its newest rows (`keepLatestForJumpDown`) and opens again
/// at its bottom. Carter's TestFlight build on 11-05 could land that jump on an empty screen: no message on it and none
/// built, the room's title and composer alone. A message must be on screen after every jump.
@MainActor
final class JumpToLatestTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        pump(0.4)
        super.tearDown()
    }

    /// Ten times: the whole room of 400 is loaded, the reader goes up to its top, and Jump to latest keeps the newest
    /// 60 and goes to them, as the room's coordinator does (at once, in the tap). Each time a message is on screen after.
    func test_jump_to_latest_from_the_top_of_a_long_room_lands_on_its_newest_messages() throws {
        let room = Room(Self.room(first: 1, last: 400, keepsLatest: true))
        try host(Host(room: room))
        pump(2)
        for jump in 1...10 {
            room.state = Self.room(first: 1, last: 400, keepsLatest: true)
            pump(1)
            let scroll = try XCTUnwrap(window.flatMap { Self.list(in: $0) }, "the room's list")
            // Up to the top, a screen at a time, as a reader does.
            let deadline = Date().addingTimeInterval(15)
            while scroll.contentOffset.y > 1, Date() < deadline {
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentOffset.y - scroll.bounds.height)),
                                        animated: false)
                pump(0.05)
            }
            pump(1.5)
            let arrow = try XCTUnwrap(Self.element("pocket.room.jumpToLatest", under: try XCTUnwrap(window)),
                                      "jump \(jump): the arrow shows up the room")
            XCTAssertTrue(arrow.accessibilityActivate(), "jump \(jump): the arrow takes the tap")
            pump(3)
            let after = try XCTUnwrap(window.flatMap { Self.list(in: $0) }, "the room's list after the jump")
            let shown = Self.messagesOnScreen(in: try XCTUnwrap(window))
            print("JUMP \(jump): offset \(Int(after.contentOffset.y)) height \(Int(after.contentSize.height)) "
                + "viewport \(Int(after.bounds.height)) messages on screen \(shown.count) "
                + "(\(shown.min() ?? 0)..\(shown.max() ?? 0)) rows \(room.state.rows.count)")
            XCTAssertTrue(room.intents.contains(.keepLatestForJumpDown), "jump \(jump): the room kept its newest rows")
            XCTAssertFalse(shown.isEmpty, "jump \(jump): a message is on screen after Jump to latest")
            XCTAssertTrue(shown.contains(400), "jump \(jump): the newest message is on screen")
            room.intents.removeAll()
        }
    }

    // MARK: - The room

    private final class Room: ObservableObject {
        @Published var state: RoomChatPresentationState
        var intents: [RoomChatIntent] = []
        init(_ state: RoomChatPresentationState) { self.state = state }

        /// As the room's coordinator: the newest 60 kept at once when the jump asks, in the same turn as the tap.
        func send(_ intent: RoomChatIntent) {
            intents.append(intent)
            if intent == .keepLatestForJumpDown, state.jumpDownKeepsLatest {
                state = JumpToLatestTests.room(first: 341, last: 400, keepsLatest: false)
            }
        }
    }

    private struct Host: View {
        @ObservedObject var room: Room
        var body: some View {
            NavigationStack { RoomChatView(state: room.state) { room.send($0) } }
        }
    }

    /// Messages `first` through `last` of a room over three days: agents and a person taking turns, every fifth long.
    nonisolated static func room(first: Int, last: Int, keepsLatest: Bool) -> RoomChatPresentationState {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        let stamp = ISO8601DateFormatter()
        let agents = ["review-agent", "build-agent", "plan-agent"]
        let messages = (first...last).map { index -> RoomChatMessageInput in
            let author = index % 7 == 0 ? "human-alex" : agents[index % 3]
            let date = start.addingTimeInterval(Double(index) * 650)
            let text = index % 5 == 0
                ? "Message \(index), long enough to wrap: " + String(repeating: "a note about the build ", count: 8)
                : "Message \(index)."
            return RoomChatMessageInput(id: "evt-\(index)", sequenceId: Int64(index), kind: .message, authorId: author,
                                        authorName: author, isHuman: author.hasPrefix("human-"), text: text,
                                        timestamp: stamp.string(from: date), date: date)
        }
        return RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages,
                                         ownAuthorIds: ["human-alex"], jumpDownKeepsLatest: keepsLatest,
                                         connection: .live,
                                         composer: RoomComposerState(canPost: true, disabledReason: nil),
                                         canReact: true)
    }

    // MARK: - Reading the screen

    private func host<Content: View>(_ view: Content) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        self.window = window
    }

    /// The tallest scroll view in the window: the room's list.
    private static func list(in view: UIView) -> UIScrollView? {
        var found = view as? UIScrollView
        for child in view.subviews {
            if let inner = list(in: child), inner.contentSize.height > (found?.contentSize.height ?? 0) { found = inner }
        }
        return found
    }

    /// The sequence ids of the messages an accessibility client finds on the window's screen.
    private static func messagesOnScreen(in window: UIWindow) -> [Int] {
        var shown: [Int] = []
        visit(window) { node, identifier in
            guard identifier.hasPrefix("pocket.room.message."),
                  node.accessibilityFrame.intersects(window.bounds),
                  let sequence = Int(identifier.dropFirst("pocket.room.message.".count)) else { return false }
            shown.append(sequence)
            return false
        }
        return shown
    }

    /// The first accessibility element under `root` whose identifier is `identifier`.
    private static func element(_ identifier: String, under root: NSObject) -> NSObject? {
        var found: NSObject?
        visit(root) { node, id in
            if id == identifier { found = node }
            return found != nil
        }
        return found
    }

    /// Walks the views and accessibility elements under `root`, giving each identified one to `body` until it says stop.
    private static func visit(_ root: NSObject, _ body: (NSObject, String) -> Bool) {
        var stack: [NSObject] = [root]
        var visited = 0
        while let node = stack.popLast(), visited < 50_000 {
            visited += 1
            if let identifier = (node as? UIAccessibilityIdentification)?.accessibilityIdentifier, !identifier.isEmpty,
               body(node, identifier) {
                return
            }
            if let view = node as? UIView { stack.append(contentsOf: view.subviews) }
            if let elements = node.accessibilityElements as? [NSObject] {
                stack.append(contentsOf: elements)
            } else {
                let count = node.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let element = node.accessibilityElement(at: index) as? NSObject { stack.append(element) }
                    }
                }
            }
        }
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}
