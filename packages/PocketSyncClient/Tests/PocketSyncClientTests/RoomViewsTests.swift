import Foundation
import XCTest
@testable import PocketSyncClient

final class RoomViewsTests: XCTestCase {
    private let message = "7c3e9f10-2a4b-4c5d-8e6f-0a1b2c3d4e5f"
    private let person = "5d2c8a1e-7b3f-4c9d-8e6a-0f1b2c3d4e5f"

    func test_a_view_target_needs_a_uuid_and_a_revision_of_at_least_one() {
        let target = RoomViewTarget(kind: .message, id: message.uppercased(), revision: 0)
        XCTAssertEqual(target?.id, message, "ids are sent lowercased")
        XCTAssertEqual(target?.revision, 1)
        XCTAssertNil(RoomViewTarget(kind: .message, id: "evt-12", revision: 1), "a row without a UUID is never reported")
        XCTAssertNil(RoomViewTarget(kind: .reply, id: "", revision: 1))
    }

    func test_the_views_page_reads_each_target_and_skips_bad_viewers() throws {
        let data = Data("""
        {"targets":[
          {"kind":"message","id":"\(message)","messageRevision":2,"viewedCount":3,"selfViewed":true,
           "viewers":[
             {"actorKind":"human","actorId":"\(person)","viewedAt":"2026-10-28T23:00:00+00:00","targetRevision":2},
             {"actorKind":"agent","actorId":"cobalt-warden","viewedAt":"2026-10-28T23:01:00+00:00","source":"read-cursor"},
             {"actorKind":"robot","actorId":"x","viewedAt":"2026-10-28T23:02:00+00:00"},
             {"actorKind":"human","actorId":"  ","viewedAt":"2026-10-28T23:02:00+00:00"}
           ],"viewersTruncated":false},
          {"kind":"reply","id":"\(person)","messageRevision":1,"viewedCount":0,"selfViewed":false,"viewers":[]},
          {"kind":"ticket","id":"x"}
        ]}
        """.utf8)
        let page = try JSONDecoder().decode(RoomViewsPage.self, from: data)
        XCTAssertEqual(page.summaries.count, 2, "an unknown kind is dropped")
        let first = try XCTUnwrap(page.summaries.first)
        XCTAssertEqual(first.kind, .message)
        XCTAssertEqual(first.revision, 2)
        XCTAssertEqual(first.viewedCount, 3)
        XCTAssertTrue(first.selfViewed)
        XCTAssertEqual(first.viewers.map(\.actorId), [person, "cobalt-warden"], "bad viewer rows are dropped")
        XCTAssertEqual(first.viewers.map(\.isHuman), [true, false])
        XCTAssertEqual(page.summaries[1].kind, .reply)
        XCTAssertEqual(page.summaries[1].viewedCount, 0)
    }

    func test_presence_reads_the_roster_and_says_when_it_cannot_tell() throws {
        let healthy = try JSONDecoder().decode(RoomPresence.self, from: Data("""
        {"status":"ok","present":[
          {"agentId":"human-\(person)","kind":"human","displayName":"griff","state":"active","lastSeenMs":1,"lastSeen":"2026-10-28T23:00:00Z"},
          {"agentId":"cobalt-warden","kind":"agent","displayName":null,"state":"idle"}
        ],"humansOnline":1,"agentsOnline":1,"ttlSeconds":90}
        """.utf8))
        XCTAssertTrue(healthy.isAvailable)
        XCTAssertEqual(healthy.participants.map(\.id), ["human-\(person)", "cobalt-warden"])
        XCTAssertEqual(healthy.participants.map(\.isHuman), [true, false])
        XCTAssertEqual(healthy.participants.first?.displayName, "griff")
        XCTAssertEqual(healthy.participants.last?.isIdle, true)
        XCTAssertEqual(healthy.humansOnline, 1)
        XCTAssertEqual(healthy.ttlSeconds, 90)

        let degraded = try JSONDecoder().decode(RoomPresence.self, from: Data("""
        {"status":"degraded","present":[],"humansOnline":null,"agentsOnline":null,"ttlSeconds":90}
        """.utf8))
        XCTAssertFalse(degraded.isAvailable, "unknown is not the same as nobody")
        XCTAssertNil(degraded.humansOnline)
        XCTAssertTrue(degraded.participants.isEmpty)
    }
}
