import Foundation
import SwiftUI
import XCTest
@testable import PocketUI

/// The helpers every room update runs, made cheap, must say exactly what the expressions they replaced said.
final class HotPathTests: XCTestCase {
    func test_a_notices_shape_drops_its_numbers_as_before() {
        let samples = [
            "⚠ bridge: message from life a1b2c3d4e5f6 (frame 707) remains queued after 105 failed relay attempts.",
            "[cost] box: $19.05 est over 1462 calls · room so far $4103.34",
            "no digits here", "", "٣ Arabic-Indic digits stay", "v2.3.10 build 2026103004"
        ]
        for sample in samples {
            let expression = sample.replacingOccurrences(of: #"[0-9]+"#, with: "#", options: .regularExpression)
            XCTAssertEqual(RoomChatRepeats.shape(sample), expression, sample)
        }
    }

    func test_a_quiet_line_is_the_same_the_second_time() {
        let text = "**READY** for [carry](/x)\nmore ⟂ speech 1"
        XCTAssertEqual(RoomChatQuiet.line(text), "READY for carry")
        XCTAssertEqual(RoomChatQuiet.line(text), "READY for carry", "remembered")
        XCTAssertEqual(RoomChatQuiet.line("> # Heading `code`"), "Heading code")
        XCTAssertEqual(ChatReferences.mentionHandles(in: "no mention here"), [])
    }

    /// Carter's freeze (#56316): the review packets were quiet rows whose first line was a 700-character JSON header,
    /// measured on every draw. The line is cut; a short line is kept whole.
    func test_a_quiet_line_from_a_giant_first_line_is_cut() {
        let header = "@aneta-claude REVIEW_PACKET {" + (1...60).map { "\"key\($0)\":\"value\"" }.joined(separator: ",")
        let packet = header + "\n" + Array(repeating: "  \"field\": \"value\",", count: 300).joined(separator: "\n")
        let line = RoomChatQuiet.line(packet)
        XCTAssertEqual(line.count, RoomChatQuiet.lineCharacters + 1)
        XCTAssertTrue(line.hasSuffix("…"))
        XCTAssertTrue(header.hasPrefix(String(line.dropLast())), "its start, as it was")
        XCTAssertEqual(RoomChatQuiet.line(packet), line, "remembered")
        let short = "@aneta-claude a short note"
        XCTAssertEqual(RoomChatQuiet.line(short), short)
    }

    /// Carter's 08:06 freeze (2026103005) stopped inside a long row's body, in `LongMessage.preview`.
    func test_a_long_rows_preview_and_length_are_kept_and_match() {
        let long = (1...60).map { "line \($0) of a long report" }.joined(separator: "\n")
        let shown = LongMessage.shown(long)
        XCTAssertEqual(shown?.preview, LongMessage.preview(long))
        XCTAssertEqual(shown?.characters, long.count)
        XCTAssertEqual(LongMessage.shown(long)?.preview, shown?.preview, "the same the second time")
        XCTAssertNil(LongMessage.shown("short"))
        XCTAssertNil(LongMessage.shown("short"), "a short message is remembered as short")
    }

    func test_inline_markdown_is_the_same_kept_or_built_and_follows_the_handles() {
        let text = "@pocket-forge see https://github.com/a/b/pull/9 and **bold**"
        let first = ChatInlineMarkdown.attributed(text, ownHandles: ["pocket-forge"])
        XCTAssertEqual(ChatInlineMarkdown.attributed(text, ownHandles: ["pocket-forge"]), first)
        XCTAssertTrue(String(first.characters).contains("a/b#9"))
        let other = ChatInlineMarkdown.attributed(text, ownHandles: [])
        let mention = first.runs.first { String(first[$0.range].characters) == "@pocket-forge" }
        let otherMention = other.runs.first { String(other[$0.range].characters) == "@pocket-forge" }
        XCTAssertNotNil(mention?.swiftUI.backgroundColor, "a mention of you stands out")
        XCTAssertNil(otherMention?.swiftUI.backgroundColor, "with other handles it is a different answer")
    }
}
