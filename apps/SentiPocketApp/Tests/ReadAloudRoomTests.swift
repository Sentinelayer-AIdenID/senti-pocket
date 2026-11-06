import Foundation
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// Read aloud on the room as the phone lays it out (a hosted window, the room's own list): a message whose block quotes
/// nest 3, 5 and 7 deep (as replies quoting replies make them), read aloud. Carter's phone (build 2026110501) stopped
/// for 19 s right after Read aloud in such a room, in nested stack layout. Each pass must take well under a second.
@MainActor
final class ReadAloudRoomTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        pump(0.4)
        super.tearDown()
    }

    func test_reading_aloud_a_deeply_quoted_message_takes_well_under_a_second() throws {
        for depth in [3, 5, 7] {
            let message = Self.message(1, text: Self.nestedQuotes(depth))
            let room = Room(RoomChatPresentationState(sessionId: "room", title: "Room", messages: [message],
                                                      ownAuthorIds: ["human-alex"], connection: .live,
                                                      composer: RoomComposerState(canPost: true, disabledReason: nil),
                                                      canReact: true))
            let firstLayout = try host(Host(room: room))
            let row = try XCTUnwrap(room.state.rows.compactMap { row -> RoomChatMessageRow? in
                if case .message(let message) = row { return message }
                return nil
            }.first)
            let start = CACurrentMediaTime()
            room.reading = row.readAloudId
            settle()
            let pass = CACurrentMediaTime() - start
            room.reading = nil
            settle()
            print("READALOUD iOS depth \(depth): first layout \(Int(firstLayout * 1000)) ms, Read aloud \(Int(pass * 1000)) ms")
            XCTAssertLessThan(firstLayout, 1, "depth \(depth): the room laid the message out in under a second")
            XCTAssertLessThan(pass, 1, "depth \(depth): Read aloud laid the message out again in under a second")
            window?.isHidden = true
            window = nil
            pump(0.2)
        }
    }

    // MARK: - The room

    private final class Room: ObservableObject {
        let state: RoomChatPresentationState
        @Published var reading: String?
        init(_ state: RoomChatPresentationState) { self.state = state }
    }

    private struct Host: View {
        @ObservedObject var room: Room
        var body: some View {
            NavigationStack { RoomChatView(state: room.state, readingAloudId: room.reading) { _ in } }
        }
    }

    /// The window's first layout of `view`, in seconds.
    private func host<Content: View>(_ view: Content) throws -> Double {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let start = CACurrentMediaTime()
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let seconds = CACurrentMediaTime() - start
        self.window = window
        pump(0.5)
        return seconds
    }

    /// The update a change asked for, and its layout.
    private func settle() {
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            window?.layoutIfNeeded()
        }
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }

    static func message(_ sequence: Int64, text: String) -> RoomChatMessageInput {
        let date = Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence) * 60)
        return RoomChatMessageInput(id: "m\(sequence)", sequenceId: sequence, kind: .message, authorId: "plan-agent",
                                    authorName: "plan-agent", isHuman: false, text: text, timestamp: "", date: date)
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
}
