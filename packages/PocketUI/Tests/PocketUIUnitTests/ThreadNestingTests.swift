import Foundation
import XCTest
@testable import PocketUI

final class ThreadNestingTests: XCTestCase {
    private func reply(_ id: String, parent: String? = nil) -> RoomChatReplyRow {
        RoomChatReplyRow(id: id, authorName: "a-\(id)", isHuman: false, isOwn: false, text: id, date: nil,
                         isEdited: false, parentReplyId: parent)
    }

    func test_a_reply_to_a_reply_sits_under_it_indented() {
        let nested = RoomChatReplyRow.nested([
            reply("r1"), reply("r2"), reply("r1a", parent: "r1"), reply("r1a1", parent: "r1a"), reply("r2a", parent: "r2")
        ])
        XCTAssertEqual(nested.map(\.id), ["r1", "r1a", "r1a1", "r2", "r2a"])
        XCTAssertEqual(nested.map(\.depth), [0, 1, 2, 0, 1])
    }

    func test_deep_threads_stop_indenting_and_nothing_is_lost() {
        var chain = [reply("d0")]
        for level in 1...6 { chain.append(reply("d\(level)", parent: "d\(level - 1)")) }
        let nested = RoomChatReplyRow.nested(chain)
        XCTAssertEqual(nested.map(\.depth), [0, 1, 2, 3, 3, 3, 3], "capped at the maximum depth")

        let orphan = RoomChatReplyRow.nested([reply("x", parent: "gone"), reply("y")])
        XCTAssertEqual(orphan.map(\.id), ["x", "y"], "a parent that is not in the thread: it answers the message")
        XCTAssertEqual(orphan.map(\.depth), [0, 0])

        let cycle = RoomChatReplyRow.nested([reply("p", parent: "q"), reply("q", parent: "p")])
        XCTAssertEqual(Set(cycle.map(\.id)), ["p", "q"], "a cycle never hides a reply")
    }

    func test_only_the_last_message_of_a_run_carries_the_action_row() {
        func input(_ id: String, _ seq: Int64, author: String, at seconds: TimeInterval) -> RoomChatMessageInput {
            RoomChatMessageInput(id: id, sequenceId: seq, kind: .message, authorId: author, authorName: author,
                                 isHuman: false, text: id, timestamp: "",
                                 date: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
        }
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: [
            input("a1", 1, author: "agent-a", at: 0),
            input("a2", 2, author: "agent-a", at: 30),
            input("b1", 3, author: "agent-b", at: 60),
            input("a3", 4, author: "agent-a", at: 90)
        ])
        let ends = state.rows.compactMap { row -> String? in
            if case .message(let message) = row, message.endsRun { return message.id }
            return nil
        }
        XCTAssertEqual(ends, ["a2", "b1", "a3"])
    }
}
