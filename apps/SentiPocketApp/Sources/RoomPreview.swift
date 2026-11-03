#if DEBUG
import Foundation
import SwiftUI
import UIKit
import PocketSyncClient
import PocketUI
import PocketVoice

/// DEBUG-only room preview: `-PocketRoomPreview` opens the real room screen and coordinator on scripted sample
/// rows, so the chat can be built, run and screenshotted on a simulator without signing in. Never compiled into
/// Release.
enum RoomPreview {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketRoomPreview") || isTicketsRequested || isTicketLinkRequested
            || isAnchorRequested || isSearchRequested
    }

    /// `-PocketRoomSearchPreview` shows the room's search with sample matches.
    static var isSearchRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketRoomSearchPreview")
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

    /// `-PocketRoomLeaderboardPreview` adds a leaderboard to the room's pins, far up its history, so its Leaderboard
    /// button shows.
    static var isLeaderboardRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketRoomLeaderboardPreview") || isLeaderboardSheetRequested
    }

    /// `-PocketRoomLeaderboardSheetPreview` also opens the leaderboard's sheet once the room has the board.
    static var isLeaderboardSheetRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketRoomLeaderboardSheetPreview")
    }

    /// `-PocketRoomFilesPreview` adds two files posted as base64 parts in replies: one whose parts are all there and
    /// match its declared hash, and one with a part missing.
    static var isFilesRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketRoomFilesPreview")
    }

    /// `-PocketRoomLongMessage` adds, last in the room, a design packet of about 27,000 characters of markdown
    /// (headings, lists, code, tables, links, mentions): the kind of message a phone stalled on with build 2026110306.
    static var isLongMessageRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketRoomLongMessage")
    }

    /// `-PocketRoomLongMessageReply` adds a short reply to the long message after it, so the reply's quote of it shows.
    static var isLongMessageReplyRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-PocketRoomLongMessageReply")
    }

    /// The long message's text: made up, the shape of a real design packet.
    /// `-PocketRoomLongMessageSections N` sets how many sections (52 by default, about 27,000 characters), and
    /// `-PocketRoomLongMessageNoTables YES` leaves the tables out, to tell what costs what.
    static let longMarkdown: String = {
        let defaults = UserDefaults.standard
        // `-PocketRoomLongMessageFile <path>`: a real message's text, read from a file on the machine running the
        // simulator, so a stall can be tried on the exact text without that text ever being in the app.
        if let path = defaults.string(forKey: "PocketRoomLongMessageFile"),
           let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty {
            return text
        }
        let asked = defaults.integer(forKey: "PocketRoomLongMessageSections")
        let sections = asked > 0 ? asked : 52
        let tables = !defaults.bool(forKey: "PocketRoomLongMessageNoTables")
        var parts = ["# Design packet: room continuity", "A preview packet. Every section has the same shape."]
        for section in 1...sections {
            parts.append("## Section \(section): flow and checks")
            parts.append("This section covers the **design** of step \(section), with `check\(section)()` and "
                + "[its notes](https://example.com/notes/\(section)). @review-agent please confirm, and @alex has the "
                + "final say. Plain words follow so the paragraph wraps across several lines on a phone screen.")
            parts.append("- First point of section \(section)\n- Second point, with **bold** and _italic_\n"
                + "  - A nested point\n1. Ordered one\n2. Ordered two")
            parts.append("```swift\nfunc check\(section)() -> Bool {\n    value > \(section)\n}\n```")
            if tables { parts.append("| Field | Value |\n|---|---|\n| id | \(section) |\n| state | ready |") }
        }
        return parts.joined(separator: "\n\n")
    }()

    @MainActor
    @ViewBuilder
    static var rootView: some View {
        if isTicketsRequested {
            NavigationStack {
                RoomTicketsScreen(
                    sessionId: "preview-room",
                    transport: RoomPreviewTickets(),
                    sender: RoomPreviewSender(),
                    writer: RoomPreviewTicketWriter(),
                    leases: RoomPreviewTickets.leases,
                    identity: RoomPreviewIdentity(),
                    assignRoster: ["review-agent", "build-agent"],
                    extras: RoomPreviewExtras(),
                    onReauthenticationRequired: {}
                )
            }
        } else if isSearchRequested {
            RoomSearchView(state: RoomPreviewSearch.sampleState) { _ in }
        } else {
            roomRoot
        }
    }

    @MainActor
    private static let reader = MessageReader()

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
                identity: RoomPreviewIdentity(),
                ticketsTransport: RoomPreviewTickets(),
                ticketWriter: RoomPreviewTicketWriter(),
                ticketLeases: RoomPreviewTickets.leases,
                ticketExtras: RoomPreviewExtras(),
                attachmentFetcher: RoomPreviewFiles(),
                receipts: RoomPreviewReceipts(),
                search: RoomPreviewSearch(),
                reader: reader,
                onReauthenticationRequired: {}
            )
        }
    }
}

/// Search over the preview room's own messages, so a match opens a real row. `-PocketRoomSearchPreview` shows the
/// matches for "paste", with "Older matches" so that row can be seen too.
private struct RoomPreviewSearch: RoomSearching {
    static let sampleState = RoomSearchPresentationState(
        query: "paste",
        rows: matches(for: "paste", before: nil, limit: 10).map(RoomSearchModel.row),
        hasMore: true
    )

    func searchRoom(sessionId: String, query: String, beforeSequence: Int64?, limit: Int) async throws -> RoomSearchPage {
        RoomSearchPage(query: query, results: Self.matches(for: query, before: beforeSequence, limit: limit))
    }

    /// The preview room's messages that contain the query, newest first, like the server's search.
    private static func matches(for query: String, before: Int64?, limit: Int) -> [RoomSearchResult] {
        RoomPreviewTransport.history
            .filter { $0.kind == .message && $0.sequenceId < (before ?? .max) && $0.text.localizedCaseInsensitiveContains(query) }
            .sorted { $0.sequenceId > $1.sequenceId }
            .prefix(limit)
            .map { RoomSearchResult(sequenceId: $0.sequenceId, snippet: $0.text, message: $0) }
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
/// Comments on t1 and the room's people, for the preview.
private struct RoomPreviewExtras: RoomTicketExtrasReading {
    static let priya = "1d2e3f40-0000-4000-8000-00000000000b"

    func comments(sessionId: String, ticketId: String, after: Int64) async throws -> RoomTicketCommentsPage {
        guard ticketId == "t1", after == 0 else { return RoomTicketCommentsPage(comments: [], cursor: after) }
        return RoomTicketCommentsPage(comments: [
            RoomTicketComment(id: "c1", body: "Repro: paste a code with a trailing space and the step accepts it.",
                              actorId: Self.priya, createdAt: "2026-10-28T14:10:00Z", cursor: 5),
            RoomTicketComment(id: "c2", body: "Fix is in review. I added a test for the **trailing space** case.",
                              actorId: "review-agent", actorKind: "agent", createdAt: "2026-10-28T18:30:00Z", cursor: 9)
        ], cursor: 9)
    }

    func memberDirectory(sessionId: String, cursor: String?) async throws -> RoomDirectoryPage {
        RoomDirectoryPage(members: [
            RoomDirectoryMember(userId: RoomPreviewIdentity.accountId, displayName: "Alex", githubLogin: "alex"),
            RoomDirectoryMember(userId: Self.priya, displayName: "Priya", githubLogin: "priya-dev")
        ])
    }
}

/// The preview's signed-in person.
private struct RoomPreviewIdentity: AccountIdentityProviding {
    static let accountId = "6f1c2b9e-0000-4000-8000-00000000000a"
    func currentAccount() async -> SignedInAccount? { SignedInAccount(githubUsername: "alex", accountId: Self.accountId) }
}

/// Answers every ticket write after a short delay, as the API would, so the actions can be tried in the preview.
private struct RoomPreviewTicketWriter: RoomTicketWriting {
    func write(_ write: RoomTicketWrite, sessionId: String, idempotencyKey: String) async throws -> RoomTicketWriteResult {
        try? await Task.sleep(nanoseconds: 500_000_000)
        let now = ISO8601DateFormatter().string(from: Date())
        switch write {
        case .file(let title, let body, let assignee):
            return RoomTicketWriteResult(ticket: RoomTicket(
                id: "t\(Int.random(in: 100...999))", title: title, body: body ?? "", status: assignee == nil ? "open" : "assigned",
                createdBy: RoomPreviewIdentity.accountId, assignee: assignee, createdAt: now, updatedAt: now, version: 1
            ))
        case .claim(let id, let version):
            let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(900))
            let credential = RoomTicketLeaseCredential(
                leaseId: UUID().uuidString.lowercased(), fence: 1, expiresAt: expiry, claimedVersion: version + 1
            )
            return RoomTicketWriteResult(
                ticket: RoomTicket(
                    id: id, title: RoomPreviewTickets.title(id), status: "working", assignee: RoomPreviewIdentity.accountId,
                    updatedAt: now, version: version + 1,
                    lease: RoomTicketLease(holder: RoomPreviewIdentity.accountId, holderKind: "human", fence: 1, expiresAt: expiry)
                ),
                lease: credential
            )
        case .release(let id, _, let version):
            return RoomTicketWriteResult(ticket: RoomTicket(id: id, title: RoomPreviewTickets.title(id), updatedAt: now, version: version + 1))
        case .assign(let id, let assignee, let version):
            return RoomTicketWriteResult(ticket: RoomTicket(
                id: id, title: RoomPreviewTickets.title(id), status: assignee.isEmpty ? "open" : "assigned",
                assignee: assignee.isEmpty ? nil : assignee, updatedAt: now, version: version + 1
            ))
        case .edit(let id, let title, let body, let version):
            return RoomTicketWriteResult(ticket: RoomTicket(
                id: id, title: title ?? RoomPreviewTickets.title(id), body: body ?? "", updatedAt: now, version: version + 1
            ))
        case .comment(let id, let body):
            return RoomTicketWriteResult(
                ticket: nil,
                comment: RoomTicketComment(id: UUID().uuidString.lowercased(), body: body, actorId: RoomPreviewIdentity.accountId,
                                           createdAt: now, cursor: Int64(Date().timeIntervalSince1970))
            )
        }
    }
}

private struct RoomPreviewTickets: RoomTicketsTransport {
    /// t6 is yours, under a lease this phone claimed: it can be released.
    static let leases: InMemoryTicketLeaseStore = {
        let store = InMemoryTicketLeaseStore()
        store.save(
            RoomTicketLeaseCredential(leaseId: "0b5c6a52-1d3e-4f70-8a9b-1c2d3e4f5a6b", fence: 1, expiresAt: leaseExpiry, claimedVersion: 2),
            sessionId: "preview-room",
            ticketId: "t6"
        )
        return store
    }()
    static let leaseExpiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(900))

    static func title(_ id: String) -> String {
        ["t1": "Fix paste validation on the email step", "t4": "Draft release notes", "t6": "Check the Android fallback"][id] ?? "Ticket \(id)"
    }

    func roomTicketSnapshot(sessionId: String, afterId: String?, limit: Int) async throws -> RoomTicketSnapshotPage {
        // Ids strictly ascending, as the API pages them: the board refuses a snapshot out of order.
        RoomTicketSnapshotPage(items: [
            RoomTicket(id: "t1", title: "Fix paste validation on the email step", body: "## Priority\nP0\n\n## Decision\nQuestion: Ship the fix today?\nOptions: Yes · No · Custom\n\nPasting skips validation.", status: "working", createdBy: "human-alex", assignee: "review-agent", createdAt: "2026-10-28T13:00:00Z", updatedAt: "2026-10-28T18:40:00Z", version: 3),
            RoomTicket(id: "t2", title: "Reset retryCount only after success", body: "## Priority\nP1", status: "assigned", createdBy: "human-alex", assignee: "build-agent", createdAt: "2026-10-28T13:05:00Z", updatedAt: "2026-10-28T17:00:00Z", version: 2),
            RoomTicket(id: "t3", title: "Add onboarding screenshots to the PR", body: "## Priority\nP2", status: "in_review", createdBy: "review-agent", assignee: "build-agent", createdAt: "2026-10-28T12:00:00Z", updatedAt: "2026-10-28T16:00:00Z", version: 4),
            RoomTicket(id: "t4", title: "Draft release notes", status: "open", createdBy: "human-alex", createdAt: "2026-10-28T11:00:00Z", updatedAt: "2026-10-28T11:00:00Z", version: 1),
            RoomTicket(id: "t5", title: "Rename onboarding flags", body: "## Priority\nP3", status: "done", createdBy: "human-alex", assignee: "build-agent", createdAt: "2026-10-27T11:00:00Z", updatedAt: "2026-10-27T15:00:00Z", version: 5),
            RoomTicket(id: "t6", title: Self.title("t6"), body: "## Priority\nP2\n\nConfirm the fallback screen on a small phone.", status: "working", createdBy: "human-alex", assignee: RoomPreviewIdentity.accountId, createdAt: "2026-10-28T14:00:00Z", updatedAt: "2026-10-28T19:00:00Z", version: 2, lease: RoomTicketLease(holder: RoomPreviewIdentity.accountId, holderKind: "human", fence: 1, expiresAt: Self.leaseExpiry))
        ], hasMore: false, cursor: 1)
    }

    func roomTicketEvents(sessionId: String, after: Int64, limit: Int) async throws -> RoomTicketEventsPage {
        RoomTicketEventsPage(tickets: [], eventCount: 0, cursor: after)
    }
}

/// Accepts every message after a short delay, so the composer's pending states can be seen in the preview.
private struct RoomPreviewSender: RoomMessageSending, RoomActionSending, RoomSummaryGenerating {
    func generateSummary(sessionId: String) async throws -> RoomSummary? {
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        // The server's prose summary (`format: "prose-v2"`), with the fields its quiet line reads.
        let text = "Alex asked the team to fix two findings in the onboarding flow before the next build. "
            + "Paste validation is fixed and build 319 is green; Alex asked for a look on a device. "
            + "The retry counter is next, once that ships, and a breakout is ordering the fixes."
        let iso = ISO8601DateFormatter()
        let body: [String: Any] = ["ok": true, "summary": [
            "format": "prose-v2", "title": "Design review: onboarding fixes", "summary": text, "model": "preview",
            "participants": ["human-alex", "review-agent", "build-agent"], "mode": "llm",
            "timeRange": ["start": iso.string(from: Date().addingTimeInterval(-5_400)), "end": iso.string(from: Date())]
        ] as [String: Any]]
        guard let summary = RoomSummary(json: try JSONSerialization.data(withJSONObject: body)) else { throw RoomSendError.rejected }
        return summary
    }

    func readSummary(sessionId: String) async throws -> RoomSummary? {
        try await generateSummary(sessionId: sessionId)
    }

    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    func sendAction(_ action: RoomActionRequest) async throws {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
}

/// The voice room in the preview: turns and the transcript go nowhere.
extension RoomPreviewSender: VoiceRoomPosting {
    func postCallStarted(sessionId: String, text: String, clientId: String) async throws {}

    func postVoiceTurn(sessionId: String, text: String, clientId: String) async throws {}

    func uploadTranscript(sessionId: String, filename: String, markdown: String, clientId: String) async throws -> VoiceTranscriptAttachment {
        VoiceTranscriptAttachment(attachmentId: "preview-transcript", filename: filename, kind: "text",
                                  contentType: "text/markdown", sizeBytes: markdown.utf8.count, status: "ready")
    }

    func postCallEnded(sessionId: String, text: String, transcript: VoiceTranscriptAttachment?, clientId: String) async throws {}
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

    fileprivate static let history: [RoomMessage] = [
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

    private var allHistory: [RoomMessage] {
        let files = RoomPreview.isFilesRequested ? Self.fileRoots : []
        var long = RoomPreview.isLongMessageRequested
            ? [Self.row(130, "review-agent", minutesAgo: 1, RoomPreview.longMarkdown)] : []
        if RoomPreview.isLongMessageReplyRequested {
            long.append(Self.row(131, "human-alex", minutesAgo: 0.5, "Looks good, merging it now.", replyTo: 130))
        }
        return (anchorScenario ? Self.earlier + Self.history : Self.history) + files + long
    }

    /// The files' messages: each says what its replies hold.
    private static let fileRoots = [
        row(124, "review-agent", minutesAgo: 3, "The onboarding checks as CSV, in 3 parts below."),
        row(125, "build-agent", minutesAgo: 2, "The fixture pack, in 3 parts below.")
    ]

    /// Each file in envelope parts, as replies to its message by the agent who posted it: every part of the checks,
    /// and two of the pack's three.
    private static let fileParts: [RoomReply] = {
        let checks = Data((["step,check,result"] + (1...24).map { "\($0),field \($0) validates on paste,pass" })
            .joined(separator: "\n").utf8)
        let pack = Data([0x50, 0x4b, 0x03, 0x04] + (0..<3_000).map { UInt8(($0 * 37 + 11) % 256) })
        func parts(_ file: Data, name: String, to root: Int64, keep: [Int]) -> [RoomReply] {
            let encoded = file.base64EncodedString()
            let size = (encoded.count + 2) / 3
            return keep.map { index in
                let chunk = String(encoded.dropFirst(index * size).prefix(size))
                let body = (try? JSONSerialization.data(withJSONObject: [
                    "artifact": name, "sha256": RoomBase64Files.sha256Hex(file), "bytes": file.count,
                    "part": index + 1, "parts": 3, "data": chunk
                ], options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
                // A few seconds apart, after the message they answer.
                let posted = base.addingTimeInterval((root == 124 ? -180 : -120) + Double(index + 1) * 10)
                let stamp = ISO8601DateFormatter().string(from: posted)
                return RoomReply(id: "file-\(root)-\(index + 1)", targetSequenceId: root,
                                 authorId: root == 124 ? "review-agent" : "build-agent",
                                 text: body, createdAt: stamp)
            }
        }
        return parts(checks, name: "onboarding-checks.csv", to: 124, keep: [0, 1, 2])
            + parts(pack, name: "fixture-pack.zip", to: 125, keep: [0, 2])
    }()

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        try? await Task.sleep(nanoseconds: 300_000_000)
        if RoomPreview.isLeaderboardRequested, beforeSequence == Self.leaderboard.sequenceId + 1 {
            return RoomEventPage(messages: [Self.leaderboard], nextBeforeSequence: nil, hasMore: false)
        }
        let rows = beforeSequence.map { before in allHistory.filter { $0.sequenceId < before } } ?? allHistory
        return RoomEventPage(messages: rows, nextBeforeSequence: nil, hasMore: false)
    }

    private static let threadReplies: [RoomReply] = [
        RoomReply(id: "r1", targetSequenceId: 111, authorId: "human-alex", text: "Is finding 2 also in the onboarding module?", createdAt: "2026-10-28T13:25:00Z"),
        RoomReply(id: "r2", targetSequenceId: 111, authorId: "review-agent", text: "Yes, `OnboardingForm.swift`. Same PR.", createdAt: "2026-10-28T13:27:00Z"),
        // The keeper files the thread after the answer: its receipt is a line under the answer, never the row.
        RoomReply(id: "r3", targetSequenceId: 111, authorId: "ticket-keeper", text: "Tickets for this message: [Ticket: Validate the email step on paste](/dashboard/sessions/preview-room?ticket=t1)", createdAt: "2026-10-28T13:28:00Z")
    ]

    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        if targetSequenceId == 111 { return RoomActionsPage(replies: Self.threadReplies) }
        let files = RoomPreview.isFilesRequested ? Self.fileParts : []
        if let targetSequenceId, targetSequenceId == 124 || targetSequenceId == 125 {
            return RoomActionsPage(replies: files.filter { $0.targetSequenceId == targetSequenceId })
        }
        return RoomActionsPage(byTarget: [
            111: RoomReactionSummary(
                targetSequenceId: 111,
                counts: ["ack": 2, "like": 3, "reply": 2],
                actorsByType: ["ack": ["build-agent", "human-alex"]],
                likedByViewer: true,
                replyTotal: 2,
                latestReplies: Self.threadReplies,
                emojiReactions: [
                    RoomEmojiReaction(emoji: "🎉", count: 3, viewerReacted: true),
                    RoomEmojiReaction(emoji: "👀", count: 1, viewerReacted: false)
                ]
            ),
            113: RoomReactionSummary(targetSequenceId: 113, counts: ["like": 1],
                                     emojiReactions: [RoomEmojiReaction(emoji: "🚀", count: 2, viewerReacted: false)]),
            120: RoomReactionSummary(
                targetSequenceId: 120,
                counts: ["ack": 1, "working_on": 1],
                actorsByType: ["ack": ["review-agent"]],
                activeOwners: ["review-agent"]
            )
        ], replies: files, pinned: (RoomPreview.isLeaderboardRequested
                    ? [RoomPinnedMessage(id: "preview-pin-board", targetSequenceId: Self.leaderboard.sequenceId,
                                         pinnedBy: "board-keeper")]
                    : []) + [
            RoomPinnedMessage(id: "preview-pin-2", targetSequenceId: 120, pinnedBy: "human-alex"),
            RoomPinnedMessage(id: "preview-pin-1", targetSequenceId: 111, pinnedBy: "review-agent")
        ])
    }

    /// The leaderboard a host process keeps pinned and edits as the scores change: far before the loaded history, so
    /// the room reads it on its own.
    static let leaderboard = row(
        3,
        "board-keeper",
        minutesAgo: 3 * 24 * 60,
        "🏆 Who's helping most in this room\n\n"
            + "🥇 **review-agent** · SentiLab team · 127.5 pts · 56 helpful\n"
            + "🥈 **build-agent** · SentiLab team · 72.1 pts · 25 helpful\n"
            + "🥉 **alex** (person) · 44.8 pts · 15 helpful ▲1\n"
            + "4. **box-host** · SentiLab team · 34.9 pts · 14 helpful ▼1\n"
            + "5. **design-agent** · 33.2 pts · 11 helpful\n"
            + "6. **a-very-long-agent-name-from-a-team-36** · 18.0 pts · 7 helpful 🆕\n\n"
            + "How it works: each message and reply is scored once for how much concrete help it gives someone "
            + "else, from 0 to 4 points. An author's best 10 messages per hour count, so volume doesn't buy rank. "
            + "Updated every 10 minutes when scores change (last 09:40 UTC)."
    )

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
