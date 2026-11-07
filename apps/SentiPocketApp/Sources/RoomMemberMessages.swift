import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI

/// Someone's messages in a room, for their profile: newest first, a page at a time as the list scrolls (sentinelayer-api
/// #1136). Paging stops at the room's start (a page with no next cursor) and never reads two pages at once. A page can
/// bring none of their messages and still say where older ones start (the API stops scanning at a row budget, and
/// filters breakout rows out): up to `emptyPagesReadOn` more are read at once, then "Load older" reads on. Nothing is
/// asked for a stand-in name a public room shows a visitor (no rows carry it), or for someone you blocked.
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
    private let isBlocked: Bool
    /// Pages came back with none of their messages, as many as are read at once: the next waits for "Load older".
    private var olderNeedsTap = false

    static let pageSize = 20
    /// How many more pages one read goes on to when a page brings none of their messages.
    static let emptyPagesReadOn = 3

    init(sessionId: String, authorId: String, reader: (any RoomAuthorMessagesReading)?, isBlocked: Bool = false,
         onReauthenticationRequired: @escaping @MainActor () -> Void = {}) {
        self.sessionId = sessionId
        self.authorId = authorId
        self.reader = reader
        self.isBlocked = isBlocked
        self.onReauthenticationRequired = onReauthenticationRequired
        isPrivate = RoomAuthor.isPublicAlias(authorId)
        reachedStart = isPrivate || isBlocked || reader == nil
        state = RoomMemberMessagesState(canLoadMore: !reachedStart, isPrivate: isPrivate, isBlocked: isBlocked)
    }

    /// Reads the next, older page of their messages, and on past pages that bring none of them, up to
    /// `emptyPagesReadOn` more.
    func loadMore() async {
        guard !isLoading, !reachedStart, let reader else { return }
        isLoading = true
        failure = nil
        olderNeedsTap = false
        publish()
        defer {
            isLoading = false
            publish()
        }
        var readOn = 0
        do {
            while true {
                let before = nextBefore
                let page = try await reader.roomMessages(by: authorId, sessionId: sessionId, beforeSequence: before,
                                                         limit: Self.pageSize)
                let known = Set(messages.map(\.sequenceId))
                let added = page.messages.filter { !known.contains($0.sequenceId) }.sorted { $0.sequenceId > $1.sequenceId }
                messages += added
                if let connection = page.connection { self.connection = connection }
                // No next cursor is the room's start: paging stops there. A cursor that does not move back would read
                // the same page again forever, so it stops too.
                guard let next = page.nextBeforeSequence, before.map({ next < $0 }) ?? true else {
                    reachedStart = true
                    return
                }
                nextBefore = next
                // A page with their messages adds rows, and the list's last row reads on as it shows.
                guard added.isEmpty, !Task.isCancelled else { return }
                // None of theirs on it: no new row will show to read on, so read the next page now, a few at most.
                guard readOn < Self.emptyPagesReadOn else {
                    olderNeedsTap = true
                    return
                }
                readOn += 1
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

    /// How their posts reach the room (tickets f7254a3b, c96649c0): what the API read, except that its "mcp" covers
    /// both MCP and the CLI's own MCP server (sentinelayer-api session_relay_service.py `_session_connection_label`).
    /// For "mcp" the newest post that says how it was sent tells them apart (`RoomPostClient`). With nothing to tell,
    /// or marks that disagree with the API (its "mcp" and a post that says "cli"), nothing is shown, never a guess.
    static func connection(api: RoomAuthorConnection?, newest: RoomPostClient?) -> RoomMemberConnection? {
        switch api {
        case .box: return .box
        case .app: return .app
        case .web: return .web
        case .cli: return .cli
        case .mcp, nil:
            switch newest {
            case .mcp: return .mcp
            case .cliMCP: return .cliMCP
            case .cli: return api == nil ? .cli : nil
            case .other, nil: return nil
            }
        }
    }

    /// The marks of the newest post that says how it was sent (their messages are newest first): a post that says
    /// nothing leaves the one before it to decide, as the web reads it.
    static func newestSentThrough(_ messages: [RoomMessage]) -> RoomPostClient? {
        messages.lazy.compactMap(\.sentThrough).first
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
            connection: Self.connection(api: connection, newest: Self.newestSentThrough(messages)),
            olderNeedsTap: olderNeedsTap,
            isBlocked: isBlocked
        )
    }
}
