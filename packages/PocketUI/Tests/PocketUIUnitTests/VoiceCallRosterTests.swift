import Foundation
import XCTest
@testable import PocketUI

final class VoiceCallRosterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Carter (#55061): a box that ended, or an agent gone for hours, is not in the call list. The room's services
    /// never answer a call.
    func test_only_agents_that_can_answer_are_offered() {
        let partners = VoiceCallRoster.partners(
            present: ["review-agent", "old-box"],
            posts: [
                .init(authorId: "respawn-orchestrator", at: now.addingTimeInterval(-10)),
                .init(authorId: "senti", at: now.addingTimeInterval(-15)),
                .init(authorId: "build-agent", at: now.addingTimeInterval(-20 * 60)),
                .init(authorId: "review-agent", at: now.addingTimeInterval(-30)),
                .init(authorId: "gone-agent", at: now.addingTimeInterval(-2 * 60 * 60)),
                .init(authorId: "undated-agent", at: nil),
                .init(authorId: "released-box", at: now.addingTimeInterval(-60))
            ],
            runningBoxes: ["quiet-box"],
            endedBoxes: ["old-box", "Released-Box"],
            now: now
        )
        XCTAssertEqual(partners, ["review-agent", "build-agent", "quiet-box"],
                       "here now, then heard from within the hour, then the boxes still running")
    }

    func test_a_running_box_is_offered_even_when_an_earlier_box_of_its_name_ended() {
        let partners = VoiceCallRoster.partners(present: [], posts: [], runningBoxes: ["ds-web"], endedBoxes: ["ds-web"],
                                                now: now)
        XCTAssertEqual(partners, ["ds-web"])
    }

    func test_the_list_is_short_with_no_person_and_no_one_twice() {
        let many = (1...12).map { "agent-\($0)" }
        let partners = VoiceCallRoster.partners(present: ["human-mrrcarter"] + many + ["AGENT-1"], posts: [],
                                                runningBoxes: ["agent-2"], endedBoxes: [], now: now)
        XCTAssertEqual(partners.count, VoiceCallRoster.limit)
        XCTAssertEqual(partners.first, "agent-1")
        XCTAssertFalse(partners.contains("AGENT-1"))
        XCTAssertFalse(partners.contains("human-mrrcarter"))
    }
}
