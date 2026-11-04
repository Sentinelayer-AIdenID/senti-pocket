#if DEBUG
import Foundation
import SwiftUI
import PocketSyncClient
import PocketUI
import PocketVoice

/// DEBUG-only agent-chat previews on the real room screen and coordinator, never compiled into Release. The names are
/// made up.
/// - `-PocketAgentChatPreview`: a chat made for one agent, as New agent makes it: its title, the box's launch line, what
///   the box says in full, the orchestrator's cost line still quiet, who is here above the first message, and the
///   composer saying how to reach the box. The box worked on your "hi" (done, its steps kept) and works on your newest
///   message now (live); it has read that message ("Seen"); Senti is thinking at the bottom.
/// - `-PocketAgentChatCrowd`: the same, with three more agents working on your newest message: three rows, then
///   "+1 working".
/// - `-PocketRoomIntroPreview`: a new, empty room, with its opening line.
enum AgentChatPreview {
    static var isRequested: Bool { scenario != nil }

    enum Scenario {
        case agentChat
        case crowd
        case emptyRoom
    }

    static var scenario: Scenario? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-PocketRoomIntroPreview") { return .emptyRoom }
        if arguments.contains("-PocketAgentChatCrowd") { return .crowd }
        if arguments.contains("-PocketAgentChatPreview") { return .agentChat }
        return nil
    }

    static let sessionId = "preview-agent-chat"
    /// Named as New agent names it.
    static let title = NewAgentChat.title(agentName: "build-agent", job: "Fix paste validation on the email step")
        ?? NewAgentChat.untitled

    @MainActor
    private static let reader = MessageReader()

    @MainActor
    @ViewBuilder
    static var rootView: some View {
        let scenario = scenario ?? .agentChat
        NavigationStack {
            RoomChatScreen(
                route: scenario == .emptyRoom
                    ? RoomRoute(sessionId: "preview-new-room", title: "Launch plan", membershipRole: "owner")
                    : RoomRoute(sessionId: sessionId, title: title, membershipRole: "owner"),
                transport: AgentChatPreviewTransport(scenario: scenario),
                sender: AgentChatPreviewSender(),
                actionSender: AgentChatPreviewSender(),
                identity: AgentChatPreviewIdentity(),
                receipts: AgentChatPreviewReceipts(scenario: scenario),
                reader: reader,
                onReauthenticationRequired: {}
            )
        }
    }
}

private struct AgentChatPreviewIdentity: AccountIdentityProviding {
    static let accountId = "6f1c2b9e-0000-4000-8000-00000000000c"
    func currentAccount() async -> SignedInAccount? { SignedInAccount(githubUsername: "alex", accountId: Self.accountId) }
}

/// Accepts every message after a moment.
private struct AgentChatPreviewSender: RoomMessageSending, RoomActionSending {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    func sendAction(_ action: RoomActionRequest) async throws {}
}

/// You and the box are here; the box has read your newest message.
private struct AgentChatPreviewReceipts: RoomReceiptsClient {
    let scenario: AgentChatPreview.Scenario

    func recordViews(sessionId: String, targets: [RoomViewTarget]) async throws {}

    func views(sessionId: String, targets: [RoomViewTarget]) async throws -> [RoomViewSummary] {
        let now = ISO8601DateFormatter().string(from: Date())
        return targets.compactMap { target in
            guard target.id == AgentChatPreviewTransport.id(506) else { return nil }
            let box = RoomViewer(isHuman: false, actorId: "build-agent", viewedAt: now)
            return RoomViewSummary(kind: target.kind, id: target.id, revision: target.revision, viewedCount: 1, viewers: [box])
        }
    }

    func publishPresence(sessionId: String, active: Bool, clientInstanceId: String) async throws -> Int? { 90 }

    func presence(sessionId: String) async throws -> RoomPresence {
        RoomPresence(
            isAvailable: true,
            participants: [
                RoomPresentParticipant(id: "human-\(AgentChatPreviewIdentity.accountId)", isHuman: true, displayName: "Alex",
                                       login: "alex")
            ] + (scenario == .emptyRoom ? [] : [RoomPresentParticipant(id: "build-agent", isHuman: false, isBox: true)]),
            humansOnline: 1,
            agentsOnline: scenario == .emptyRoom ? 0 : 1,
            ttlSeconds: 90
        )
    }
}

/// The chat's few messages: your "hi", the box's launch line, its signed answers, the orchestrator's cost, and your
/// newest message; the box's notes as it works; and Senti thinking.
private struct AgentChatPreviewTransport: RoomTransport {
    let scenario: AgentChatPreview.Scenario
    private static let base = Date()

    static func id(_ seq: Int64) -> String { String(format: "00000000-0000-4000-8000-%012lld", seq) }

    private static func stamp(secondsAgo: Double) -> String {
        ISO8601DateFormatter().string(from: base.addingTimeInterval(-secondsAgo))
    }

    static func row(_ seq: Int64, _ author: String, secondsAgo: Double, _ text: String) -> RoomMessage {
        let human = RoomMessage.isHumanAuthor(author)
        return RoomMessage(id: id(seq), sequenceId: seq, kind: .message, authorId: author, authorName: human ? "Alex" : author,
                           isHuman: human, text: text, timestamp: stamp(secondsAgo: secondsAgo))
    }

    /// The relay's signature line under a box's words.
    private static let signature = "\n⟂ speech 4f2a9c1e7b3d5a60 · preview-model · life 0a1b2c3d4e5f · signed preview-relay"

    static let history: [RoomMessage] = [
        row(501, "human-alex", secondsAgo: 600, "hi"),
        row(502, "respawn-orchestrator", secondsAgo: 580,
            "🚀 Minted build-agent on preview-model: its own machine (life 0a1b2c3d4e5f), until 18:30Z unless extended.\n"
                + "It works in its box and reports here as build-agent; messages in this room reach it."),
        row(503, "build-agent", secondsAgo: 420,
            "Hi Alex. I'm on it: I'll reproduce the paste bug on the email step, fix the validation, and post the "
                + "build here when it's green." + signature),
        row(504, "build-agent", secondsAgo: 240,
            "Found it: pasting skips `validate()` because the field only checks on keystrokes. The fix runs it on "
                + "paste and on blur." + signature),
        row(505, "respawn-orchestrator", secondsAgo: 180, "[cost] build-agent: $0.42 est over 18 calls"),
        row(506, "human-alex", secondsAgo: 120, "@build-agent can you also check the retry counter?")
    ]

    private static func note(_ id: String, on seq: Int64, by agent: String, secondsAgo: Double, _ text: String) -> RoomWorkingOn {
        RoomWorkingOn(id: id, targetSequenceId: seq, actorId: agent, note: text, createdAt: stamp(secondsAgo: secondsAgo))
    }

    /// The box's notes on your "hi" (answered at 420 s ago: it worked 2m 14s) and on your newest message (still going).
    private var notes: [RoomWorkingOn] {
        var notes = [
            Self.note("w1", on: 501, by: "build-agent", secondsAgo: 554, "Reading the onboarding form"),
            Self.note("w2", on: 501, by: "build-agent", secondsAgo: 520, "Reproducing the paste bug"),
            Self.note("w3", on: 501, by: "build-agent", secondsAgo: 482, "Tracing validate() on the email step"),
            Self.note("w4", on: 501, by: "build-agent", secondsAgo: 450, "Drafting the answer"),
            Self.note("w5", on: 506, by: "build-agent", secondsAgo: 110, "Reading the retry counter code"),
            Self.note("w6", on: 506, by: "build-agent", secondsAgo: 80, "Reproducing the reset after a failed submit"),
            Self.note("w7", on: 506, by: "build-agent", secondsAgo: 40, "Running the onboarding tests on the simulator"),
            Self.note("w8", on: 506, by: "build-agent", secondsAgo: 12, "Writing the fix so retryCount resets only after success")
        ]
        if scenario == .crowd {
            notes += [
                Self.note("c1", on: 506, by: "review-agent", secondsAgo: 30, "Reviewing the paste fix"),
                Self.note("c2", on: 506, by: "test-agent", secondsAgo: 20, "Writing a test for the retry counter"),
                Self.note("c3", on: 506, by: "docs-agent", secondsAgo: 50, "Updating the onboarding notes")
            ]
        }
        return notes
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        guard scenario != .emptyRoom else { return RoomEventPage(messages: [], nextBeforeSequence: nil, hasMore: false) }
        let rows = beforeSequence.map { before in Self.history.filter { $0.sequenceId < before } } ?? Self.history
        return RoomEventPage(messages: rows, nextBeforeSequence: nil, hasMore: false)
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        guard scenario != .emptyRoom, targetSequenceId == nil else { return RoomActionsPage() }
        return RoomActionsPage(workingOn: notes)
    }

    /// Senti starts thinking a second in and keeps at it, renewing as a runtime does.
    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> {
        let thinks = scenario != .emptyRoom
        return AsyncStream { continuation in
            let task = Task {
                continuation.yield(.frame(.control))
                guard thinks else { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                while !Task.isCancelled {
                    continuation.yield(.frame(.composing(agentId: "senti", targetSequenceId: 506)))
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
