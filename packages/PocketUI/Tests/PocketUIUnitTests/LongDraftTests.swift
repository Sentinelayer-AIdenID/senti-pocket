import XCTest
@testable import PocketUI

/// Ticket 7674d10b (Carter: a long draft slows the box). The per-keystroke helpers walk the draft in place now; they
/// must answer exactly as the array-copying versions did.
final class LongDraftTests: XCTestCase {
    /// The previous implementations, kept here as the reference.
    private func referenceEditOffset(_ old: String, _ new: String) -> Int {
        let before = Array(old), after = Array(new)
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] {
            suffix += 1
        }
        return after.count - suffix
    }

    private func referenceQuery(_ draft: String, _ offset: Int) -> (query: String, range: Range<Int>)? {
        let characters = Array(draft)
        guard offset >= 0, offset <= characters.count else { return nil }
        var start = offset
        let handle: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        while start > 0, handle(characters[start - 1]) { start -= 1 }
        guard start > 0, characters[start - 1] == "@" else { return nil }
        let at = start - 1
        if at > 0, !characters[at - 1].isWhitespace { return nil }
        return (String(characters[start..<offset]), at..<offset)
    }

    func test_edit_offsets_match_the_reference_for_typing_pasting_deleting_and_emoji() {
        let pairs: [(String, String)] = [
            ("", "a"), ("ask @wa", "ask @war"), ("ask @war to go", "ask @wa to go"), ("hello", "hello"),
            ("one two", "one three two"), ("👨‍👩‍👧 hi", "👨‍👩‍👧 hi!"), ("café", "cafés"), ("aaaa", "aaa"),
            ("abc", ""), ("x@y", "x@yz"), (String(repeating: "word ", count: 2_000), String(repeating: "word ", count: 2_000) + "@w")
        ]
        for (old, new) in pairs {
            XCTAssertEqual(MentionSuggester.editOffset(from: old, to: new), referenceEditOffset(old, new), "\(old.prefix(20)) → \(new.prefix(20))")
        }
    }

    func test_active_queries_match_the_reference_at_every_offset() {
        for draft in ["ask @war to check", "@all now", "mail a@b.com", "👋 @pocket-forge hi", "@", "no mention", "x @a-b_c9 y"] {
            for offset in -1...(draft.count + 1) {
                let ours = MentionSuggester.activeQuery(in: draft, at: offset)
                let reference = referenceQuery(draft, offset)
                XCTAssertEqual(ours?.query, reference?.query, "\(draft) at \(offset)")
                XCTAssertEqual(ours?.range, reference?.range, "\(draft) at \(offset)")
            }
        }
    }

    /// Carter, 11-04: still slow at 2,000 characters. A keystroke at the end is answered without walking the draft: nil
    /// exactly where the full answer is the end of the new text, and the full answer everywhere else.
    func test_an_edit_at_the_end_is_nil_and_any_other_edit_is_the_full_offset() {
        let long = String(repeating: "word ", count: 2_000)
        let pairs: [(String, String)] = [
            ("", "a"), ("ask @wa", "ask @war"), ("ask @war to go", "ask @wa to go"), ("hello", "hello"),
            ("one two", "one three two"), ("👨‍👩‍👧 hi", "👨‍👩‍👧 hi!"), ("café", "cafés"), ("aaaa", "aaa"),
            ("abc", ""), ("x@y", "x@yz"), ("e", "e\u{301}"), ("👍", "👍🏽"), ("ab", "acb"), ("abc", "xbc"),
            (long, long + "@w"), (long + "x", long), (long, "@w " + long)
        ]
        for (old, new) in pairs {
            let full = referenceEditOffset(old, new)
            let ours = MentionSuggester.editOffsetUnlessAtEnd(from: old, to: new)
            if full == new.count {
                XCTAssertNil(ours, "\(old.prefix(12)) → \(new.prefix(12)): the edit ended at the end")
            } else {
                XCTAssertEqual(ours, full, "\(old.prefix(12)) → \(new.prefix(12))")
            }
        }
    }

    /// The `@word` at the end, found from the end only: the same answer as the offset-based query at the end.
    func test_the_query_at_the_end_matches_the_query_at_the_last_offset() {
        let drafts = ["ask @war to check", "ask @war", "@all", "mail a@b.com", "👋 @build-agent", "@", "no mention",
                      "x @a-b_c9", "x@y", " @", "line\n@agent", String(repeating: "word ", count: 2_000) + "@wa"]
        for draft in drafts {
            XCTAssertEqual(MentionSuggester.queryAtEnd(of: draft), referenceQuery(draft, draft.count)?.query, draft)
        }
        // A run of letters longer than any handle is not looked through to its start.
        XCTAssertNil(MentionSuggester.queryAtEnd(of: "@" + String(repeating: "a", count: 10_000)))
    }

    func test_a_keystroke_is_never_a_paste_and_a_paste_still_is() {
        let long = String(repeating: "x", count: 5_000)
        XCTAssertNil(RoomComposerDraft.pastedBlock(from: long, to: long + "y"))
        let block = String(repeating: "p", count: RoomComposerDraft.pastedBlockLength)
        XCTAssertEqual(RoomComposerDraft.pastedBlock(from: "hi ", to: "hi " + block)?.block, block)
    }

    func test_length_lines_read_the_same() {
        let composer = RoomComposerState(canPost: true, disabledReason: nil, maximumLength: 64_000)
        XCTAssertNil(composer.lengthNote(for: "short"))
        XCTAssertEqual(composer.lengthNote(for: String(repeating: "a", count: 1_234)), "1,234 of 64,000 characters")
        XCTAssertEqual(composer.lengthProblem(for: String(repeating: "a", count: 64_001)),
                       "Too long to send: 64,001 of 64,000 characters.")
    }
}
