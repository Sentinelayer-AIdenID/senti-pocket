import Foundation
import XCTest
@testable import PocketUI

/// A file posted as base64 parts shows as a card at its thread's root: verified, its name, size, hash and parts with a
/// way to save it; otherwise the reason and nothing to save. The posts it came from fold behind the card.
final class RoomFilePresentationTests: XCTestCase {
    private let declaredHash = "9b1f5b6cba4a92954a0ecd0cee5730d99d25dc09a5cc7da631079bb9963fab71"

    private func input(_ id: String, seq: Int64, at seconds: TimeInterval, text: String = "A note.",
                       inline: Bool = false) -> RoomChatMessageInput {
        RoomChatMessageInput(
            id: id, sequenceId: seq, kind: .message, authorId: "ada-agent", authorName: "ada-agent", isHuman: false,
            text: text, timestamp: "", replyToSequenceId: inline ? seq : nil,
            date: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
            inlineReplyId: inline ? String(id.dropFirst("reply-".count)) : nil
        )
    }

    private func card(verified: Data?, status: String? = nil, hashes: [String] = [], previewable: Bool = false,
                      name: String = "fixture-pack.zip") -> RoomChatFileCard {
        RoomChatFileCard(thread: 10, name: name, sha256: declaredHash, verified: verified, status: status, partsTotal: 3,
                         partPosts: 3, computedHashes: hashes, previewable: previewable)
    }

    func test_a_verified_file_shows_its_size_hash_and_parts_and_can_be_saved() throws {
        let data = Data(repeating: 7, count: 3_004)
        let verified = card(verified: data)
        let size = ByteCountFormatter.string(fromByteCount: 3_004, countStyle: .file)
        XCTAssertEqual(verified.detail, "\(size) · sha256 ✓ 9b1f5b6cba4a · 3 parts")
        XCTAssertEqual(verified.content?.data, data)
        XCTAssertTrue(verified.isVerified)
        XCTAssertNil(verified.mismatch)
        XCTAssertNil(verified.preview, "not a text file")
        XCTAssertEqual(verified.partsToggleTitle, "3 data parts")
        XCTAssertEqual(verified.id, "10/fixture-pack.zip/\(declaredHash)")
    }

    func test_a_file_that_is_not_verified_shows_why_and_cannot_be_saved() {
        let missing = card(verified: nil, status: "2 of 3 parts")
        XCTAssertEqual(missing.detail, "2 of 3 parts")
        XCTAssertNil(missing.content)
        XCTAssertFalse(missing.isVerified)

        let mismatch = card(verified: nil, status: "hash mismatch",
                            hashes: [String(repeating: "1", count: 64), String(repeating: "a", count: 64)])
        XCTAssertEqual(mismatch.detail, "hash mismatch")
        XCTAssertEqual(mismatch.mismatch, "decoded 111111111111 · unzipped aaaaaaaaaaaa")
        XCTAssertNil(mismatch.preview, "nothing of an unverified file is shown")
    }

    func test_a_text_file_previews_its_first_forty_lines_as_plain_text() throws {
        let lines = (1...60).map { #"{"id":"KB-\#($0)","note":"<b>not markup</b>"}"# }
        let long = String(repeating: "x", count: 500)
        let data = Data((lines + [long]).joined(separator: "\n").utf8)
        let preview = try XCTUnwrap(card(verified: data, previewable: true, name: "knowledge.jsonl").preview)
        let shown = preview.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(shown.count, 40)
        XCTAssertEqual(String(shown[0]), #"{"id":"KB-1","note":"<b>not markup</b>"}"#, "the text as it is")
        XCTAssertEqual(RoomChatFileCard.preview(of: Data(long.utf8)).count, RoomChatFileCard.previewLineLength + 1,
                       "a long line is cut, with an ellipsis")
    }

    /// The card goes on the thread's root message; each part (a message by its id, a reply by its own) is marked so
    /// the room folds it behind the card.
    func test_the_card_goes_on_the_root_and_the_parts_are_marked() throws {
        let verified = card(verified: Data([1, 2, 3]))
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room",
            messages: [input("m9", seq: 9, at: 0), input("m10", seq: 10, at: 10, text: "The pack, in 3 parts below.")],
            replies: [input("reply-r1", seq: 10, at: 20, inline: true),
                      input("reply-r2", seq: 10, at: 30, inline: true)],
            files: [10: [verified]],
            fileParts: ["r1": 10, "r2": 10]
        )
        let rows = state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
        let root = try XCTUnwrap(rows.first { $0.id == "m10" })
        XCTAssertEqual(root.files, [verified])
        XCTAssertNil(root.filePartOf, "the root is not a part")
        XCTAssertTrue(rows.filter(\.isInlineReply).allSatisfy { $0.filePartOf == 10 }, "every part shown is marked")
        XCTAssertTrue(rows.filter(\.isInlineReply).allSatisfy { $0.files.isEmpty }, "the card is on the root alone")
        XCTAssertFalse(rows.filter(\.isInlineReply).isEmpty)
        XCTAssertTrue(rows.first { $0.id == "m9" }?.files.isEmpty ?? false, "other messages carry nothing")
    }

    /// With the root not loaded, the card goes on the newest part shown, so the file is never lost from the room.
    func test_without_the_root_the_card_goes_on_the_newest_part() throws {
        let missing = card(verified: nil, status: "2 of 3 parts")
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room",
            messages: [input("m30", seq: 30, at: 0)],
            replies: [input("reply-r1", seq: 10, at: 20, inline: true)],
            files: [10: [missing]],
            fileParts: ["r1": 10]
        )
        let part = try XCTUnwrap(state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row, message.isInlineReply { return message }
            return nil
        }.last)
        XCTAssertEqual(part.files, [missing])
        XCTAssertEqual(part.filePartOf, 10)
    }

    func test_the_thread_sheet_marks_the_replies_that_are_parts() throws {
        let replies = ["r1", "r2", "r3"].map { id in
            RoomChatReplyRow(id: id, authorName: "lin-agent", isHuman: false, isOwn: false, text: "data", date: nil,
                             isEdited: false)
        }
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room",
            messages: [input("m10", seq: 10, at: 0)],
            thread: RoomChatThreadInput(sequenceId: 10, replies: replies),
            files: [10: [card(verified: Data([1]))]],
            fileParts: ["r1": 10, "r3": 10]
        )
        let thread = try XCTUnwrap(state.thread)
        XCTAssertEqual(thread.replies.map(\.filePartOf), [10, nil, 10], "r2 is an ordinary reply")
        XCTAssertEqual(thread.parent.files.count, 1, "the sheet shows the card with its message")
    }
}
