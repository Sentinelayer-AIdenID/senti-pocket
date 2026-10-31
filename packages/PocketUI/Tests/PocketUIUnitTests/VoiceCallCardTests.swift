import Foundation
import XCTest
@testable import PocketUI

final class VoiceCallCardTests: XCTestCase {
    private let base = Date()

    private func input(_ id: String, seq: Int64, _ author: String, _ text: String, at minutes: Double,
                       voice: Bool = false) -> RoomChatMessageInput {
        RoomChatMessageInput(id: id, sequenceId: seq, kind: .message, authorId: author, authorName: author,
                             isHuman: author.hasPrefix("human-"), text: text, timestamp: "",
                             date: base.addingTimeInterval(minutes * 60), isVoiceTurn: voice)
    }

    func test_a_meeting_ring_tells_agents_the_first_answer_has_the_floor() {
        let meeting = VoiceCallMarkers.start(caller: "mrrcarter", agents: ["a", "b"], meeting: true)
        XCTAssertTrue(meeting.contains("the first agent to answer a turn has the floor"))
        XCTAssertEqual(VoiceCallMarkers.calledAgents(in: meeting), ["a", "b"])
        XCTAssertFalse(VoiceCallMarkers.start(caller: "mrrcarter", agents: ["a"], meeting: false).contains("floor"),
                       "one agent has the floor anyway")
    }

    func test_timings_report_the_middle_and_the_slow_end() {
        var timings = VoiceCallTimings()
        XCTAssertNil(timings.line())
        XCTAssertTrue(timings.markdown().isEmpty)
        for seconds in [2.0, 3.0, 4.0, 5.0, 9.0] { timings.record(.gap, seconds) }
        timings.record(.voiceStart, 0.24)
        timings.record(.gap, -1)
        timings.record(.answer, .infinity)
        timings.noteHeld()
        XCTAssertEqual(timings.percentile(.gap, 0.5), 4, "nearest rank")
        XCTAssertEqual(timings.percentile(.gap, 0.95), 9)
        XCTAssertNil(timings.percentile(.answer, 0.5), "nonsense samples are dropped")
        XCTAssertEqual(timings.line(),
                       "Timings: you stop → answer heard 4.0 s (p95 9.0 s, 5) · voice starts 0.2 s · 1 held for the floor.")
        XCTAssertEqual(timings.markdown().count, 5, "header, rule, two measures and the held line")
    }

    func test_the_markers_ring_by_mention_and_close_by_their_own_words() {
        let start = VoiceCallMarkers.start(caller: "mrrcarter", agents: ["pocket-forge", "claude-warden"], meeting: true)
        XCTAssertTrue(start.hasPrefix("📞 Calling @pocket-forge @claude-warden: mrrcarter started a voice meeting."))
        XCTAssertEqual(VoiceCallMarkers.calledAgents(in: start), ["pocket-forge", "claude-warden"])
        XCTAssertNil(VoiceCallMarkers.calledAgents(in: "📞 Calling: nobody"))
        XCTAssertNil(VoiceCallMarkers.calledAgents(in: "Calling @x: not ours"))
        XCTAssertTrue(VoiceCallMarkers.isEnd("📞 Voice room with pocket-forge ended · 26 s · 2 turns."))
        XCTAssertFalse(VoiceCallMarkers.isEnd("📞 Voice room with pocket-forge is great"))
    }

    /// Carter (#54996): a call should be its own collapsed item, not all over the room.
    func test_a_call_folds_into_one_card_and_everything_else_stays() {
        let start = VoiceCallMarkers.start(caller: "mrrcarter", agents: ["pocket-forge"], meeting: false)
        let inputs = [
            input("m1", seq: 1, "review-agent", "before the call", at: -10),
            input("m2", seq: 2, "human-mrrcarter", start, at: 0),
            input("m3", seq: 3, "human-mrrcarter", "@pocket-forge can you hear me", at: 0.2, voice: true),
            input("m4", seq: 4, "respawn-orchestrator", "[cost] unrelated", at: 0.3),
            input("m5", seq: 5, "pocket-forge", "Loud and clear.", at: 0.4),
            input("m6", seq: 6, "human-mrrcarter", "a typed message, not a turn", at: 0.5),
            input("m7", seq: 7, "human-mrrcarter", "📞 Voice room with pocket-forge ended · 40 s · 2 turns.", at: 0.7),
            input("m8", seq: 8, "pocket-forge", "Summary: we ship build 12.", at: 1)
        ]
        let folded = VoiceCallCard.fold(inputs)
        XCTAssertEqual(folded.kept.map(\.id), ["m1", "m2", "m4", "m6", "m8"], "only the call's turns and its end fold")
        let card = try? XCTUnwrap(folded.cards["m2"])
        XCTAssertEqual(card?.turns.map(\.id), ["m3", "m5"])
        XCTAssertEqual(card?.agents, ["pocket-forge"])
        XCTAssertEqual(card?.isLive, false)
        XCTAssertEqual(card?.title, "Voice room with pocket-forge")
        XCTAssertEqual(card?.summary(), "2 turns · 42 s", "under a minute it says seconds")

        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: inputs)
        let rows = state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
        XCTAssertEqual(rows.map(\.id), ["m1", "m2", "m4", "m6", "m8"])
        XCTAssertEqual(rows.first { $0.id == "m2" }?.call?.turns.count, 2, "the opening message is the card")
    }

    func test_a_call_that_is_still_going_is_live_and_a_new_call_closes_the_last() {
        let start = VoiceCallMarkers.start(caller: "mrrcarter", agents: ["pocket-forge"], meeting: false)
        let live = VoiceCallCard.fold([
            input("a", seq: 1, "human-mrrcarter", start, at: -2),
            input("b", seq: 2, "pocket-forge", "Hello", at: -1)
        ])
        XCTAssertEqual(live.cards["a"]?.isLive, true)
        XCTAssertEqual(live.cards["a"]?.summary(), "live · 1 turn")
        XCTAssertEqual(live.kept.map(\.id), ["a", "b"], "a call not yet closed hides nothing an agent posts (warden)")

        let two = VoiceCallCard.fold([
            input("a", seq: 1, "human-mrrcarter", start, at: -5),
            input("b", seq: 2, "pocket-forge", "Hello", at: -4),
            input("c", seq: 3, "human-mrrcarter", start, at: -3),
            input("d", seq: 4, "pocket-forge", "Again", at: -2)
        ])
        XCTAssertEqual(two.kept.map(\.id), ["a", "b", "c", "d"], "neither call closed with its own message")
        XCTAssertEqual(two.cards["a"]?.isLive, false, "the second call closed the first")
        XCTAssertEqual(two.cards["a"]?.turns.map(\.id), ["b"])
        XCTAssertEqual(two.cards["c"]?.turns.map(\.id), ["d"])
    }

    /// warden: a call the app never closed (it quit mid-call) must not hide agents' posts, and no call runs past
    /// half an hour.
    func test_an_unclosed_call_hides_nothing_and_a_call_stops_at_half_an_hour() {
        let start = VoiceCallMarkers.start(caller: "mrrcarter", agents: ["pocket-forge"], meeting: false)
        let folded = VoiceCallCard.fold([
            input("a", seq: 1, "human-mrrcarter", start, at: -100),
            input("b", seq: 2, "human-mrrcarter", "@pocket-forge spoken", at: -99, voice: true),
            input("c", seq: 3, "pocket-forge", "An answer.", at: -98),
            input("d", seq: 4, "pocket-forge", "Much later, unrelated to any call.", at: -40)
        ])
        XCTAssertEqual(folded.kept.map(\.id), ["a", "c", "d"], "only the spoken turn folds; the agent's posts stay")
        XCTAssertEqual(folded.cards["a"]?.turns.map(\.id), ["b", "c"], "the card still lists the conversation")
        XCTAssertEqual(folded.cards["a"]?.isLive, false, "past half an hour the call is over")
        XCTAssertEqual(VoiceCallCard.longestCall, 30 * 60)
    }

    /// Carter (10-30): bring warden into a call that is already going.
    func test_an_agent_added_mid_call_is_rung_by_mention_and_its_answers_fold_into_the_card() {
        let add = VoiceCallMarkers.added(caller: "mrrcarter", agent: "claude-warden", joining: ["pocket-forge"])
        XCTAssertTrue(add.hasPrefix("📞 Adding @claude-warden: mrrcarter added you to a voice room already going with pocket-forge."))
        XCTAssertTrue(add.contains("The first agent to answer a turn has the floor"), "the added agent learns the floor rule")
        XCTAssertEqual(VoiceCallMarkers.addedAgents(in: add), ["claude-warden"], "only the added agent is mentioned")
        XCTAssertNil(VoiceCallMarkers.calledAgents(in: add), "an add never opens a call of its own")
        XCTAssertNil(VoiceCallMarkers.addedAgents(in: VoiceCallMarkers.start(caller: "mrrcarter", agents: ["a"], meeting: false)))

        let start = VoiceCallMarkers.start(caller: "mrrcarter", agents: ["pocket-forge"], meeting: false)
        let inputs = [
            input("m1", seq: 1, "human-mrrcarter", start, at: 0),
            input("m2", seq: 2, "pocket-forge", "Hi Carter.", at: 0.1),
            input("m3", seq: 3, "claude-warden", "Before I was added, not the call's.", at: 0.15),
            input("m4", seq: 4, "human-mrrcarter", add, at: 0.2),
            input("m5", seq: 5, "claude-warden", "Warden here.", at: 0.3),
            input("m6", seq: 6, "human-mrrcarter", "📞 Voice room with pocket-forge and claude-warden ended · 30 s · 3 turns.", at: 0.5)
        ]
        let folded = VoiceCallCard.fold(inputs)
        XCTAssertEqual(folded.kept.map(\.id), ["m1", "m3"], "the add and the added agent's answers leave with the call")
        let card = folded.cards["m1"]
        XCTAssertEqual(card?.agents, ["pocket-forge", "claude-warden"])
        XCTAssertEqual(card?.turns.map(\.id), ["m2", "m5"])
        XCTAssertEqual(card?.title, "Voice meeting with pocket-forge and claude-warden")

        // A call that never closed hides nothing, the add included.
        let unclosed = VoiceCallCard.fold(Array(inputs.dropLast()))
        XCTAssertEqual(unclosed.kept.map(\.id), ["m1", "m2", "m3", "m4", "m5"])
        XCTAssertEqual(unclosed.cards["m1"]?.turns.map(\.id), ["m2", "m5"])
    }

    /// Carter (10-30): tick several agents and call them together.
    func test_the_picker_rings_the_ticked_agents_in_the_lists_order() {
        let partners = ["pocket-forge", "claude-warden", "review-agent"]
        var pick = VoiceCallPick()
        XCTAssertEqual(pick.callTitle(of: partners), "Tick who to call")
        pick.toggle("review-agent")
        XCTAssertEqual(pick.callTitle(of: partners), "Call review-agent")
        pick.toggle("Pocket-Forge")
        XCTAssertTrue(pick.isPicked("pocket-forge"))
        XCTAssertEqual(pick.agents(of: partners), ["pocket-forge", "review-agent"], "the list's order, not the taps'")
        XCTAssertEqual(pick.callTitle(of: partners), "Call these 2")
        pick.toggle("review-agent")
        XCTAssertEqual(pick.agents(of: partners), ["pocket-forge"], "a second tap unticks")
        XCTAssertEqual(pick.agents(of: ["claude-warden"]), [], "one that dropped off the list is not rung")
    }

    func test_only_a_call_with_agents_still_going_can_take_someone_more() {
        XCTAssertFalse(VoiceRoomState(with: []).canAdd, "a meeting already has everyone")
        XCTAssertTrue(VoiceRoomState(with: ["pocket-forge"]).canAdd)
        XCTAssertFalse(VoiceRoomState(phase: .ending, with: ["pocket-forge"]).canAdd)
        XCTAssertFalse(VoiceRoomState(with: (1...VoiceCallRoster.limit).map { "agent-\($0)" }).canAdd, "full")
        XCTAssertFalse(VoiceRoomState(with: ["pocket-forge"]).sharesFloor)
        XCTAssertTrue(VoiceRoomState(with: ["pocket-forge", "claude-warden"]).sharesFloor)
        XCTAssertEqual(VoiceRoomState(with: ["a", "b", "c"]).title, "a, b and c")
    }

    /// Carter (Voice Lab #56359): "I don't see a mute button in this when I call you". The button says what a tap does
    /// and shows the microphone as it is, Talk takes no turn while muted, and the panel says where the call is muted.
    func test_the_mute_button_says_what_a_tap_does_and_the_panel_says_where_it_is_muted() {
        for agents in [["pocket-forge"], []] {
            var state = VoiceRoomState(with: agents)
            XCTAssertEqual(state.muteLabel, "Mute")
            XCTAssertEqual(state.muteSymbol, "mic")
            XCTAssertTrue(state.canTalk)
            state.isMuted = true
            XCTAssertEqual(state.muteLabel, "Unmute")
            XCTAssertEqual(state.muteSymbol, "mic.slash")
            XCTAssertFalse(state.canTalk, "Talk takes no turn while muted")
            XCTAssertEqual(state.mutedStatus, "Muted", "a call made in the app")
            state.hasCallScreen = true
            XCTAssertEqual(state.mutedStatus, "Muted on the call screen", "an agent's call answered on the call screen")
        }
        XCTAssertFalse(VoiceRoomState(phase: .ending, with: ["pocket-forge"]).canTalk)
        XCTAssertFalse(VoiceRoomState(phase: .ended, with: ["pocket-forge"]).canTalk)
    }

    /// Found porting the card to the web (#694): the closing message carries the transcript and folds into the card,
    /// so the card offers the file itself. A call that never closed has none.
    func test_a_closed_calls_card_offers_the_transcript_its_closing_message_carried() {
        let start = VoiceCallMarkers.start(caller: "mrrcarter", agents: ["pocket-forge"], meeting: false)
        let file = RoomAttachmentChip(attachmentId: "att-123456", filename: "voice-pocket-forge-20261030-2100.md",
                                      kind: .markdown)
        let end = RoomChatMessageInput(id: "m3", sequenceId: 3, kind: .message, authorId: "human-mrrcarter",
                                       authorName: "human-mrrcarter", isHuman: true,
                                       text: "📞 Voice room with pocket-forge ended · 40 s · 1 turns.", timestamp: "",
                                       date: base.addingTimeInterval(60), attachments: [file])
        let inputs = [
            input("m1", seq: 1, "human-mrrcarter", start, at: 0),
            input("m2", seq: 2, "pocket-forge", "Hi Carter.", at: 0.2),
            end
        ]
        let folded = VoiceCallCard.fold(inputs)
        XCTAssertEqual(folded.kept.map(\.id), ["m1"], "the closing message folds into the card")
        XCTAssertEqual(folded.cards["m1"]?.transcript, file, "and the card offers its transcript")
        XCTAssertNil(VoiceCallCard.fold(Array(inputs.dropLast())).cards["m1"]?.transcript, "an open call has none yet")
    }
}
