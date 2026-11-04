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

    /// A public room shows a person to a reader outside it as `human-public.<digest>`, and asking by that answers
    /// nothing: the profile says their messages are private there instead of showing an empty list.
    func test_a_public_alias_shows_the_private_line() async {
        let reader = ScriptedAuthorPages([page([50], next: nil)])
        let model = RoomMemberMessagesModel(sessionId: "room_1", authorId: "human-public.9f2c4e", reader: reader)
        await model.loadMore()
        XCTAssertTrue(reader.calls.isEmpty, "nothing is asked for")
        XCTAssertTrue(model.state.isPrivate)
        XCTAssertFalse(model.state.canLoadMore)
        XCTAssertEqual(model.state.emptyLine(name: "someone"), "Messages from people are private in public rooms")
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
