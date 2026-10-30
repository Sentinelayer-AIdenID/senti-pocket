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

    /// Carter: agents' back-and-forth should not be all over the room. A thread is one row: its newest reply, at its
    /// own time, saying how many replies and who; it moves down as the thread grows, and the message stays put.
    func test_a_thread_is_one_row_at_its_newest_reply_and_moves_down_as_it_grows() {
        let messages = [
            input("m1", seq: 1, at: 0, author: "human-mrrcarter", text: "Senti web doesn't work"),
            input("m2", seq: 2, at: 100, text: "cost line"),
            input("m3", seq: 3, at: 200, text: "another")
        ]
        let replies = [
            input("reply-1", seq: 1, at: 50, author: "claude-warden", replyTo: 1, inline: true),
            input("reply-2", seq: 1, at: 150, author: "pocket-forge", replyTo: 1, inline: true),
            input("reply-3", seq: 1, at: 250, author: "claude-warden", replyTo: 1, inline: true),
            input("reply-4", seq: 2, at: 120, author: "ticket-keeper", replyTo: 2, inline: true)
        ]
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages, replies: replies)
        XCTAssertEqual(messageIds(state), ["m1", "m2", "reply-4", "m3", "reply-3"])
        let rows = state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
        XCTAssertEqual(rows.first { $0.id == "reply-3" }?.trail?.label, "3 replies · claude-warden, pocket-forge")
        XCTAssertEqual(rows.first { $0.id == "reply-4" }?.trail?.count, 1)
        XCTAssertNil(rows.first { $0.id == "m1" }?.trail, "messages carry no trail")
    }

    /// The room was full of one bridge warning with a rising retry count: that is one row with a count.
    func test_a_notice_repeating_with_only_its_numbers_changed_is_one_row() {
        let warn = { (n: Int) in "⚠ bridge: message from life 0d7010eb4e60 (frame 707) remains queued after \(n) failed relay attempts." }
        let messages = [
            input("m1", seq: 1, at: 0, author: "respawn-orchestrator", text: warn(105)),
            input("m2", seq: 2, at: 60, author: "respawn-orchestrator", text: warn(107)),
            input("m3", seq: 3, at: 120, author: "respawn-orchestrator", text: warn(109)),
            input("m4", seq: 4, at: 180, author: "respawn-orchestrator", text: "[cost] something else entirely here"),
            input("m5", seq: 5, at: 240, author: "respawn-orchestrator", text: warn(111)),
            input("m6", seq: 6, at: 300, author: "human-mrrcarter", text: "same words 1 same words same words"),
            input("m7", seq: 7, at: 360, author: "human-mrrcarter", text: "same words 2 same words same words")
        ]
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages)
        XCTAssertEqual(messageIds(state), ["m3", "m4", "m5", "m6", "m7"], "a run folds; a different message breaks it; people never fold")
        let rows = state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
        XCTAssertEqual(rows.first { $0.id == "m3" }?.repeats, 3)
        XCTAssertEqual(rows.first { $0.id == "m5" }?.repeats, 1)
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
        XCTAssertEqual(messageIds(state), ["m100", "m110", "m120", "reply-b", "reply-undated"],
                       "each thread once, as its newest reply at its own time; one without a time goes last")

        let reply = state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row, message.id == "reply-undated" { return message }
            return nil
        }.first
        XCTAssertEqual(reply?.isInlineReply, true)
        XCTAssertEqual(reply?.replyContext, "respawn-orchestrator: Cost line one", "it quotes what it answers")
        XCTAssertEqual(reply?.trail, RoomChatTrail(count: 2, authors: ["review-agent"]), "the thread's two replies, one author")
        XCTAssertEqual(reply?.trail?.label, "2 replies · review-agent")
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
