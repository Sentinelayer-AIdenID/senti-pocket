import Foundation

/// The reads an open room needs: back-pagination, forward catch-up and the live stream. A protocol so the app's
/// room coordinator is testable with a scripted fake.
public protocol RoomTransport: Sendable {
    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage
    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage
    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent>
    /// Replies and reaction summaries: the room's newest actions, or one thread when `targetSequenceId` is set.
    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage
    /// The same, the page older than `beforeCursor` (a page's `nextCursor`); nil reads the newest page.
    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int, beforeCursor: String?) async throws
        -> RoomActionsPage
    /// One thread opened at one of its replies, in one read however far back it is: up to `limit` actions around it
    /// (`aroundActionId`, sentinelayer-api #1199), with `anchoredActionId` and a cursor each way. A reply not in the
    /// thread throws `RoomActionNotFound`; an API without this read answers with the thread's newest page.
    func roomActions(sessionId: String, targetSequenceId: Int64, limit: Int, aroundActionId: String) async throws
        -> RoomActionsPage
    /// The page newer than `afterCursor` (a read around a reply's, or a page's read on from it).
    func roomActions(sessionId: String, targetSequenceId: Int64, limit: Int, afterCursor: String) async throws
        -> RoomActionsPage
    /// The breakouts started from this room that the viewer may see (metadata only).
    func roomBreakouts(parentSessionId: String, cursor: String?, limit: Int) async throws -> RoomBreakoutsPage
    /// A short-lived link to one attachment's bytes.
    func attachmentDownload(sessionId: String, attachmentId: String) async throws -> RoomAttachmentDownload
    /// The same link, as a download with a safe file name when `asDownload` (for saving and sharing).
    func attachmentDownload(sessionId: String, attachmentId: String, asDownload: Bool) async throws -> RoomAttachmentDownload
    /// The room's people, for owners and admins (the API refuses everyone else).
    func roomMembers(sessionId: String) async throws -> RoomMembersPage
    /// What the room offers (`@any`), from its read.
    func roomFeatures(sessionId: String) async throws -> RoomFeatures
}

extension RoomTransport {
    /// Transports without reply and reaction support show none.
    public func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        RoomActionsPage()
    }

    /// Transports without pages read the newest page only: there is nothing older.
    public func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int,
                            beforeCursor: String?) async throws -> RoomActionsPage {
        guard beforeCursor == nil else { return RoomActionsPage() }
        return try await roomActions(sessionId: sessionId, targetSequenceId: targetSequenceId, limit: limit)
    }

    /// Transports without reads around a reply answer as an API without them does: with the thread's newest page.
    public func roomActions(sessionId: String, targetSequenceId: Int64, limit: Int,
                            aroundActionId: String) async throws -> RoomActionsPage {
        try await roomActions(sessionId: sessionId, targetSequenceId: targetSequenceId, limit: limit, beforeCursor: nil)
    }

    /// Transports without reads around a reply never give a newer page's cursor: there is nothing newer to read.
    public func roomActions(sessionId: String, targetSequenceId: Int64, limit: Int,
                            afterCursor: String) async throws -> RoomActionsPage {
        RoomActionsPage()
    }

    /// Transports without breakout support show none.
    public func roomBreakouts(parentSessionId: String, cursor: String?, limit: Int) async throws -> RoomBreakoutsPage {
        RoomBreakoutsPage()
    }

    /// Transports without attachment support cannot open files.
    public func attachmentDownload(sessionId: String, attachmentId: String) async throws -> RoomAttachmentDownload {
        throw SessionTransportError.invalidRequest
    }

    /// Transports that cannot ask for a download link give the inline one.
    public func attachmentDownload(sessionId: String, attachmentId: String, asDownload: Bool) async throws -> RoomAttachmentDownload {
        try await attachmentDownload(sessionId: sessionId, attachmentId: attachmentId)
    }

    /// Transports without a member list offer only the people seen in the room.
    public func roomMembers(sessionId: String) async throws -> RoomMembersPage {
        RoomMembersPage()
    }

    /// Transports without the room's read offer nothing beyond what every room has.
    public func roomFeatures(sessionId: String) async throws -> RoomFeatures {
        RoomFeatures()
    }
}

extension HTTPSessionTransport: RoomTransport {}

/// The room's ticket board reads: the snapshot pages and the event feed.
public protocol RoomTicketsTransport: Sendable {
    func roomTicketSnapshot(sessionId: String, afterId: String?, limit: Int) async throws -> RoomTicketSnapshotPage
    func roomTicketEvents(sessionId: String, after: Int64, limit: Int) async throws -> RoomTicketEventsPage
}

extension HTTPSessionTransport: RoomTicketsTransport {}
