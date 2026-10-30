import XCTest
@testable import PocketVoice

/// The web's Listen rules (sentinelayer-web `useSpeech.test.ts`), case for case.
final class SpeechTextTests: XCTestCase {
    func test_markdown_is_stripped_down_to_plain_speech() {
        XCTAssertEqual(SpeechText.spoken(fromMarkdown: "**Bold** _em_ `code`"), "Bold em code")
        XCTAssertEqual(SpeechText.spoken(fromMarkdown: "# Heading\n\nBody"), "Heading\n\nBody")
        XCTAssertEqual(SpeechText.spoken(fromMarkdown: "- one\n- two"), "one\ntwo")
        XCTAssertEqual(SpeechText.spoken(fromMarkdown: "see [docs](https://x.io)"), "see docs")
        XCTAssertEqual(SpeechText.spoken(fromMarkdown: "visit https://example.com/page now"), "visit link now")
        XCTAssertEqual(SpeechText.spoken(fromMarkdown: "hey @review-agent ok"), "hey review-agent ok")
        XCTAssertEqual(SpeechText.spoken(fromMarkdown: "![screenshot](https://x.io/a.png) attached"), "screenshot attached")
        XCTAssertEqual(SpeechText.spoken(fromMarkdown: "> quoted\n| a | b |"), "quoted\n a b")
    }

    /// A box's "⟂ speech …" line and a fast answer's "⟂ quick voice" line are labels for the eye, never said.
    func test_a_signature_line_is_not_read_aloud() {
        XCTAssertEqual(
            SpeechText.spoken(fromMarkdown: "Build 21 is up.\n⟂ speech bcee41139aa6a1dd · model via codex · managed"),
            "Build 21 is up."
        )
        XCTAssertEqual(SpeechText.spoken(fromMarkdown: "I heard you.\n  ⟂ quick voice · facts: last post"), "I heard you.")
        XCTAssertEqual(SpeechText.spoken(fromMarkdown: "The ⟂ sign mid-line stays."), "The ⟂ sign mid-line stays.")
    }

    func test_a_code_block_is_announced_instead_of_read_aloud() {
        let spoken = SpeechText.spoken(fromMarkdown: "before\n```\nrm -rf /\n```\nafter")
        XCTAssertTrue(spoken.contains("code block"))
        XCTAssertFalse(spoken.contains("rm -rf"))
    }

    func test_empty_input_says_nothing() {
        XCTAssertEqual(SpeechText.spoken(fromMarkdown: ""), "")
        XCTAssertEqual(SpeechText.spoken(fromMarkdown: "   \n  "), "")
        XCTAssertEqual(SpeechText.segments(""), [])
    }

    func test_sentences_become_segments_and_the_last_has_no_pause() {
        let segments = SpeechText.segments("One. Two. Three.")
        XCTAssertEqual(segments.map(\.text), ["One.", "Two.", "Three."])
        XCTAssertEqual(segments.first?.pauseAfter, SpeechText.sentencePause)
        XCTAssertEqual(segments.last?.pauseAfter, 0)
    }

    func test_a_paragraph_break_gets_a_longer_pause_than_a_sentence() {
        let segments = SpeechText.segments("A. B.\n\nC.")
        XCTAssertEqual(segments.map(\.text), ["A.", "B.", "C."])
        XCTAssertGreaterThan(segments[1].pauseAfter, segments[0].pauseAfter)
        XCTAssertEqual(segments[2].pauseAfter, 0)
    }

    func test_a_long_run_on_sentence_is_split_into_clauses() {
        let long = "alpha, " + String(repeating: "beta ", count: 60) + "end."
        let segments = SpeechText.segments(long)
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.text.count <= SpeechText.maxSegmentLength })
        XCTAssertEqual(segments.dropLast().map(\.pauseAfter), Array(repeating: SpeechText.clausePause, count: segments.count - 1))
        XCTAssertEqual(segments.map(\.text).joined(separator: " "), long, "no word is lost or repeated")
    }
}
