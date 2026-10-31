import Foundation
import PocketContracts
import XCTest
@testable import PocketUI

/// Carter, 10-31: the room list says how many people and agents are in each room, right after how long ago it was
/// active, and shows a badge with your unread messages, as Discord does.
final class RoomListActivityTests: XCTestCase {
    func test_counts_of_zero_or_none_show_nothing() {
        for activity in [RoomListActivity.none,
                         RoomListActivity(humansOnline: nil, agentsOnline: nil, unread: nil),
                         RoomListActivity(humansOnline: -1, agentsOnline: -4, unread: -2)] {
            XCTAssertFalse(activity.showsHumans)
            XCTAssertFalse(activity.showsAgents)
            XCTAssertFalse(activity.showsOnline)
            XCTAssertNil(activity.badgeText)
            XCTAssertNil(activity.onlineDescription)
            XCTAssertNil(activity.accessibilityDescription)
        }
        let agentsOnly = RoomListActivity(humansOnline: 0, agentsOnline: 2, unread: 0)
        XCTAssertFalse(agentsOnly.showsHumans, "no person when nobody is here")
        XCTAssertTrue(agentsOnly.showsAgents)
        let peopleOnly = RoomListActivity(humansOnline: 3, agentsOnline: nil, unread: 0)
        XCTAssertTrue(peopleOnly.showsHumans)
        XCTAssertFalse(peopleOnly.showsAgents, "no bot when no agent is here")
    }

    func test_the_row_says_who_is_online_and_what_is_unread_in_words() {
        XCTAssertEqual(RoomListActivity(humansOnline: 3, agentsOnline: 2, unread: 5).accessibilityDescription,
                       "3 people and 2 agents online, 5 unread")
        XCTAssertEqual(RoomListActivity(humansOnline: 1, agentsOnline: 1, unread: 0).accessibilityDescription,
                       "1 person and 1 agent online")
        XCTAssertEqual(RoomListActivity(humansOnline: 0, agentsOnline: 4, unread: 0).accessibilityDescription,
                       "4 agents online")
        XCTAssertEqual(RoomListActivity(humansOnline: 2, agentsOnline: 0, unread: 1).accessibilityDescription,
                       "2 people online, 1 unread")
        XCTAssertEqual(RoomListActivity(humansOnline: 0, agentsOnline: 0, unread: 7).accessibilityDescription,
                       "7 unread")
    }

    func test_the_badge_counts_to_99_then_says_99_plus() {
        XCTAssertNil(RoomListActivity.badgeText(for: 0))
        XCTAssertNil(RoomListActivity.badgeText(for: -3))
        XCTAssertEqual(RoomListActivity.badgeText(for: 1), "1")
        XCTAssertEqual(RoomListActivity.badgeText(for: 99), "99")
        XCTAssertEqual(RoomListActivity.badgeText(for: 100), "99+")
        XCTAssertEqual(RoomListActivity.badgeText(for: 4_000), "99+")
        XCTAssertEqual(RoomListActivity(humansOnline: 0, agentsOnline: 0, unread: 99).unreadDescription, "99 unread")
        XCTAssertEqual(RoomListActivity(humansOnline: 0, agentsOnline: 0, unread: 100).unreadDescription,
                       "more than 99 unread", "the server counts to 100 at most: 100 means 100 or more, as 99+ says")
        XCTAssertEqual(RoomListActivity(humansOnline: 3, agentsOnline: 2, unread: 100).accessibilityDescription,
                       "3 people and 2 agents online, more than 99 unread")
    }

    func test_the_room_you_are_in_has_no_badge_but_keeps_who_is_online() {
        let busy = RoomListActivity(humansOnline: 1, agentsOnline: 3, unread: 12)
        let room = PocketSidePanel.Room(id: "a", title: "Design review", subtitle: nil, lastActivity: nil, activity: busy)
        XCTAssertEqual(PocketSidePanel.shownActivity(of: room, currentRoomId: "a"),
                       RoomListActivity(humansOnline: 1, agentsOnline: 3, unread: 0))
        XCTAssertEqual(PocketSidePanel.shownActivity(of: room, currentRoomId: "b"), busy)
        XCTAssertEqual(PocketSidePanel.shownActivity(of: room, currentRoomId: nil), busy)
    }

    func test_the_side_panel_row_is_read_as_its_name_then_who_and_what() {
        XCTAssertEqual(PocketSidePanel.accessibilityLabel(
            title: "Weekly sync", isCurrent: false,
            activity: RoomListActivity(humansOnline: 3, agentsOnline: 2, unread: 5)),
                       "Weekly sync, 3 people and 2 agents online, 5 unread")
        XCTAssertEqual(PocketSidePanel.accessibilityLabel(
            title: "Design review", isCurrent: true, activity: RoomListActivity(humansOnline: 1, agentsOnline: 0, unread: 0)),
                       "Design review, open now, 1 person online")
        XCTAssertEqual(PocketSidePanel.accessibilityLabel(title: "Release notes", isCurrent: false, activity: .none),
                       "Release notes", "as before when there is nothing to say")
    }
}

/// The room list's row from the server's fields, and what this phone has read since the list was counted.
final class SessionRowActivityTests: XCTestCase {
    private func session(_ extra: String) throws -> SessionSummary {
        let json = """
        {"sessionId":"room-a","status":"active","archiveStatus":"active","visibility":"private",
        "membershipRole":"owner","title":"Room A","summaryText":null,"summaryGeneratedAt":null,"summaryModel":null,
        "agentCount":2,"eventCount":41,"totalCostUsd":0,"createdAt":null,"lastActivityAt":null,"expiresAt":null,
        "killedAt":null,"templateName":null,"codebasePath":null,"s3ArchivePath":null\(extra)}
        """
        return try JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))
    }

    private func row(_ summary: SessionSummary, readThrough: Int64? = nil) -> SessionRowPresentation? {
        SessionListPresentationState(
            sessions: [summary], includesArchived: false, hasMore: false,
            provenance: .network(lastUpdated: Date(timeIntervalSince1970: 1_000)),
            readThrough: readThrough.map { ["room-a": $0] } ?? [:]
        ).rows.first
    }

    private let badges = #","online":{"humans":3,"agents":2},"lastReadSequenceId":4810,"#
        + #""unread":{"count":5,"firstUnreadSequenceId":4811}"#

    func test_the_row_carries_who_is_online_and_where_unread_starts() throws {
        let shown = try XCTUnwrap(row(try session(badges)))
        XCTAssertEqual(shown.activity, RoomListActivity(humansOnline: 3, agentsOnline: 2, unread: 5))
        XCTAssertEqual(shown.firstUnreadSequenceId, 4811)
        XCTAssertEqual(shown.lastReadSequenceId, 4810)
    }

    func test_an_older_server_shows_no_counts_and_no_badge() throws {
        let shown = try XCTUnwrap(row(try session("")))
        XCTAssertEqual(shown.activity, .none)
        XCTAssertNil(shown.firstUnreadSequenceId)
        XCTAssertNil(shown.lastReadSequenceId)
    }

    func test_a_count_made_before_this_phone_read_the_room_shows_no_badge() throws {
        let summary = try session(badges)
        let read = try XCTUnwrap(row(summary, readThrough: 4811))
        XCTAssertEqual(read.activity.unread, 0, "the first unread is read")
        XCTAssertNil(read.firstUnreadSequenceId)
        XCTAssertEqual(read.lastReadSequenceId, 4811, "the room opens from where this phone read")
        XCTAssertEqual(read.activity.humansOnline, 3, "who is online is not about reading")

        let behind = try XCTUnwrap(row(summary, readThrough: 4800))
        XCTAssertEqual(behind.activity.unread, 5, "a read behind the first unread leaves the count")
        XCTAssertEqual(behind.firstUnreadSequenceId, 4811)
        XCTAssertEqual(behind.lastReadSequenceId, 4810)
    }

    func test_no_count_means_no_place_to_open_at() throws {
        let shown = try XCTUnwrap(row(try session(#","unread":{"count":0,"firstUnreadSequenceId":4811}"#)))
        XCTAssertEqual(shown.activity.unread, 0)
        XCTAssertNil(shown.firstUnreadSequenceId)
    }
}

/// Where the "New messages" line goes when a room opens at your first unread message, and where a room opens.
final class RoomUnreadLinePlacementTests: XCTestCase {
    private static let start = Date(timeIntervalSince1970: 1_793_000_000)

    private func input(_ seq: Int64, _ author: String = "ada-agent", _ text: String = "A note.",
                       voice: Bool = false) -> RoomChatMessageInput {
        let date = Self.start.addingTimeInterval(Double(seq) * 10)
        return RoomChatMessageInput(
            id: "evt-\(seq)", sequenceId: seq, kind: .message, authorId: author, authorName: author,
            isHuman: author.hasPrefix("human-"), text: text,
            timestamp: ISO8601DateFormatter().string(from: date), date: date, isVoiceTurn: voice
        )
    }

    private func state(_ messages: [RoomChatMessageInput], line: Int64?, canLoadOlder: Bool = false,
                       focus: Int64? = nil) -> RoomChatPresentationState {
        RoomChatPresentationState(sessionId: "room", title: "Room", messages: messages,
                                  ownAuthorIds: ["human-sam"], unreadDividerSequence: line,
                                  canLoadOlder: canLoadOlder, focusSequenceId: focus)
    }

    /// The message right under the line, or nil with no line.
    private func underTheLine(_ state: RoomChatPresentationState) -> Int64? {
        guard let index = state.rows.firstIndex(of: .unreadDivider), index + 1 < state.rows.count,
              case .message(let row) = state.rows[index + 1] else { return nil }
        return row.sequenceId
    }

    func test_the_line_goes_right_before_the_first_unread_message() {
        let rows = state((1...6).map { input($0) }, line: 4)
        XCTAssertEqual(underTheLine(rows), 4)
        XCTAssertEqual(rows.rows.filter { $0 == .unreadDivider }.count, 1, "one line")
    }

    func test_a_first_unread_spoken_in_a_call_puts_the_line_before_the_calls_card() {
        let messages = [
            input(100),
            input(101, "human-sam", VoiceCallMarkers.start(caller: "sam", agents: ["ada-agent"], meeting: false)),
            input(102, "human-sam", "Can you hear me?", voice: true),
            input(103, "ada-agent", "Yes, loud and clear."),
            input(104, "human-sam", "\(VoiceCallMarkers.endPrefix)ada-agent ended after 1 min.")
        ]
        let rows = state(messages, line: 103)
        XCTAssertEqual(underTheLine(rows), 101, "the call's card holds the answer you have not heard")
    }

    func test_a_line_before_every_loaded_row_waits_for_its_place_while_older_rows_are_not_loaded() {
        let messages = (10...15).map { input($0) }
        XCTAssertNil(underTheLine(state(messages, line: 5, canLoadOlder: true)), "where it belongs is not loaded")
        XCTAssertEqual(underTheLine(state(messages, line: 5, canLoadOlder: false)), 10, "the start of the room")
        XCTAssertEqual(underTheLine(state(messages, line: 10, canLoadOlder: true)), 10, "the first loaded row itself")
    }

    func test_a_line_after_every_row_shows_nothing() {
        XCTAssertNil(underTheLine(state((1...6).map { input($0) }, line: 9)))
    }

    func test_the_room_opens_at_the_line_on_its_first_list_and_at_the_latest_when_put_back_there() {
        let messages = (1...6).map { input($0) }
        XCTAssertEqual(state(messages, line: 4).openPosition(reopening: false), .unreadLine)
        XCTAssertEqual(state(messages, line: 4).openPosition(reopening: true), .latest,
                       "a send or Jump to latest from up the history goes to the newest")
        XCTAssertEqual(state(messages, line: nil).openPosition(reopening: false), .latest, "nothing unread: as before")
        XCTAssertEqual(state(messages, line: 4, focus: 2).openPosition(reopening: false), .message(2),
                       "a link or notification decides")
    }
}
