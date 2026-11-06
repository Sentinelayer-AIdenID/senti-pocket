import PocketContracts
import XCTest
@testable import PocketUI

/// Plain words for people who are not technical (Carter, 2026-11-06, ticket 693f0cc5): Room info rather than the Flight
/// record, no box words for a person without boxes, "last seen just now", Activity said as what happened, and the
/// first list a person meets says chats.
final class FriendlyWordsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func box(_ name: String, phase: String = "working") -> FlightRecordState.Box {
        FlightRecordState.Box(id: name, name: name, model: "model", phase: phase, job: nil, current: nil,
                              lastActivity: nil, expiresAt: nil, consoleURL: nil, lines: [], posts: 0, doneSummary: nil)
    }

    private let agent = FlightRecordState.Agent(id: "review-agent", isHere: true, isIdle: false, status: "Reading the diff",
                                                statusAt: nil)

    private func person(_ name: String) -> RoomRoster.Member {
        RoomRoster.Member(id: name, name: name, kind: .person, status: .here)
    }

    // MARK: Room info

    func test_room_info_opens_with_the_people_then_the_agents_then_the_boxes() {
        let full = FlightRecordState(boxes: [box("astra-box")], agents: [agent], people: [person("Carter")])
        XCTAssertEqual(full.sections, [.people, .agents, .boxes])
        let noBoxes = FlightRecordState(agents: [agent], people: [person("Carter")])
        XCTAssertEqual(noBoxes.sections, [.people, .agents])
        XCTAssertEqual(FlightRecordState(people: [person("Carter")]).sections, [.people])
    }

    func test_a_room_without_boxes_says_nothing_about_boxes() {
        // A person who cannot see boxes: no count, no totals, and no box read that failed.
        for state in [
            FlightRecordState(agents: [agent], people: [person("Carter")]),
            FlightRecordState(people: [person("Carter")], failure: "Couldn't load the boxes. Trying again every 30 seconds."),
            FlightRecordState(people: [person("Carter")], totals: FlightRecordState.Totals(minted: 0, active: 0, finished: 0))
        ] {
            XCTAssertFalse(state.showsBoxes)
            XCTAssertNil(state.summary, "a box count for a room without boxes")
            XCTAssertNil(state.shownFailure, "a box failure said to a person without boxes")
        }
    }

    func test_a_room_with_boxes_says_how_many_and_when_a_read_failed() {
        let working = FlightRecordState(boxes: [box("a-box"), box("b-box", phase: "waiting")], finishedBoxes: 2)
        XCTAssertTrue(working.showsBoxes)
        XCTAssertEqual(working.summary, "2 boxes · 1 working now · 2 finished")
        XCTAssertNil(working.shownFailure, "boxes on screen: no failure line over them")

        let failure = "Couldn't load the boxes. Trying again every 30 seconds."
        let finishedOnly = FlightRecordState(finishedBoxes: 3, failure: failure)
        XCTAssertEqual(finishedOnly.summary, "0 boxes · 3 finished")
        XCTAssertEqual(finishedOnly.shownFailure, failure, "a person who has had boxes here hears why they did not load")
        let counted = FlightRecordState(failure: failure, totals: FlightRecordState.Totals(minted: 4, active: 0, finished: 4))
        XCTAssertTrue(counted.showsBoxes)
        XCTAssertEqual(counted.shownFailure, failure)
    }

    // MARK: Last seen

    func test_last_seen_reads_just_now_never_now_ago() {
        XCTAssertEqual(PocketSidePanel.lastSeen(of: now.addingTimeInterval(-20), now: now), "last seen just now")
        XCTAssertEqual(PocketSidePanel.lastSeen(of: now.addingTimeInterval(-5 * 60), now: now), "last seen 5m ago")
        XCTAssertEqual(PocketSidePanel.lastSeen(of: now.addingTimeInterval(-3 * 3_600), now: now), "last seen 3h ago")
        for seconds in [0.0, 30, 59, 60, 3_600, 90_000] {
            let words = PocketSidePanel.lastSeen(of: now.addingTimeInterval(-seconds), now: now)
            XCTAssertFalse(words.contains("now ago"), words)
        }
    }

    // MARK: Activity

    func test_activity_says_what_happened_never_the_servers_token() {
        XCTAssertEqual(ActivityWords.event("session_message"), "Message")
        XCTAssertEqual(ActivityWords.event(" SESSION_MESSAGE "), "Message")
        XCTAssertEqual(ActivityWords.event("agent_response"), "Answer")
        XCTAssertEqual(ActivityWords.event("session_titled"), "Chat renamed")
        XCTAssertEqual(ActivityWords.event("room_event_postponed"), "Event moved")
        XCTAssertEqual(ActivityWords.event("file_lock"), "Update", "a type it does not know is an update")
        XCTAssertEqual(ActivityWords.action("ack"), "Acknowledged")
        XCTAssertEqual(ActivityWords.action("view"), "Seen")
        XCTAssertEqual(ActivityWords.action("comment"), "Replied")
        XCTAssertEqual(ActivityWords.action("unreact"), "Took back a reaction")
        XCTAssertEqual(ActivityWords.action("escalate"), "Update")

        // The server's own types (its message actions and its session events), every one in words: no underscores,
        // no numbers, nothing left as the server spells it.
        let actions = ["ack", "working_on", "reply", "like", "dislike", "disregard", "view", "pin", "unpin", "unlike",
                       "undislike", "react", "unreact"]
        let events = ["session_message", "session_say", "agent_response", "human_relay", "session_titled",
                      "session_member_joined", "agent_admission_joined", "agent_admission_state_changed",
                      "session_branched_from", "session_branched_to", "room_event_reminder", "room_event_cancelled",
                      "room_event_postponed", "agent_join", "agent_leave", "agent_complete", "agent_error"]
        for (type, words) in actions.map({ ($0, ActivityWords.action($0)) }) + events.map({ ($0, ActivityWords.event($0)) }) {
            XCTAssertNotEqual(words, "Update", "\(type) is one of the server's own and has its words")
            XCTAssertNil(words.rangeOfCharacter(from: CharacterSet(charactersIn: "_#0123456789")), "\(type): \(words)")
            XCTAssertNotEqual(words.lowercased(), type.replacingOccurrences(of: "_", with: " "), "\(type) as the server spells it")
        }
    }

    // MARK: The chat list

    func test_the_first_list_a_person_meets_says_chats() {
        XCTAssertEqual(ChatListWords.title, "Chats")
        XCTAssertEqual(ChatListWords.emptyTitle(.network(lastUpdated: now)), "No chats yet")
        XCTAssertEqual(ChatListWords.emptyDetail(.network(lastUpdated: now)), "Chats you start or join show up here.")
        XCTAssertEqual(ChatListWords.loadMore, "Load more chats")
        XCTAssertEqual(ChatListWords.upToDate(updated: "now"), "Up to date · updated now")
        let provenances: [SessionPresentationProvenance] = [
            .network(lastUpdated: now), .cache(cachedAt: now, authenticationExpired: true), .fixture, .unavailable
        ]
        let words = [ChatListWords.title, ChatListWords.section, ChatListWords.rowHint, ChatListWords.loadMore,
                     ChatListWords.loading, ChatListWords.loadingDetail, ChatListWords.notConnected,
                     ChatListWords.upToDate(updated: "now"), ChatListWords.savedCopy(from: "5 minutes ago", signInAgain: true)]
            + provenances.map(ChatListWords.emptyTitle) + provenances.map(ChatListWords.emptyDetail)
        for line in words {
            XCTAssertFalse(line.localizedCaseInsensitiveContains("session"), line)
            XCTAssertFalse(line.localizedCaseInsensitiveContains("authorized"), line)
        }
    }

    /// The chat list, Activity and Saved summaries say how long ago the same way.
    func test_how_long_ago_reads_just_now_or_minutes_ago_never_now_ago() {
        XCTAssertEqual(AgoText.words(now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(AgoText.words(now.addingTimeInterval(-5 * 60), now: now), "5m ago")
        XCTAssertEqual(AgoText.words(now.addingTimeInterval(-42 * 60 - 12), now: now), "42m ago")
        XCTAssertEqual(AgoText.words(now.addingTimeInterval(-3 * 3_600), now: now), "3h ago")
        XCTAssertEqual(AgoText.words(now.addingTimeInterval(-2 * 86_400), now: now), "2d ago")
        for seconds in [0.0, 30, 59, 60, 3_600, 90_000] {
            let words = AgoText.words(now.addingTimeInterval(-seconds), now: now)
            XCTAssertFalse(words.contains("now ago"), words)
        }
        XCTAssertEqual(ChatListWords.noActivity, "No activity yet")
    }

    // MARK: Who did it, in Activity

    /// Activity names who wrote or did something as the chat does: "You"; a person by name, else their GitHub login,
    /// else "A person"; an agent by its id, never the name it gives itself (here a model's). Never an account's hex
    /// or "human-". The people, agents and ids are made up.
    func test_activity_names_people_and_agents_never_by_a_hex_id_or_a_models_name() throws {
        let hex = "0123456789abcdef0123456789abcdef"
        func event(_ id: String, _ agent: String, _ name: String?) -> String {
            let shown = name.map { #"{"displayName":"\#($0)"}"# } ?? "{}"
            return #"{"id":"\#(id)","event":"session_message","agent":\#(shown),"agentId":"\#(agent)","agentModel":"m","#
                + #""payload":{"text":"hi"},"ts":"2026-11-06T09:00:00Z","timestamp":"2026-11-06T09:00:00Z","cursor":"c","#
                + #""sequenceId":\#(id.count * 7),"sessionId":"room-1","source":"phone"}"#
        }
        func action(_ id: String, _ kind: String, _ actor: String) -> String {
            #"{"id":"\#(id)","sessionId":"room-1","targetSequenceId":7,"targetCursor":null,"targetActionId":null,"#
                + #""actionType":"ack","actorKind":"\#(kind)","actorId":"\#(actor)","actorUserId":null,"actorRole":null,"#
                + #""note":null,"metadata":{},"idempotencyKey":"k-\#(id)","createdAt":"2026-11-06T09:01:00Z"}"#
        }
        let events = try JSONDecoder().decode(SessionEventForwardPage.self, from: Data(("{\"events\":[" + [
            event("e1", "build-agent", "nimbus-large-2"),
            event("e22", "human-ada", "Ada Lovelace"),
            event("e333", "human-g.\(hex)", nil),
            event("e4444", "human-alex", "Alex"),
        ].joined(separator: ",") + "]}").utf8))
        let actions = try JSONDecoder().decode(SessionActionPage.self, from: Data((
            #"{"sessionId":"room-1","count":5,"projection":{},"actions":["# + [
                action("a1", "human", "human-ada"),
                action("a2", "human", "human-g.\(hex)"),
                action("a3", "human", "human-octo-reader"),
                action("a4", "human", "alex"),
                action("a5", "agent", "review-agent"),
            ].joined(separator: ",") + "]}").utf8))
        let state = SessionActivityPresentationState(sessionId: "room-1", eventPage: events, actionPage: actions,
                                                     provenance: .network(lastUpdated: now),
                                                     naming: ActivityNaming(you: ["human-alex"]))
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.events.map(\.author), ["build-agent", "Ada Lovelace", "A person", "You"])
        XCTAssertEqual(state.actions.map(\.actor), ["Ada Lovelace", "A person", "octo-reader", "You", "review-agent"])
        for name in state.events.map(\.author) + state.actions.map(\.actor) {
            XCTAssertFalse(name.localizedCaseInsensitiveContains("human-"), name)
            XCTAssertFalse(name.contains("0123456789"), name)
            XCTAssertFalse(name.contains("nimbus"), name)
        }
        // With no one signed in, nobody is "You".
        let anyone = SessionActivityPresentationState(sessionId: "room-1", eventPage: events, actionPage: actions,
                                                      provenance: .network(lastUpdated: now))
        XCTAssertEqual(anyone.events.last?.author, "Alex")
        XCTAssertEqual(anyone.actions[3].actor, "Alex", "a person's action goes by the name their messages carry")
    }
}
