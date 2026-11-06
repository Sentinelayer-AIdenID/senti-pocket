#if DEBUG
import Foundation
import SwiftUI
import PocketSyncClient
import PocketUI

/// DEBUG-only: `-PocketEstimatePreview` opens a room whose read offers estimates, with an estimate card in each state
/// for screenshots (light, dark and the largest text size are the simulator's own settings):
/// - ready, with three options: one with a measured cost and a ticket not priced, one with nothing measured, and one
///   whose judge uses a ChatGPT plan with its weekly-limit percent;
/// - picked by someone else, expired, and failed with its reason;
/// - and one asked on your own message: it is in that message's thread, and the message carries "Estimate ready".
/// Never compiled into Release. Goals, handles and numbers are made up.
enum RoomEstimatePreview {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketEstimatePreview")
    }

    @MainActor
    static var rootView: some View {
        NavigationStack {
            RoomChatScreen(
                route: RoomRoute(sessionId: "preview-estimates", title: "Shop build", membershipRole: "contributor"),
                transport: EstimatePreviewRoom(),
                sender: EstimatePreviewSender(),
                identity: EstimatePreviewIdentity(),
                reader: MessageReader(),
                estimator: EstimatePreviewEstimator(),
                onReauthenticationRequired: {}
            )
        }
    }

    static let readyId = "00000000-0000-4000-8000-0000000000e1"
    static let pickedId = "00000000-0000-4000-8000-0000000000e2"
    static let expiredId = "00000000-0000-4000-8000-0000000000e3"
    static let failedId = "00000000-0000-4000-8000-0000000000e4"
    static let threadId = "00000000-0000-4000-8000-0000000000e5"
    static let goal = "Add a checkout page to my shop, with a cart that remembers what was added."

    static func options() -> [RoomEstimate.Option] {
        [
            RoomEstimate.Option(id: "boxes_judge", label: "Senti boxes + Claude judge", judgeKind: "claude_subscription",
                                judgeBilling: .plan, lowUsd: 6, highUsd: 14, unpricedTickets: 1,
                                judgeTokensLow: 120_000, judgeTokensHigh: 300_000, plan: .claude, lowMinutes: 40,
                                highMinutes: 120, expectedRounds: 2, maxRounds: 3,
                                caveats: ["Ranges from 3 measured small tickets; wide on purpose."]),
            RoomEstimate.Option(id: "frontier_alone", label: "A frontier coder alone", judgeKind: "none",
                                judgeBilling: RoomEstimateBilling.none, lowMinutes: 30, highMinutes: 90,
                                expectedRounds: 1, maxRounds: 2, caveats: ["No measured basis for this size yet."]),
            RoomEstimate.Option(id: "mix", label: "Mix: boxes for small tickets, Codex judge", judgeKind: "codex",
                                judgeBilling: .plan, lowUsd: 9, highUsd: 20.5, unpricedTickets: 2,
                                judgeTokensLow: 80_000, judgeTokensHigh: 160_000, plan: .chatgpt,
                                weeklyLimitPercentLow: 2, weeklyLimitPercentHigh: 5, lowMinutes: 60, highMinutes: 180,
                                expectedRounds: 2, maxRounds: 3)
        ]
    }

    static func estimate(_ id: String) -> RoomEstimate {
        let status: RoomEstimateStatus
        switch id {
        case pickedId: status = .picked
        case expiredId: status = .expired
        case failedId: status = .failed
        default: status = .ready
        }
        return RoomEstimate(
            estimateId: id,
            goal: goal,
            options: status == .failed ? [] : options(),
            suggested: "boxes_judge",
            status: status,
            failureReason: status == .failed ? "The goal was too short to split into tickets." : nil,
            askedBy: id == pickedId ? "griff" : "alex",
            pickedOptionId: status == .picked ? "boxes_judge" : nil,
            pickedBy: status == .picked ? "griff" : nil,
            basisMeasuredAt: "2026-11-06",
            basisSources: ["pilot 3 tickets", "benchmark 20 tickets"]
        )
    }
}

private struct EstimatePreviewRoom: RoomTransport {
    private static let base = Date()

    private static func stamp(minutesAgo: Double) -> String {
        ISO8601DateFormatter().string(from: base.addingTimeInterval(-minutesAgo * 60))
    }

    private static func card(_ seq: Int64, _ id: String, status: RoomEstimateStatus, source: Int64? = nil,
                             minutesAgo: Double) -> RoomMessage {
        let summary = RoomEstimateSummary(
            estimateId: id, status: status, suggested: "boxes_judge", askedBy: "alex", sourceSequenceId: source,
            options: RoomEstimatePreview.options().map {
                RoomEstimateOptionSummary(id: $0.id, label: $0.label, lowUsd: $0.lowUsd, highUsd: $0.highUsd,
                                          judgeBilling: $0.judgeBilling)
            })
        return RoomMessage(id: String(format: "00000000-0000-4000-8000-%012lld", seq), sequenceId: seq,
                           kind: .estimateCard, authorId: "senti", authorName: "senti", isHuman: false, text: "",
                           timestamp: stamp(minutesAgo: minutesAgo), eventType: RoomEstimateSummary.eventType,
                           estimate: summary)
    }

    private static func message(_ seq: Int64, _ author: String, _ text: String, minutesAgo: Double) -> RoomMessage {
        RoomMessage(id: String(format: "00000000-0000-4000-8000-%012lld", seq), sequenceId: seq, kind: .message,
                    authorId: author, authorName: author.hasPrefix("human-") ? String(author.dropFirst(6)) : author,
                    isHuman: author.hasPrefix("human-"), text: text, timestamp: stamp(minutesAgo: minutesAgo))
    }

    private static let history: [RoomMessage] = [
        message(1, "human-alex", RoomEstimatePreview.goal, minutesAgo: 60),
        card(2, RoomEstimatePreview.readyId, status: .ready, minutesAgo: 59),
        card(3, RoomEstimatePreview.pickedId, status: .picked, minutesAgo: 50),
        card(4, RoomEstimatePreview.expiredId, status: .expired, minutesAgo: 40),
        card(5, RoomEstimatePreview.failedId, status: .failed, minutesAgo: 30),
        message(6, "human-alex", "And a page to see past orders?", minutesAgo: 20),
        card(7, RoomEstimatePreview.threadId, status: .ready, source: 6, minutesAgo: 19)
    ]

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: beforeSequence == nil ? Self.history : [], nextBeforeSequence: nil, hasMore: false)
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }

    func roomFeatures(sessionId: String) async throws -> RoomFeatures {
        RoomFeatures(estimates: true)
    }
}

private struct EstimatePreviewSender: RoomMessageSending {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {}
}

private struct EstimatePreviewIdentity: AccountIdentityProviding {
    func currentAccount() async -> SignedInAccount? {
        SignedInAccount(githubUsername: "alex", accountId: "6f1c2b9e-0000-4000-8000-00000000000b")
    }
}

/// Answers each estimate as its state needs; a pick or a plan answer is taken and changes nothing.
private struct EstimatePreviewEstimator: RoomEstimating {
    func requestEstimate(sessionId: String, goal: String, sourceSequenceId: Int64?) async throws {}

    func estimate(sessionId: String, estimateId: String) async throws -> RoomEstimate {
        try? await Task.sleep(nanoseconds: 300_000_000)
        return RoomEstimatePreview.estimate(estimateId)
    }

    func pick(sessionId: String, estimateId: String, optionId: String) async throws -> RoomEstimatePick { .started }

    func savePlan(_ answer: RoomEstimatePlanAnswer) async throws {}
}
#endif
