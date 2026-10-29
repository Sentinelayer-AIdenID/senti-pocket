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
            isInlineReply: inline
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
            input("reply-a", seq: 100, at: 300, author: "claude-warden", replyTo: 100, inline: true),
            input("reply-undated", seq: 100, at: nil, author: "claude-warden", replyTo: 100, inline: true)
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
}
