#if DEBUG
import Foundation
import SwiftUI
import PocketSyncClient

/// DEBUG-only room preview: `-PocketRoomPreview` opens the real room screen and coordinator on scripted sample
/// rows, so the chat can be built, run and screenshotted on a simulator without signing in. Never compiled into
/// Release.
enum RoomPreview {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketRoomPreview")
    }

    @MainActor
    static var rootView: some View {
        NavigationStack {
            RoomChatScreen(
                route: RoomRoute(sessionId: "preview-room", title: "Design review"),
                transport: RoomPreviewTransport(),
                onReauthenticationRequired: {}
            )
        }
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
        row(114, "build-agent", minutesAgo: 79, "Simulator screenshots attached to the PR."),
        row(115, "senti", minutesAgo: 70, "Onboarding review: 2 findings, 1 fixed", kind: .checkpoint),
        row(120, "human-alex", minutesAgo: 12, "Thanks. Ship the fix for finding 1 first, then the retry counter."),
        row(121, "review-agent", minutesAgo: 10, "Fix for finding 1 is up: validation now runs on paste and on blur. Call me at [support](tel:5551234) if you'd rather talk it through."),
        row(122, "build-agent", minutesAgo: 4, "Rebuilding with the fix now.")
    ]

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let rows = beforeSequence.map { before in Self.history.filter { $0.sequenceId < before } } ?? Self.history
        return RoomEventPage(messages: rows, nextBeforeSequence: nil, hasMore: false)
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
