import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI

/// The room's search (sentinelayer-web `useSessionLiveController` `runSearch`), across everything the room holds
/// (Carter, #55006): its messages through the server's search (at least 2 characters, 10 matches a page, newest
/// first, older matches on demand), and its people and shared things (tickets, pull requests, files, checkpoints,
/// links, code) matched on the phone. Tabs narrow it to one kind. The server search runs as you type, once typing
/// pauses, and at once on submit; a newer search makes any older answer stale. "More from" keeps only what one
/// person wrote.
@MainActor
final class RoomSearchModel: ObservableObject {
    @Published private(set) var state = RoomSearchPresentationState(message: RoomSearchModel.hint)

    static let pageSize = 10
    /// How long typing must pause before the words are searched.
    static let typingPause: TimeInterval = 0.35
    static let hint = "Search this room's messages, people, tickets and files."

    private let sessionId: String
    private let searcher: any RoomSearching
    private let people: @MainActor () -> [RoomSearchPerson]
    private let artifacts: @MainActor () -> (items: [RoomArtifact], isReading: Bool)
    private let onReauthenticationRequired: @MainActor () -> Void
    /// The words in the field now (people and shared things match these at once).
    private var words = ""
    /// The words the message results are for.
    private var query = ""
    private var scope: RoomSearchScope = .all
    private var from: RoomSearchPerson?
    private var rows: [RoomSearchRow] = []
    private var nextBeforeSequence: Int64?
    private var isSearching = false
    private var isLoadingMore = false
    private var message: String?
    private var token = 0
    private var pending: Task<Void, Never>?
    private let sleep: @Sendable (TimeInterval) async -> Void

    init(
        sessionId: String,
        searcher: any RoomSearching,
        people: @escaping @MainActor () -> [RoomSearchPerson] = { [] },
        artifacts: @escaping @MainActor () -> (items: [RoomArtifact], isReading: Bool) = { ([], false) },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        onReauthenticationRequired: @escaping @MainActor () -> Void
    ) {
        self.sessionId = sessionId
        self.searcher = searcher
        self.people = people
        self.artifacts = artifacts
        self.sleep = sleep
        self.onReauthenticationRequired = onReauthenticationRequired
    }

    func send(_ intent: RoomSearchIntent) {
        switch intent {
        case .submit(let text):
            pending?.cancel()
            words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            submit(words)
        case .typed(let text):
            typed(text)
        case .loadMore:
            loadMore()
        case .scope(let scope):
            self.scope = scope
            if scope.searchesMessages, messageQuery != query { submit(words) } else { publish() }
        case .from(let person):
            from = person
            if person != nil { scope = .messages }
            submit(words)
        case .open, .openArtifact:
            break   // the room screen opens them
        }
    }

    /// The room's people or shared things changed (they are still being read): match them again.
    func sourcesChanged() {
        publish()
    }

    /// What the server searches: the words, or with only "more from" set, the person's name.
    private var messageQuery: String {
        if let from, words.unicodeScalars.count < RoomSearchPresentationState.minimumQueryLength {
            return from.isHuman ? String(from.authorId.dropFirst("human-".count)) : from.authorId
        }
        return words
    }

    private func submit(_ text: String) {
        token += 1
        let search = messageQuery
        guard scope.searchesMessages, search.unicodeScalars.count >= RoomSearchPresentationState.minimumQueryLength else {
            query = ""
            rows = []
            nextBeforeSequence = nil
            isSearching = false
            isLoadingMore = false
            message = text.isEmpty || !scope.searchesMessages ? nil
                : "Type at least \(RoomSearchPresentationState.minimumQueryLength) characters."
            publish()
            return
        }
        query = search
        rows = []
        nextBeforeSequence = nil
        isSearching = true
        isLoadingMore = false
        message = nil
        publish()
        fetch(before: nil, token: token)
    }

    /// Searches once typing pauses; each keystroke restarts the wait. People and shared things match at once.
    private func typed(_ text: String) {
        pending?.cancel()
        words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard messageQuery != query else {
            publish()
            return
        }
        guard messageQuery.unicodeScalars.count >= RoomSearchPresentationState.minimumQueryLength else {
            token += 1
            query = ""
            rows = []
            nextBeforeSequence = nil
            isSearching = false
            message = words.isEmpty && from == nil ? Self.hint : nil
            publish()
            return
        }
        publish()
        let words = self.words
        pending = Task { [weak self] in
            await self?.sleep(Self.typingPause)
            guard !Task.isCancelled else { return }
            self?.submit(words)
        }
    }

    private func loadMore() {
        guard nextBeforeSequence != nil, !isSearching, !isLoadingMore else { return }
        isLoadingMore = true
        publish()
        fetch(before: nextBeforeSequence, token: token)
    }

    private func fetch(before: Int64?, token: Int) {
        let sessionId = self.sessionId
        let searcher = self.searcher
        let query = self.query
        let author = from?.authorId.lowercased()
        Task { [weak self] in
            do {
                let page = try await searcher.searchRoom(
                    sessionId: sessionId, query: query, beforeSequence: before, limit: Self.pageSize
                )
                guard let self, self.token == token else { return }
                var seen = Set(self.rows.map(\.sequenceId))
                let kept = page.results.filter { result in
                    guard let author else { return true }
                    return result.message?.authorId.lowercased() == author
                }
                self.rows += kept.filter { seen.insert($0.sequenceId).inserted }.map(Self.row)
                self.nextBeforeSequence = page.nextBeforeSequence
                self.isSearching = false
                self.isLoadingMore = false
                self.message = self.rows.isEmpty && !page.hasMore ? "No messages match \u{201C}\(query)\u{201D}." : nil
                self.publish()
            } catch {
                guard let self, self.token == token else { return }
                switch error as? SessionTransportError {
                case .reauthenticationRequired?, .notLoggedIn?: self.onReauthenticationRequired()
                default: break
                }
                self.isSearching = false
                self.isLoadingMore = false
                self.message = "Search did not finish. Check your connection and try again."
                self.publish()
            }
        }
    }

    private func publish() {
        let shared = artifacts()
        let local = RoomSearchPresentationState.localMatches(query: words, scope: scope, people: people(),
                                                             artifacts: shared.items)
        state = RoomSearchPresentationState(
            query: query,
            rows: scope.searchesMessages ? rows : [],
            isSearching: isSearching && scope.searchesMessages,
            isLoadingMore: isLoadingMore,
            hasMore: scope.searchesMessages && nextBeforeSequence != nil,
            message: scope.searchesMessages ? message : nil,
            scope: scope,
            from: from,
            people: local.people,
            artifacts: local.artifacts,
            isReadingArtifacts: shared.isReading
        )
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
