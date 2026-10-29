import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI

/// The room's message search (sentinelayer-web `useSessionLiveController` `runSearch`): run on submit with at least 2
/// characters, 10 matches a page, newest first, older matches on demand. A newer search makes any older answer stale.
@MainActor
final class RoomSearchModel: ObservableObject {
    @Published private(set) var state = RoomSearchPresentationState(
        message: "Search this room's messages by words, names or agents."
    )

    static let pageSize = 10

    private let sessionId: String
    private let searcher: any RoomSearching
    private let onReauthenticationRequired: @MainActor () -> Void
    private var query = ""
    private var rows: [RoomSearchRow] = []
    private var nextBeforeSequence: Int64?
    private var token = 0

    init(sessionId: String, searcher: any RoomSearching, onReauthenticationRequired: @escaping @MainActor () -> Void) {
        self.sessionId = sessionId
        self.searcher = searcher
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    func send(_ intent: RoomSearchIntent) {
        switch intent {
        case .submit(let text):
            submit(text)
        case .loadMore:
            loadMore()
        case .open:
            break   // the room screen jumps to the message
        }
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        token += 1
        guard trimmed.unicodeScalars.count >= RoomSearchPresentationState.minimumQueryLength else {
            query = ""
            rows = []
            nextBeforeSequence = nil
            state = RoomSearchPresentationState(message: "Type at least \(RoomSearchPresentationState.minimumQueryLength) characters.")
            return
        }
        query = trimmed
        rows = []
        nextBeforeSequence = nil
        state = RoomSearchPresentationState(query: trimmed, isSearching: true)
        fetch(before: nil, token: token)
    }

    private func loadMore() {
        guard let before = nextBeforeSequence, !state.isSearching, !state.isLoadingMore else { return }
        state = RoomSearchPresentationState(query: query, rows: rows, isLoadingMore: true, hasMore: true)
        fetch(before: before, token: token)
    }

    private func fetch(before: Int64?, token: Int) {
        let sessionId = self.sessionId
        let searcher = self.searcher
        let query = self.query
        Task { [weak self] in
            do {
                let page = try await searcher.searchRoom(
                    sessionId: sessionId, query: query, beforeSequence: before, limit: Self.pageSize
                )
                guard let self, self.token == token else { return }
                var seen = Set(self.rows.map(\.sequenceId))
                self.rows += page.results.filter { seen.insert($0.sequenceId).inserted }.map(Self.row)
                self.nextBeforeSequence = page.nextBeforeSequence
                self.state = RoomSearchPresentationState(
                    query: query,
                    rows: self.rows,
                    hasMore: page.hasMore,
                    message: self.rows.isEmpty ? "No messages match \u{201C}\(query)\u{201D}." : nil
                )
            } catch {
                guard let self, self.token == token else { return }
                switch error as? SessionTransportError {
                case .reauthenticationRequired?, .notLoggedIn?: self.onReauthenticationRequired()
                default: break
                }
                self.state = RoomSearchPresentationState(
                    query: query,
                    rows: self.rows,
                    hasMore: self.nextBeforeSequence != nil,
                    message: "Search did not finish. Check your connection and try again."
                )
            }
        }
    }

    nonisolated static func row(_ result: RoomSearchResult) -> RoomSearchRow {
        RoomSearchRow(
            sequenceId: result.sequenceId,
            author: result.message?.authorName,
            isHuman: result.message?.isHuman ?? false,
            date: result.message.flatMap { ParsedSessionTimestamp($0.timestamp).date },
            snippet: result.snippet
        )
    }
}
