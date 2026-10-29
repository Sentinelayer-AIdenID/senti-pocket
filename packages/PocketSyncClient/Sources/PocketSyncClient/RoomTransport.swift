import Foundation

/// The reads an open room needs: back-pagination, forward catch-up and the live stream. A protocol so the app's
/// room coordinator is testable with a scripted fake.
public protocol RoomTransport: Sendable {
    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage
    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage
    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent>
    /// Replies and reaction summaries: the room's newest actions, or one thread when `targetSequenceId` is set.
    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage
}

extension RoomTransport {
    /// Transports without reply and reaction support show none.
    public func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        RoomActionsPage()
    }
}

extension HTTPSessionTransport: RoomTransport {}
