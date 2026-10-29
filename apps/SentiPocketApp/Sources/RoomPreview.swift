#if DEBUG
import Foundation
import SwiftUI
import UIKit
import PocketSyncClient

/// DEBUG-only room preview: `-PocketRoomPreview` opens the real room screen and coordinator on scripted sample
/// rows, so the chat can be built, run and screenshotted on a simulator without signing in. Never compiled into
/// Release.
enum RoomPreview {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketRoomPreview") || isTicketsRequested || isTicketLinkRequested
            || isAnchorRequested
    }

    /// `-PocketTicketLinkPreview` opens the room as a link to ticket t1 would: the ticket over the chat.
    static var isTicketLinkRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketTicketLinkPreview")
    }

    /// `-PocketRoomAnchorPreview` opens the room scrolled up at message 30 of a longer history, then grows message 5
    /// (far above the screen) with an edit and appends a new message: what you are reading must not move.
    static var isAnchorRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketRoomAnchorPreview")
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
                route: RoomRoute(
                    sessionId: "preview-room",
                    title: "Design review",
                    membershipRole: "owner",
                    focusSequenceId: isAnchorRequested ? 30 : nil,
                    focusTicketId: isTicketLinkRequested ? "t1" : nil
                ),
                transport: RoomPreviewTransport(anchorScenario: isAnchorRequested),
                sender: RoomPreviewSender(),
                actionSender: RoomPreviewSender(),
                ticketsTransport: RoomPreviewTickets(),
                attachmentFetcher: RoomPreviewFiles(),
                receipts: RoomPreviewReceipts(),
                onReauthenticationRequired: {}
            )
        }
    }
}

/// Who viewed the preview's messages, and who is here, so the read line, ticks and presence pill can be seen.
private struct RoomPreviewReceipts: RoomReceiptsClient {
    static let alex = "11111111-0000-4000-8000-000000000001"

    func recordViews(sessionId: String, targets: [RoomViewTarget]) async throws {}

    func views(sessionId: String, targets: [RoomViewTarget]) async throws -> [RoomViewSummary] {
        let now = ISO8601DateFormatter().string(from: Date())
        let alex = RoomViewer(isHuman: true, actorId: Self.alex, viewedAt: now)
        let agent = RoomViewer(isHuman: false, actorId: "review-agent", viewedAt: now)
        return targets.map { target in
            // Some rows nobody has seen yet, some only an agent has, the rest both.
            let seq = Int64(target.id.suffix(12)) ?? 0
            let viewers = seq % 5 == 0 ? [] : (seq % 3 == 0 ? [agent] : [alex, agent])
            return RoomViewSummary(kind: target.kind, id: target.id, revision: target.revision,
                                   viewedCount: viewers.count, viewers: viewers)
        }
    }

    func publishPresence(sessionId: String, active: Bool, clientInstanceId: String) async throws -> Int? { 90 }

    func presence(sessionId: String) async throws -> RoomPresence {
        RoomPresence(
            isAvailable: true,
            participants: [
                RoomPresentParticipant(id: "human-\(Self.alex)", isHuman: true, displayName: "Alex"),
                RoomPresentParticipant(id: "review-agent", isHuman: false),
                RoomPresentParticipant(id: "build-agent", isHuman: false, isIdle: true)
            ],
            humansOnline: 1,
            agentsOnline: 2,
            ttlSeconds: 90
        )
    }
}

/// Renders the preview screenshot locally instead of downloading it.
private struct RoomPreviewFiles: AttachmentFileFetching {
    func data(from url: URL, maximumBytes: Int) async throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1170, height: 900))
        return renderer.pngData { context in
            UIColor.systemIndigo.withAlphaComponent(0.18).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1170, height: 900))
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 90, y: 140, width: 990, height: 120))
            UIColor.white.setFill()
            context.fill(CGRect(x: 90, y: 360, width: 990, height: 110))
            context.fill(CGRect(x: 90, y: 520, width: 990, height: 110))
        }
    }

    func file(from url: URL, filename: String) async throws -> URL {
        throw AttachmentFetchError.failed
    }
}

/// Sample tickets for the Tickets tab preview.
private struct RoomPreviewTickets: RoomTicketsTransport {
    func roomTicketSnapshot(sessionId: String, afterId: String?, limit: Int) async throws -> RoomTicketSnapshotPage {
        RoomTicketSnapshotPage(items: [
            RoomTicket(id: "t1", title: "Fix paste validation on the email step", body: "## Priority\nP0\n\n## Decision\nQuestion: Ship the fix today?\nOptions: Yes · No · Custom\n\nPasting skips validation.", status: "working", createdBy: "human-alex", assignee: "review-agent", createdAt: "2026-10-28T13:00:00Z", updatedAt: "2026-10-28T18:40:00Z", version: 3),
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
            id: String(format: "00000000-0000-4000-8000-%012lld", seq),
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
        withFiles(row(114, "build-agent", minutesAgo: 79, "Simulator screenshots attached to https://github.com/example/app/pull/42")),
        row(116, "build-agent", minutesAgo: 78, "Repro:\n```\nxcodebuild test -scheme App -only-testing:OnboardingTests\n```"),
        row(115, "senti", minutesAgo: 70, "Onboarding review: 2 findings, 1 fixed", kind: .checkpoint),
        row(120, "human-alex", minutesAgo: 12, "Thanks. Ship the fix for finding 1 first, then the retry counter."),
        row(121, "review-agent", minutesAgo: 10, "@alex fix for finding 1 is up: validation now runs on paste and on blur. Call me at [support](tel:5551234) if you'd rather talk it through."),
        row(122, "build-agent", minutesAgo: 4, "Rebuilding with the fix now."),
        breakoutOpened(117, minutesAgo: 60),
        breakoutOutcome(119, minutesAgo: 30)
    ].sorted { $0.sequenceId < $1.sequenceId }

    private static let breakoutRoom = "preview-breakout"

    /// A screenshot and a PDF on one message, for the attachment cards.
    private static func withFiles(_ message: RoomMessage) -> RoomMessage {
        RoomMessage(id: message.id, sequenceId: message.sequenceId, kind: message.kind, authorId: message.authorId,
                    authorName: message.authorName, isHuman: message.isHuman, text: message.text,
                    timestamp: message.timestamp, attachments: [
                        RoomAttachment(attachmentId: "preview-screen", filename: "onboarding-email-step.png", kind: .image,
                                       contentType: "image/png", sizeBytes: 482_000, summaryStatus: "ready"),
                        RoomAttachment(attachmentId: "preview-report", filename: "review-findings.pdf", kind: .pdf,
                                       contentType: "application/pdf", sizeBytes: 1_250_000, summaryStatus: "processing")
                    ])
    }

    func attachmentDownload(sessionId: String, attachmentId: String) async throws -> RoomAttachmentDownload {
        guard let url = URL(string: "https://preview.invalid/\(attachmentId)") else { throw SessionTransportError.invalidRequest }
        return RoomAttachmentDownload(url: url, expiresIn: 300)
    }

    private static func breakoutOpened(_ seq: Int64, minutesAgo: Double) -> RoomMessage {
        let base = row(seq, "review-agent", minutesAgo: minutesAgo, "")
        return RoomMessage(id: base.id, sequenceId: seq, kind: .breakoutOpened, authorId: "review-agent",
                           authorName: "review-agent", isHuman: false, text: "", timestamp: base.timestamp,
                           breakout: RoomBreakoutEvent(childSessionId: breakoutRoom))
    }

    private static func breakoutOutcome(_ seq: Int64, minutesAgo: Double) -> RoomMessage {
        let base = row(seq, "review-agent", minutesAgo: minutesAgo, "")
        let text = "Ship the paste fix first; the retry counter follows in build 320."
        return RoomMessage(id: base.id, sequenceId: seq, kind: .breakoutOutcome, authorId: "review-agent",
                           authorName: "review-agent", isHuman: false, text: text, timestamp: base.timestamp,
                           breakout: RoomBreakoutEvent(childSessionId: breakoutRoom, outcome: RoomBreakoutOutcome(
                               outcomeId: "preview-outcome", revision: 1, text: text, authorId: "review-agent",
                               acknowledgements: [
                                   RoomBreakoutAcknowledgement(principalId: "review-agent", isHuman: false, state: .ack),
                                   RoomBreakoutAcknowledgement(principalId: "build-agent", isHuman: false, state: .ack),
                                   RoomBreakoutAcknowledgement(principalId: "human-alex", isHuman: true, state: .missing)
                               ]
                           )))
    }

    func roomBreakouts(parentSessionId: String, cursor: String?, limit: Int) async throws -> RoomBreakoutsPage {
        guard parentSessionId != Self.breakoutRoom else { return RoomBreakoutsPage() }
        return RoomBreakoutsPage(items: [RoomBreakout(
            childSessionId: Self.breakoutRoom,
            parentSessionId: parentSessionId,
            title: "Order of the onboarding fixes",
            isLocked: true,
            participants: [
                .init(id: "review-agent", isHuman: false),
                .init(id: "build-agent", isHuman: false),
                .init(id: "human-alex", name: "Alex", isHuman: true)
            ],
            messageCount: 14,
            unreadCount: 3,
            canRead: true,
            canPost: true
        )])
    }

    /// The reading-position scenario: forty earlier notes before the usual history.
    var anchorScenario = false

    private static let earlier: [RoomMessage] = (1...40).map { seq in
        row(Int64(seq), seq.isMultiple(of: 3) ? "human-alex" : "review-agent", minutesAgo: Double(30 * 60 - seq),
            "Earlier note \(seq): checking the onboarding copy, step \(seq).")
    }

    private var allHistory: [RoomMessage] { anchorScenario ? Self.earlier + Self.history : Self.history }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let rows = beforeSequence.map { before in allHistory.filter { $0.sequenceId < before } } ?? allHistory
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
        ], pinned: [
            RoomPinnedMessage(id: "preview-pin-2", targetSequenceId: 120, pinnedBy: "human-alex"),
            RoomPinnedMessage(id: "preview-pin-1", targetSequenceId: 111, pinnedBy: "review-agent")
        ])
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> {
        if anchorScenario { return anchorStream() }
        return AsyncStream { continuation in
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

    /// At 6s message 5 (far above the screen) is edited to be much longer; at 7s a new message arrives at the bottom.
    private func anchorStream() -> AsyncStream<RoomStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.frame(.control))
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                let original = Self.earlier[4]
                let longer = (1...12).map { "Line \($0) of a much longer edit to note 5." }.joined(separator: "\n")
                continuation.yield(.frame(.message(RoomMessage(
                    id: original.id,
                    sequenceId: original.sequenceId,
                    kind: original.kind,
                    authorId: original.authorId,
                    authorName: original.authorName,
                    isHuman: original.isHuman,
                    text: longer,
                    timestamp: original.timestamp,
                    revision: 3,
                    isEdited: true
                ))))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continuation.yield(.frame(.message(Self.row(124, "build-agent", minutesAgo: 0, "Build 320 is green."))))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
