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

        let two = VoiceCallCard.fold([
            input("a", seq: 1, "human-mrrcarter", start, at: -5),
            input("b", seq: 2, "pocket-forge", "Hello", at: -4),
            input("c", seq: 3, "human-mrrcarter", start, at: -3),
            input("d", seq: 4, "pocket-forge", "Again", at: -2)
        ])
        XCTAssertEqual(two.kept.map(\.id), ["a", "c"])
        XCTAssertEqual(two.cards["a"]?.isLive, false, "the second call closed the first")
        XCTAssertEqual(two.cards["c"]?.turns.map(\.id), ["d"])
    }
}
