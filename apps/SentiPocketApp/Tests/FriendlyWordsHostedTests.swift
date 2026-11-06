import PocketContracts
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

    // MARK: The chat list's rows

    /// Every row of the chat list, hosted and read the way VoiceOver reads it, says the chat's name, when it was last
    /// active and what is unread, with its summary: never its id (a UUID, or a short hex id), the server's status, a
    /// role, a kind or a count. The chats are made up: one owned, busy, of a kind, with people online and unread; one
    /// joined, untitled and new.
    func test_a_chat_row_says_its_name_when_and_unread_never_an_id_a_role_or_counts() throws {
        let uuid = "3f2a9c4e-1b7d-4e8a-9f60-2c5d8e7a1b34"
        let shortHex = "a74f14cd09"
        let fiveMinutesAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5 * 60 - 10))
        let page = try JSONDecoder().decode(SessionListPage.self, from: Data("""
        {"sessions":[
          {"sessionId":"\(uuid)","status":"active","archiveStatus":"active","visibility":"private",
           "membershipRole":"owner","title":"Design review","summaryText":"Ada checked the new screens.",
           "agentCount":5,"eventCount":1000,"totalCostUsd":0,"lastActivityAt":"\(fiveMinutesAgo)","roomType":"research",
           "online":{"humans":2,"agents":5},"unread":{"count":2,"firstUnreadSequenceId":40},"kind":"room"},
          {"sessionId":"\(shortHex)","status":"active","archiveStatus":"active","visibility":"private",
           "membershipRole":"contributor","title":null,"agentCount":0,"eventCount":0,"totalCostUsd":0,"kind":"room"}
        ],"count":2,"include_archived":false,"next_cursor":null,"has_more":false}
        """.utf8))
        let state = SessionListPresentationState(page: page, provenance: .network(lastUpdated: Date()))
        XCTAssertEqual(state.rows.map(\.sessionId), [uuid, shortHex])
        let window = try HostedSummary.host(SessionListView(state: state) { _ in }, height: 1_200)
        defer { HostedSummary.close(window) }

        // Read once both rows are drawn: the second row's words are the last to come.
        var read: [String] = []
        let end = Date().addingTimeInterval(15)
        repeat {
            HostedSummary.pump(0.1)
            read = HostedSummary.elements(in: window)
                .flatMap { [$0.accessibilityLabel, $0.accessibilityValue] }
                .compactMap { $0 }
                .filter { !$0.isEmpty }
        } while Date() < end && !(read.contains { $0.contains("Design review") } && read.contains { $0.contains("Untitled chat") })
        for words in ["Design review", "Ada checked the new screens.", "5m ago", "2 unread", "Untitled chat",
                      "No activity yet"] {
            XCTAssertTrue(read.contains { $0.contains(words) }, "a row does not say \(words): \(read)")
        }

        let ids = try NSRegularExpression(pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                                          options: .caseInsensitive)
        // Six or more hex characters, digits and letters both: an id, never a word ("added") or a number ("1000").
        let hex = try NSRegularExpression(pattern: #"\b(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{6,}\b"#,
                                          options: .caseInsensitive)
        let server = try NSRegularExpression(pattern: #"\b(events?|agents?|owner|contributor|active|research)\b"#,
                                             options: .caseInsensitive)
        for label in read {
            let all = NSRange(label.startIndex..., in: label)
            XCTAssertNil(ids.firstMatch(in: label, range: all), "an id on the chat list: \(label)")
            XCTAssertNil(hex.firstMatch(in: label, range: all), "hex on the chat list: \(label)")
            XCTAssertNil(server.firstMatch(in: label, range: all), "a count, role, status or kind on the chat list: \(label)")
        }
    }
}
