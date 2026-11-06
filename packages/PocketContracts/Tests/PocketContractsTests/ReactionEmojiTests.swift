import Foundation
import XCTest
@testable import PocketContracts

/// An emoji reaction holds exactly one emoji, whatever the room or the API sends.
final class ReactionEmojiTests: XCTestCase {
    func test_one_emoji_of_every_kind_is_taken() {
        let taken = [
            "👍",                                      // a pictograph
            "\u{2764}\u{FE0F}",                        // with the emoji selector
            "👍\u{1F3FD}",                             // with a skin tone
            "👩\u{200D}💻",                            // joined parts
            "👨\u{200D}👩\u{200D}👧\u{200D}👦",        // seven code points
            "🇺🇸",                                     // a flag
            "1\u{FE0F}\u{20E3}",                       // a keycap
            "#\u{20E3}",                               // a keycap without the selector
            "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"   // England's flag
        ]
        for emoji in taken {
            XCTAssertTrue(ReactionEmoji.isValid(emoji), "\(emoji.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    func test_text_mentions_and_anything_but_one_emoji_are_refused() {
        let refused: [(String, String)] = [
            ("", "nothing"),
            ("@all", "a mention"),
            ("abc", "letters"),
            ("a", "one letter"),
            ("1", "a digit"),
            ("@", "an at sign"),
            ("👍👍", "two emoji"),
            ("👍 ", "an emoji and a space"),
            ("\u{2139}\u{FE0F}", "a letter, even one shown as an emoji"),
            ("\u{2605}", "a symbol that is not an emoji"),
            ("a\u{20E3}", "a keycap on a letter"),
            ("1\u{200D}\u{20E3}", "a keycap with a joiner in it"),
            ("1\u{20E3}\u{20E3}", "a keycap marked twice"),
            ("🇦", "one regional indicator alone"),
            ("🇦\u{FE0F}", "a regional indicator with a selector"),
            ("👍\u{E0041}\u{E0042}", "hidden tag text after an emoji"),
            ("\u{1F3F4}\u{E0061}\u{E0062}\u{E007F}", "tag text that is not a flag"),
            ("👍\u{0301}", "a combining mark"),
            ("\u{1F9D1}\u{1F3FB}\u{200D}\u{2764}\u{FE0F}\u{200D}\u{1F48B}\u{200D}\u{1F9D1}\u{1F3FC}", "ten code points")
        ]
        for (text, why) in refused {
            XCTAssertFalse(ReactionEmoji.isValid(text), why)
        }
    }
}
