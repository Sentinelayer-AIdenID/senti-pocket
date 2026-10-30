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
        let warn = { (n: Int) in "⚠ bridge: message from life a1b2c3d4e5f6 (frame 707) remains queued after \(n) failed relay attempts." }
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
        XCTAssertEqual(rows.first { $0.id == "m3" }?.repeatStack, "m1", "a stack is named by its first notice")
        XCTAssertEqual(rows.first { $0.id == "m5" }?.repeats, 1)
        XCTAssertNil(rows.first { $0.id == "m5" }?.repeatStack, "a lone notice is in no stack")
    }

    /// warden: folding must never hide what differs. A notice with a file, a reaction or a thread always shows.
    func test_a_notice_with_something_of_its_own_never_folds() {
        let warn = { (n: Int) in "⚠ bridge: message from life a1b2c3d4e5f6 (frame 707) remains queued after \(n) failed relay attempts." }
        let file = RoomAttachmentChip(attachmentId: "att-1", filename: "trace.txt", kind: .other, processingStatus: "ready")
        func notice(_ id: String, _ seq: Int64, _ n: Int, reactions: RoomChatReactions? = nil,
                    attachments: [RoomAttachmentChip] = []) -> RoomChatMessageInput {
            RoomChatMessageInput(id: id, sequenceId: seq, kind: .message, authorId: "respawn-orchestrator",
                                 authorName: "respawn-orchestrator", isHuman: false, text: warn(n), timestamp: "",
                                 date: Date(timeIntervalSince1970: 1_800_000_000 + Double(seq) * 60),
                                 reactions: reactions, attachments: attachments)
        }
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: [
            notice("m1", 1, 1),
            notice("m2", 2, 2, attachments: [file]),
            notice("m3", 3, 3),
            notice("m4", 4, 4, reactions: RoomChatReactions(replyCount: 2)),
            notice("m5", 5, 5),
            notice("m6", 6, 6, reactions: RoomChatReactions(chips: [.init(type: "like", count: 1, isMine: false)])),
            notice("m7", 7, 7),
            notice("m8", 8, 8)
        ])
        XCTAssertEqual(messageIds(state), ["m1", "m2", "m3", "m4", "m5", "m6", "m8"],
                       "a file, a thread and a reaction each stand alone; only the last plain pair folds")
        XCTAssertTrue(RoomChatRepeats.isFoldable(notice("x", 9, 9, reactions: RoomChatReactions())),
                      "an empty reaction line is nothing of its own")
    }

    /// warden: a folded stack opens to show each notice, and folds again from its first one.
    func test_an_opened_stack_shows_each_notice_and_offers_to_fold_again() {
        let warn = { (n: Int) in "⚠ bridge: message from life a1b2c3d4e5f6 (frame 707) remains queued after \(n) failed relay attempts." }
        let messages = [
            input("m1", seq: 1, at: 0, text: warn(1)),
            input("m2", seq: 2, at: 60, text: warn(2)),
            input("m3", seq: 3, at: 120, text: warn(3))
        ]
        let opened = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages,
                                               expandedRepeats: ["m1"])
        XCTAssertEqual(messageIds(opened), ["m1", "m2", "m3"], "an opened stack shows every notice")
        let rows = opened.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
        XCTAssertEqual(rows.map(\.repeatStack), ["m1", "m1", "m1"])
        XCTAssertEqual(rows.map(\.foldsRepeats), [true, false, false], "only the first notice offers to fold again")
        XCTAssertEqual(rows.map(\.repeats), [1, 1, 1])

        let other = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages,
                                              expandedRepeats: ["m9"])
        XCTAssertEqual(messageIds(other), ["m3"], "opening another stack leaves this one folded")
    }

    /// A notice opened from a link (a search hit, a pin) is never folded away under a newer one.
    func test_a_notice_being_opened_keeps_its_run_unfolded() {
        let warn = { (n: Int) in "⚠ bridge: message from life a1b2c3d4e5f6 (frame 707) remains queued after \(n) failed relay attempts." }
        let messages = [
            input("m1", seq: 1, at: 0, text: warn(1)),
            input("m2", seq: 2, at: 60, text: warn(2)),
            input("m3", seq: 3, at: 120, text: warn(3))
        ]
        let focused = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages,
                                                focusSequenceId: 1)
        XCTAssertTrue(messageIds(focused).contains("m1"), "the message being opened is on screen")
        XCTAssertEqual(RoomChatRepeats.fold(messages, keep: 2).kept.map(\.id), ["m1", "m2", "m3"],
                       "a run holding the kept message does not fold")
    }

    /// Carter (#55006 reply): he could not edit his own message.
    func test_only_your_own_messages_offer_edit_when_you_can_post() throws {
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room",
            messages: [input("m1", seq: 1, at: 0, author: "human-mrrcarter", text: "mine"),
                       input("m2", seq: 2, at: 10, author: "review-agent", text: "theirs")],
            ownAuthorIds: ["human-mrrcarter"]
        )
        let rows = state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
        let mine = try XCTUnwrap(rows.first { $0.id == "m1" })
        let theirs = try XCTUnwrap(rows.first { $0.id == "m2" })
        XCTAssertTrue(mine.options(canReply: true, canReact: true, canPin: false, isPinned: false, pinsFull: false, canEdit: true)
            .contains { $0.kind == .edit })
        XCTAssertFalse(mine.options(canReply: false, canReact: true, canPin: false, isPinned: false, pinsFull: false, canEdit: false)
            .contains { $0.kind == .edit }, "a viewer cannot edit")
        XCTAssertFalse(theirs.options(canReply: true, canReact: true, canPin: false, isPinned: false, pinsFull: false, canEdit: true)
            .contains { $0.kind == .edit }, "never someone else's")
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
        XCTAssertEqual(options.map(\.kind), [.reply, .thread, .listen, .like, .dislike, .acknowledge, .copy], "no pin on a reply")
        XCTAssertEqual(reply.replyIntent("same here"), .sendReplyToReply(sequenceId: 100, replyId: "r1", text: "same here"),
                       "a reply written to a reply shown in the room answers it, in its thread")
        XCTAssertEqual(parent.replyIntent("thanks"), .sendReply(sequenceId: 100, text: "thanks"))
        let reader = reply.options(canReply: false, canReact: false, canPin: false, isPinned: false, pinsFull: false)
        XCTAssertEqual(reader.map(\.kind), [.thread, .listen, .copy], "someone who cannot post opens the thread to read")
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
