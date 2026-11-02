import Foundation
import XCTest
import PocketContracts
@testable import PocketUI

final class RoomEmojiReactionsTests: XCTestCase {
    private func input(_ id: String, seq: Int64, at seconds: TimeInterval, author: String = "review-agent",
                       text: String = "hi", reactions: RoomChatReactions? = nil, replyTo: Int64? = nil,
                       inlineReplyId: String? = nil) -> RoomChatMessageInput {
        RoomChatMessageInput(
            id: id, sequenceId: seq, kind: .message, authorId: author, authorName: author,
            isHuman: author.hasPrefix("human-"), text: text, timestamp: "", replyToSequenceId: replyTo,
            date: Date(timeIntervalSince1970: 1_800_000_000 + seconds), reactions: reactions, inlineReplyId: inlineReplyId
        )
    }

    private func messageRow(_ state: RoomChatPresentationState, _ id: String) -> RoomChatMessageRow? {
        state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row, message.id == id { return message }
            return nil
        }.first
    }

    private func reactions(_ emoji: [RoomChatReactions.EmojiChip]) -> RoomChatReactions {
        RoomChatReactions.make(counts: ["like": 2], actorsByType: [:], activeOwners: [], likedByViewer: false,
                               dislikedByViewer: false, replyCount: 0, isPinned: false, emoji: emoji)
    }

    func test_emoji_chips_follow_the_reactions_in_first_use_order_with_yours_marked() {
        let line = reactions([
            .init(emoji: "🎉", count: 3, isMine: true),
            .init(emoji: "👀", count: 1, isMine: false)
        ])
        XCTAssertEqual(line.chips.map(\.type), ["like"], "the existing reactions are unchanged")
        XCTAssertEqual(line.emojiChips.map(\.emoji), ["🎉", "👀"])
        XCTAssertEqual(line.emojiChips.map(\.isMine), [true, false])
        XCTAssertEqual(line.emojiChips.map(\.count), [3, 1])
    }

    func test_at_most_twenty_emoji_chips_show_under_a_message() {
        let many = (0..<25).map { RoomChatReactions.EmojiChip(emoji: String(UnicodeScalar(0x1F600 + $0)!), count: 1, isMine: false) }
        XCTAssertEqual(reactions(many).emojiChips, Array(many.prefix(20)))
    }

    func test_an_emoji_chip_says_its_count_whether_it_is_yours_and_what_a_tap_does() {
        let mine = RoomChatReactions.EmojiChip(emoji: "👍", count: 3, isMine: true)
        let theirs = RoomChatReactions.EmojiChip(emoji: "👀", count: 1, isMine: false)
        XCTAssertEqual(mine.accessibilityLabel(canReact: true), "👍 3, you reacted. Double-tap to remove")
        XCTAssertEqual(theirs.accessibilityLabel(canReact: true), "👀 1. Double-tap to add yours")
        XCTAssertEqual(mine.accessibilityLabel(canReact: false), "👍 3, you reacted", "no tap is offered to a reader who cannot react")
    }

    func test_a_line_with_only_emoji_reactions_is_not_empty_and_its_notice_never_folds() {
        let line = RoomChatReactions(emojiChips: [.init(emoji: "🎉", count: 1, isMine: false)])
        XCTAssertFalse(line.isEmpty)
        let notice = { (n: Int) in "remains queued after \(n) failed relay attempts, retrying shortly" }
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: [
            input("m1", seq: 1, at: 0, text: notice(1)),
            input("m2", seq: 2, at: 60, text: notice(2), reactions: line),
            input("m3", seq: 3, at: 120, text: notice(3))
        ])
        XCTAssertEqual(state.rows.compactMap { row -> String? in
            if case .message(let message) = row { return message.id }
            return nil
        }, ["m1", "m2", "m3"], "a notice someone reacted to stands alone")
    }

    func test_tapping_an_emoji_chip_adds_yours_or_takes_yours_back() throws {
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room",
            messages: [input("m7", seq: 7, at: 0)],
            replies: [input("reply-r1", seq: 7, at: 60, replyTo: 7, inlineReplyId: "r1")]
        )
        let message = try XCTUnwrap(messageRow(state, "m7"))
        let reply = try XCTUnwrap(messageRow(state, "reply-r1"))
        XCTAssertEqual(message.emojiToggle(.init(emoji: "🎉", count: 2, isMine: false)),
                       .setEmojiReaction(sequenceId: 7, replyId: nil, emoji: "🎉", isOn: true), "not yours: react")
        XCTAssertEqual(message.emojiToggle(.init(emoji: "🎉", count: 2, isMine: true)),
                       .setEmojiReaction(sequenceId: 7, replyId: nil, emoji: "🎉", isOn: false), "yours: unreact")
        XCTAssertEqual(reply.emojiReaction("👀", isOn: true),
                       .setEmojiReaction(sequenceId: 7, replyId: "r1", emoji: "👀", isOn: true),
                       "a reply shown in the room is reacted to itself, never the message it answers")
    }

    func test_add_reaction_is_offered_with_the_reactions_only_where_the_picker_is_allowed() throws {
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: [input("m7", seq: 7, at: 0)],
                                              canReact: true, canAddEmoji: true)
        XCTAssertTrue(state.canAddEmoji)
        let row = try XCTUnwrap(messageRow(state, "m7"))
        let offered = row.options(canReply: true, canReact: true, canPin: false, isPinned: false, pinsFull: false,
                                  canAddEmoji: true)
        XCTAssertEqual(offered.map(\.kind), [.reply, .thread, .listen, .like, .dislike, .acknowledge, .emoji, .copy])
        XCTAssertNil(offered.first { $0.kind == .emoji }?.intent, "the view opens the picker")
        let refused = row.options(canReply: true, canReact: true, canPin: false, isPinned: false, pinsFull: false,
                                  canAddEmoji: false)
        XCTAssertFalse(refused.contains { $0.kind == .emoji })

        let denied = RoomChatPresentationState(sessionId: "room", title: "Room", messages: [input("m7", seq: 7, at: 0)],
                                               failure: .accessDenied, canReact: true, canAddEmoji: true)
        XCTAssertFalse(denied.canAddEmoji, "nothing is offered beside an access failure")
    }

    func test_the_picker_offers_two_dozen_common_emoji_each_one_emoji() {
        XCTAssertEqual(RoomEmojiPicker.common.count, 24)
        XCTAssertEqual(Set(RoomEmojiPicker.common).count, 24, "none twice")
        for emoji in RoomEmojiPicker.common {
            XCTAssertTrue(ReactionEmoji.isValid(emoji), emoji)
        }
    }

    func test_recently_used_emoji_come_newest_first_once_each_and_only_a_rows_worth() throws {
        let suite = "pocket.emoji.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(RoomEmojiPicker.recent(in: defaults), [])

        for emoji in ["👍", "🎉", "👍"] { RoomEmojiPicker.noteUsed(emoji, in: defaults) }
        XCTAssertEqual(RoomEmojiPicker.recent(in: defaults), ["👍", "🎉"])

        for emoji in ["😀", "😁", "😂", "😃", "😄", "😅"] { RoomEmojiPicker.noteUsed(emoji, in: defaults) }
        XCTAssertEqual(RoomEmojiPicker.recent(in: defaults), ["😅", "😄", "😃", "😂", "😁", "😀"])
        XCTAssertEqual(defaults.stringArray(forKey: RoomEmojiPicker.recentKey)?.count, RoomEmojiPicker.recentLimit,
                       "no more is kept than is shown")

        defaults.set(["abc", "🔥", "@here", "🙏", "😀", "😁", "😂", "😃", "😄", "😅"], forKey: RoomEmojiPicker.recentKey)
        XCTAssertEqual(RoomEmojiPicker.recent(in: defaults), ["🔥", "🙏", "😀", "😁", "😂", "😃"],
                       "what the phone kept is read as untrusted too")
    }
}
