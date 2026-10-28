import Foundation
import XCTest
@testable import PocketUI

final class MentionSuggesterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func test_the_query_is_the_trailing_at_token_after_whitespace_or_the_start() {
        XCTAssertEqual(MentionSuggester.activeQuery(in: "@cob")?.query, "cob")
        XCTAssertEqual(MentionSuggester.activeQuery(in: "ping @")?.query, "")
        XCTAssertEqual(MentionSuggester.activeQuery(in: "ping @cobalt-war")?.query, "cobalt-war")
        XCTAssertNil(MentionSuggester.activeQuery(in: "mail me@example"), "an @ inside a word is not a mention")
        XCTAssertNil(MentionSuggester.activeQuery(in: "@cobalt-warden thanks"), "a finished mention is not active")
        XCTAssertNil(MentionSuggester.activeQuery(in: "no mention"))
    }

    func test_candidates_put_humans_first_then_recent_agents_and_drop_yourself() {
        let candidates = MentionSuggester.candidates(
            authors: [
                (id: "zeta-agent", name: "zeta-agent", isHuman: false, lastActive: now.addingTimeInterval(-60)),
                (id: "alpha-agent", name: "alpha-agent", isHuman: false, lastActive: now.addingTimeInterval(-3600)),
                (id: "human-mrrcarter", name: "mrrCarter", isHuman: true, lastActive: now),
                (id: "human-griff", name: "Griff Ryan", isHuman: true, lastActive: now.addingTimeInterval(-7200))
            ],
            ownHandles: ["mrrcarter"],
            now: now
        )
        XCTAssertEqual(candidates.map(\.handle), ["griff", "zeta-agent", "alpha-agent"],
                       "humans, then agents active in the last 10 minutes, then the rest; you are never offered")
        XCTAssertEqual(candidates.first?.displayName, "Griff Ryan",
                       "a person is shown by name but mentioned by login, the only handle the API notifies")
    }

    func test_suggestions_offer_all_for_a_prefix_and_match_handles_or_names() {
        let candidates = [
            MentionCandidate(handle: "cobalt-warden", displayName: "cobalt-warden", isHuman: false),
            MentionCandidate(handle: "griff", displayName: "Griff Ryan", isHuman: true)
        ]
        XCTAssertEqual(MentionSuggester.suggestions(for: "", among: candidates).map(\.handle), ["all", "cobalt-warden", "griff"])
        XCTAssertEqual(MentionSuggester.suggestions(for: "al", among: candidates).map(\.handle), ["all"])
        XCTAssertEqual(MentionSuggester.suggestions(for: "ryan", among: candidates).map(\.handle), ["griff"], "display names match too")
        XCTAssertEqual(MentionSuggester.apply(candidates[0], to: "thanks @cob"), "thanks @cobalt-warden ")
    }
}

final class TicketDecisionTests: XCTestCase {
    func test_a_decision_section_gives_its_question_options_and_custom() {
        let decision = TicketDecision.parse("""
        ## Intent
        x

        ## Decision
        Question: Ship the room chat first?
        Options: Yes · No · After the composer · Custom

        ## Priority
        P1
        """)
        XCTAssertEqual(decision?.question, "Ship the room chat first?")
        XCTAssertEqual(decision?.options, ["Yes", "No", "After the composer"])
        XCTAssertEqual(decision?.allowsCustom, true)
    }

    func test_no_options_is_an_open_question_and_fenced_examples_never_count() {
        XCTAssertEqual(TicketDecision.parse("## Decision needed\nWhich host?")?.allowsCustom, true)
        XCTAssertEqual(TicketDecision.parse("## Decision needed\nWhich host?")?.options, [])
        XCTAssertNil(TicketDecision.parse("```\n## Decision\nQuestion: fake?\nOptions: Yes · No\n```"))
        XCTAssertNil(TicketDecision.parse("## Decision\n\n## Next"), "no question means no decision")
        XCTAssertEqual(TicketDecision.parse("## Decision\nQuestion: a, b or c?\nOptions: a, b · c")?.options, ["a, b", "c"],
                       "only the middle dot separates options")
    }

    func test_the_chat_line_matches_the_web_and_names_the_assignee() {
        XCTAssertEqual(
            TicketDecision.chatLine(sessionId: "room_1", ticketId: "t1", title: "Pick a [host]", answer: "Yes", assignee: "cobalt-warden"),
            "Decision on [Ticket: Pick a host](/dashboard/sessions/room_1?ticket=t1): Yes @cobalt-warden",
            "brackets in a title cannot break the link card"
        )
        XCTAssertEqual(
            TicketDecision.chatLine(sessionId: "room_1", ticketId: "t1", title: "Pick", answer: "Custom", detail: "On the Mac", assignee: nil),
            "Decision on [Ticket: Pick](/dashboard/sessions/room_1?ticket=t1): Custom — On the Mac"
        )
        XCTAssertTrue(TicketDecision.chatLine(sessionId: "r", ticketId: "t", title: "T", answer: "No",
                                              assignee: "5d2c8a1e-7b3f-4c9d-8e6a-0f1b2c3d4e5f", personLabel: { _ in "Carter" })
            .hasSuffix(": No (for Carter)"), "a user id is never @-mentioned")
    }
}
