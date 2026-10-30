import Foundation
import XCTest
@testable import PocketUI

/// Carter's #55014: who is talking shows at a glance.
final class RoomChatDensityTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func input(_ id: String, seq: Int64, at seconds: TimeInterval, author: String,
                       kind: RoomChatMessageInput.Kind = .message, text: String = "hi") -> RoomChatMessageInput {
        RoomChatMessageInput(
            id: id,
            sequenceId: seq,
            kind: kind,
            authorId: author,
            authorName: author,
            isHuman: author.hasPrefix("human-"),
            text: text,
            timestamp: "",
            date: Date(timeIntervalSince1970: 1_800_000_000 + seconds)
        )
    }

    private func rows(_ state: RoomChatPresentationState) -> [RoomChatMessageRow] {
        state.rows.compactMap { row in
            if case .message(let message) = row { return message }
            return nil
        }
    }

    func test_a_turn_starts_only_where_the_room_changes_hands() {
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: [
            input("m1", seq: 1, at: 0, author: "human-mrrcarter"),
            input("a2", seq: 2, at: 60, author: "claude-warden"),
            input("a3", seq: 3, at: 70, author: "claude-warden"),
            input("b4", seq: 4, at: 80, author: "ticket-keeper"),
            input("m5", seq: 5, at: 90, author: "human-mrrcarter"),
            input("m6", seq: 6, at: 100, author: "human-mrrcarter"),
            input("c7", seq: 7, at: 110, author: "senti", kind: .checkpoint, text: "Checkpoint"),
            input("a8", seq: 8, at: 120, author: "claude-warden")
        ], calendar: utc)
        let turns = Dictionary(uniqueKeysWithValues: rows(state).map { ($0.id, $0.startsTurn) })
        XCTAssertEqual(turns["m1"], false, "the first message follows the day's header")
        XCTAssertEqual(turns["a2"], true, "an agent after a person")
        XCTAssertEqual(turns["a3"], false, "the same agent again")
        XCTAssertEqual(turns["b4"], false, "another agent: a new header, not a new turn")
        XCTAssertEqual(turns["m5"], true, "a person after an agent")
        XCTAssertEqual(turns["m6"], false)
        XCTAssertEqual(turns["a8"], false, "a checkpoint is a break of its own")
    }

    private func reply(_ id: String, to parent: Int64, at seconds: TimeInterval, author: String, text: String) -> RoomChatMessageInput {
        RoomChatMessageInput(
            id: "reply-\(id)",
            sequenceId: parent,
            kind: .message,
            authorId: author,
            authorName: author,
            isHuman: author.hasPrefix("human-"),
            text: text,
            timestamp: "",
            replyToSequenceId: parent,
            date: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
            inlineReplyId: id
        )
    }

    func test_background_chatter_is_one_quiet_line_unless_it_is_said_to_you() {
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: [
            input("m1", seq: 1, at: 0, author: "human-mrrcarter", text: "Can someone look at the build?"),
            input("o2", seq: 2, at: 10, author: "respawn-orchestrator", text: "[cost] astra: $1.20 est over 9 calls"),
            input("t3", seq: 3, at: 20, author: "ticket-keeper", text: "🎫 2 new from #1: P2 [Ticket: Fix it](/x)"),
            input("a4", seq: 4, at: 30, author: "ds-omar", text: "@claude-warden READY FOR CARRY: 71ff3fa"),
            input("b5", seq: 5, at: 40, author: "astra", text: "test ⟂ speech c705 · model · managed · life 00e3c6a10829"),
            input("a6", seq: 6, at: 50, author: "pocket-forge", text: "@mrrCarter build 14 is out"),
            input("a7", seq: 7, at: 60, author: "claude-warden", text: "@all heads up: deploy at 3"),
            input("a8", seq: 8, at: 70, author: "pocket-forge", text: "Build 14 is on TestFlight."),
            input("h9", seq: 9, at: 80, author: "human-griff", text: "@claude-warden hi")
        ], ownAuthorIds: ["human-mrrcarter"], replies: [
            reply("r1", to: 1, at: 90, author: "claude-warden", text: "@pocket-forge can you take this?")
        ], calendar: utc)
        let quiet = Dictionary(uniqueKeysWithValues: rows(state).map { ($0.id, $0.isQuiet) })
        XCTAssertEqual(quiet["o2"], true, "the orchestrator's cost line")
        XCTAssertEqual(quiet["t3"], true, "the ticket keeper")
        XCTAssertEqual(quiet["a4"], true, "an agent speaking to another agent")
        XCTAssertEqual(quiet["b5"], true, "a box's signed speech")
        XCTAssertEqual(quiet["a6"], false, "it mentions you")
        XCTAssertEqual(quiet["a7"], false, "@all is you too")
        XCTAssertEqual(quiet["a8"], false, "said to the whole room")
        XCTAssertEqual(quiet["h9"], false, "people are never background")
        XCTAssertEqual(quiet["m1"], false)
        XCTAssertEqual(quiet["reply-r1"], false, "said in a thread you started")
        XCTAssertEqual(RoomChatQuiet.line("**READY** for [carry](/x)\nmore ⟂ speech 1"), "READY for carry")
        XCTAssertEqual(RoomChatQuiet.line("test ⟂ speech c705 · life 1"), "test")
    }

    func test_a_box_thread_is_one_line_with_the_box_and_its_status() {
        let launch = """
        🚀 Minted astra-breakout-api3 on gpt-6-astra for ticket 1a2b3c4d (Breakouts (API) fix): its own machine \
        (life cfa292ca3e18), until 03:30Z unless extended.
        It works in its box and reports here as astra-breakout-api3; messages in this room reach it.
        """
        let messages = [
            input("m1", seq: 1, at: 0, author: "human-mrrcarter", text: "Start the breakout work"),
            input("l10", seq: 10, at: 10, author: "respawn-orchestrator", text: launch),
            input("m11", seq: 11, at: 400, author: "claude-warden", text: "Deploy is green.")
        ]
        let replies = [
            reply("r1", to: 10, at: 60, author: "astra-breakout-api3", text: "R27 progress: reproducing ⟂ speech a · life cfa292ca3e18"),
            reply("r2", to: 10, at: 120, author: "claude-warden", text: "@astra-breakout-api3 accepted"),
            reply("r3", to: 10, at: 180, author: "astra-breakout-api3", text: "READY FOR CARRY round 27 ⟂ speech b"),
            reply("r4", to: 10, at: 200, author: "astra-breakout-api3", text: "@mrrcarter I need your GO for the edge rule")
        ]
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages,
                                              ownAuthorIds: ["human-mrrcarter"], replies: replies, calendar: utc)
        let shown = rows(state)
        let box = shown.first { $0.id == "l10" }?.box
        XCTAssertEqual(box?.name, "astra-breakout-api3")
        XCTAssertEqual(box?.launch.model, "gpt-6-astra")
        XCTAssertEqual(box?.launch.ticketTitle, "Breakouts (API) fix")
        XCTAssertEqual(box?.launch.lifeId, "cfa292ca3e18")
        XCTAssertEqual(box?.replies, 4)
        XCTAssertEqual(box?.status, "@mrrcarter I need your GO for the edge rule")
        XCTAssertEqual(box?.isEnded, false)
        XCTAssertEqual(shown.first { $0.id == "l10" }?.isQuiet, false, "the launch line is the box's own line")
        XCTAssertEqual(shown.map(\.id), ["m1", "l10", "reply-r4", "m11"],
                       "what the box says stays in its thread, except what it says to you")
        // The thread's summary is the box's, both on its line and on what it says to you; it reads aloud as itself.
        XCTAssertEqual(shown.first { $0.id == "l10" }?.summaryThreadId, 10)
        XCTAssertEqual(shown.first { $0.id == "reply-r4" }?.summaryThreadId, 10)
        XCTAssertNil(shown.first { $0.id == "m11" }?.summaryThreadId, "a message with no thread has no summary")
        let boxLine = shown.first { $0.id == "l10" }
        let boxReply = shown.first { $0.id == "reply-r4" }
        XCTAssertNotEqual(boxLine?.summaryReadAloudId, boxLine?.readAloudId)
        XCTAssertNotEqual(boxLine?.summaryReadAloudId, boxReply?.summaryReadAloudId, "only the row being read shows stop")
        XCTAssertEqual(boxLine?.summaryReadAloudId.flatMap(RoomReadAloud.summaryThread), 10, "the player opens its thread")
        XCTAssertNil(RoomReadAloud.summaryThread(RoomReadAloud.message(10)))

        let ended = RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages + [
            input("c12", seq: 12, at: 500, author: "respawn-orchestrator",
                  text: "[cost] final: astra-breakout-api3: $28.88 est over 226 calls (0 unknown, 0 unpriced)")
        ], ownAuthorIds: ["human-mrrcarter"], replies: Array(replies.prefix(3)), calendar: utc)
        let endedBox = rows(ended).first { $0.id == "l10" }?.box
        XCTAssertEqual(endedBox?.isEnded, true)
        XCTAssertEqual(endedBox?.status, "finished · READY FOR CARRY round 27")
        XCTAssertEqual(rows(ended).first { $0.id == "c12" }?.isQuiet, true)
        XCTAssertNil(RoomBoxThread.launch("Minted astra: its own machine (life cfa292ca3e18)"), "only the orchestrator's line")
    }
}
