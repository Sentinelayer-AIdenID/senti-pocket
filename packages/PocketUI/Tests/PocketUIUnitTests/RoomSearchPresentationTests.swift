import Foundation
import XCTest
@testable import PocketUI

final class RoomSearchPresentationTests: XCTestCase {
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
