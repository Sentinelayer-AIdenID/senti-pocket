#if DEBUG
import Foundation
import SwiftUI
import PocketSyncClient

/// DEBUG-only room preview: `-PocketRoomPreview` opens the real room screen and coordinator on scripted sample
/// rows, so the chat can be built, run and screenshotted on a simulator without signing in. Never compiled into
/// Release.
enum RoomPreview {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketRoomPreview") || isTicketsRequested
    }

    /// `-PocketTicketsPreview` opens the Tickets tab on sample tickets.
    static var isTicketsRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketTicketsPreview")
    }

    @MainActor
    @ViewBuilder
    static var rootView: some View {
        if isTicketsRequested {
            NavigationStack {
                RoomTicketsScreen(sessionId: "preview-room", transport: RoomPreviewTickets(), onReauthenticationRequired: {})
            }
        } else {
            roomRoot
        }
    }

    @MainActor
    private static var roomRoot: some View {
        NavigationStack {
            RoomChatScreen(
                route: RoomRoute(sessionId: "preview-room", title: "Design review", membershipRole: "owner"),
                transport: RoomPreviewTransport(),
                sender: RoomPreviewSender(),
                actionSender: RoomPreviewSender(),
                onReauthenticationRequired: {}
            )
        }
    }
}

/// Sample tickets for the Tickets tab preview.
private struct RoomPreviewTickets: RoomTicketsTransport {
    func roomTicketSnapshot(sessionId: String, afterId: String?, limit: Int) async throws -> RoomTicketSnapshotPage {
        RoomTicketSnapshotPage(items: [
            RoomTicket(id: "t1", title: "Fix paste validation on the email step", body: "## Priority\nP0\n\nPasting skips validation.", status: "working", createdBy: "human-alex", assignee: "review-agent", createdAt: "2026-10-28T13:00:00Z", updatedAt: "2026-10-28T18:40:00Z", version: 3),
            RoomTicket(id: "t2", title: "Reset retryCount only after success", body: "## Priority\nP1", status: "assigned", createdBy: "human-alex", assignee: "build-agent", createdAt: "2026-10-28T13:05:00Z", updatedAt: "2026-10-28T17:00:00Z", version: 2),
            RoomTicket(id: "t3", title: "Add onboarding screenshots to the PR", body: "## Priority\nP2", status: "in_review", createdBy: "review-agent", assignee: "build-agent", createdAt: "2026-10-28T12:00:00Z", updatedAt: "2026-10-28T16:00:00Z", version: 4),
            RoomTicket(id: "t4", title: "Draft release notes", status: "open", createdBy: "human-alex", createdAt: "2026-10-28T11:00:00Z", updatedAt: "2026-10-28T11:00:00Z", version: 1),
            RoomTicket(id: "t5", title: "Rename onboarding flags", body: "## Priority\nP3", status: "done", createdBy: "human-alex", assignee: "build-agent", createdAt: "2026-10-27T11:00:00Z", updatedAt: "2026-10-27T15:00:00Z", version: 5)
        ], hasMore: false, cursor: 1)
    }

    func roomTicketEvents(sessionId: String, after: Int64, limit: Int) async throws -> RoomTicketEventsPage {
        RoomTicketEventsPage(tickets: [], eventCount: 0, cursor: after)
    }
}

/// Accepts every message after a short delay, so the composer's pending states can be seen in the preview.
private struct RoomPreviewSender: RoomMessageSending, RoomActionSending {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    func sendAction(_ action: RoomActionRequest) async throws {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
}

/// Scripted rows for the preview: a day of history, then one agent starts composing and posts while you watch.
private struct RoomPreviewTransport: RoomTransport {
    private static let base = Date()

    private static func row(
        _ seq: Int64,
        _ author: String,
        minutesAgo: Double,
        _ text: String,
        kind: RoomMessageKind = .message,
        replyTo: Int64? = nil,
        edited: Bool = false
    ) -> RoomMessage {
        let stamp = ISO8601DateFormatter().string(from: base.addingTimeInterval(-minutesAgo * 60))
        return RoomMessage(
            id: "preview-\(seq)",
            sequenceId: seq,
            kind: kind,
            authorId: author,
            authorName: RoomMessage.isHumanAuthor(author) ? "Alex" : author,
            isHuman: RoomMessage.isHumanAuthor(author),
            text: text,
            timestamp: stamp,
            replyToSequenceId: replyTo,
            revision: edited ? 2 : 1,
            isEdited: edited
        )
    }

    private static let history: [RoomMessage] = [
        row(101, "human-alex", minutesAgo: 26 * 60, "Morning all. Can we get the onboarding flow reviewed today?"),
        row(102, "review-agent", minutesAgo: 26 * 60 - 2, "On it. I'll post findings in this thread."),
        row(110, "human-alex", minutesAgo: 95, "Where are we on the onboarding review?"),
        row(111, "review-agent", minutesAgo: 93, "Two findings so far:\n1. The **email step** skips validation on paste.\n2. `retryCount` resets after a failed submit.", replyTo: 110),
        row(112, "review-agent", minutesAgo: 92, "Details are in [the PR](https://github.com/example/app/pull/42)."),
        row(113, "build-agent", minutesAgo: 80, "Build 318 is green on iOS 16 and 26.", edited: true),
        row(114, "build-agent", minutesAgo: 79, "Simulator screenshots attached to https://github.com/example/app/pull/42"),
        row(116, "build-agent", minutesAgo: 78, "Repro:\n```\nxcodebuild test -scheme App -only-testing:OnboardingTests\n```"),
        row(115, "senti", minutesAgo: 70, "Onboarding review: 2 findings, 1 fixed", kind: .checkpoint),
        row(120, "human-alex", minutesAgo: 12, "Thanks. Ship the fix for finding 1 first, then the retry counter."),
        row(121, "review-agent", minutesAgo: 10, "@alex fix for finding 1 is up: validation now runs on paste and on blur. Call me at [support](tel:5551234) if you'd rather talk it through."),
        row(122, "build-agent", minutesAgo: 4, "Rebuilding with the fix now.")
    ]

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let rows = beforeSequence.map { before in Self.history.filter { $0.sequenceId < before } } ?? Self.history
        return RoomEventPage(messages: rows, nextBeforeSequence: nil, hasMore: false)
    }

    private static let threadReplies: [RoomReply] = [
        RoomReply(id: "r1", targetSequenceId: 111, authorId: "human-alex", text: "Is finding 2 also in the onboarding module?", createdAt: "2026-10-28T13:25:00Z"),
        RoomReply(id: "r2", targetSequenceId: 111, authorId: "review-agent", text: "Yes, `OnboardingForm.swift`. Same PR.", createdAt: "2026-10-28T13:27:00Z")
    ]

    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        if targetSequenceId == 111 { return RoomActionsPage(replies: Self.threadReplies) }
        return RoomActionsPage(byTarget: [
            111: RoomReactionSummary(
                targetSequenceId: 111,
                counts: ["ack": 2, "like": 3, "reply": 2],
                actorsByType: ["ack": ["build-agent", "human-alex"]],
                likedByViewer: true,
                replyTotal: 2,
                latestReplies: Self.threadReplies
            ),
            113: RoomReactionSummary(targetSequenceId: 113, counts: ["like": 1]),
            120: RoomReactionSummary(
                targetSequenceId: 120,
                counts: ["ack": 1, "working_on": 1],
                actorsByType: ["ack": ["review-agent"]],
                activeOwners: ["review-agent"]
            )
        ])
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.frame(.control))
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continuation.yield(.frame(.composing(agentId: "build-agent", targetSequenceId: 122)))
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continuation.yield(.frame(.message(Self.row(
                    123,
                    "build-agent",
                    minutesAgo: 0,
                    "Build 319 is green. Ready for a look on device."
                ))))
                // Stay connected like a quiet live room.
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
