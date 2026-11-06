import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

// Ticket bc6c291f: in a room whose read offers estimates, your own message offers "Get an estimate", and the room shows
// the estimate's card: from the room's summary, then the whole estimate. Only whoever asked, or an owner or admin,
// picks; a pick someone made first shows theirs; the plan question is asked once. Off, there is no button and no card.
// Goals, handles and numbers are made up.

private final class EstimateRoom: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let history: [RoomMessage]
    private let features: RoomFeatures
    private var reads = 0

    init(history: [RoomMessage], features: RoomFeatures) {
        self.history = history
        self.features = features
    }

    var featureReads: Int { lock.withLock { reads } }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: beforeSequence == nil ? history : [])
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }

    func roomFeatures(sessionId: String) async throws -> RoomFeatures {
        lock.withLock { reads += 1 }
        return features
    }
}

private final class FakeEstimator: RoomEstimating, @unchecked Sendable {
    private let lock = NSLock()
    private var current: RoomEstimate
    private let pickAnswer: Result<RoomEstimatePick, Error>
    private var _reads = 0
    private var _picks: [String] = []
    private var _asks: [String] = []
    private var _sources: [Int64?] = []
    private var _plans: [RoomEstimatePlanAnswer] = []

    init(_ estimate: RoomEstimate, pick: Result<RoomEstimatePick, Error> = .success(.started)) {
        current = estimate
        pickAnswer = pick
    }

    var reads: Int { lock.withLock { _reads } }
    var picks: [String] { lock.withLock { _picks } }
    var asks: [String] { lock.withLock { _asks } }
    var sources: [Int64?] { lock.withLock { _sources } }
    var plans: [RoomEstimatePlanAnswer] { lock.withLock { _plans } }

    func requestEstimate(sessionId: String, goal: String, sourceSequenceId: Int64?) async throws {
        lock.withLock {
            _asks.append(goal)
            _sources.append(sourceSequenceId)
        }
    }

    func estimate(sessionId: String, estimateId: String) async throws -> RoomEstimate {
        lock.withLock {
            _reads += 1
            return current
        }
    }

    func pick(sessionId: String, estimateId: String, optionId: String) async throws -> RoomEstimatePick {
        lock.withLock { _picks.append(optionId) }
        return try pickAnswer.get()
    }

    func savePlan(_ answer: RoomEstimatePlanAnswer) async throws {
        lock.withLock { _plans.append(answer) }
    }
}

private struct AcceptingSender: RoomMessageSending {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {}
}

@MainActor
final class RoomEstimatesRoomTests: XCTestCase {
    private static let estimateId = "6f1c2d3e-4a5b-4c6d-8e9f-0a1b2c3d4e5f"
    private static let goal = "Add a checkout page to my shop"

    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "pocket.tests.estimates.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    private static func history(askedBy: String) -> [RoomMessage] {
        [
            RoomMessage(id: "e1", sequenceId: 1, kind: .message, authorId: "human-alex", authorName: "alex",
                        isHuman: true, text: goal, timestamp: "2026-11-06T21:30:00Z"),
            RoomMessage(id: "e2", sequenceId: 2, kind: .message, authorId: "human-griff", authorName: "griff",
                        isHuman: true, text: "Can we also add gift cards?", timestamp: "2026-11-06T21:31:00Z"),
            RoomMessage(id: "e3", sequenceId: 3, kind: .estimateCard, authorId: "senti", authorName: "senti",
                        isHuman: false, text: "", timestamp: "2026-11-06T21:32:00Z",
                        eventType: RoomEstimateSummary.eventType,
                        estimate: RoomEstimateSummary(
                            estimateId: estimateId, status: .ready, suggested: "boxes_judge", askedBy: askedBy,
                            sourceSequenceId: 1,
                            options: [
                                RoomEstimateOptionSummary(id: "boxes_judge", label: "Senti boxes + Claude judge",
                                                          lowUsd: 6, highUsd: 14, judgeBilling: .plan),
                                RoomEstimateOptionSummary(id: "frontier_alone", label: "A frontier coder alone",
                                                          judgeBilling: RoomEstimateBilling.none)
                            ]))
        ]
    }

    private static func estimate(askedBy: String, percents: Bool = false, planNamed: Bool = true,
                                 status: RoomEstimateStatus = .ready) -> RoomEstimate {
        RoomEstimate(
            estimateId: estimateId,
            goal: goal,
            options: [
                RoomEstimate.Option(id: "boxes_judge", label: "Senti boxes + Claude judge",
                                    judgeKind: "claude_subscription", judgeBilling: .plan, lowUsd: 6, highUsd: 14,
                                    unpricedTickets: 1, judgeTokensLow: 120_000, judgeTokensHigh: 300_000,
                                    plan: planNamed ? .claude : nil,
                                    weeklyLimitPercentLow: percents ? 3 : nil, weeklyLimitPercentHigh: percents ? 8 : nil,
                                    lowMinutes: 40, highMinutes: 120, expectedRounds: 2, maxRounds: 3,
                                    caveats: ["Ranges from 3 measured small tickets; wide on purpose."]),
                RoomEstimate.Option(id: "frontier_alone", label: "A frontier coder alone", judgeKind: "none",
                                    judgeBilling: RoomEstimateBilling.none, lowMinutes: 30, highMinutes: 90)
            ],
            suggested: "boxes_judge",
            status: status,
            askedBy: askedBy,
            basisMeasuredAt: "2026-11-06",
            basisSources: ["pilot 3 tickets", "benchmark 20 tickets"]
        )
    }

    private func room(askedBy: String = "alex", role: String = "contributor", offered: Bool = true,
                      estimator: FakeEstimator) -> (RoomChatCoordinator, EstimateRoom) {
        let transport = EstimateRoom(history: Self.history(askedBy: askedBy),
                                     features: RoomFeatures(estimates: offered))
        let coordinator = RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            sender: AcceptingSender(),
            membershipRole: role,
            ownAuthorIds: ["human-alex"],
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            estimator: estimator,
            estimatePlanDefaults: defaults,
            onReauthenticationRequired: {}
        )
        return (coordinator, transport)
    }

    private func card(_ coordinator: RoomChatCoordinator) -> RoomEstimateCard? {
        coordinator.state.estimates[Self.estimateId]
    }

    private func rows(_ coordinator: RoomChatCoordinator) -> [RoomChatMessageRow] {
        coordinator.state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
    }

    /// Off, the room shows neither the button nor a card, and reads no estimate; on, both.
    func test_with_estimates_off_there_is_no_button_and_no_card() async {
        let estimator = FakeEstimator(Self.estimate(askedBy: "alex"))
        let (off, offRoom) = room(offered: false, estimator: estimator)
        off.resume()
        await waitUntil("loaded and read") { !off.state.isLoadingInitial && offRoom.featureReads == 1 }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(off.state.offersEstimates)
        XCTAssertTrue(off.state.estimates.isEmpty)
        XCTAssertFalse(rows(off).contains { $0.estimateId != nil }, "no card")
        XCTAssertEqual(rows(off).map(\.id), ["e1", "e2"])
        off.send(.requestEstimate(sequenceId: 1, goal: Self.goal))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(estimator.asks, [], "nothing asked of a room that does not offer it")
        XCTAssertEqual(estimator.reads, 0)
        off.pause()

        let (on, _) = room(estimator: estimator)
        on.resume()
        await waitUntil("the card") { self.card(on) != nil }
        XCTAssertTrue(on.state.offersEstimates)
        XCTAssertTrue(rows(on).contains { $0.estimateId == Self.estimateId })
        on.pause()
    }

    /// The card draws from the room's summary, then from the whole estimate; asking sends your message's words and the
    /// message, and is never offered on someone else's.
    func test_the_card_reads_the_whole_estimate_and_asking_sends_your_message() async throws {
        let estimator = FakeEstimator(Self.estimate(askedBy: "alex", percents: true))
        let (coordinator, _) = room(estimator: estimator)
        coordinator.resume()
        await waitUntil("the whole estimate read") { self.card(coordinator)?.status == .ready }
        let card = try XCTUnwrap(self.card(coordinator))
        XCTAssertEqual(card.options.map(\.costText), ["$6–$14 · +1 not priced", "No basis yet"])
        XCTAssertEqual(card.options.map(\.isSuggested), [true, false])
        XCTAssertEqual(card.options[0].billingText, "Judge uses your Claude plan: about 3–8% of your weekly limit")
        XCTAssertEqual(card.basisLine, "Based on pilot 3 tickets and benchmark 20 tickets, measured 2026-11-06")
        XCTAssertTrue(card.canPick, "whoever asked picks")
        XCTAssertNil(card.planQuestion, "the plan is known: nothing to ask")

        coordinator.send(.requestEstimate(sequenceId: 1, goal: Self.goal))
        coordinator.send(.requestEstimate(sequenceId: 2, goal: "Can we also add gift cards?"))
        await waitUntil("asked") { !estimator.asks.isEmpty }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(estimator.asks, [Self.goal], "only your own message")
        XCTAssertEqual(estimator.sources, [1], "the card is posted under the message it was asked on")
        coordinator.pause()
    }

    /// The share of a weekly limit is shown only for a plan the estimate names; without it, the tokens.
    func test_a_percent_without_a_named_plan_is_not_shown() async throws {
        let estimator = FakeEstimator(Self.estimate(askedBy: "alex", percents: true, planNamed: false))
        let (coordinator, _) = room(estimator: estimator)
        coordinator.resume()
        await waitUntil("read") { self.card(coordinator)?.status == .ready }
        let billing = try XCTUnwrap(card(coordinator)?.options.first?.billingText)
        XCTAssertEqual(billing, "Judge uses your Claude plan: 120k–300k tokens")
        XCTAssertFalse(billing.contains("%"))
        coordinator.pause()
    }

    /// Someone who did not ask, and is not an owner or admin, sees the card but never picks; an admin may.
    func test_only_whoever_asked_or_an_owner_or_admin_can_pick() async {
        let estimator = FakeEstimator(Self.estimate(askedBy: "griff"))
        let (coordinator, _) = room(askedBy: "griff", estimator: estimator)
        coordinator.resume()
        await waitUntil("read") { self.card(coordinator)?.status == .ready }
        XCTAssertEqual(card(coordinator)?.canPick, false)
        XCTAssertEqual(card(coordinator)?.statusText, "Waiting for whoever asked to pick one.")
        XCTAssertNil(card(coordinator)?.planQuestion, "never asked of someone who did not ask")
        coordinator.send(.pickEstimate(estimateId: Self.estimateId, optionId: "boxes_judge"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(estimator.picks, [], "a pick from someone who may not is never sent")
        coordinator.pause()

        let (admin, _) = room(askedBy: "griff", role: "admin", estimator: estimator)
        admin.resume()
        await waitUntil("read") { self.card(admin)?.status == .ready }
        XCTAssertEqual(card(admin)?.canPick, true)
        admin.send(.pickEstimate(estimateId: Self.estimateId, optionId: "boxes_judge"))
        await waitUntil("picked") { estimator.picks == ["boxes_judge"] }
        await waitUntil("shown as yours") {
            self.card(admin)?.status == .picked(optionLabel: "Senti boxes + Claude judge", by: "Someone", byYou: true)
        }
        XCTAssertEqual(card(admin)?.statusText, "You picked Senti boxes + Claude judge.")
        XCTAssertEqual(card(admin)?.canPick, false)
        admin.pause()
    }

    /// A 409: someone picked first. Their pick stands, the card shows it and says so, and Pick goes.
    func test_a_pick_someone_made_first_shows_their_pick() async {
        let estimator = FakeEstimator(Self.estimate(askedBy: "alex"),
                                      pick: .success(.alreadyPicked(optionId: "frontier_alone", by: "griff")))
        let (coordinator, _) = room(estimator: estimator)
        coordinator.resume()
        await waitUntil("read") { self.card(coordinator)?.status == .ready }
        coordinator.send(.pickEstimate(estimateId: Self.estimateId, optionId: "boxes_judge"))
        await waitUntil("the first pick shown") {
            self.card(coordinator)?.status == .picked(optionLabel: "A frontier coder alone", by: "griff", byYou: false)
        }
        XCTAssertEqual(card(coordinator)?.notice, "griff picked first.")
        XCTAssertEqual(card(coordinator)?.pickedOptionId, "frontier_alone")
        XCTAssertEqual(card(coordinator)?.canPick, false)
        XCTAssertEqual(card(coordinator)?.statusText, "griff picked A frontier coder alone.")
        coordinator.pause()
    }

    /// While a plan-billed judge can only show tokens, whoever asked is asked their plan, once: the answer is saved to
    /// their account, and the question never comes back, not even in a new room.
    func test_the_plan_question_is_asked_once_and_the_answer_saved() async throws {
        let estimator = FakeEstimator(Self.estimate(askedBy: "alex"))
        let (coordinator, _) = room(estimator: estimator)
        coordinator.resume()
        await waitUntil("read") { self.card(coordinator)?.status == .ready }
        let question = try XCTUnwrap(card(coordinator)?.planQuestion)
        XCTAssertEqual(question.question, "Which Claude plan are you on?")
        XCTAssertEqual(question.choices.map(\.value), ["pro", "max5", "max20"])
        XCTAssertEqual(card(coordinator)?.options.first?.billingText, "Judge uses your Claude plan: 120k–300k tokens")
        coordinator.send(.answerEstimatePlan(estimateId: Self.estimateId, plan: "max5"))
        await waitUntil("saved") { !estimator.plans.isEmpty }
        XCTAssertEqual(estimator.plans.map(\.kind), [.claude])
        XCTAssertEqual(estimator.plans.map(\.plan), ["max5"])
        XCTAssertNil(card(coordinator)?.planQuestion)
        coordinator.pause()

        let (again, _) = room(estimator: estimator)
        again.resume()
        await waitUntil("read") { self.card(again)?.status == .ready }
        XCTAssertNil(card(again)?.planQuestion, "asked once")
        again.pause()
    }

    /// An estimate that expired offers Ask again to whoever asked: the same goal, under the same message.
    func test_an_expired_estimate_asks_again_with_the_same_goal() async {
        let estimator = FakeEstimator(Self.estimate(askedBy: "alex", status: .expired))
        let (coordinator, _) = room(estimator: estimator)
        coordinator.resume()
        await waitUntil("read") { self.card(coordinator)?.status == .expired }
        XCTAssertEqual(card(coordinator)?.canAskAgain, true)
        XCTAssertEqual(card(coordinator)?.canPick, false)
        coordinator.send(.askEstimateAgain(estimateId: Self.estimateId))
        await waitUntil("asked again") { !estimator.asks.isEmpty }
        XCTAssertEqual(estimator.asks, [Self.goal])
        XCTAssertEqual(estimator.sources, [1])
        coordinator.pause()
    }
}
