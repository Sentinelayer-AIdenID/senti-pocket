import Foundation
import XCTest
@testable import PocketSyncClient

final class SentiNotificationsTests: XCTestCase {
    func test_links_open_rooms_messages_replies_and_tickets_from_senti_only() {
        let full = SentiLink(string: "https://sentinelayer.com/dashboard/sessions/0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d?message=4242&reply=7c3e9f10-2a4b-4c5d-8e6f-0a1b2c3d4e5f")
        XCTAssertEqual(full?.sessionId, "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d")
        XCTAssertEqual(full?.messageSequence, 4242)
        XCTAssertEqual(full?.replyId, "7c3e9f10-2a4b-4c5d-8e6f-0a1b2c3d4e5f")

        XCTAssertEqual(SentiLink(string: "/dashboard/sessions/room_1?ticket=c0ffee08-1234")?.ticketId, "c0ffee08-1234",
                       "in-app relative links resolve")
        XCTAssertEqual(SentiLink(string: "https://www.sentinelayer.com/app/sessions/room_1")?.sessionId, "room_1",
                       "the /app alias resolves")
        XCTAssertNil(SentiLink(string: "https://evil.example/dashboard/sessions/room_1"), "other hosts never route in-app")
        XCTAssertNil(SentiLink(string: "http://sentinelayer.com/dashboard/sessions/room_1"), "https only")
        XCTAssertNil(SentiLink(string: "https://sentinelayer.com:444/dashboard/sessions/room_1"))
        XCTAssertNil(SentiLink(string: "https://sentinelayer.com/dashboard/sessions/room_1/extra"))
        XCTAssertNil(SentiLink(string: "https://sentinelayer.com/dashboard/sessions/..%2F..?message=1"))
        XCTAssertNil(SentiLink(string: "https://sentinelayer.com/dashboard/sessions/room_1?message=0")?.messageSequence,
                     "a non-positive message is ignored")
        XCTAssertNil(SentiLink(string: "https://sentinelayer.com/dashboard/sessions/room_1?reply=not-a-uuid")?.replyId)
        XCTAssertEqual(SentiLink(string: "https://sentinelayer.com/dashboard/sessions/room_1?admission=adm_1.a-b:c")?.admissionId,
                       "adm_1.a-b:c", "an agent's request to join opens from its link")
        XCTAssertNil(SentiLink(string: "https://sentinelayer.com/dashboard/sessions/room_1?admission=a%2Fb")?.admissionId,
                     "an admission id outside the id alphabet is dropped, the room still opens")
    }

    func test_the_page_decodes_notifications_and_names_the_actor_like_the_web() throws {
        let page = try JSONDecoder().decode(SentiNotificationsPage.self, from: Data("""
        {"ok":true,"notifications":[
          {"id":"n1","kind":"mention","subjectId":"room_1","title":"cobalt-warden mentioned you","body":"@mrrCarter look",
           "actionUrl":"https://sentinelayer.com/dashboard/sessions/room_1?message=12","isRead":false,
           "createdAt":"2026-10-28T18:47:41+00:00","actorName":null},
          {"id":"n2","kind":"invite_accepted","subjectId":"room_2","title":"Someone accepted your invite","body":"",
           "actionUrl":"https://sentinelayer.com/dashboard/sessions/room_2","isRead":true,"createdAt":"2026-10-27T10:00:00+00:00",
           "actorName":"griff"},
          {"kind":"mention"}
        ]}
        """.utf8))
        XCTAssertEqual(page.notifications.map(\.id), ["n1", "n2"], "a row without an id is skipped")
        XCTAssertEqual(page.notifications[0].link?.messageSequence, 12)
        XCTAssertEqual(page.notifications[1].title, "griff accepted your invite")
        XCTAssertTrue(page.notifications[1].isRead)
    }
}
