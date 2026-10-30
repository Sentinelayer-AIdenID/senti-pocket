import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI

/// The room's message search (sentinelayer-web `useSessionLiveController` `runSearch`): at least 2 characters, 10
/// matches a page, newest first, older matches on demand. It runs as you type, once typing pauses, and at once on
/// submit. A newer search makes any older answer stale.
@MainActor
final class RoomSearchModel: ObservableObject {
    @Published private(set) var state = RoomSearchPresentationState(
        message: "Search this room's messages by words, names or agents."
    )

    static let pageSize = 10
    /// How long typing must pause before the words are searched.
    static let typingPause: TimeInterval = 0.35

    private let sessionId: String
    private let searcher: any RoomSearching
    private let onReauthenticationRequired: @MainActor () -> Void
    private var query = ""
    private var rows: [RoomSearchRow] = []
    private var nextBeforeSequence: Int64?
    private var token = 0
    private var pending: Task<Void, Never>?
    private let sleep: @Sendable (TimeInterval) async -> Void

    init(
        sessionId: String,
        searcher: any RoomSearching,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        self.sessionId = sessionId
        self.searcher = searcher
        self.sleep = sleep
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    func send(_ intent: RoomSearchIntent) {
        switch intent {
        case .submit(let text):
            pending?.cancel()
            submit(text)
        case .typed(let text):
            typed(text)
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

    /// Searches once typing pauses; each keystroke restarts the wait. Fewer than 2 characters clears quietly.
    private func typed(_ text: String) {
        pending?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query else { return }
        guard trimmed.unicodeScalars.count >= RoomSearchPresentationState.minimumQueryLength else {
            token += 1
            query = ""
            rows = []
            nextBeforeSequence = nil
            state = RoomSearchPresentationState(message: "Search this room's messages by words, names or agents.")
            return
        }
        pending = Task { [weak self] in
            await self?.sleep(Self.typingPause)
            guard !Task.isCancelled else { return }
            self?.submit(trimmed)
        }
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
