import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts
import XCTest
@testable import PocketSyncClient

/// The estimate step against its contract (draft 2 and its contract answers): the room read's flag, the room event's
/// summary, the whole estimate, the routes, a first pick on a 409, and the plan saved to your account. All read in one
/// adapter (`RoomEstimates.swift`). Goals, handles and numbers are made up.
final class RoomEstimatesTests: XCTestCase {
    static let estimateId = "6f1c2d3e-4a5b-4c6d-8e9f-0a1b2c3d4e5f"

    /// The whole estimate as draft 2 writes it, with the plan percent of the contract answers.
    static let draftTwo = """
    {
      "estimateId": "6f1c2d3e-4a5b-4c6d-8e9f-0a1b2c3d4e5f",
      "sessionId": "room-1",
      "goal": "Add a checkout page to my shop",
      "tickets": [{"title": "Add the checkout route", "size": "S"},
                  {"title": "Wire the cart", "size": "L", "estimatedMinutes": 90}],
      "options": [
        {"id": "boxes_judge", "label": "Senti boxes + Claude judge", "coder": "senti_box",
         "judge": {"kind": "claude_subscription", "provider": "anthropic", "billing": "plan"},
         "cost": {"lowUsd": 6.0, "highUsd": 14.5, "covers": ["box compute"], "unpricedTickets": 1},
         "planUsage": {"judgeTokensLow": 120000, "judgeTokensHigh": 300000, "plan": "claude_subscription",
                       "weeklyLimitPercentLow": 3, "weeklyLimitPercentHigh": 8.5},
         "time": {"lowMinutes": 40, "highMinutes": 120},
         "rounds": {"expected": 2, "max": 3},
         "confidence": "low",
         "noBasisFor": ["L tickets"],
         "caveats": ["Ranges from 3 measured small tickets; wide on purpose."]},
        {"id": "frontier_alone", "label": "A frontier coder alone", "coder": "frontier",
         "judge": {"kind": "none", "provider": null, "billing": "none"},
         "cost": null,
         "planUsage": {"judgeTokensLow": null, "judgeTokensHigh": null, "plan": null},
         "time": {"lowMinutes": 30, "highMinutes": 90},
         "rounds": {"expected": 1, "max": 2},
         "confidence": "low",
         "noBasisFor": ["S tickets", "L tickets"],
         "caveats": []},
        {"id": "mix", "label": "Mix", "coder": "frontier",
         "judge": {"kind": "codex", "provider": "openai", "billing": "plan"},
         "cost": {"lowUsd": null, "highUsd": null, "covers": [], "unpricedTickets": 2},
         "planUsage": {"judgeTokensLow": 80000, "judgeTokensHigh": 160000, "plan": "chatgpt"},
         "time": {"lowMinutes": 60, "highMinutes": 180},
         "rounds": {"expected": 2, "max": 3},
         "confidence": "medium", "noBasisFor": [], "caveats": []}
      ],
      "suggested": "boxes_judge",
      "basis": {"measuredAt": "2026-11-06", "sources": ["pilot 3 tickets", "benchmark 20 tickets"]},
      "status": "ready",
      "failureReason": null,
      "askedBy": "alex",
      "pickedOptionId": null,
      "pickedBy": null,
      "pickedAt": null,
      "createdAt": "2026-11-06T21:40:00Z",
      "expiresAt": "2026-11-07T21:40:00Z"
    }
    """

    private static func json(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }

    func test_the_whole_estimate_reads_every_field_of_draft_two() throws {
        let estimate = try XCTUnwrap(RoomEstimate(json: Self.json(Self.draftTwo)))
        XCTAssertEqual(estimate.estimateId, Self.estimateId)
        XCTAssertEqual(estimate.goal, "Add a checkout page to my shop")
        XCTAssertEqual(estimate.status, .ready)
        XCTAssertEqual(estimate.suggested, "boxes_judge")
        XCTAssertEqual(estimate.askedBy, "alex")
        XCTAssertNil(estimate.pickedOptionId)
        XCTAssertEqual(estimate.basisMeasuredAt, "2026-11-06")
        XCTAssertEqual(estimate.basisSources, ["pilot 3 tickets", "benchmark 20 tickets"])
        XCTAssertEqual(estimate.options.map(\.id), ["boxes_judge", "frontier_alone", "mix"])

        let boxes = estimate.options[0]
        XCTAssertEqual(boxes.label, "Senti boxes + Claude judge")
        XCTAssertEqual(boxes.judgeKind, "claude_subscription")
        XCTAssertEqual(boxes.judgeBilling, .plan)
        XCTAssertEqual(boxes.lowUsd, 6.0)
        XCTAssertEqual(boxes.highUsd, 14.5)
        XCTAssertEqual(boxes.unpricedTickets, 1, "a ticket left out of the cost is counted")
        XCTAssertEqual(boxes.covers, ["box compute"])
        XCTAssertEqual(boxes.judgeTokensLow, 120_000)
        XCTAssertEqual(boxes.judgeTokensHigh, 300_000)
        XCTAssertEqual(boxes.plan, .claude)
        XCTAssertEqual(boxes.planKind, .claude)
        XCTAssertEqual(boxes.weeklyLimitPercentLow, 3)
        XCTAssertEqual(boxes.weeklyLimitPercentHigh, 8.5)
        XCTAssertEqual(boxes.lowMinutes, 40)
        XCTAssertEqual(boxes.highMinutes, 120)
        XCTAssertEqual(boxes.expectedRounds, 2)
        XCTAssertEqual(boxes.maxRounds, 3)
        XCTAssertEqual(boxes.caveats, ["Ranges from 3 measured small tickets; wide on purpose."])

        let alone = estimate.options[1]
        XCTAssertNil(alone.lowUsd, "cost: null is nothing measured, never $0")
        XCTAssertNil(alone.highUsd)
        XCTAssertEqual(alone.judgeBilling, RoomEstimateBilling.none)
        XCTAssertNil(alone.planKind)
        XCTAssertNil(alone.plan)

        let mix = estimate.options[2]
        XCTAssertNil(mix.lowUsd, "a cost without its ends is nothing measured")
        XCTAssertEqual(mix.unpricedTickets, 2)
        XCTAssertEqual(mix.planKind, .chatgpt, "Codex is billed to a ChatGPT plan")
        XCTAssertNil(mix.weeklyLimitPercentLow, "no percent until the plan is known")
    }

    func test_a_failed_estimate_reads_its_reason_and_a_picked_one_who_picked() throws {
        let failed = try XCTUnwrap(RoomEstimate(json: Self.json("""
        {"estimateId": "\(Self.estimateId)", "status": "failed", "failureReason": "The goal was too short to split.",
         "options": []}
        """)))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.failureReason, "The goal was too short to split.")
        let picked = try XCTUnwrap(RoomEstimate(json: Self.json(Self.draftTwo
            .replacingOccurrences(of: "\"status\": \"ready\"", with: "\"status\": \"picked\"")
            .replacingOccurrences(of: "\"pickedOptionId\": null", with: "\"pickedOptionId\": \"frontier_alone\"")
            .replacingOccurrences(of: "\"pickedBy\": null", with: "\"pickedBy\": \"griff\""))))
        XCTAssertEqual(picked.status, .picked)
        XCTAssertEqual(picked.pickedOptionId, "frontier_alone")
        XCTAssertEqual(picked.pickedBy, "griff")
        XCTAssertNil(RoomEstimate(json: Self.json(#"{"estimateId": "\#(Self.estimateId)", "status": "soon"}"#)),
                     "a status it does not know is not shown")
    }

    /// The room's event (`session_estimate_card`) draws the card before the whole estimate is read. Only that event:
    /// the draft's `estimate_card` was never sent.
    func test_the_room_event_carries_the_cards_summary() throws {
        let event = """
        {"id": "ev-42", "sequenceId": 42, "event": "session_estimate_card", "ts": "2026-11-06T21:40:05Z",
         "agent": {"id": "senti"},
         "payload": {"estimateId": "\(Self.estimateId)", "status": "ready", "suggested": "boxes_judge",
                     "askedBy": "alex", "sourceSequenceId": 41,
                     "options": [{"id": "boxes_judge", "label": "Senti boxes + Claude judge", "lowUsd": 6,
                                  "highUsd": 14.5, "judgeBilling": "plan"},
                                 {"id": "frontier_alone", "label": "A frontier coder alone", "lowUsd": null,
                                  "highUsd": null, "judgeBilling": "none"}]}}
        """
        let message = try XCTUnwrap(RoomMessage(json: Self.json(event)))
        XCTAssertEqual(message.kind, .estimateCard)
        XCTAssertEqual(message.text, "")
        let summary = try XCTUnwrap(message.estimate)
        XCTAssertEqual(summary.estimateId, Self.estimateId)
        XCTAssertEqual(summary.status, .ready)
        XCTAssertEqual(summary.suggested, "boxes_judge")
        XCTAssertEqual(summary.askedBy, "alex")
        XCTAssertEqual(summary.sourceSequenceId, 41)
        XCTAssertEqual(summary.options, [
            RoomEstimateOptionSummary(id: "boxes_judge", label: "Senti boxes + Claude judge", lowUsd: 6, highUsd: 14.5,
                                      judgeBilling: .plan),
            RoomEstimateOptionSummary(id: "frontier_alone", label: "A frontier coder alone", lowUsd: nil, highUsd: nil,
                                      judgeBilling: RoomEstimateBilling.none)
        ])
        XCTAssertNil(RoomMessage(json: Self.json(event.replacingOccurrences(of: "session_estimate_card",
                                                                           with: "estimate_card"))),
                     "the draft's name is not an event")
        XCTAssertNil(RoomMessage(json: Self.json(event.replacingOccurrences(of: Self.estimateId, with: "not an id!"))),
                     "a card without an estimate to read is not shown")
    }

    func test_the_room_read_offers_estimates_only_when_it_says_true() throws {
        func features(_ text: String) throws -> RoomFeatures {
            try JSONDecoder().decode(RoomFeatures.self, from: Data(text.utf8))
        }
        XCTAssertTrue(try features(#"{"features": {"estimates": true}}"#).estimates)
        XCTAssertFalse(try features(#"{"features": {"estimates": false}}"#).estimates)
        XCTAssertFalse(try features(#"{"features": {"estimates": "yes"}}"#).estimates)
        XCTAssertFalse(try features(#"{"features": {}}"#).estimates)
        XCTAssertFalse(try features(#"{}"#).estimates)
    }

    // MARK: - The routes

    private func client(_ handler: @escaping (PersonalRoutesURLProtocol.Seen) -> (Int, String)) -> HTTPRoomEstimatesClient {
        PersonalRoutesURLProtocol.reset(handler: handler)
        return HTTPRoomEstimatesClient(apiBaseURL: URL(string: "https://api.example.test"),
                                       urlSession: PersonalRoutesURLProtocol.session(), tokenProvider: { "person-token" })
    }

    func test_asking_sends_the_trimmed_goal_and_the_message_it_was_asked_on() async throws {
        let estimates = client { _ in (202, #"{"estimateId": "6f1c2d3e-4a5b-4c6d-8e9f-0a1b2c3d4e5f"}"#) }
        try await estimates.requestEstimate(sessionId: "room-1", goal: "  Add a checkout page \n", sourceSequenceId: 41)
        try await estimates.requestEstimate(sessionId: "room-1", goal: String(repeating: "a", count: 2_500),
                                            sourceSequenceId: nil)
        let seen = PersonalRoutesURLProtocol.requests
        XCTAssertEqual(seen.map(\.method), ["POST", "POST"])
        XCTAssertEqual(seen.map(\.path), ["/api/v1/sessions/room-1/estimates", "/api/v1/sessions/room-1/estimates"])
        XCTAssertEqual(seen[0].authorization, "Bearer person-token")
        XCTAssertEqual(seen[0].body, .object(["goal": .string("Add a checkout page"), "sourceSequenceId": .int(41)]))
        XCTAssertEqual(seen[1].body, .object(["goal": .string(String(repeating: "a", count: 2_000))]),
                       "capped at 2000, no message")
        do {
            try await estimates.requestEstimate(sessionId: "room-1", goal: "   ", sourceSequenceId: nil)
            XCTFail("an empty goal was sent")
        } catch {
            XCTAssertEqual(error as? RoomEstimateError, .rejected)
        }
    }

    func test_reading_an_estimate_by_id() async throws {
        let estimates = client { _ in (200, Self.draftTwo) }
        let estimate = try await estimates.estimate(sessionId: "room-1", estimateId: Self.estimateId)
        XCTAssertEqual(estimate.options.count, 3)
        XCTAssertEqual(PersonalRoutesURLProtocol.requests.map(\.path),
                       ["/api/v1/sessions/room-1/estimates/\(Self.estimateId)"])
        XCTAssertEqual(PersonalRoutesURLProtocol.requests.map(\.method), ["GET"])
    }

    /// A pick starts the work; someone else's pick first is a 409 that names it, and is no error.
    func test_a_pick_starts_and_a_second_pick_answers_with_the_first() async throws {
        let started = client { _ in (200, #"{"status": "started", "ticketIds": [], "boxId": null}"#) }
        let outcome = try await started.pick(sessionId: "room-1", estimateId: Self.estimateId, optionId: "boxes_judge")
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(PersonalRoutesURLProtocol.requests.first?.path,
                       "/api/v1/sessions/room-1/estimates/\(Self.estimateId)/pick")
        XCTAssertEqual(PersonalRoutesURLProtocol.requests.first?.body, .object(["optionId": .string("boxes_judge")]))

        let second = client { _ in
            (409, #"{"error": {"code": "ESTIMATE_ALREADY_PICKED", "message": "Already picked"}, "#
                + #""pickedOptionId": "frontier_alone", "pickedBy": "griff", "pickedAt": "2026-11-06T21:41:00Z"}"#)
        }
        let first = try await second.pick(sessionId: "room-1", estimateId: Self.estimateId, optionId: "boxes_judge")
        XCTAssertEqual(first, .alreadyPicked(optionId: "frontier_alone", by: "griff"))
    }

    func test_refusals_are_said_as_what_they_are() async {
        let cases: [(Int, String, RoomEstimateError)] = [
            (403, #"{"detail": "Forbidden"}"#, .notAllowed),
            (404, #"{"detail": "Not Found"}"#, .unavailable),
            (429, #"{"detail": "Too many"}"#, .rateLimited(retryAfterSeconds: nil)),
            (409, #"{"error": {"code": "SOMETHING_ELSE"}}"#, .rejected),
            (503, #"{}"#, .retryable),
        ]
        for (status, body, expected) in cases {
            let estimates = client { _ in (status, body) }
            do {
                _ = try await estimates.pick(sessionId: "room-1", estimateId: Self.estimateId, optionId: "mix")
                XCTFail("\(status) picked")
            } catch {
                XCTAssertEqual(error as? RoomEstimateError, expected, "\(status)")
            }
        }
    }

    func test_your_plan_is_saved_to_your_account_and_only_a_plan_the_api_takes() async throws {
        let estimates = client { _ in (200, #"{"claudePlan": "max5"}"#) }
        try await estimates.savePlan(try XCTUnwrap(RoomEstimatePlanAnswer(kind: .claude, plan: "max5")))
        try await estimates.savePlan(try XCTUnwrap(RoomEstimatePlanAnswer(kind: .chatgpt, plan: "team")))
        let seen = PersonalRoutesURLProtocol.requests
        XCTAssertEqual(seen.map(\.method), ["PATCH", "PATCH"])
        XCTAssertEqual(seen.map(\.path), ["/api/v1/auth/me", "/api/v1/auth/me"])
        XCTAssertEqual(seen[0].body, .object(["claudePlan": .string("max5")]))
        XCTAssertEqual(seen[1].body, .object(["chatgptPlan": .string("team")]))
        XCTAssertNil(RoomEstimatePlanAnswer(kind: .claude, plan: "plus"), "not a Claude plan")
        XCTAssertNil(RoomEstimatePlanAnswer(kind: .chatgpt, plan: "max20"), "not a ChatGPT plan")
    }
}
