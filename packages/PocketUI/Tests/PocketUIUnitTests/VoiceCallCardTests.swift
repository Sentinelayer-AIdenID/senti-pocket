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
}
