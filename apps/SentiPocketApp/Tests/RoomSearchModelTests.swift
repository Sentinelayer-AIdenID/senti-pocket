import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class ScriptedSearch: RoomSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [Result<RoomSearchPage, Error>]
    /// Answers by query when set, so concurrent searches cannot swap their answers.
    private let byQuery: [String: RoomSearchPage]
    private var calls: [(query: String, before: Int64?)] = []
    /// Holds each answer until released, so a test can make an older answer arrive late.
    private let gate: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ pages: [Result<RoomSearchPage, Error>] = [], byQuery: [String: RoomSearchPage] = [:], gate: Bool = false) {
        self.pages = pages
        self.byQuery = byQuery
        self.gate = gate
    }

    func searchRoom(sessionId: String, query: String, beforeSequence: Int64?, limit: Int) async throws -> RoomSearchPage {
        let next: Result<RoomSearchPage, Error> = lock.withLock {
            calls.append((query, beforeSequence))
            if let page = byQuery[query] { return .success(page) }
            return pages.isEmpty ? .success(RoomSearchPage(query: query)) : pages.removeFirst()
        }
        if gate { await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } } }
        return try next.get()
    }

    /// Answers the newest search first, so the older answer arrives last: the one a model must not show.
    func releaseNewestFirst() async {
        let all: [CheckedContinuation<Void, Never>] = lock.withLock {
            defer { waiting.removeAll() }
            return waiting
        }
        for continuation in all.reversed() {
            continuation.resume()
            for _ in 0..<20 { await Task.yield() }
        }
    }

    func recorded() -> [(query: String, before: Int64?)] {
        lock.withLock { calls }
    }

    func waitingCount() -> Int {
        lock.withLock { waiting.count }
    }
}

@MainActor
final class RoomSearchModelTests: XCTestCase {
    /// Carter (#54900): matches should come as you type, once you pause, without a search per keystroke.
    func test_typing_searches_once_after_a_pause_and_short_words_clear_quietly() async {
        let search = ScriptedSearch()
        let model = RoomSearchModel(
            sessionId: "room_1",
            searcher: search,
            sleep: { _ in try? await Task.sleep(nanoseconds: 40_000_000) },
            onReauthenticationRequired: {}
        )
        model.send(.typed("ch"))
        model.send(.typed("che"))
        model.send(.typed("chec"))
        for _ in 0..<200 where search.recorded().isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(search.recorded().map(\.query), ["chec"], "one search, for the words at the pause")
        model.send(.typed("c"))
        XCTAssertTrue(model.state.rows.isEmpty)
        XCTAssertTrue(model.state.query.isEmpty, "fewer than 2 characters clears without an error")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(search.recorded().count, 1)
    }

    private func result(_ seq: Int64, _ snippet: String) -> RoomSearchResult {
        RoomSearchResult(sequenceId: seq, snippet: snippet, message: RoomMessage(
            id: "e\(seq)", sequenceId: seq, kind: .message, authorId: "review-agent", authorName: "review-agent",
            isHuman: false, text: snippet, timestamp: "2026-10-28T18:00:00Z"
        ))
    }

    private func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    func test_a_short_query_asks_for_more_and_sends_nothing() {
        let search = ScriptedSearch([])
        let model = RoomSearchModel(sessionId: "room_1", searcher: search, onReauthenticationRequired: {})
        model.send(.submit(" a "))
        XCTAssertEqual(model.state.message, "Type at least 2 characters.")
        XCTAssertTrue(search.recorded().isEmpty)
    }

    func test_matches_come_newest_first_and_older_ones_load_on_demand_once_each() async {
        let search = ScriptedSearch([
            .success(RoomSearchPage(query: "paste", results: [result(52, "runs on paste"), result(47, "paste skips")], nextBeforeSequence: 47)),
            .success(RoomSearchPage(query: "paste", results: [result(47, "paste skips"), result(12, "paste test")]))
        ])
        let model = RoomSearchModel(sessionId: "room_1", searcher: search, onReauthenticationRequired: {})
        model.send(.submit("  paste "))
        XCTAssertTrue(model.state.isSearching)
        await waitUntil("first page") { model.state.rows.count == 2 }
        XCTAssertEqual(model.state.query, "paste")
        XCTAssertTrue(model.state.hasMore)
        XCTAssertEqual(model.state.rows.first?.author, "review-agent")

        model.send(.loadMore)
        await waitUntil("second page") { model.state.rows.count == 3 }
        XCTAssertEqual(model.state.rows.map(\.sequenceId), [52, 47, 12], "a match already listed is not repeated")
        XCTAssertFalse(model.state.hasMore)
        XCTAssertEqual(search.recorded().map(\.before), [nil, 47])
    }

    func test_a_newer_search_makes_an_older_answer_stale() async {
        let search = ScriptedSearch(byQuery: [
            "old": RoomSearchPage(query: "old", results: [result(9, "old match")]),
            "new": RoomSearchPage(query: "new", results: [result(30, "new match")])
        ], gate: true)
        let model = RoomSearchModel(sessionId: "room_1", searcher: search, onReauthenticationRequired: {})
        model.send(.submit("old"))
        model.send(.submit("new"))
        await waitUntil("both waiting") { search.waitingCount() == 2 }
        await search.releaseNewestFirst()
        await waitUntil("new results") { model.state.rows.map(\.sequenceId) == [30] }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.state.rows.map(\.sequenceId), [30], "the old answer never replaces the new one")
        XCTAssertEqual(model.state.query, "new")
    }

    private func artifact(_ id: String, _ kind: RoomArtifact.Kind, _ title: String, sequence: Int64) -> RoomArtifact {
        RoomArtifact(id: id, kind: kind, title: title, detail: nil, url: nil, sequenceId: sequence,
                     author: "ticket-keeper", date: nil, mentions: 1)
    }

    /// Carter (#55006): one search across everything, narrowed by tabs.
    func test_people_and_shared_things_match_at_once_and_tabs_narrow_them() {
        let search = ScriptedSearch()
        let model = RoomSearchModel(
            sessionId: "room_1",
            searcher: search,
            people: {
                [RoomSearchPerson(authorId: "claude-warden", name: "claude-warden", isHuman: false),
                 RoomSearchPerson(authorId: "human-mrrcarter", name: "mrrcarter", isHuman: true)]
            },
            artifacts: {
                ([self.artifact("t1", .ticket, "Make tickets clickable", sequence: 5),
                  self.artifact("f1", .file, "crash report.txt", sequence: 6),
                  self.artifact("c1", .checkpoint, "Voice room shipped", sequence: 7)], false)
            },
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            onReauthenticationRequired: {}
        )
        model.send(.typed("tickets"))
        XCTAssertEqual(model.state.artifacts.map(\.id), ["t1"], "a ticket matches as you type, before any server search")
        XCTAssertTrue(model.state.people.isEmpty)
        model.send(.typed("warden"))
        XCTAssertEqual(model.state.people.map(\.authorId), ["claude-warden"])
        model.send(.typed("crash"))
        model.send(.scope(.artifacts(.file)))
        XCTAssertEqual(model.state.scope, .artifacts(.file))
        XCTAssertEqual(model.state.artifacts.map(\.id), ["f1"])
        XCTAssertTrue(model.state.rows.isEmpty, "the Files tab shows no messages")
        model.send(.scope(.artifacts(.ticket)))
        XCTAssertTrue(model.state.artifacts.isEmpty, "the Tickets tab holds no file")
    }

    /// Carter (#54900): search by person, "more from" them.
    func test_more_from_a_person_keeps_only_what_they_wrote() async {
        let warden = RoomSearchResult(sequenceId: 40, snippet: "deploy is green", message: RoomMessage(
            id: "e40", sequenceId: 40, kind: .message, authorId: "claude-warden", authorName: "claude-warden",
            isHuman: false, text: "deploy is green", timestamp: "2026-10-28T18:00:00Z"))
        let search = ScriptedSearch(byQuery: [
            "claude-warden": RoomSearchPage(query: "claude-warden", results: [result(41, "@claude-warden please look"), warden]),
            "mrrcarter": RoomSearchPage(query: "mrrcarter", results: [])
        ])
        let model = RoomSearchModel(sessionId: "room_1", searcher: search, onReauthenticationRequired: {})
        model.send(.from(RoomSearchPerson(authorId: "claude-warden", name: "claude-warden", isHuman: false)))
        XCTAssertEqual(model.state.scope, .messages)
        await waitUntil("their messages") { !model.state.isSearching && !model.state.rows.isEmpty }
        XCTAssertEqual(model.state.rows.map(\.sequenceId), [40], "a message that only mentions them is left out")
        XCTAssertEqual(model.state.from?.authorId, "claude-warden")
        model.send(.from(RoomSearchPerson(authorId: "human-mrrcarter", name: "mrrcarter", isHuman: true)))
        await waitUntil("a person's login") { search.recorded().last?.query == "mrrcarter" }
    }

    func test_no_matches_and_a_failed_search_say_so() async {
        let search = ScriptedSearch([
            .success(RoomSearchPage(query: "zzz")),
            .failure(SessionTransportError.reauthenticationRequired)
        ])
        var reauth = 0
        let model = RoomSearchModel(sessionId: "room_1", searcher: search, onReauthenticationRequired: { reauth += 1 })
        model.send(.submit("zzz"))
        await waitUntil("no matches") { model.state.message?.hasPrefix("No messages match") == true }
        model.send(.submit("again"))
        await waitUntil("failure") { model.state.message?.hasPrefix("Search did not finish") == true }
        XCTAssertEqual(reauth, 1, "an expired sign-in asks you to sign in again")
    }
}
