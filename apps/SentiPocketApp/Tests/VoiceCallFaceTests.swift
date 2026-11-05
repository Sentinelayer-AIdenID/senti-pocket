import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// The answering agent's face on the call screen, with a mouth that moves with its voice (Carter, 11-05), drawn once per
/// answer and moved by Core Animation, never by drawing the call screen again per tick.
@MainActor
final class VoiceCallFaceTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        pump(0.3)
        super.tearDown()
    }

    func test_the_mouth_opens_with_the_agents_voice_only_while_its_face_talks() {
        let meter = VoiceLevelMeter()
        let mouth = VoiceCallMouthView(style: .mouth)
        mouth.frame = CGRect(x: 0, y: 0, width: 52, height: 24)
        mouth.layoutIfNeeded()
        mouth.follow(meter)
        mouth.talks = true
        XCTAssertEqual(mouth.level, 0, "closed before a word")

        meter.hear(0.9, from: .agent)
        pump(0.12)
        XCTAssertGreaterThan(mouth.level, 0.5, "a word opens the mouth")
        XCTAssertEqual(mouth.mouthScale, VoiceCallMouthView.openness(mouth.level), accuracy: 0.001)
        pump(1.5)
        XCTAssertEqual(mouth.level, 0, "and it closes as the word fades")
        XCTAssertEqual(mouth.mouthScale, VoiceCallMouthView.openness(0), accuracy: 0.001)

        meter.hear(0.9, from: .you)
        pump(0.12)
        XCTAssertEqual(mouth.level, 0, "your own voice never moves the agent's mouth")
        meter.reset()

        mouth.talks = false
        meter.hear(0.9, from: .agent)
        pump(0.12)
        XCTAssertEqual(mouth.level, 0, "a face that is not talking keeps its mouth closed")
        meter.reset()
    }

    func test_a_talking_face_moves_without_drawing_the_call_screen_again() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 5
        var state = VoiceRoomState(phase: .speaking(speaker: "review-agent (voice)"), with: ["review-agent"])
        state.joined = ["review-agent"]
        state.answering = VoiceRoomAnswering(turnId: "t1", agentId: "review-agent", name: "Reviewer", isSpeaking: true)
        let meter = VoiceLevelMeter()
        window.rootViewController = UIHostingController(rootView: VoiceRoomPanel(
            state: state, meter: meter, partnerLab: nil, send: { _ in }
        ))
        window.makeKeyAndVisible()
        self.window = window
        pump(1)
        let drawn = VoiceCallTrace.faceDraws
        let mouth = try XCTUnwrap(Self.views(of: VoiceCallMouthView.self, in: window).first, "the face has its mouth")

        // Two seconds of speech, a word every 200 ms.
        var widest = 0.0
        for length in [4, 7, 2, 9, 5, 3, 8, 6, 4, 7] {
            meter.hear(VoiceLevelMeter.level(wordLength: length), from: .agent)
            pump(0.2)
            widest = max(widest, mouth.level)
        }
        XCTAssertGreaterThan(widest, 0.5, "the mouth moved with the words")
        XCTAssertEqual(VoiceCallTrace.faceDraws - drawn, 0, "the face is not drawn again per tick of the voice")
        meter.reset()
    }

    private static func views<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(of: type, in: $0) }
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.02))) }
    }
}
