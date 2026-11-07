import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// One author's pages, scripted, with every read recorded.
private final class ScriptedAuthorPages: RoomAuthorMessagesReading, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [RoomAuthorPage]
    private var _calls: [(author: String, before: Int64?, limit: Int)] = []

    init(_ pages: [RoomAuthorPage]) { self.pages = pages }

    var calls: [(author: String, before: Int64?, limit: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    func roomMessages(by authorId: String, sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomAuthorPage {
        lock.lock()
        defer { lock.unlock() }
        _calls.append((authorId, beforeSequence, limit))
        return pages.isEmpty ? RoomAuthorPage(messages: []) : pages.removeFirst()
    }
}

/// A room of messages: the first read gets the newest `newest`; any other page is cut from the whole room.
private final class WholeRoomTransport: RoomTransport, @unchecked Sendable {
    let room: [RoomMessage]
    let newest: Int

    init(room: [RoomMessage], newest: Int) {
        self.room = room.sorted { $0.sequenceId > $1.sequenceId }
        self.newest = newest
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        let below = room.filter { $0.sequenceId < (beforeSequence ?? .max) }
        let page = Array(below.prefix(beforeSequence == nil ? newest : limit))
        return RoomEventPage(messages: page, hasMore: below.count > page.count)
    }
    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: Array(room.filter { $0.sequenceId > fromSequence }.reversed().prefix(limit)))
    }
    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }
}

@MainActor
final class RoomMemberViewTests: XCTestCase {
    private func message(_ seq: Int64, author: String = "agent-a1", text: String? = nil) -> RoomMessage {
        RoomMessage(id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: author, authorName: author,
                    isHuman: RoomMessage.isHumanAuthor(author), text: text ?? "message \(seq)",
                    timestamp: "2026-11-04T10:00:00.000000+00:00")
    }

    private func page(_ seqs: [Int64], next: Int64?, connection: RoomAuthorConnection? = nil) -> RoomAuthorPage {
        RoomAuthorPage(messages: seqs.map { message($0) }, nextBeforeSequence: next, connection: connection)
    }

    /// Their messages come a page at a time, newest first; once a page has no next cursor the room's start is reached,
    /// and nothing more is read.
    func test_paging_stops_at_a_null_next_before_sequence() async {
        let reader = ScriptedAuthorPages([page([300, 280], next: 280), page([260, 240], next: nil), page([200], next: 180)])
        let model = RoomMemberMessagesModel(sessionId: "room_1", authorId: "agent-a1", reader: reader)
        XCTAssertTrue(model.state.canLoadMore, "nothing read yet")

        await model.loadMore()
        XCTAssertEqual(model.state.rows.map(\.sequenceId), [300, 280])
        XCTAssertTrue(model.state.canLoadMore)
        await model.loadMore()
        XCTAssertEqual(model.state.rows.map(\.sequenceId), [300, 280, 260, 240])
        XCTAssertFalse(model.state.canLoadMore, "the room's start")
        await model.loadMore()
        await model.loadMore()
        XCTAssertEqual(reader.calls.map(\.before), [nil, 280], "never a read past the room's start")
        XCTAssertEqual(reader.calls.map(\.limit), [20, 20])
        XCTAssertEqual(reader.calls.first?.author, "agent-a1")
        XCTAssertEqual(model.state.rows.map(\.sequenceId), [300, 280, 260, 240])
    }

    func test_a_cursor_that_does_not_move_back_stops_paging() async {
        let reader = ScriptedAuthorPages([page([300], next: 280), page([290], next: 280), page([100], next: 90)])
        let model = RoomMemberMessagesModel(sessionId: "room_1", authorId: "agent-a1", reader: reader)
        await model.loadMore()
        await model.loadMore()
        await model.loadMore()
        XCTAssertEqual(reader.calls.map(\.before), [nil, 280], "the same page is never read again and again")
        XCTAssertFalse(model.state.canLoadMore)
    }

    /// The API can answer a page with none of their messages and a cursor (its scan stops at a row budget, and breakout
    /// rows are filtered out). No new row shows to read on, so the read goes on by itself to where their messages are.
    func test_a_page_with_no_rows_but_a_cursor_reads_on() async {
        let reader = ScriptedAuthorPages([page([], next: 900), page([], next: 700), page([650, 600], next: 500),
                                          page([450], next: nil)])
        let model = RoomMemberMessagesModel(sessionId: "room_1", authorId: "agent-a1", reader: reader)
        await model.loadMore()
        XCTAssertEqual(reader.calls.map(\.before), [nil, 900, 700], "on past both empty pages, and no further")
        XCTAssertEqual(model.state.rows.map(\.sequenceId), [650, 600])
        XCTAssertTrue(model.state.canLoadMore)
        XCTAssertFalse(model.state.showsLoadOlder, "rows came: the list's last row reads on as it shows")
        XCTAssertEqual(model.state.phase, .idle)
    }

    /// Reading on is bounded: three more pages at most, then "Load older" shows, and each tap reads as far again.
    func test_reading_on_stops_after_three_more_pages_then_load_older_reads_on() async {
        let reader = ScriptedAuthorPages([page([], next: 9000), page([], next: 8000), page([], next: 7000),
                                          page([], next: 6000), page([], next: 5000), page([], next: 4000),
                                          page([], next: 3000), page([], next: 2000), page([1500], next: nil)])
        let model = RoomMemberMessagesModel(sessionId: "room_1", authorId: "agent-a1", reader: reader)
        await model.loadMore()
        XCTAssertEqual(reader.calls.map(\.before), [nil, 9000, 8000, 7000], "the first page and three more, no more")
        XCTAssertTrue(model.state.showsLoadOlder)
        XCTAssertEqual(model.state.emptyLine(name: "agent-a1"), "No messages from agent-a1 found so far.")

        // "Load older".
        await model.loadMore()
        XCTAssertEqual(reader.calls.map(\.before), [nil, 9000, 8000, 7000, 6000, 5000, 4000, 3000])
        XCTAssertTrue(model.state.showsLoadOlder, "still none of theirs: the button stays")

        await model.loadMore()
        XCTAssertEqual(reader.calls.last?.before, 2000)
        XCTAssertEqual(model.state.rows.map(\.sequenceId), [1500])
        XCTAssertFalse(model.state.showsLoadOlder, "the room's start")
        XCTAssertFalse(model.state.canLoadMore)
        XCTAssertNil(model.state.emptyLine(name: "agent-a1"))
    }

    /// Someone you blocked: their messages are neither read nor listed, and the list says why.
    func test_a_blocked_author_is_not_read_and_the_list_says_so() async {
        let reader = ScriptedAuthorPages([page([50], next: nil)])
        let model = RoomMemberMessagesModel(sessionId: "room_1", authorId: "human-pat", reader: reader, isBlocked: true)
        await model.loadMore()
        XCTAssertTrue(reader.calls.isEmpty)
        XCTAssertTrue(model.state.isBlocked)
        XCTAssertTrue(model.state.listedRows.isEmpty)
        XCTAssertEqual(model.state.emptyLine(name: "pat"), "You blocked them.")
        XCTAssertNil(model.state.blockReference, "and Block is not offered again")
    }

    /// Tickets f7254a3b and c96649c0: the API's "mcp" covers MCP and the CLI's own MCP server alike, so the newest
    /// post's own marks tell them apart; the CLI says so. With nothing to tell, marks that disagree with the API, or a
    /// kind this app does not name, nothing is shown.
    func test_the_card_says_which_way_an_agent_is_connected() {
        let card = RoomMemberMessagesModel.connection
        XCTAssertEqual(card(.mcp, .cliMCP), .cliMCP, "the CLI's MCP server: Connected through the CLI (MCP)")
        XCTAssertEqual(card(.mcp, .cliMCP)?.label, "Connected through the CLI (MCP)")
        XCTAssertEqual(card(nil, .cliMCP)?.label, "Connected through the CLI (MCP)")
        XCTAssertEqual(card(.mcp, .mcp), .mcp, "any other MCP: Connected through MCP")
        XCTAssertEqual(card(.mcp, .mcp)?.label, "Connected through MCP")
        XCTAssertEqual(card(.cli, .cli)?.label, "Connected through the CLI")
        XCTAssertEqual(card(nil, .cli)?.label, "Connected through the CLI")
        XCTAssertNil(card(.mcp, .cli), "mixed marks (the API's mcp, a post that says cli): no line")
        XCTAssertNil(card(.mcp, .other), "a kind not named: no line")
        XCTAssertNil(card(nil, .other))
        XCTAssertNil(card(.mcp, nil), "the API's mcp alone could be either: no line")
        XCTAssertNil(card(nil, nil), "unknown: no line")
        XCTAssertEqual(card(.box, .cli), .box, "a box stays a box")
    }

    /// The card reads the newest post that says how it was sent, never an older one; a newer post that says nothing
    /// leaves it to the one before (as the web reads it).
    func test_the_card_reads_the_newest_posts_marks() async {
        func line(newestFirst marks: [RoomPostClient?], api: RoomAuthorConnection? = .mcp) async -> String? {
            let messages = marks.enumerated().map { index, mark in
                RoomMessage(id: "evt-\(100 - index)", sequenceId: Int64(100 - index), kind: .message,
                            authorId: "agent-a1", authorName: "agent-a1", isHuman: false, text: "message",
                            timestamp: "2026-11-07T10:00:00.000000+00:00", sentThrough: mark)
            }
            let model = RoomMemberMessagesModel(
                sessionId: "room_1", authorId: "agent-a1",
                reader: ScriptedAuthorPages([RoomAuthorPage(messages: messages, nextBeforeSequence: nil,
                                                            connection: api)])
            )
            await model.loadMore()
            return model.state.connectionLine
        }
        let newestMCP = await line(newestFirst: [.mcp, .cliMCP])
        XCTAssertEqual(newestMCP, "Connected through MCP", "the newest post decides")
        let newestCLIMCP = await line(newestFirst: [.cliMCP, .mcp])
        XCTAssertEqual(newestCLIMCP, "Connected through the CLI (MCP)", "the newest post decides")
        let quietNewest = await line(newestFirst: [nil, .cliMCP, .mcp])
        XCTAssertEqual(quietNewest, "Connected through the CLI (MCP)", "a newer post that says nothing leaves it")
        let mixed = await line(newestFirst: [.cli, .cliMCP])
        XCTAssertNil(mixed, "the API's mcp and a newest post that says cli disagree: no line")
        let unnamed = await line(newestFirst: [.other, .cliMCP])
        XCTAssertNil(unnamed, "a newest post of a kind not named says nothing")
        let fromTheCLI = await line(newestFirst: [.cli, .mcp], api: nil)
        XCTAssertEqual(fromTheCLI, "Connected through the CLI")
    }

    /// For people the API usually knows no connection: nothing is shown then, never a guess.
    func test_a_null_connection_shows_nothing() async {
        let unknown = RoomMemberMessagesModel(sessionId: "room_1", authorId: "human-pat",
                                              reader: ScriptedAuthorPages([page([50], next: nil, connection: nil)]))
        await unknown.loadMore()
        XCTAssertNil(unknown.state.connection)
        XCTAssertNil(unknown.state.connectionLine, "no line at all")

        let box = RoomMemberMessagesModel(sessionId: "room_1", authorId: "agent-a1",
                                          reader: ScriptedAuthorPages([page([50], next: 40, connection: .box),
                                                                       page([30], next: nil, connection: nil)]))
        await box.loadMore()
        XCTAssertEqual(box.state.connectionLine, "Runs in a box")
        await box.loadMore()
        XCTAssertEqual(box.state.connectionLine, "Runs in a box", "a later page that says nothing takes nothing back")
    }

    /// A public room shows a visitor a person who signed in with an account id under a stand-in name
    /// (`human-public.<digest>`), and no rows carry it: nothing is asked for, and the profile says why there is no list.
    func test_a_public_alias_shows_the_private_line() async {
        let reader = ScriptedAuthorPages([page([50], next: nil)])
        let model = RoomMemberMessagesModel(sessionId: "room_1", authorId: "human-public.9f2c4e", reader: reader)
        await model.loadMore()
        XCTAssertTrue(reader.calls.isEmpty, "nothing is asked for")
        XCTAssertTrue(model.state.isPrivate)
        XCTAssertFalse(model.state.canLoadMore)
        XCTAssertEqual(model.state.emptyLine(name: "someone"), RoomMemberMessagesState.privateLine)
        XCTAssertTrue(model.state.rows.isEmpty)

        let person = RoomMemberMessagesModel(sessionId: "room_1", authorId: "human-pat",
                                             reader: ScriptedAuthorPages([page([], next: nil)]))
        await person.loadMore()
        XCTAssertEqual(person.state.emptyLine(name: "pat"), "No messages from pat in this room yet.",
                       "a member with no messages is not called private")
    }

    func test_a_read_that_fails_says_so_and_retries_the_same_page() async {
        final class Failing: RoomAuthorMessagesReading, @unchecked Sendable {
            var failures = 1
            var befores: [Int64?] = []
            func roomMessages(by authorId: String, sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomAuthorPage {
                befores.append(beforeSequence)
                if failures > 0 {
                    failures -= 1
                    throw SessionTransportError.service(statusCode: 503)
                }
                return RoomAuthorPage(messages: [], nextBeforeSequence: nil)
            }
        }
        let reader = Failing()
        let model = RoomMemberMessagesModel(sessionId: "room_1", authorId: "agent-a1", reader: reader)
        await model.loadMore()
        XCTAssertEqual(model.state.phase, .failed("Their messages couldn't load."))
        XCTAssertTrue(model.state.canLoadMore, "Retry reads it again")
        await model.loadMore()
        XCTAssertEqual(reader.befores, [nil, nil])
        XCTAssertEqual(model.state.phase, .idle)
    }

    /// Ticket 386081b1: on build 02 every card said "Their messages couldn't load" (the server answered the read with a
    /// 503). Once the read is answered, Retry shows their messages, an agent's and a person's alike, newest first.
    func test_once_the_read_is_answered_retry_shows_an_agents_and_a_persons_messages() async {
        final class FailingThenAnswer: RoomAuthorMessagesReading, @unchecked Sendable {
            var answered = false
            let page: RoomAuthorPage
            init(page: RoomAuthorPage) { self.page = page }
            func roomMessages(by authorId: String, sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomAuthorPage {
                guard answered else { throw SessionTransportError.service(statusCode: 503) }
                return page
            }
        }
        for author in ["build-agent", "human-alex"] {
            // Oldest first on purpose: the card puts them newest first itself.
            let reader = FailingThenAnswer(page: RoomAuthorPage(messages: [message(62300, author: author),
                                                                         message(62392, author: author)],
                                                              nextBeforeSequence: nil))
            let model = RoomMemberMessagesModel(sessionId: "room_1", authorId: author, reader: reader)
            await model.loadMore()
            XCTAssertEqual(model.state.phase, .failed("Their messages couldn't load."), author)
            XCTAssertTrue(model.state.rows.isEmpty, author)
            XCTAssertTrue(model.state.canLoadMore, "\(author): Retry is offered")
            XCTAssertNil(model.state.emptyLine(name: author), "\(author): after a failure, never \"no messages yet\"")
            reader.answered = true
            await model.loadMore()
            XCTAssertEqual(model.state.phase, .idle, author)
            XCTAssertEqual(model.state.rows.map(\.sequenceId), [62392, 62300], "\(author)'s messages, newest first")
            XCTAssertFalse(model.state.canLoadMore, "\(author): the room's start")
        }
    }

    /// Two taps on Retry while it reads read once: the card never reads two pages at once, and shows their messages once.
    func test_two_taps_on_retry_read_once() async {
        final class FailThenHold: RoomAuthorMessagesReading, @unchecked Sendable {
            private let lock = NSLock()
            private var reads = 0
            private var released = false
            let page: RoomAuthorPage
            init(page: RoomAuthorPage) { self.page = page }

            var calls: Int {
                lock.lock()
                defer { lock.unlock() }
                return reads
            }

            func release() {
                lock.lock()
                released = true
                lock.unlock()
            }

            private var isReleased: Bool {
                lock.lock()
                defer { lock.unlock() }
                return released
            }

            func roomMessages(by authorId: String, sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomAuthorPage {
                lock.lock()
                reads += 1
                let first = reads == 1
                lock.unlock()
                if first { throw SessionTransportError.service(statusCode: 503) }
                while !isReleased { try? await Task.sleep(nanoseconds: 2_000_000) }
                return page
            }
        }
        let reader = FailThenHold(page: RoomAuthorPage(messages: [message(10, author: "build-agent")], nextBeforeSequence: nil))
        let model = RoomMemberMessagesModel(sessionId: "room_1", authorId: "build-agent", reader: reader)
        await model.loadMore()
        XCTAssertEqual(model.state.phase, .failed("Their messages couldn't load."))
        async let first: Void = model.loadMore()
        async let second: Void = model.loadMore()
        try? await Task.sleep(nanoseconds: 50_000_000)
        reader.release()
        _ = await (first, second)
        XCTAssertEqual(reader.calls, 2, "the failed read and one Retry, never two at once")
        XCTAssertEqual(model.state.rows.map(\.sequenceId), [10], "their message, once")
        XCTAssertEqual(model.state.phase, .idle)
    }

    /// Tapping one of their messages brings that message into view in the room, by the room's own focus path: one far
    /// back is loaded around it, and the room is focused on exactly its sequence.
    func test_a_jump_focuses_the_right_sequence() async {
        let room = (1...60).map { message(Int64($0) * 10, author: $0 % 3 == 0 ? "agent-a1" : "human-pat") }
        let coordinator = RoomChatCoordinator(
            sessionId: "room_1", title: "Room",
            transport: WholeRoomTransport(room: room, newest: 10),
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            onReauthenticationRequired: {}
        )
        coordinator.resume()
        for _ in 0..<500 where coordinator.state.rows.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNil(coordinator.state.messageRow(for: 90), "far back, not loaded")

        let theirs = room.filter { $0.authorId == "agent-a1" }.sorted { $0.sequenceId > $1.sequenceId }
        let model = RoomMemberMessagesModel(sessionId: "room_1", authorId: "agent-a1",
                                            reader: ScriptedAuthorPages([RoomAuthorPage(messages: theirs, nextBeforeSequence: nil)]))
        await model.loadMore()
        let row = try? XCTUnwrap(model.state.rows.first { $0.sequenceId == 90 })
        XCTAssertEqual(row?.text, "message 90")

        // What the profile's tap does once its sheet has gone (`RoomChatScreen.focus(on:)`).
        coordinator.focus(on: row?.sequenceId ?? 0)
        XCTAssertEqual(coordinator.state.focusSequenceId, 90)
        for _ in 0..<500 where coordinator.state.messageRow(for: 90) == nil { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertNotNil(coordinator.state.messageRow(for: 90), "loaded around it")
        XCTAssertEqual(coordinator.state.focusSequenceId, 90, "and focused on exactly that one")
        coordinator.pause()
    }
}
