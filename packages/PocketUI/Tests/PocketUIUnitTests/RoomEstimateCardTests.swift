import Foundation
import XCTest
@testable import PocketUI

/// The estimate card's words: a cost nobody measured is never $0, tickets left out are counted, a weekly-limit percent
/// is said only for a judge billed to a plan, VoiceOver reads each option as one element, and only whoever asked (or
/// an owner or admin) picks. Labels and numbers are made up.
final class RoomEstimateCardTests: XCTestCase {
    private typealias Option = RoomEstimateCard.Option

    func test_a_cost_nobody_measured_says_no_basis_yet_never_zero() {
        XCTAssertEqual(Option(id: "a", label: "A").costText, "No basis yet")
        XCTAssertEqual(Option(id: "a", label: "A", lowUsd: nil, highUsd: 14).costText, "No basis yet",
                       "one end is not a range")
        XCTAssertEqual(Option(id: "a", label: "A", unpricedTickets: 3).costText, "No basis yet")
        XCTAssertFalse(Option(id: "a", label: "A").accessibilityLabel.contains("$0"))
        XCTAssertEqual(Option(id: "a", label: "A", lowUsd: 0, highUsd: 0).costText, "$0", "a measured nothing is $0")
    }

    func test_tickets_left_out_of_a_cost_are_counted_on_it() {
        XCTAssertEqual(Option(id: "a", label: "A", lowUsd: 6, highUsd: 14.5).costText, "$6–$14.50")
        XCTAssertEqual(Option(id: "a", label: "A", lowUsd: 6, highUsd: 14, unpricedTickets: 2).costText,
                       "$6–$14 · +2 not priced")
        XCTAssertEqual(Option(id: "a", label: "A", lowUsd: 3, highUsd: 3).costText, "$3")
    }

    func test_time_and_rounds_read_as_ranges() {
        XCTAssertEqual(Option(id: "a", label: "A", lowMinutes: 40, highMinutes: 120).timeText, "40 min–2 h")
        XCTAssertEqual(Option(id: "a", label: "A", lowMinutes: 90, highMinutes: 90).timeText, "1.5 h")
        XCTAssertNil(Option(id: "a", label: "A", lowMinutes: 40).timeText)
        XCTAssertEqual(Option(id: "a", label: "A", expectedRounds: 2, maxRounds: 3).roundsText,
                       "About 2 review rounds, up to 3")
        XCTAssertEqual(Option(id: "a", label: "A", expectedRounds: 1, maxRounds: 1).roundsText, "About 1 review round")
    }

    /// The weekly-limit percent describes a plan, so only a judge billed to one says it; without it, the tokens.
    func test_the_weekly_limit_percent_is_said_only_for_a_judge_billed_to_a_plan() {
        let withPercent = Option(id: "a", label: "A", billing: .plan(.claude), judgeTokensLow: 120_000,
                                 judgeTokensHigh: 300_000, weeklyLimitPercentLow: 3, weeklyLimitPercentHigh: 8.5)
        XCTAssertEqual(withPercent.billingText, "Judge uses your Claude plan: about 3–9% of your weekly limit")
        let tokensOnly = Option(id: "a", label: "A", billing: .plan(.claude), judgeTokensLow: 120_000,
                                judgeTokensHigh: 300_000)
        XCTAssertEqual(tokensOnly.billingText, "Judge uses your Claude plan: 120k–300k tokens")
        let codex = Option(id: "a", label: "A", billing: .plan(.chatgpt), judgeTokensLow: 1_200_000,
                           judgeTokensHigh: 1_200_000)
        XCTAssertEqual(codex.billingText, "Judge uses your ChatGPT plan: 1.2M tokens")
        let perToken = Option(id: "a", label: "A", billing: .perToken, weeklyLimitPercentLow: 3,
                              weeklyLimitPercentHigh: 8)
        XCTAssertEqual(perToken.billingText, "Judge paid per token, in the cost")
        XCTAssertFalse(perToken.billingText?.contains("%") == true, "no plan, no percent")
        XCTAssertNil(Option(id: "a", label: "A", billing: RoomEstimateCard.Billing.none).billingText)
    }

    /// VoiceOver reads each option as one element: its label, cost, time, then "suggested".
    func test_voiceover_reads_an_option_as_label_cost_time_then_suggested() {
        let suggested = Option(id: "a", label: "Senti boxes + Claude judge", lowUsd: 6, highUsd: 14, unpricedTickets: 1,
                               lowMinutes: 40, highMinutes: 120, isSuggested: true)
        XCTAssertEqual(suggested.accessibilityLabel,
                       "Senti boxes + Claude judge, $6 to $14, +1 not priced, 40 minutes to 2 hours, suggested")
        let other = Option(id: "b", label: "A frontier coder alone", lowMinutes: 30, highMinutes: 30)
        XCTAssertEqual(other.accessibilityLabel, "A frontier coder alone, No basis yet, 30 minutes")
    }

    /// Whoever asked picks, and so do the room's owners and admins; anyone else sees the card without the buttons.
    func test_only_whoever_asked_or_an_owner_or_admin_may_pick() {
        let own: Set<String> = ["human-alex"]
        XCTAssertTrue(RoomEstimateCard.mayPick(askedBy: "alex", ownHandles: own, role: "contributor"))
        XCTAssertTrue(RoomEstimateCard.mayPick(askedBy: "Alex", ownHandles: own, role: nil))
        XCTAssertFalse(RoomEstimateCard.mayPick(askedBy: "griff", ownHandles: own, role: "contributor"))
        XCTAssertFalse(RoomEstimateCard.mayPick(askedBy: nil, ownHandles: own, role: "contributor"))
        XCTAssertTrue(RoomEstimateCard.mayPick(askedBy: "griff", ownHandles: own, role: "owner"))
        XCTAssertTrue(RoomEstimateCard.mayPick(askedBy: "griff", ownHandles: own, role: "Admin"))
        XCTAssertFalse(RoomEstimateCard.mayPick(askedBy: "griff", ownHandles: own, role: "viewer"))
    }

    func test_pick_shows_only_while_it_is_ready_and_the_status_says_where_it_stands() {
        let options = [Option(id: "a", label: "Boxes")]
        XCTAssertTrue(RoomEstimateCard(estimateId: "e", options: options, status: .ready, canPick: true).canPick)
        for status: RoomEstimateCard.Status in [.loading, .expired, .failed(reason: "Too short."),
                                                .picked(optionLabel: "Boxes", by: "griff", byYou: false)] {
            XCTAssertFalse(RoomEstimateCard(estimateId: "e", options: options, status: status, canPick: true).canPick,
                           "\(status)")
        }
        XCTAssertEqual(RoomEstimateCard(estimateId: "e", options: options,
                                        status: .picked(optionLabel: "Boxes", by: "griff", byYou: false)).statusText,
                       "griff picked Boxes.")
        XCTAssertEqual(RoomEstimateCard(estimateId: "e", options: options,
                                        status: .picked(optionLabel: "Boxes", by: "alex", byYou: true)).statusText,
                       "You picked Boxes.")
        XCTAssertEqual(RoomEstimateCard(estimateId: "e", options: options, status: .failed(reason: "Too short."))
            .statusText, "Too short.")
        XCTAssertEqual(RoomEstimateCard(estimateId: "e", options: options, status: .expired).statusText,
                       "This estimate expired.")
        XCTAssertEqual(RoomEstimateCard.notAQuote, "Estimate, not a quote")
    }

    func test_the_basis_line_names_the_measured_sources_and_when() {
        XCTAssertEqual(RoomEstimateCard.basisLine(sources: ["pilot 3 tickets", "benchmark 20 tickets"],
                                                  measuredAt: "2026-11-06"),
                       "Based on pilot 3 tickets and benchmark 20 tickets, measured 2026-11-06")
        XCTAssertEqual(RoomEstimateCard.basisLine(sources: ["pilot 3 tickets"], measuredAt: nil),
                       "Based on pilot 3 tickets")
        XCTAssertNil(RoomEstimateCard.basisLine(sources: [], measuredAt: nil))
    }

    /// "Get an estimate" is on your own messages, and only in a room that offers estimates.
    func test_get_an_estimate_is_offered_on_your_own_message_only_where_the_room_offers_it() throws {
        let state = RoomChatPresentationState(
            sessionId: "room", title: "Room",
            messages: [
                RoomChatMessageInput(id: "m1", sequenceId: 1, kind: .message, authorId: "human-alex", authorName: "alex",
                                     isHuman: true, text: "Add a checkout page to my shop",
                                     timestamp: "2026-11-06T21:30:00Z"),
                RoomChatMessageInput(id: "m2", sequenceId: 2, kind: .message, authorId: "review-agent",
                                     authorName: "review-agent", isHuman: false, text: "Sounds good",
                                     timestamp: "2026-11-06T21:31:00Z")
            ],
            ownAuthorIds: ["human-alex"]
        )
        let rows = state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
        let mine = try XCTUnwrap(rows.first { $0.id == "m1" })
        let theirs = try XCTUnwrap(rows.first { $0.id == "m2" })
        func offers(_ row: RoomChatMessageRow, _ offered: Bool, canPost: Bool = true) -> RoomRowOption? {
            row.options(canReply: canPost, canReact: true, canPin: false, isPinned: false, pinsFull: false,
                        canEdit: canPost, offersEstimates: offered).first { $0.kind == .estimate }
        }
        let option = try XCTUnwrap(offers(mine, true))
        XCTAssertEqual(option.title, "Get an estimate")
        XCTAssertEqual(option.intent, .requestEstimate(sequenceId: 1, goal: "Add a checkout page to my shop"))
        XCTAssertNil(offers(mine, false), "a room that does not offer estimates shows no button")
        XCTAssertNil(offers(theirs, true), "never on someone else's message")
        XCTAssertNil(offers(mine, true, canPost: false), "not for someone who cannot post here")
    }

    /// Asked on a message, a card belongs to that message's thread, and the message carries a chip saying where it
    /// stands; one asked on no message is the room's own.
    func test_a_card_asked_on_a_message_is_that_threads_and_the_message_gets_a_chip() {
        let asked = RoomEstimateCard(estimateId: "e1", options: [], status: .ready, sourceSequenceId: 7, order: 9)
        let older = RoomEstimateCard(estimateId: "e0", options: [], status: .expired, sourceSequenceId: 7, order: 8)
        let roomOwn = RoomEstimateCard(estimateId: "e2", options: [], status: .ready, order: 10)
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: [],
                                              estimates: ["e1": asked, "e0": older, "e2": roomOwn])
        XCTAssertEqual(state.estimates(askedOn: 7).map(\.estimateId), ["e0", "e1"], "oldest first")
        XCTAssertEqual(state.estimateChip(on: 7), "Estimate ready", "the newest says where it stands")
        XCTAssertNil(state.estimateChip(on: 8))
        XCTAssertTrue(state.estimates(askedOn: 8).isEmpty)
        let picked = RoomEstimateCard(estimateId: "e1", options: [],
                                      status: .picked(optionLabel: "Boxes", by: "griff", byYou: false),
                                      sourceSequenceId: 7, order: 11)
        XCTAssertEqual(RoomChatPresentationState(sessionId: "room", title: "Room", messages: [],
                                                 estimates: ["e1": picked]).estimateChip(on: 7), "Estimate picked")
    }

    func test_the_estimate_intents_wait_for_the_ai_consent_but_the_plan_answer_does_not() {
        XCTAssertTrue(RoomChatIntent.requestEstimate(sequenceId: 1, goal: "x").isRoomWrite)
        XCTAssertTrue(RoomChatIntent.pickEstimate(estimateId: "e", optionId: "a").isRoomWrite)
        XCTAssertTrue(RoomChatIntent.askEstimateAgain(estimateId: "e").isRoomWrite)
        XCTAssertFalse(RoomChatIntent.answerEstimatePlan(estimateId: "e", plan: "pro").isRoomWrite)
    }
}
