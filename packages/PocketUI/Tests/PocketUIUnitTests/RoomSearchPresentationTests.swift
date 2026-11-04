import Foundation
import XCTest
@testable import PocketUI

final class RoomSearchPresentationTests: XCTestCase {
    /// App Store screenshots: a search result showed its message as typed. The server sends one line of about 80
    /// characters around the match, cut anywhere: only unmistakable marks go, and code stays as written.
    func test_a_server_snippet_reads_as_text_and_code_stays_as_written() {
        let cases: [(String, String, String)] = [
            ("ails so far: 1. The **email step** skips validation on paste. 2. `retryCount` resets", "paste",
             "ails so far: 1. The email step skips validation on paste. 2. retryCount resets"),
            ("Details are in [the PR](https://github.com/example/app/pull/42) about paste.", "paste",
             "Details are in the PR about paste."),
            ("## Status paste is fixed", "paste", "Status paste is fixed"),
            ("> quoted paste text", "paste", "quoted paste text"),
            ("- [x] paste check done", "paste", "paste check done"),
            ("| a | paste | c | |---|---|---| | 1 | 2 | 3 |", "paste", "a paste c 1 2 3"),
            ("```swift let x = paste() ```", "paste", "let x = paste()"),
            ("Build it with ```bash make paste ``` then ship", "paste", "Build it with make paste then ship"),
            ("glob packages/*/Sources/*.swift for paste", "paste", "glob packages/*/Sources/*.swift for paste"),
            ("see __init__.py and paste", "paste", "see __init__.py and paste"),
            ("2*3*4 paste", "paste", "2*3*4 paste"),
            (">= 3 pastes", "paste", ">= 3 pastes"),
            ("run `a | b` to paste", "paste", "run a | b to paste"),
            ("x || y paste", "paste", "x || y paste"),
        ]
        for (snippet, query, reads) in cases {
            XCTAssertEqual(RoomSearchPresentationState.plainSnippet(snippet, query: query), reads, snippet)
        }
    }

    /// When cleaning would hide what was searched for (a match inside a link's address) or leave nothing, the snippet
    /// is shown as the server sent it.
    func test_a_snippet_whose_match_cleaning_would_hide_is_shown_as_sent() {
        XCTAssertEqual(RoomSearchPresentationState.plainSnippet("See [docs](https://example.com/paste-guide) now", query: "paste"),
                       "See [docs](https://example.com/paste-guide) now")
        XCTAssertEqual(RoomSearchPresentationState.plainSnippet("```", query: "x"), "```", "nothing left: as sent")
        let plain = RoomSearchPresentationState.plainSnippet("The **deploy** went _green_", query: "deploy")
        XCTAssertEqual(RoomSearchPresentationState.highlight(plain, query: "deploy")?.match, "deploy")
    }

    /// A whole message stands in when the server sent no snippet: only the part around the match is read and cleaned.
    func test_a_long_text_is_cut_around_the_match_first() {
        let long = String(repeating: "filler words ", count: 8_000) + "the **paste** fix " + String(repeating: "more ", count: 8_000)
        let started = Date()
        let plain = RoomSearchPresentationState.plainSnippet(long, query: "paste")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        XCTAssertLessThan(plain.count, 400)
        XCTAssertTrue(plain.contains("the paste fix"), plain)
    }

    func test_the_first_match_is_marked_whatever_its_case() {
        let parts = RoomSearchPresentationState.highlight("Validation runs on PASTE and on paste", query: " paste ")
        XCTAssertEqual(parts?.before, "Validation runs on ")
        XCTAssertEqual(parts?.match, "PASTE")
        XCTAssertEqual(parts?.after, " and on paste")
        XCTAssertNil(RoomSearchPresentationState.highlight("nothing here", query: "paste"))
        XCTAssertNil(RoomSearchPresentationState.highlight("anything", query: "  "))
    }

    /// Carter (#55006): every word must be there, in any order, ignoring case and accents; tabs keep their kind.
    func test_people_and_shared_things_match_every_word_within_their_tab() {
        XCTAssertTrue(RoomSearchPresentationState.matches("voice SHIPPED", in: ["Voice room shipped"]))
        XCTAssertTrue(RoomSearchPresentationState.matches("cafe", in: ["Café menu", nil]))
        XCTAssertFalse(RoomSearchPresentationState.matches("voice stopped", in: ["Voice room shipped"]))
        XCTAssertFalse(RoomSearchPresentationState.matches("   ", in: ["anything"]), "no words match nothing")

        let people = [RoomSearchPerson(authorId: "claude-warden", name: "claude-warden", isHuman: false)]
        let shared = [
            RoomArtifact(id: "t", kind: .ticket, title: "Warden review queue", detail: nil, url: nil, sequenceId: 1,
                         author: "ticket-keeper", date: nil, mentions: 1),
            RoomArtifact(id: "f", kind: .file, title: "warden-notes.md", detail: nil, url: nil, sequenceId: 2,
                         author: "claude-warden", date: nil, mentions: 1)
        ]
        let all = RoomSearchPresentationState.localMatches(query: "warden", scope: .all, people: people, artifacts: shared)
        XCTAssertEqual(all.people.map(\.id), ["claude-warden"])
        XCTAssertEqual(all.artifacts.map(\.id), ["t", "f"])
        let files = RoomSearchPresentationState.localMatches(query: "warden", scope: .artifacts(.file), people: people,
                                                             artifacts: shared)
        XCTAssertTrue(files.people.isEmpty)
        XCTAssertEqual(files.artifacts.map(\.id), ["f"])
        XCTAssertTrue(RoomSearchPresentationState.localMatches(query: "warden", scope: .messages, people: people,
                                                               artifacts: shared).artifacts.isEmpty)
    }
}
