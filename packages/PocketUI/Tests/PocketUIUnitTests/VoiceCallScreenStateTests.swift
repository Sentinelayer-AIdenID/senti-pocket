import XCTest
@testable import PocketUI

/// The call screen's Speaker, who is answering, and whose face it shows (Carter, 11-05).
final class VoiceCallScreenStateTests: XCTestCase {
    func test_a_call_starts_on_the_speaker_and_voiceover_reads_on_or_off() {
        var state = VoiceRoomState(with: ["build-agent"])
        XCTAssertTrue(state.isSpeakerOn, "calls start on the loudspeaker, as they always have")
        XCTAssertEqual(state.speakerValue, "On")
        state.isSpeakerOn = false
        XCTAssertEqual(state.speakerValue, "Off")
    }

    func test_the_face_is_the_agent_answering_then_whoever_is_read_aloud() {
        var state = VoiceRoomState(with: ["build-agent", "review-agent"])
        XCTAssertNil(state.face, "nobody answers yet: the call shows its coin")
        XCTAssertNil(state.answeringLine)

        state.answering = VoiceRoomAnswering(turnId: "t1", agentId: "review-agent", name: "Reviewer")
        XCTAssertEqual(state.answeringLine, "Reviewer is answering")
        XCTAssertEqual(state.face, VoiceRoomFace(id: "review-agent", talks: false), "its face, still, before any sound")
        state.answering?.isSpeaking = true
        XCTAssertEqual(state.face, VoiceRoomFace(id: "review-agent", talks: true))

        state.answering = nil
        state.phase = .speaking(speaker: "build-agent (voice)")
        XCTAssertEqual(state.face, VoiceRoomFace(id: "build-agent", talks: true), "the voice line talks as its agent")
        state.phase = .speaking(speaker: "review-agent")
        XCTAssertEqual(state.face, VoiceRoomFace(id: "review-agent", talks: true))
        state.phase = .ready
        XCTAssertNil(state.face)
    }
}
