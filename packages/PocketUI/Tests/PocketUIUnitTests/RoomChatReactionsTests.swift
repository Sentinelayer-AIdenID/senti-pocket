import Foundation
import XCTest
@testable import PocketUI

final class RoomChatReactionsTests: XCTestCase {
    func test_chips_follow_the_web_order_and_mark_your_own_like_or_dislike() {
        let reactions = RoomChatReactions.make(
            counts: ["dislike": 1, "ack": 2, "like": 5, "reply": 3, "working_on": 1],
            actorsByType: [:],
            activeOwners: [],
            likedByViewer: true,
            dislikedByViewer: false,
            replyCount: 3,
            isPinned: false
        )
        XCTAssertEqual(reactions.chips.map(\.type), ["ack", "like", "dislike"], "replies and working are not chips")
        XCTAssertEqual(reactions.chips.map(\.isMine), [false, true, false])
        XCTAssertEqual(reactions.replyCount, 3)
    }

    func test_acked_by_shows_three_sorted_names_then_a_count_and_strips_the_human_prefix() {
        let reactions = RoomChatReactions.make(
            counts: ["ack": 5],
            actorsByType: ["ack": ["ticket-keeper", "human-mrrcarter", "cobalt-warden", "coral-helper", "build-agent"]],
            activeOwners: ["cobalt-warden"],
            likedByViewer: false,
            dislikedByViewer: false,
            replyCount: 0,
            isPinned: true
        )
        XCTAssertEqual(reactions.ackedBy, "Acked by build-agent, cobalt-warden, coral-helper +2")
        XCTAssertEqual(reactions.working, "Working: cobalt-warden")
        XCTAssertTrue(reactions.isPinned)
        XCTAssertEqual(RoomChatReactions.names(["human-griff"], prefix: "Acked by"), "Acked by griff")
        XCTAssertTrue(RoomChatReactions.make(
            counts: [:], actorsByType: [:], activeOwners: [], likedByViewer: false, dislikedByViewer: false,
            replyCount: 0, isPinned: false
        ).isEmpty)
    }

    func test_the_open_thread_attaches_to_its_rendered_parent_or_is_dropped() {
        let message = RoomChatMessageInput(
            id: "e1", sequenceId: 7, kind: .message, authorId: "cobalt-warden", authorName: "cobalt-warden",
            isHuman: false, text: "parent", timestamp: "2026-10-28T10:00:00Z"
        )
        let reply = RoomChatReplyRow(
            id: "r1", authorName: "mrrcarter", isHuman: true, isOwn: true, text: "ok", date: nil, isEdited: false
        )
        let open = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: [message],
            thread: RoomChatThreadInput(sequenceId: 7, replies: [reply], canReply: true)
        )
        XCTAssertEqual(open.thread?.parent.text, "parent")
        XCTAssertEqual(open.thread?.replies.map(\.id), ["r1"])
        XCTAssertEqual(open.thread?.canReply, true)

        let missing = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: [message],
            thread: RoomChatThreadInput(sequenceId: 99, replies: [])
        )
        XCTAssertNil(missing.thread, "a thread whose parent is not loaded is not shown")

        let denied = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: [message], failure: .accessDenied,
            thread: RoomChatThreadInput(sequenceId: 7, replies: [reply])
        )
        XCTAssertNil(denied.thread)
        XCTAssertFalse(denied.canReact)
    }

    func test_a_reply_over_the_limit_is_held_in_the_reply_box() {
        let message = RoomChatMessageInput(
            id: "e1", sequenceId: 7, kind: .message, authorId: "cobalt-warden", authorName: "cobalt-warden",
            isHuman: false, text: "parent", timestamp: "2026-10-28T10:00:00Z"
        )
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room", messages: [message],
            thread: RoomChatThreadInput(sequenceId: 7, replies: [], canReply: true, maximumReplyLength: 4_000)
        )
        XCTAssertNil(state.thread?.replyLengthProblem(for: String(repeating: "a", count: 4_000)))
        let problem = state.thread?.replyLengthProblem(for: String(repeating: "a", count: 4_001))
        XCTAssertTrue(problem?.hasPrefix("Too long to send: ") == true, problem ?? "nil")
    }
}
