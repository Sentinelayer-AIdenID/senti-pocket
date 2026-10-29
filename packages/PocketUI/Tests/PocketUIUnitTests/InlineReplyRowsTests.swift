import Foundation
import XCTest
@testable import PocketUI

final class InlineReplyRowsTests: XCTestCase {
    private func input(_ id: String, seq: Int64, at seconds: TimeInterval?, author: String = "respawn-orchestrator",
                       text: String = "hi", replyTo: Int64? = nil, inline: Bool = false) -> RoomChatMessageInput {
        RoomChatMessageInput(
            id: id,
            sequenceId: seq,
            kind: .message,
            authorId: author,
            authorName: author,
            isHuman: author.hasPrefix("human-"),
            text: text,
            timestamp: "",
            replyToSequenceId: replyTo,
            date: seconds.map { Date(timeIntervalSince1970: 1_800_000_000 + $0) },
            inlineReplyId: inline ? String(id.dropFirst("reply-".count)) : nil
        )
    }

    private func messageIds(_ state: RoomChatPresentationState) -> [String] {
        state.rows.compactMap { row in
            if case .message(let message) = row { return message.id }
            return nil
        }
    }

    func test_replies_sit_at_their_own_time_among_the_messages() {
        let messages = [
            input("m100", seq: 100, at: 0, text: "Cost line one"),
            input("m110", seq: 110, at: 600),
            input("m120", seq: 120, at: 1_200)
        ]
        let replies = [
            input("reply-b", seq: 110, at: 1_500, author: "ds-aid-x", replyTo: 110, inline: true),
            input("reply-a", seq: 100, at: 300, author: "review-agent", replyTo: 100, inline: true),
            input("reply-undated", seq: 100, at: nil, author: "review-agent", replyTo: 100, inline: true)
        ]
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages, replies: replies)
        XCTAssertEqual(messageIds(state), ["m100", "reply-a", "m110", "m120", "reply-b", "reply-undated"],
                       "each reply after the messages that came before it; one without a time goes last")

        let reply = state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row, message.id == "reply-a" { return message }
            return nil
        }.first
        XCTAssertEqual(reply?.isInlineReply, true)
        XCTAssertEqual(reply?.replyContext, "respawn-orchestrator: Cost line one", "it quotes what it answers")
        XCTAssertEqual(reply?.showsHeader, true)
    }

    func test_a_reply_to_a_message_that_is_not_loaded_has_no_quote_and_long_lines_are_cut() {
        let long = String(repeating: "word ", count: 30)
        let state = RoomChatPresentationState(
            sessionId: "room",
            title: "Room",
            messages: [input("m1", seq: 1, at: 0, text: long + "\nsecond line")],
            replies: [
                input("reply-x", seq: 1, at: 10, replyTo: 1, inline: true),
                input("reply-y", seq: 999, at: 20, replyTo: 999, inline: true)
            ]
        )
        let rows = state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
        XCTAssertEqual(rows.first { $0.id == "reply-x" }?.replyContext?.hasSuffix("…"), true, "only the first line, kept short")
        XCTAssertNil(rows.first { $0.id == "reply-y" }?.replyContext)
        XCTAssertEqual(state.lastMessageId, "reply-y", "a reply can be the newest row, so the view follows it")
    }

    private func messageRow(_ state: RoomChatPresentationState, _ id: String) -> RoomChatMessageRow? {
        state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row, message.id == id { return message }
            return nil
        }.first
    }

    /// Review on #205: a reply shown in the room carries its message's sequence, so its long-press Like, Pin and
    /// Listen acted on the message it answers.
    func test_a_reply_shown_in_the_room_acts_on_itself_never_on_the_message_it_answers() throws {
        let state = RoomChatPresentationState(
            sessionId: "room",
            title: "Room",
            messages: [input("m100", seq: 100, at: 0, text: "Cost line one")],
            pinned: [RoomChatPinned(sequenceId: 100, snippet: "Cost line one", pinnedBy: "mrrcarter")],
            canPin: true,
            replies: [input("reply-r1", seq: 100, at: 60, author: "review-agent", text: "on it", replyTo: 100, inline: true)]
        )
        let parent = try XCTUnwrap(messageRow(state, "m100"))
        let reply = try XCTUnwrap(messageRow(state, "reply-r1"))

        let options = reply.options(canReply: true, canReact: true, canPin: true, isPinned: state.isPinned(reply), pinsFull: false)
        XCTAssertEqual(options.map(\.kind), [.thread, .listen, .like, .dislike, .acknowledge, .copy], "no pin on a reply")
        for intent in options.compactMap(\.intent) {
            if case .react = intent { XCTFail("a reaction from a reply's menu lands on the message it answers") }
            if case .setPinned = intent { XCTFail("a reply's menu pins the message it answers") }
        }
        XCTAssertEqual(options.first { $0.kind == .like }?.intent, .reactToReply(sequenceId: 100, replyId: "r1", type: "like"),
                       "a like goes to the reply itself")
        XCTAssertEqual(options.first { $0.kind == .listen }?.intent, .readAloud(id: RoomReadAloud.reply("r1"), text: "on it"))
        XCTAssertEqual(options.first { $0.kind == .thread }?.intent, .openThread(sequenceId: 100), "it opens its thread")
        XCTAssertEqual(reply.reaction("dislike"), .reactToReply(sequenceId: 100, replyId: "r1", type: "dislike"),
                       "the reaction chips under a reply react to the reply too")

        XCTAssertTrue(state.isPinned(parent))
        XCTAssertFalse(state.isPinned(reply), "a pinned message does not mark its replies")
        XCTAssertNotEqual(reply.readAloudId, parent.readAloudId, "reading the message aloud does not mark its replies")
        XCTAssertEqual(reply.accessibilityId, "pocket.room.reply.r1")
        XCTAssertEqual(parent.accessibilityId, "pocket.room.message.100")

        // The message's own menu still acts on the message.
        let parentIntents = parent.options(canReply: true, canReact: true, canPin: true, isPinned: true, pinsFull: false)
            .compactMap(\.intent)
        XCTAssertTrue(parentIntents.contains(.react(sequenceId: 100, type: "like")))
        XCTAssertTrue(parentIntents.contains(.setPinned(sequenceId: 100, isPinned: false)))
        XCTAssertTrue(parentIntents.contains(.readAloud(id: RoomReadAloud.message(100), text: "Cost line one")))
    }

    /// A jump, a focus or a thread looks for the message itself: a reply under the same sequence is never taken
    /// for it, also when the message is not loaded.
    func test_a_message_is_found_by_its_sequence_never_as_a_reply_shown_under_it() {
        let state = RoomChatPresentationState(
            sessionId: "room",
            title: "Room",
            messages: [input("m1", seq: 1, at: 0)],
            thread: RoomChatThreadInput(sequenceId: 999, replies: []),
            replies: [input("reply-x", seq: 999, at: 10, replyTo: 999, inline: true)]
        )
        XCTAssertNil(state.messageRow(for: 999), "its message is not loaded")
        XCTAssertNil(state.thread, "the thread waits for its message instead of opening on a reply")
        XCTAssertEqual(state.messageRow(for: 1)?.id, "msg:m1")
    }
}
