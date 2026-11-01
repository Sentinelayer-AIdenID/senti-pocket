import Foundation
import PocketContracts
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

/// The room's history as pages: the newest page first, the one message at a place, and windows further back. Records
/// every read of one message.
private final class BoardRoom: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let newest: [RoomMessage]
    private let older: [RoomMessage]
    private let singles: [Int64: [RoomMessage]]
    private var failures: Set<Int64>
    private var actions: [RoomActionsPage]
    private var singleReads: [Int64] = []

    init(newest: [RoomMessage], older: [RoomMessage] = [], singles: [Int64: [RoomMessage]] = [:],
         failOnce: Set<Int64> = [], actions: [RoomActionsPage]) {
        self.newest = newest
        self.older = older
        self.singles = singles
        self.failures = failOnce
        self.actions = actions
    }

    /// The places read one message at a time.
    var reads: [Int64] { locked { singleReads } }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        try locked {
            guard let before = beforeSequence else {
                return RoomEventPage(messages: newest, nextBeforeSequence: newest.first?.sequenceId, hasMore: true)
            }
            if limit == 1 {
                let place = before - 1
                singleReads.append(place)
                if failures.remove(place) != nil { throw SessionTransportError.network }
                return RoomEventPage(messages: singles[place] ?? [], nextBeforeSequence: nil, hasMore: true)
            }
            let rows = older.filter { $0.sequenceId < before }.suffix(limit)
            return RoomEventPage(messages: Array(rows), nextBeforeSequence: rows.first?.sequenceId, hasMore: true)
        }
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        locked {
            let rows = older.filter { $0.sequenceId > fromSequence }.prefix(limit)
            return RoomEventPage(messages: Array(rows), nextBeforeSequence: nil, hasMore: true)
        }
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }

    /// Each read of the actions answers the next page given; the last one stays.
    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage {
        locked { actions.count > 1 ? actions.removeFirst() : (actions.first ?? RoomActionsPage()) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// A room that keeps a leaderboard pinned (a message starting with the trophy, edited as the scores change) shows a
/// Leaderboard button under its title, which opens it as a pin opens, exactly when the state's `leaderboard` is set.
/// The pinned message's text is known wherever it is in the room, and follows its edits.
@MainActor
final class RoomLeaderboardTests: XCTestCase {
    private static let boardText = "🏆 Who's helping most in this room\n\n"
        + "🥇 **ada-agent** · SentiLab team · 42.0 pts · 9 helpful\n"
        + "🥈 **lin-agent** · 31.5 pts · 7 helpful\n\n"
        + "How it works: answers that close a question score points (last 13:58 UTC)."

    private func message(_ seq: Int64, _ text: String? = nil, revision: Int64 = 1,
                         author: String = "ada-agent") -> RoomMessage {
        RoomMessage(id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: author, authorName: author,
                    isHuman: false, text: text ?? "Note \(seq).", timestamp: "2026-10-31T14:00:00Z",
                    revision: revision, isEdited: revision > 1)
    }

    private func pins(_ seqs: Int64...) -> RoomActionsPage {
        RoomActionsPage(pinned: seqs.map {
            RoomPinnedMessage(id: "pin-\($0)", targetSequenceId: $0, pinnedBy: "board-keeper")
        })
    }

    private func room(_ transport: BoardRoom) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Help",
            transport: transport,
            membershipRole: "contributor",
            ownAuthorIds: ["human-sam"],
            sleep: { seconds in
                if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            },
            onReauthenticationRequired: {}
        )
    }

    private func waitUntil(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)", file: file, line: line)
    }

    /// Lets every task the room started run as far as it can.
    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private var newestPage: [RoomMessage] { (290...300).map { message(Int64($0)) } }

    func test_no_trophy_without_a_pin_that_starts_with_one() async {
        let transport = BoardRoom(newest: newestPage, actions: [pins(298, 295)])
        let room = room(transport)
        room.resume()
        await waitUntil("pins loaded") { room.state.pinned.count == 2 }
        XCTAssertNil(room.state.leaderboard)
        XCTAssertEqual(transport.reads, [], "both pinned messages are in the loaded rows")
        room.pause()
    }

    /// The board is pinned far up the room: its one message is read at its place, once, and the trophy shows.
    func test_a_board_pinned_far_up_the_room_is_read_once_and_shows_the_trophy() async {
        let transport = BoardRoom(newest: newestPage, singles: [57: [message(57, Self.boardText)]],
                                  actions: [pins(298, 57)])
        let room = room(transport)
        room.resume()
        await waitUntil("the board read") { room.state.leaderboard != nil }
        XCTAssertEqual(room.state.leaderboard?.sequenceId, 57)
        XCTAssertEqual(room.state.leaderboard?.snippet, "🏆 Who's helping most in this room")
        XCTAssertEqual(room.state.pinned.map(\.sequenceId), [298, 57], "the strip keeps the room's order")

        await room.refreshActions(force: true)
        await settle()
        XCTAssertEqual(transport.reads, [57], "read once")
        room.pause()
    }

    /// The board's edits come live: its text follows them, and an edit that takes the trophy away takes the button.
    func test_the_trophy_follows_the_boards_edits() async {
        let transport = BoardRoom(newest: newestPage, singles: [57: [message(57, Self.boardText)]],
                                  actions: [pins(57)])
        let room = room(transport)
        room.resume()
        await waitUntil("the board read") { room.state.leaderboard != nil }

        room.handle(.edited(message(57, "🏆 Who's helping most in this room (updated)\n1. lin-agent", revision: 2),
                            sequenceId: 301))
        XCTAssertEqual(room.state.leaderboard?.snippet, "🏆 Who's helping most in this room (updated)")
        room.handle(.edited(message(57, "Scores are paused this week.", revision: 3), sequenceId: 302))
        XCTAssertNil(room.state.leaderboard, "no longer a leaderboard")
        XCTAssertEqual(room.state.pinned.first?.snippet, "Scores are paused this week.")
        room.handle(.edited(message(57, "🏆 Older edit arriving late", revision: 2), sequenceId: 303))
        XCTAssertNil(room.state.leaderboard, "an older revision never wins")
        room.pause()
    }

    /// A read that failed is tried at the room's next read of its pins; a place holding no message is not.
    func test_a_failed_read_is_tried_again_and_a_place_with_no_message_is_not() async {
        let transport = BoardRoom(newest: newestPage, singles: [57: [message(57, Self.boardText)]], failOnce: [57],
                                  actions: [pins(57, 12)])
        let room = room(transport)
        room.resume()
        await waitUntil("both read once") { transport.reads.count == 2 }
        await settle()
        XCTAssertNil(room.state.leaderboard, "the read failed")

        await room.refreshActions(force: true)
        await waitUntil("the board read again") { room.state.leaderboard?.sequenceId == 57 }
        await room.refreshActions(force: true)
        await settle()
        XCTAssertEqual(transport.reads.sorted(), [12, 57, 57], "12 holds no message: asked once")
        room.pause()
    }

    /// Unpinned, the board and its trophy go; pinned again, it is read again rather than shown as it was.
    func test_a_board_unpinned_then_pinned_again_is_read_again() async {
        let transport = BoardRoom(newest: newestPage, singles: [57: [message(57, Self.boardText)]],
                                  actions: [pins(57), pins(298), pins(57)])
        let room = room(transport)
        room.resume()
        await waitUntil("the board read") { room.state.leaderboard != nil }

        await room.refreshActions(force: true)
        XCTAssertNil(room.state.leaderboard, "unpinned")
        await room.refreshActions(force: true)
        await waitUntil("pinned again and read") { room.state.leaderboard?.sequenceId == 57 }
        XCTAssertEqual(transport.reads, [57, 57])
        room.pause()
    }

    /// The board in the loaded rows needs no read; when the rows move to a window further back, it keeps its text.
    func test_a_board_in_the_loaded_rows_keeps_its_trophy_when_the_rows_move_away() async {
        let older = (40...160).map { message(Int64($0)) }
        let newest = (290...299).map { message(Int64($0)) } + [message(300, Self.boardText)]
        let transport = BoardRoom(newest: newest, older: older, actions: [pins(300)])
        let room = room(transport)
        room.resume()
        await waitUntil("pins loaded") { room.state.leaderboard?.sequenceId == 300 }

        room.send(.jumpToMessage(sequenceId: 90))
        await waitUntil("the window around 90") {
            room.state.rows.contains { row in
                if case .message(let message) = row { return message.sequenceId == 90 }
                return false
            }
        }
        await settle()
        XCTAssertFalse(room.state.rows.contains { row in
            if case .message(let message) = row { return message.sequenceId == 300 }
            return false
        }, "the board's row has left the loaded rows")
        XCTAssertEqual(room.state.leaderboard?.sequenceId, 300, "and the trophy stays")
        XCTAssertEqual(transport.reads, [], "with no read of its own")
        room.pause()
    }

    // MARK: - The sheet

    private func shownRows(_ room: RoomChatCoordinator) -> [String]? {
        guard case .board(let board)? = room.state.leaderboardSheet?.content else { return nil }
        return board.rows.map(\.name)
    }

    /// The trophy opens the board as a ranked list in a sheet (never a jump to the message), and Done closes it.
    func test_the_trophy_opens_the_board_as_a_list() async {
        let transport = BoardRoom(newest: newestPage, singles: [57: [message(57, Self.boardText)]],
                                  actions: [pins(57)])
        let room = room(transport)
        room.resume()
        await waitUntil("the board read") { room.state.leaderboard != nil }
        XCTAssertNil(room.state.leaderboardSheet, "closed until asked")

        room.send(.openLeaderboard)
        XCTAssertEqual(shownRows(room), ["ada-agent", "lin-agent"])
        XCTAssertEqual(room.state.leaderboardSheet?.sequenceId, 57)
        XCTAssertNil(room.state.focusSequenceId, "the room stays where it was")
        room.send(.closeLeaderboard)
        XCTAssertNil(room.state.leaderboardSheet)
        room.pause()
    }

    /// While it is open, the list follows the board's edits: the standings change in place.
    func test_an_edit_updates_the_open_board() async {
        let transport = BoardRoom(newest: newestPage, singles: [57: [message(57, Self.boardText)]],
                                  actions: [pins(57)])
        let room = room(transport)
        room.resume()
        await waitUntil("the board read") { room.state.leaderboard != nil }
        room.send(.openLeaderboard)

        let swapped = "🏆 Who's helping most in this room\n\n"
            + "🥇 **lin-agent** · 45.5 pts · 10 helpful ▲1\n"
            + "🥈 **ada-agent** · SentiLab team · 42.0 pts · 9 helpful ▼1\n"
            + "🥉 **sam** (person) · 3.0 pts · 1 helpful 🆕"
        room.handle(.edited(message(57, swapped, revision: 2), sequenceId: 301))
        XCTAssertEqual(shownRows(room), ["lin-agent", "ada-agent", "sam"])
        guard case .board(let board)? = room.state.leaderboardSheet?.content else { return XCTFail("no board") }
        XCTAssertEqual(board.rows.map(\.move), [.up(1), .down(1), .new])
        room.pause()
    }

    /// An edit that leaves no row to read shows "Board unavailable", never the message's raw text.
    func test_an_unreadable_board_falls_back() async {
        let transport = BoardRoom(newest: newestPage, singles: [57: [message(57, Self.boardText)]],
                                  actions: [pins(57)])
        let room = room(transport)
        room.resume()
        await waitUntil("the board read") { room.state.leaderboard != nil }
        room.send(.openLeaderboard)
        room.handle(.edited(message(57, "🏆 Who's helping most in this room\n\nRecounting, back soon.", revision: 2),
                            sequenceId: 301))
        XCTAssertEqual(room.state.leaderboardSheet?.content, .unavailable)
        room.pause()
    }

    /// The board is read on its own at revision 1, then shows at revision 2 in a window loaded around it ("Open
    /// message"). Back at the latest messages, the window gone, it stays at revision 2: a board never goes back to an
    /// older revision because the rows that held the newer one were let go.
    func test_a_newer_board_seen_in_a_loaded_window_stays_after_the_window_goes() async {
        let newer = Self.boardText.replacingOccurrences(of: "42.0 pts", with: "99.0 pts")
        let older = (40...160).map { seq in
            seq == 57 ? message(57, newer, revision: 2) : message(Int64(seq))
        }
        let transport = BoardRoom(newest: newestPage, older: older, singles: [57: [message(57, Self.boardText)]],
                                  actions: [pins(57)])
        let room = room(transport)
        room.resume()
        await waitUntil("the board read at revision 1") { room.state.leaderboard?.text.contains("42.0 pts") == true }

        room.send(.jumpToMessage(sequenceId: 57))
        await waitUntil("revision 2 in the window around it") {
            room.state.leaderboard?.text.contains("99.0 pts") == true
        }
        room.send(.focusHandled)
        room.send(.jumpToLatest)
        await waitUntil("back at the latest messages, the window gone") {
            room.state.rows.contains { row in
                if case .message(let message) = row { return message.sequenceId == 300 }
                return false
            } && !room.state.rows.contains { row in
                if case .message(let message) = row { return message.sequenceId == 57 }
                return false
            }
        }
        await settle()
        XCTAssertEqual(room.state.leaderboard?.text, newer, "revision 2 stays")
        room.send(.openLeaderboard)
        guard case .board(let board)? = room.state.leaderboardSheet?.content else { return XCTFail("no board") }
        XCTAssertEqual(board.rows.first?.points, "99.0")
        XCTAssertEqual(transport.reads, [57], "read on its own once, at revision 1")
        room.pause()
    }

    /// An open board that is unpinned closes; pinned again, it stays closed until it is opened again.
    func test_an_unpinned_board_closes_its_sheet_and_stays_closed_when_pinned_again() async {
        let transport = BoardRoom(newest: newestPage, singles: [57: [message(57, Self.boardText)]],
                                  actions: [pins(57), pins(298), pins(57)])
        let room = room(transport)
        room.resume()
        await waitUntil("the board read") { room.state.leaderboard != nil }
        room.send(.openLeaderboard)
        XCTAssertNotNil(room.state.leaderboardSheet)

        await room.refreshActions(force: true)
        XCTAssertNil(room.state.leaderboard, "unpinned")
        XCTAssertNil(room.state.leaderboardSheet)
        await room.refreshActions(force: true)
        await waitUntil("pinned again and read") { room.state.leaderboard?.sequenceId == 57 }
        XCTAssertNil(room.state.leaderboardSheet, "closed until opened again")
        room.send(.openLeaderboard)
        XCTAssertNotNil(room.state.leaderboardSheet)
        room.pause()
    }

    /// A board message as its event comes over the wire, with a `payload.postedBy` saying the room's owner posted it.
    private func claimingOwner(_ seq: Int64, _ text: String, author: String, revision: Int64 = 1) -> JSONValue {
        .object([
            "id": .string("evt-\(seq)"), "sequenceId": .int(seq), "event": .string("session_message"),
            "agent": .object(["id": .string(author)]), "messageRevision": .int(revision),
            "ts": .string("2026-10-31T14:00:00Z"),
            "payload": .object([
                "message": .string(text),
                "postedBy": .object(["isRoomOwner": .bool(true), "external": .bool(false)]),
            ]),
        ])
    }

    /// A member's board whose event says the room's owner posted it is read as any member's board: the newer board
    /// wins over it, and an edit saying the same changes nothing. Whoever posted the board, the open sheet holds the
    /// board and nothing about its poster: the poster line is removed until the server provides a verified poster.
    func test_a_claim_that_the_owner_posted_a_board_changes_nothing_and_the_sheet_names_no_poster() async throws {
        let theirs = Self.boardText.replacingOccurrences(of: "**ada-agent**", with: "**mallory**")
        let claimed = try XCTUnwrap(RoomMessage(json: claimingOwner(57, theirs, author: "mallory")))
        let transport = BoardRoom(
            newest: newestPage,
            singles: [57: [claimed], 60: [message(60, Self.boardText, author: "room-host")]],
            actions: [pins(60, 57), pins(57)]
        )
        let room = room(transport)
        room.resume()
        await waitUntil("both read") {
            room.state.pinned.count == 2 && room.state.pinned.allSatisfy { !$0.text.isEmpty }
        }
        XCTAssertEqual(room.state.leaderboard?.sequenceId, 60, "the newer board")

        let edit = try XCTUnwrap(RoomMessage.edited(from: .object([
            "id": .string("evt-301"), "sequenceId": .int(301), "event": .string("session_message_edited"),
            "payload": .object([
                "targetSequenceId": .int(57), "targetMessageId": .string("evt-57"),
                "event": claimingOwner(57, theirs + " ", author: "mallory", revision: 2),
            ]),
        ])))
        room.handle(.edited(edit, sequenceId: 301))
        XCTAssertEqual(room.state.pinned.last?.text, theirs + " ", "the edit is in")
        XCTAssertEqual(room.state.leaderboard?.sequenceId, 60, "and changes nothing")
        room.send(.openLeaderboard)
        let newer = try XCTUnwrap(RoomLeaderboard.parse(Self.boardText))
        XCTAssertEqual(room.state.leaderboardSheet, RoomChatLeaderboardSheet(sequenceId: 60, content: .board(newer)))
        room.send(.closeLeaderboard)

        await room.refreshActions(force: true)
        XCTAssertEqual(room.state.pinned.map(\.sequenceId), [57], "the newer board unpinned")
        XCTAssertEqual(room.state.leaderboard?.sequenceId, 57)
        room.send(.openLeaderboard)
        let edited = try XCTUnwrap(RoomLeaderboard.parse(theirs + " "))
        XCTAssertEqual(room.state.leaderboardSheet, RoomChatLeaderboardSheet(sequenceId: 57, content: .board(edited)))
        room.pause()
    }

    /// Asked to open before the board's message is read (a link, or the room opening with it), the sheet waits and
    /// shows the board once it is read.
    func test_an_open_asked_before_the_board_is_read_shows_it_once_read() async {
        let transport = BoardRoom(newest: newestPage, singles: [57: [message(57, Self.boardText)]],
                                  actions: [pins(57)])
        let room = room(transport)
        room.send(.openLeaderboard)
        XCTAssertNil(room.state.leaderboardSheet, "no board yet")
        room.resume()
        await waitUntil("the board read and shown") { room.state.leaderboardSheet != nil }
        XCTAssertEqual(room.state.leaderboardSheet?.sequenceId, 57)
        room.pause()
    }
}
