import Foundation
import XCTest
@testable import PocketSyncClient

final class RoomBreakoutsTests: XCTestCase {
    private func page(_ json: String) throws -> RoomBreakoutsPage {
        try JSONDecoder().decode(RoomBreakoutsPage.self, from: Data(json.utf8))
    }

    private func events(_ json: String) throws -> RoomEventPage {
        try JSONDecoder().decode(RoomEventPage.self, from: Data(json.utf8))
    }

    func test_a_descriptor_gives_the_card_and_what_this_viewer_may_do() throws {
        let result = try page("""
        {"items": [{
          "version": 1, "childSessionId": "child_1", "parentSessionId": "room_1", "revision": 3,
          "parentAnchorSequence": 120, "sourceMessageSequence": 118, "title": "Pick the storage",
          "status": "open", "agentAccess": "approval_required", "createdAt": "2026-10-28T20:40:00Z",
          "participants": [{"kind": "agent", "id": "cobalt-warden"}, {"kind": "human", "id": "human-mrrcarter", "name": "Carter"}],
          "messageCount": 12, "unreadCount": 3,
          "viewer": {"canRead": true, "canPost": false, "canRequestAccess": false, "canManageAgentAccess": true},
          "publishedOutcome": null
        }], "nextCursor": null, "complete": true}
        """)
        let breakout = try XCTUnwrap(result.items.first)
        XCTAssertEqual(breakout.title, "Pick the storage")
        XCTAssertTrue(breakout.isOpen)
        XCTAssertTrue(breakout.isLocked, "approval_required locks it to agents")
        XCTAssertEqual(breakout.participants?.map(\.id), ["cobalt-warden", "human-mrrcarter"])
        XCTAssertEqual(breakout.participants?.last?.name, "Carter")
        XCTAssertEqual(breakout.messageCount, 12)
        XCTAssertEqual(breakout.unreadCount, 3)
        XCTAssertTrue(breakout.canRead)
        XCTAssertFalse(breakout.canPost)
        XCTAssertFalse(breakout.hasPublishedOutcome)
        XCTAssertEqual(breakout.parentAnchorSequence, 120)
    }

    func test_what_the_server_withholds_stays_unknown_and_bad_rows_are_dropped() throws {
        let result = try page("""
        {"items": [
          {"childSessionId": "child_2", "title": "Locked breakout", "status": "closed", "participants": null,
           "messageCount": null, "unreadCount": null, "viewer": {"canRead": false, "canPost": false}},
          {"childSessionId": "../escape", "title": "bad id"},
          {"title": "no id"},
          {"childSessionId": "child_2", "title": "duplicate"}
        ]}
        """)
        XCTAssertEqual(result.items.map(\.childSessionId), ["child_2"])
        let hidden = try XCTUnwrap(result.items.first)
        XCTAssertNil(hidden.participants)
        XCTAssertNil(hidden.messageCount)
        XCTAssertFalse(hidden.isOpen)
        XCTAssertFalse(hidden.canRead, "no viewer flag means no access, never access by default")
    }

    func test_the_parent_timeline_carries_breakout_cards_and_outcomes() throws {
        let result = try events("""
        {"events": [
          {"id": "e1", "sequenceId": 120, "event": "session_breakout_opened", "agent": {"id": "cobalt-warden"},
           "ts": "2026-10-28T20:40:00Z", "payload": {"childSessionId": "child_1", "relationVersion": 1}},
          {"id": "e2", "sequenceId": 130, "event": "session_breakout_outcome", "agent": {"id": "coral-helper"},
           "ts": "2026-10-28T21:00:00Z", "payload": {
             "childSessionId": "child_1", "outcomeId": "out_1", "revision": 2, "contentHash": "ab",
             "text": "Use R2 for media.", "authorId": "coral-helper", "sourceThrough": "c1", "publishedAt": "2026-10-28T21:00:00Z",
             "acknowledgements": [
               {"principalId": "coral-helper", "principalKind": "agent", "state": "ack"},
               {"principalId": "cobalt-warden", "principalKind": "agent", "state": "disagree"},
               {"principalId": "human-mrrcarter", "principalKind": "human", "state": "maybe"},
               {"principalId": "coral-helper", "principalKind": "agent", "state": "ack"}
             ]}},
          {"id": "e3", "sequenceId": 131, "event": "session_breakout_opened", "payload": {"relationVersion": 1}},
          {"id": "e4", "sequenceId": 132, "event": "session_breakout_outcome", "payload": {"childSessionId": "child_1", "outcomeId": "o", "text": "  "}}
        ], "has_more": false}
        """)
        XCTAssertEqual(result.messages.map(\.sequenceId), [120, 130], "a card without a room, or an outcome without text, is not shown")
        let opened = result.messages[0]
        XCTAssertEqual(opened.kind, .breakoutOpened)
        XCTAssertEqual(opened.breakout?.childSessionId, "child_1")
        XCTAssertNil(opened.breakout?.outcome)

        let outcome = try XCTUnwrap(result.messages[1].breakout?.outcome)
        XCTAssertEqual(result.messages[1].kind, .breakoutOutcome)
        XCTAssertEqual(outcome.text, "Use R2 for media.")
        XCTAssertEqual(outcome.revision, 2)
        XCTAssertEqual(outcome.acknowledgements.map(\.principalId), ["coral-helper", "cobalt-warden", "human-mrrcarter"],
                       "one answer per participant")
        XCTAssertEqual(outcome.acknowledgements.map(\.state), [.ack, .disagree, .missing],
                       "an unknown state reads as not acknowledged, never as agreement")
        XCTAssertTrue(outcome.acknowledgements[2].isHuman)
    }
}
