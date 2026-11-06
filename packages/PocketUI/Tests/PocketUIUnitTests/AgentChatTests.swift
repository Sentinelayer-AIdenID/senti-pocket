import Foundation
import XCTest
@testable import PocketUI

/// Carter, #61679: in a chat made for one agent, what the agent says shows in full (it all folded as background); the
/// people ring stops covering the first message; and a room with a running box says how to reach it.
final class AgentChatTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func input(_ id: String, seq: Int64, author: String, text: String,
                       kind: RoomChatMessageInput.Kind = .message) -> RoomChatMessageInput {
        RoomChatMessageInput(id: id, sequenceId: seq, kind: kind, authorId: author, authorName: author,
                             isHuman: author.hasPrefix("human-"), text: text, timestamp: "",
                             date: Date(timeIntervalSince1970: 1_800_000_000 + Double(seq) * 30))
    }

    private static let launch = "🚀 Minted build-agent on model-x: its own machine (life 0123456789ab), until 03:30Z "
        + "unless extended.\nIt works in its box and reports here as build-agent; messages in this room reach it."
    private static let signed = "Plan: reproduce the failing build, then fix it.\n⟂ speech 0123abcd4567ef89 · model-x · "
        + "life 0123456789ab · signed relay"

    /// A chat a New agent made: you, the orchestrator's launch and cost lines, the ticket keeper, Senti and the box.
    private func agentChat(_ extra: [RoomChatMessageInput] = []) -> [RoomChatMessageInput] {
        [
            input("l1", seq: 1, author: "respawn-orchestrator", text: Self.launch),
            input("h2", seq: 2, author: "human-alex", text: "hi"),
            input("b3", seq: 3, author: "build-agent", text: Self.signed),
            input("o4", seq: 4, author: "respawn-orchestrator", text: "[cost] build-agent: $0.10 est over 3 calls"),
            input("t5", seq: 5, author: "ticket-keeper", text: "🎫 1 new from #2: P2 [Ticket: Fix it](/x)"),
            input("s6", seq: 6, author: "senti", text: "Noted.")
        ] + extra
    }

    private func rows(_ state: RoomChatPresentationState) -> [String: RoomChatMessageRow] {
        var byId: [String: RoomChatMessageRow] = [:]
        for row in state.rows { if case .message(let message) = row { byId[message.id] = message } }
        return byId
    }

    func test_a_chat_made_for_one_box_shows_what_it_says_in_full() throws {
        let state = RoomChatPresentationState(sessionId: "chat", title: "build-agent · Fix the build",
                                              messages: agentChat(), ownAuthorIds: ["human-alex"], calendar: utc)
        XCTAssertEqual(state.roomAgent, "build-agent")
        let shown = rows(state)
        let post = try XCTUnwrap(shown["b3"])
        XCTAssertFalse(post.isQuiet, "the chat's own agent is never background")
        XCTAssertEqual(post.text, "Plan: reproduce the failing build, then fix it.", "the relay's signature line stays hidden")
        XCTAssertEqual(shown["o4"]?.isQuiet, true, "the orchestrator's costs stay quiet")
        XCTAssertEqual(shown["t5"]?.isQuiet, true, "the ticket keeper stays quiet")
        XCTAssertNotNil(shown["l1"]?.box, "the launch line is still the box's line")

        // Known from the mint alone, before any launch line is loaded; case as the mint has it.
        let fromMint = RoomChatPresentationState(sessionId: "chat", title: "Chat", messages: Array(agentChat().dropFirst()),
                                                 ownAuthorIds: ["human-alex"], runningBoxes: ["Build-Agent"], calendar: utc)
        XCTAssertEqual(fromMint.roomAgent, "build-agent")
        XCTAssertEqual(rows(fromMint)["b3"]?.isQuiet, false)

        // An ended box's chat is still its chat.
        let ended = RoomChatPresentationState(sessionId: "chat", title: "Chat", messages: Array(agentChat().dropFirst()),
                                              ownAuthorIds: ["human-alex"], endedBoxNames: ["build-agent"], calendar: utc)
        XCTAssertEqual(ended.roomAgent, "build-agent")
    }

    func test_a_room_with_any_other_agent_keeps_box_speech_as_background() {
        func agent(_ messages: [RoomChatMessageInput], running: Set<String> = [],
                   presence: RoomChatPresence? = nil) -> RoomChatPresentationState {
            RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages, ownAuthorIds: ["human-alex"],
                                      presence: presence, runningBoxes: running, calendar: utc)
        }
        let another = agent(agentChat([input("r7", seq: 7, author: "review-agent", text: "Looks fine to me.")]))
        XCTAssertNil(another.roomAgent, "another agent posted")
        XCTAssertEqual(rows(another)["b3"]?.isQuiet, true, "box speech is background, as before")
        XCTAssertTrue(rows(another)["b3"]?.text.contains("⟂ speech") == true, "and its text is as it was")

        let twoBoxes = agent(agentChat(), running: ["build-agent", "test-agent"])
        XCTAssertNil(twoBoxes.roomAgent, "two boxes")

        let present = agent(agentChat(), presence: RoomChatPresence(label: "", compactCount: "1", isAvailable: true, people: [
            RoomChatPresence.Person(id: "review-agent", name: "review-agent", isHuman: false, isIdle: false)
        ]))
        XCTAssertNil(present.roomAgent, "another agent is here, though it has not posted")

        let joined = agent(agentChat([input("j7", seq: 7, author: "review-agent", text: "", kind: .memberJoined)]))
        XCTAssertNil(joined.roomAgent, "another agent joined")

        let noBox = agent([input("h1", seq: 1, author: "human-alex", text: "hi"),
                           input("a2", seq: 2, author: "review-agent", text: "@build-agent over to you")])
        XCTAssertNil(noBox.roomAgent, "an agent that is not a box")

        let sentiToo = agent(agentChat([input("s7", seq: 7, author: "Senti", text: "Here is a summary.")]))
        XCTAssertEqual(sentiToo.roomAgent, "build-agent", "Senti is the room's own voice, not another agent")
    }

    func test_the_composer_says_how_to_reach_a_running_box() {
        func state(_ messages: [RoomChatMessageInput], running: Set<String> = [], ended: Set<String> = []) -> Bool {
            RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages, ownAuthorIds: ["human-alex"],
                                      runningBoxes: running, endedBoxNames: ended, calendar: utc).hasRunningBox
        }
        let people = [input("h1", seq: 1, author: "human-alex", text: "hi"),
                      input("h2", seq: 2, author: "human-sam", text: "hello"),
                      input("a3", seq: 3, author: "review-agent", text: "An agent that is not a box.")]
        XCTAssertFalse(state(people), "no box in the room")
        XCTAssertTrue(state(agentChat()), "a box launched here and not ended")
        XCTAssertTrue(state(people, running: ["build-agent"]), "a box the mint runs in this room")
        XCTAssertFalse(state(agentChat([input("o9", seq: 9, author: "respawn-orchestrator",
                                              text: "[cost] final: build-agent: $1.20 est over 30 calls")])),
                       "its final cost line: ended")
        XCTAssertFalse(state(agentChat(), ended: ["build-agent"]), "the mint says it ended")
        XCTAssertTrue(state(agentChat(), running: ["build-agent"], ended: ["build-agent"]), "running beats an old end")

        XCTAssertEqual(RoomComposerPlaceholder.text(ticketMode: false, replying: false, hasRunningBox: true),
                       "@name to reach an agent")
        XCTAssertEqual(RoomComposerPlaceholder.text(ticketMode: false, replying: false, hasRunningBox: false), "Message",
                       "a room of people keeps its words")
        XCTAssertEqual(RoomComposerPlaceholder.text(ticketMode: false, replying: true, hasRunningBox: true), "Reply")
        XCTAssertEqual(RoomComposerPlaceholder.text(ticketMode: true, replying: false, hasRunningBox: true),
                       "Describe the ticket")
    }

    /// The list keeps the ring's height clear above its first message, as tall as the ring's taller shape, so the ring
    /// coming, going or turning from an arc into a ring never moves a message.
    func test_the_list_keeps_the_rings_height_clear_above_the_first_message() {
        XCTAssertGreaterThanOrEqual(RoomPeopleAvatars.reservedHeight, RoomPeopleAvatars.ringHeight + RoomPeopleAvatars.topGap)
        XCTAssertGreaterThanOrEqual(RoomPeopleAvatars.reservedHeight, RoomPeopleAvatars.arcHeight + RoomPeopleAvatars.topGap)
    }

    /// Protected content never shows beside an access failure: no agent, no hint.
    func test_an_access_failure_names_no_agent() {
        let state = RoomChatPresentationState(sessionId: "chat", title: "Chat", messages: agentChat(),
                                              failure: .accessDenied, runningBoxes: ["build-agent"], calendar: utc)
        XCTAssertNil(state.roomAgent)
        XCTAssertFalse(state.hasRunningBox)
    }
}
