import Foundation

/// The reads an open room needs: back-pagination, forward catch-up and the live stream. A protocol so the app's
/// room coordinator is testable with a scripted fake.
public protocol RoomTransport: Sendable {
    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage
    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage
    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent>
    /// Replies and reaction summaries: the room's newest actions, or one thread when `targetSequenceId` is set.
    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage
    /// The breakouts started from this room that the viewer may see (metadata only).
    func roomBreakouts(parentSessionId: String, cursor: String?, limit: Int) async throws -> RoomBreakoutsPage
    /// A short-lived link to one attachment's bytes.
    func attachmentDownload(sessionId: String, attachmentId: String) async throws -> RoomAttachmentDownload
}

extension RoomTransport {
    /// Transports without reply and reaction support show none.
    public func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
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
}

extension HTTPSessionTransport: RoomTransport {}

/// The room's ticket board reads: the snapshot pages and the event feed.
public protocol RoomTicketsTransport: Sendable {
    func roomTicketSnapshot(sessionId: String, afterId: String?, limit: Int) async throws -> RoomTicketSnapshotPage
    func roomTicketEvents(sessionId: String, after: Int64, limit: Int) async throws -> RoomTicketEventsPage
}

extension HTTPSessionTransport: RoomTicketsTransport {}
