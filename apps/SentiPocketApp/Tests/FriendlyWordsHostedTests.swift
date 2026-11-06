import PocketSyncClient
import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// A mint that refuses every read the same way.
private final class RefusingMint: MintReading, @unchecked Sendable {
    let error: MintError
    init(_ error: MintError) { self.error = error }
    func roomLives(sessionId: String) async throws -> [MintLife] { throw error }
    func roomSnapshot(sessionId: String) async throws -> MintRoomLives { throw error }
    func flight(lifeId: String) async throws -> MintFlightRecord { throw error }
}

/// The words a new person meets, hosted in a window and read the way VoiceOver reads them (Carter, 2026-11-06, ticket
/// 693f0cc5): Room info with no box words for a person without boxes, people first, "last seen just now"; and the
/// on-device speech model only under Settings' Advanced.
@MainActor
final class FriendlyWordsHostedTests: XCTestCase {
    private func labels(in window: UIWindow) -> [String] {
        HostedSummary.elements(in: window).compactMap(\.accessibilityLabel).filter { !$0.isEmpty }
    }

    private func element(labelled label: String, in window: UIWindow) -> NSObject? {
        HostedSummary.elements(in: window).first { $0.accessibilityLabel == label }
    }

    func test_room_info_for_a_person_without_boxes_says_no_box_words_and_starts_with_the_people() throws {
        let state = FlightRecordState(
            agents: [FlightRecordState.Agent(id: "review-agent", isHere: true, isIdle: false, status: "Reading the diff",
                                             statusAt: nil)],
            people: [RoomRoster.Member(id: "carter", name: "Carter", kind: .person, status: .idle,
                                       lastSeen: Date().addingTimeInterval(-10))],
            failure: "Couldn't load the boxes. Trying again every 30 seconds."
        )
        let window = try HostedSummary.host(FlightRecordPanel(state: state, onClose: {}))
        defer { HostedSummary.close(window) }
        guard HostedSummary.wait(for: "pocket.flight.person.carter", in: window) != nil else {
            return XCTFail("the person never showed: \(HostedSummary.identifiers(in: window))")
        }
        let read = labels(in: window)
        XCTAssertTrue(read.contains("Room info"), "the panel is Room info: \(read)")
        XCTAssertTrue(read.contains("Close room info"), "\(read)")
        XCTAssertTrue(read.contains { $0.contains("last seen just now") }, "\(read)")
        for label in read {
            XCTAssertFalse(label.localizedCaseInsensitiveContains("box"), "box words for a person without boxes: \(label)")
            XCTAssertFalse(label.localizedCaseInsensitiveContains("flight"), label)
            XCTAssertFalse(label.contains("now ago"), label)
        }
        let people = try XCTUnwrap(element(labelled: "People", in: window), "no People heading: \(read)")
        let agents = try XCTUnwrap(element(labelled: "Agents", in: window), "no Agents heading: \(read)")
        XCTAssertLessThan(people.accessibilityFrame.minY, agents.accessibilityFrame.minY, "the people come first")
    }

    func test_settings_keeps_the_speech_model_under_advanced_and_says_crashes_plainly() throws {
        // Tall enough that every row of Settings is drawn: a row never drawn would read as absent.
        let window = try HostedSummary.host(
            WhisperModelSettingsView(coordinator: WhisperModelProvisioningCoordinator(), onSignOut: {}),
            height: 2_400
        )
        defer { HostedSummary.close(window) }
        guard HostedSummary.wait(for: "settings.account.sign-out", in: window) != nil else {
            return XCTFail("Settings never drew its last row: \(HostedSummary.identifiers(in: window))")
        }
        XCTAssertNotNil(HostedSummary.element("settings.advanced", in: window), "no Advanced in Settings")
        for id in ["settings.whisper.status", "settings.whisper.choose-file", "settings.whisper.refresh"] {
            XCTAssertNil(HostedSummary.element(id, in: window), "\(id) on Settings' first screen")
        }
        let read = labels(in: window)
        for words in ["On-device speech", "Model file", "Verify Again", "ggml"] {
            XCTAssertFalse(read.contains { $0.localizedCaseInsensitiveContains(words) }, "\(words) on Settings' first screen")
        }
        XCTAssertTrue(read.contains { $0.contains(WhisperModelSettingsView.crashTitle) }, "\(read)")
        XCTAssertFalse(read.contains { $0.localizedCaseInsensitiveContains("crash") }, "\(read)")
    }

    /// A 403 on the box reads is most people's case: Room info keeps nothing to say about it. Another failure is kept,
    /// but said only to a person who has had boxes in the room.
    func test_a_refused_box_read_is_said_to_nobody_and_a_failed_one_only_to_people_with_boxes() async {
        let refused = FlightRecordCoordinator(sessionId: "room", mint: RefusingMint(.forbidden), sleep: { _ in },
                                              now: { Date() })
        await refused.refresh()
        XCTAssertNil(refused.state.failure, "\"This account cannot see the room's boxes.\" for a person without boxes")

        let failed = FlightRecordCoordinator(sessionId: "room", mint: RefusingMint(.unavailable), sleep: { _ in },
                                             now: { Date() })
        await failed.refresh()
        XCTAssertNotNil(failed.state.failure)
        XCTAssertNil(failed.state.shownFailure, "a box failure said to a person who never had boxes here")
    }
}
