import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class TwoTicketTransport: RoomTicketsTransport, @unchecked Sendable {
    func roomTicketSnapshot(sessionId: String, afterId: String?, limit: Int) async throws -> RoomTicketSnapshotPage {
        RoomTicketSnapshotPage(items: [
            // Snapshot ids are strictly ascending, as the API pages them.
            RoomTicket(id: "done-1", title: "Finished", status: "done", version: 2),
            RoomTicket(id: "open-1", title: "Open", status: "open", version: 1)
        ], hasMore: false, cursor: 1)
    }

    func roomTicketEvents(sessionId: String, after: Int64, limit: Int) async throws -> RoomTicketEventsPage {
        RoomTicketEventsPage(tickets: [], eventCount: 0, cursor: after)
    }
}

final class RoomLinkRouterTests: XCTestCase {
    private let room = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"

    private func action(_ link: String, inRoom sessionId: String? = nil) -> RoomLinkAction {
        RoomLinkRouter.action(for: URL(string: link)!, inRoom: sessionId ?? room)
    }

    func test_links_to_this_room_stay_in_the_room() {
        XCTAssertEqual(action("https://sentinelayer.com/dashboard/sessions/\(room)?message=3456"), .focusMessage(3456))
        XCTAssertEqual(action("/dashboard/sessions/\(room)?ticket=c0ffee08-1234"), .openTicket("c0ffee08-1234"),
                       "the decision line's relative ticket link opens the ticket over the room")
        XCTAssertEqual(action("https://www.sentinelayer.com/app/sessions/\(room)?admission=adm-1"), .openAdmissions)
        XCTAssertEqual(action("https://sentinelayer.com/dashboard/sessions/\(room.uppercased())?message=7"), .focusMessage(7),
                       "room ids compare without case")
        XCTAssertEqual(action("https://sentinelayer.com/dashboard/sessions/\(room)"), .ignore, "already here")
    }

    func test_a_ticket_wins_over_a_message_like_the_web_drawer() {
        XCTAssertEqual(action("/dashboard/sessions/\(room)?message=5&ticket=t1"), .openTicket("t1"))
    }

    func test_another_room_opens_that_room() {
        let other = "/dashboard/sessions/room_2?message=9"
        XCTAssertEqual(action(other), .openRoom(SentiLink(sessionId: "room_2", messageSequence: 9)))
    }

    func test_other_web_links_open_in_the_browser_and_unsafe_links_do_nothing() {
        XCTAssertEqual(action("https://github.com/a/b/pull/1"), .openInBrowser(URL(string: "https://github.com/a/b/pull/1")!))
        XCTAssertEqual(action("/pricing"), .openInBrowser(URL(string: "https://sentinelayer.com/pricing")!),
                       "an in-app path that is not a room opens on the Senti site, as the web resolves it")
        XCTAssertEqual(action("//evil.example/dashboard/sessions/\(room)"), .ignore, "protocol-relative links never open")
        XCTAssertEqual(action("javascript:alert(1)"), .ignore)
        XCTAssertEqual(action("tel:5551234"), .ignore)
        XCTAssertEqual(action("http://sentinelayer.com/dashboard/sessions/\(room)?message=1"),
                       .openInBrowser(URL(string: "http://sentinelayer.com/dashboard/sessions/\(room)?message=1")!),
                       "plain http is never treated as an in-app link")
    }
}

@MainActor
final class IncomingLinkInboxTests: XCTestCase {
    func test_a_room_link_waits_until_taken_once() {
        let inbox = IncomingLinkInbox()
        XCTAssertTrue(inbox.receive(URL(string: "https://sentinelayer.com/dashboard/sessions/room_1?ticket=t1")!))
        XCTAssertEqual(inbox.revision, 1)
        XCTAssertEqual(inbox.take(), SentiLink(sessionId: "room_1", ticketId: "t1"))
        XCTAssertNil(inbox.take(), "each link opens once")
    }

    func test_only_senti_room_links_are_queued_and_the_newest_wins() {
        let inbox = IncomingLinkInbox()
        XCTAssertFalse(inbox.receive(URL(string: "https://evil.example/dashboard/sessions/room_1")!))
        XCTAssertFalse(inbox.receive(URL(string: "https://sentinelayer.com/pricing")!))
        XCTAssertEqual(inbox.revision, 0)
        inbox.receive(URL(string: "https://sentinelayer.com/dashboard/sessions/room_1")!)
        inbox.receive(URL(string: "https://sentinelayer.com/dashboard/sessions/room_2?admission=adm-1")!)
        XCTAssertEqual(inbox.take(), SentiLink(sessionId: "room_2", admissionId: "adm-1"))
    }
}

@MainActor
final class RoomTicketLinkTests: XCTestCase {
    func test_a_linked_ticket_is_found_even_when_the_list_hides_it() async {
        let coordinator = RoomTicketsCoordinator(
            sessionId: "room_1",
            transport: TwoTicketTransport(),
            focusTicketId: "done-1",
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            onReauthenticationRequired: {}
        )
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.rows.map(\.id), ["open-1"], "the list shows active tickets")
        XCTAssertEqual(coordinator.state.focusedTicket?.id, "done-1", "a link still opens an archived ticket")
    }
}
