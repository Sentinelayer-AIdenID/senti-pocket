import Foundation
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// Carter's hard rule: the app must not get slower. The Working rows' pulse and Senti's avatar move by Core Animation
/// alone, so the room's views are not drawn again frame by frame for them (counted with `RoomRenderProbe`), and they stop
/// while the room is covered.
@MainActor
final class AgentChatMotionTests: XCTestCase {
    private var window: UIWindow?

    private final class Room: ObservableObject {
        @Published var covered = false
        let state: RoomChatPresentationState

        init() {
            let start = Date().addingTimeInterval(-600)
            var inputs: [RoomChatMessageInput] = (1...40).map { seq in
                RoomChatMessageInput(id: "m\(seq)", sequenceId: Int64(seq), kind: .message,
                                     authorId: seq.isMultiple(of: 2) ? "human-alex" : "review-agent",
                                     authorName: seq.isMultiple(of: 2) ? "Alex" : "review-agent",
                                     isHuman: seq.isMultiple(of: 2), text: "Note \(seq) about the onboarding flow.",
                                     timestamp: "", date: start.addingTimeInterval(Double(seq) * 10))
            }
            let work = ["build-agent", "test-agent", "docs-agent"].enumerated().map { index, agent in
                RoomChatWorkLine(id: "w\(index)", actorId: agent, text: "Working on step \(index + 1)",
                                 at: Date().addingTimeInterval(-Double(index + 1) * 5), isLive: true)
            }
            inputs.append(RoomChatMessageInput(id: "m41", sequenceId: 41, kind: .message, authorId: "human-alex",
                                               authorName: "Alex", isHuman: true, text: "@build-agent please fix it",
                                               timestamp: "", date: Date().addingTimeInterval(-30), work: work))
            state = RoomChatPresentationState(sessionId: "motion", title: "Motion", messages: inputs,
                                              ownAuthorIds: ["human-alex"], connection: .live, composingAgents: ["senti"],
                                              composer: RoomComposerState(canPost: true, disabledReason: nil))
        }
    }

    private struct Host: View {
        @ObservedObject var room: Room

        var body: some View {
            NavigationStack {
                RoomChatView(state: room.state) { _ in }
            }
            .environment(\.roomIsCovered, room.covered)
            // As the app's window group gives it: hosted on its own, a view is told nothing of the scene.
            .environment(\.scenePhase, .active)
        }
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    private func run(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func test_the_pulse_and_sentis_avatar_move_without_redrawing_the_room_and_stop_when_covered() throws {
        let room = Room()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 5
        window.rootViewController = UIHostingController(rootView: Host(room: room))
        window.makeKeyAndVisible()
        self.window = window
        run(1.5)

        XCTAssertGreaterThanOrEqual(RoomRenderProbe.motions(in: window).count, 4,
                                    "three pulses and Senti's avatar are on screen")
        let moving = RoomRenderProbe.motions(in: window).filter { $0 }.count
        XCTAssertGreaterThanOrEqual(moving, 4, "three pulses and Senti's avatar move")

        RoomRenderProbe.reset()
        run(4)
        let rows = RoomRenderProbe.count(RoomRenderProbe.workingRows)
        let senti = RoomRenderProbe.count(RoomRenderProbe.sentiThinking)
        print("RoomRenderProbe in 4 s: Working rows \(rows), Senti's line \(senti), moving layers \(moving)")
        // About 240 frames went by. The rows are drawn only if something changes; Senti's line once per phrase (2 s).
        XCTAssertLessThanOrEqual(rows, 4, "the Working rows are not drawn frame by frame (\(rows) in 4 s)")
        XCTAssertLessThanOrEqual(senti, 6, "Senti's line is drawn once per phrase, not per frame (\(senti) in 4 s)")
        XCTAssertGreaterThanOrEqual(senti, 1, "its phrase turned at least once (\(senti) in 4 s)")

        room.covered = true
        run(0.5)
        XCTAssertEqual(RoomRenderProbe.motions(in: window).filter { $0 }.count, 0, "covered: nothing moves")
        RoomRenderProbe.reset()
        run(2.5)
        XCTAssertEqual(RoomRenderProbe.count(RoomRenderProbe.sentiThinking), 0, "covered: no phrase turns")

        room.covered = false
        run(0.5)
        XCTAssertGreaterThanOrEqual(RoomRenderProbe.motions(in: window).filter { $0 }.count, 4, "uncovered: moving again")
    }
}
