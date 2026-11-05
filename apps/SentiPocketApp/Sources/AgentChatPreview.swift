#if DEBUG
import Foundation
import SwiftUI
import PocketSyncClient
import PocketUI
import PocketVoice

/// DEBUG-only: `-PocketAgentChatPreview` opens a chat made for one agent, as New agent makes it, on the real room screen
/// and coordinator: its title, the box's launch line, what the box says shown in full, the orchestrator's cost line
/// still quiet, who is here above the first message, and the composer saying how to reach the box. Never compiled into
/// Release. The names are made up.
enum AgentChatPreview {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketAgentChatPreview")
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
        NavigationStack {
            RoomChatScreen(
                route: RoomRoute(sessionId: sessionId, title: title, membershipRole: "owner"),
                transport: AgentChatPreviewTransport(),
                sender: AgentChatPreviewSender(),
                actionSender: AgentChatPreviewSender(),
                identity: AgentChatPreviewIdentity(),
                receipts: AgentChatPreviewReceipts(),
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

/// You and the box are here.
private struct AgentChatPreviewReceipts: RoomReceiptsClient {
    func recordViews(sessionId: String, targets: [RoomViewTarget]) async throws {}

    func views(sessionId: String, targets: [RoomViewTarget]) async throws -> [RoomViewSummary] { [] }

    func publishPresence(sessionId: String, active: Bool, clientInstanceId: String) async throws -> Int? { 90 }

    func presence(sessionId: String) async throws -> RoomPresence {
        RoomPresence(
            isAvailable: true,
            participants: [
                RoomPresentParticipant(id: "human-\(AgentChatPreviewIdentity.accountId)", isHuman: true, displayName: "Alex",
                                       login: "alex"),
                RoomPresentParticipant(id: "build-agent", isHuman: false, isBox: true)
            ],
            humansOnline: 1,
            agentsOnline: 1,
            ttlSeconds: 90
        )
    }
}

/// The chat's few messages: the box's launch line, your "hi", the box's signed answers, and the orchestrator's cost.
private struct AgentChatPreviewTransport: RoomTransport {
    private static let base = Date()

    static func row(_ seq: Int64, _ author: String, minutesAgo: Double, _ text: String) -> RoomMessage {
        let human = RoomMessage.isHumanAuthor(author)
        return RoomMessage(
            id: String(format: "00000000-0000-4000-8000-%012lld", seq),
            sequenceId: seq,
            kind: .message,
            authorId: author,
            authorName: human ? "Alex" : author,
            isHuman: human,
            text: text,
            timestamp: ISO8601DateFormatter().string(from: base.addingTimeInterval(-minutesAgo * 60))
        )
    }

    /// The relay's signature line under a box's words.
    private static let signature = "\n⟂ speech 4f2a9c1e7b3d5a60 · preview-model · life 0a1b2c3d4e5f · signed preview-relay"

    static let history: [RoomMessage] = [
        row(501, "human-alex", minutesAgo: 9, "hi"),
        row(502, "respawn-orchestrator", minutesAgo: 8,
            "🚀 Minted build-agent on preview-model: its own machine (life 0a1b2c3d4e5f), until 18:30Z unless extended.\n"
                + "It works in its box and reports here as build-agent; messages in this room reach it."),
        row(503, "build-agent", minutesAgo: 7,
            "Hi Alex. I'm on it: I'll reproduce the paste bug on the email step, fix the validation, and post the "
                + "build here when it's green." + signature),
        row(504, "build-agent", minutesAgo: 4,
            "Found it: pasting skips `validate()` because the field only checks on keystrokes. The fix runs it on "
                + "paste and on blur." + signature),
        row(505, "respawn-orchestrator", minutesAgo: 3, "[cost] build-agent: $0.42 est over 18 calls")
    ]

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        let rows = beforeSequence.map { before in Self.history.filter { $0.sequenceId < before } } ?? Self.history
        return RoomEventPage(messages: rows, nextBeforeSequence: nil, hasMore: false)
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> {
        AsyncStream { continuation in continuation.yield(.frame(.control)) }
    }
}
#endif
