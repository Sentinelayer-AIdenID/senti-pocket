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

    // MARK: How long ago

    /// Activity and Saved summaries, hosted, say how long ago in words ("42m ago", "3h ago"), never iOS's ticking
    /// "42 min, 12 sec". The room, its people and its words are made up.
    func test_activity_and_saved_summaries_say_how_long_ago_never_a_ticking_time() throws {
        let iso = ISO8601DateFormatter()
        let fortyTwoMinutesAgo = iso.string(from: Date().addingTimeInterval(-42 * 60 - 12))
        let thirtyEightMinutesAgo = iso.string(from: Date().addingTimeInterval(-38 * 60 - 12))
        let threeHoursAgo = iso.string(from: Date().addingTimeInterval(-3 * 3_600 - 12))
        let decoder = JSONDecoder()
        let events = try decoder.decode(SessionEventForwardPage.self, from: Data("""
        {"events":[{"id":"ev-1","event":"session_message","agent":{"displayName":"Ada"},
        "agentId":"human-ada","agentModel":"","payload":{"text":"Can someone check the notes?"},
        "ts":"\(fortyTwoMinutesAgo)","timestamp":"\(fortyTwoMinutesAgo)","cursor":"c1",
        "sequenceId":7,"sessionId":"room-1","source":"phone"}]}
        """.utf8))
        let actions = try decoder.decode(SessionActionPage.self, from: Data("""
        {"sessionId":"room-1","count":1,"projection":{},"actions":[{"id":"act-1",
        "sessionId":"room-1","targetSequenceId":7,"targetCursor":null,"targetActionId":null,
        "actionType":"ack","actorKind":"human","actorId":"ada","actorUserId":null,"actorRole":"owner",
        "note":"Read it","metadata":{},"idempotencyKey":"idem-1","createdAt":"\(thirtyEightMinutesAgo)"}]}
        """.utf8))
        let checkpoints = try decoder.decode(SessionCheckpointListPage.self, from: Data("""
        {"checkpoints":[{"checkpointId":"cp-1","sessionId":"room-1","kind":"manual_checkpoint",
        "title":"Sunday summary","summary":"Ada and the agents agreed the notes.","startSequence":1,
        "endSequence":7,"tokenRange":null,"createdBy":"ada","createdByAgentId":"human-ada","eventSequence":8,
        "cursor":"c8","createdAt":"\(threeHoursAgo)","summarySections":{},"grade":"A-","gradeScore":91,
        "gradeVersion":"v1","gradeReasons":[]}],"count":1}
        """.utf8))
        let activity = SessionActivityPresentationState(sessionId: "room-1", eventPage: events, actionPage: actions,
                                                        provenance: .network(lastUpdated: Date()))
        let saved = SessionCheckpointListPresentationState(sessionId: "room-1", page: checkpoints,
                                                          provenance: .network(lastUpdated: Date()))
        XCTAssertNil(activity.failure)
        XCTAssertNil(saved.failure)
        // iOS's ticking time: "42 min, 12 sec", "3 hr, 1 min".
        let ticking = try NSRegularExpression(pattern: #"\b\d+ (sec|min|hr|hrs)\b"#)
        let screens: [(String, AnyView, [String])] = [
            ("Activity", AnyView(SessionActivityView(state: activity) { _ in }), ["42m ago", "38m ago"]),
            ("Saved summaries", AnyView(SessionCheckpointListView(state: saved) { _ in }), ["3h ago"]),
        ]
        for (screen, view, wanted) in screens {
            let window = try HostedSummary.host(view, height: 1_200)
            var read: [String] = []
            let end = Date().addingTimeInterval(15)
            repeat {
                HostedSummary.pump(0.1)
                read = HostedSummary.elements(in: window).compactMap(\.accessibilityLabel).filter { !$0.isEmpty }
            } while Date() < end && !(wanted.allSatisfy { words in read.contains { $0.contains(words) } })
            HostedSummary.close(window)
            for words in wanted {
                XCTAssertTrue(read.contains { $0.contains(words) }, "\(screen) does not say \(words): \(read)")
            }
            for label in read {
                XCTAssertNil(ticking.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
                             "\(screen) shows a ticking time: \(label)")
            }
        }
    }

    // MARK: The Pocket sheet

    /// With no chat open the Pocket sheet says chat, never session or authorization.
    func test_the_pocket_sheet_with_no_chat_open_says_chat() {
        XCTAssertEqual(PocketIdleWords.title, "Choose a chat")
        for words in [PocketIdleWords.title, PocketIdleWords.message] {
            XCTAssertFalse(words.localizedCaseInsensitiveContains("session"), words)
            XCTAssertFalse(words.localizedCaseInsensitiveContains("authoriz"), words)
        }
    }

    // MARK: The ring's count

    /// The count on the ring's pill stays inside the pill at every text size, the largest too: digits taller than the
    /// pill spill over "Start of the room", which a UI test cannot see (it reads the ring as one element).
    func test_the_rings_count_stays_inside_its_pill_at_the_largest_text_size() {
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3, .accessibility5] {
            let digits = UIHostingController(rootView: RoomCountPillDigits.text("88").environment(\.dynamicTypeSize, size))
            let fitted = digits.sizeThatFits(in: CGSize(width: 300, height: 300))
            XCTAssertGreaterThan(fitted.height, 0, "\(size): the digits drew")
            XCTAssertLessThanOrEqual(fitted.height, RoomCountPillDigits.height, "\(size): the digits spill out of the pill")
        }
    }
}
