import Foundation
import XCTest
@testable import PocketUI

final class RoomArtifactsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_793_300_000)

    private func message(_ seq: Int64, _ author: String, _ text: String, minutes: Double,
                         files: [(id: String, name: String)] = []) -> RoomArtifactSource {
        RoomArtifactSource(id: "evt-\(seq)", sequenceId: seq, author: author, text: text,
                           date: base.addingTimeInterval(minutes * 60), files: files)
    }

    /// Carter (#54955): the room's artifacts in one place, each tied back to the message it came from.
    func test_each_thing_is_listed_once_tied_to_its_newest_mention() {
        let room = "00000000-0000-4000-8000-00000000a214"
        let messages = [
            message(1, "pocket-forge", "Opened https://github.com/Sentinelayer-AIdenID/senti-pocket/pull/210 for review.", minutes: 0),
            message(2, "claude-warden", "Reviewing [the voice room](https://github.com/Sentinelayer-AIdenID/senti-pocket/pull/210) now; docs at https://developer.apple.com/documentation/pushkit.", minutes: 5),
            message(3, "ticket-keeper", "🎫 Ticket for this message: [Ticket: Lower the text box](/dashboard/sessions/\(room)?ticket=0000c214)", minutes: 6),
            message(4, "pocket-forge", "Here is the fold:\n```swift\nlet trails = RoomChatTrail.fold(inputs)\n```", minutes: 7),
            message(5, "human-mrrcarter", "the transcript", minutes: 8, files: [(id: "att-12345678", name: "voice-call.md")])
        ]
        let artifacts = RoomArtifacts.extract(from: messages)
        XCTAssertEqual(artifacts.map(\.kind), [.file, .code, .ticket, .pullRequest, .link], "newest first")

        let pr = artifacts.first { $0.kind == .pullRequest }
        XCTAssertEqual(pr?.mentions, 2, "a PR mentioned twice is one entry")
        XCTAssertEqual(pr?.sequenceId, 2, "tied to its newest mention")
        XCTAssertEqual(pr?.title, "the voice room")
        XCTAssertEqual(pr?.detail, "Sentinelayer-AIdenID/senti-pocket#210")

        XCTAssertEqual(artifacts.first { $0.kind == .ticket }?.title, "Lower the text box")
        XCTAssertEqual(artifacts.first { $0.kind == .link }?.detail, "developer.apple.com")
        XCTAssertEqual(artifacts.first { $0.kind == .code }?.title, "let trails = RoomChatTrail.fold(inputs)")
        XCTAssertEqual(artifacts.first { $0.kind == .code }?.detail, "swift")
        XCTAssertEqual(artifacts.first { $0.kind == .file }?.title, "voice-call.md")
    }

    func test_a_senti_ticket_link_is_a_ticket_not_a_link_and_plain_text_has_nothing() {
        let absolute = "[Ticket: Fix the bell](https://sentinelayer.com/dashboard/sessions/0000a214?ticket=0000b214)"
        let artifacts = RoomArtifacts.extract(from: [message(1, "ticket-keeper", absolute, minutes: 0)])
        XCTAssertEqual(artifacts.map(\.kind), [.ticket])
        XCTAssertTrue(RoomArtifacts.extract(from: [message(2, "a", "nothing to see here", minutes: 1)]).isEmpty)
        XCTAssertNil(RoomArtifacts.firstCodeLine(in: "```\n```"), "an empty code block is not an artifact")
    }
}
