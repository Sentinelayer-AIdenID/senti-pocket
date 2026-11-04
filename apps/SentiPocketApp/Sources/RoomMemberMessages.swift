import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI

/// Someone's messages in a room, for their profile: newest first, a page at a time as the list scrolls (sentinelayer-api
/// #1136). Paging stops at the room's start (a page with no next cursor), never reads two pages at once, and never asks
/// for a person a public room shows by an alias: their messages are private there, and the profile says so.
@MainActor
final class RoomMemberMessagesModel: ObservableObject {
    @Published private(set) var state: RoomMemberMessagesState

    let sessionId: String
    let authorId: String
    private let reader: (any RoomAuthorMessagesReading)?
    private let onReauthenticationRequired: @MainActor () -> Void
    private var messages: [RoomMessage] = []
    /// Where the next (older) page starts; nil before the first page.
    private var nextBefore: Int64?
    /// A page reached the start of the room (or nothing can be read): no more pages.
    private var reachedStart: Bool
    private var isLoading = false
    private var failure: String?
    private var connection: RoomAuthorConnection?
    private let isPrivate: Bool

    static let pageSize = 20

    init(sessionId: String, authorId: String, reader: (any RoomAuthorMessagesReading)?,
         onReauthenticationRequired: @escaping @MainActor () -> Void = {}) {
        self.sessionId = sessionId
        self.authorId = authorId
        self.reader = reader
        self.onReauthenticationRequired = onReauthenticationRequired
        isPrivate = RoomAuthor.isPublicAlias(authorId)
        reachedStart = isPrivate || reader == nil
        state = RoomMemberMessagesState(canLoadMore: !reachedStart, isPrivate: isPrivate)
    }

    /// Reads the next, older page of their messages.
    func loadMore() async {
        guard !isLoading, !reachedStart, let reader else { return }
        isLoading = true
        failure = nil
        publish()
        defer {
            isLoading = false
            publish()
        }
        let before = nextBefore
        do {
            let page = try await reader.roomMessages(by: authorId, sessionId: sessionId, beforeSequence: before,
                                                     limit: Self.pageSize)
            let known = Set(messages.map(\.sequenceId))
            messages += page.messages.filter { !known.contains($0.sequenceId) }.sorted { $0.sequenceId > $1.sequenceId }
            if let connection = page.connection { self.connection = connection }
            // No next cursor is the room's start: paging stops there. A cursor that does not move back would read the
            // same page again forever, so it stops too.
            if let next = page.nextBeforeSequence, before.map({ next < $0 }) ?? true {
                nextBefore = next
            } else {
                reachedStart = true
            }
        } catch SessionTransportError.cancelled {
            // Closed while reading: nothing to say.
        } catch SessionTransportError.reauthenticationRequired {
            onReauthenticationRequired()
            failure = "Sign in again to see their messages."
        } catch SessionTransportError.rateLimited {
            failure = "Too many reads just now. Try again in a minute."
        } catch {
            failure = "Their messages couldn't load."
        }
    }

    private func publish() {
        state = RoomMemberMessagesState(
            rows: messages.map {
                RoomMemberMessageRow(sequenceId: $0.sequenceId, text: RoomChatQuiet.line($0.text),
                                     date: ParsedSessionTimestamp($0.timestamp).date, attachments: $0.attachments.count)
            },
            phase: isLoading ? .loading : (failure.map { .failed($0) } ?? .idle),
            canLoadMore: !reachedStart,
            isPrivate: isPrivate,
            connection: connection.flatMap { RoomMemberConnection(rawValue: $0.rawValue) }
        )
    }
}
