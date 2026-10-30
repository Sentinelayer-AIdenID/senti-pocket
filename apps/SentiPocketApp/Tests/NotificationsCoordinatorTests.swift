import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class ScriptedNotifications: NotificationsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [Result<SentiNotificationsPage, Error>]

    init(_ pages: [Result<SentiNotificationsPage, Error>]) { self.pages = pages }

    func notifications() async throws -> SentiNotificationsPage {
        let next: Result<SentiNotificationsPage, Error> = {
            lock.lock()
            defer { lock.unlock() }
            return pages.count > 1 ? pages.removeFirst() : (pages.first ?? .success(SentiNotificationsPage(notifications: [])))
        }()
        return try next.get()
    }
}

private final class RecordingMarker: NotificationReadMarking, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    func markRead(id: String) async throws {
        lock.lock()
        ids.append(id)
        lock.unlock()
    }

    func marked() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

@MainActor
final class NotificationsCoordinatorTests: XCTestCase {
    private func note(_ id: String, read: Bool = false, url: String? = nil, at: String = "2026-10-28T18:00:00Z") -> SentiNotification {
        SentiNotification(
            id: id,
            kind: "mention",
            sessionId: "room_1",
            title: "cobalt-warden mentioned you",
            link: url.flatMap(SentiLink.init(string:)),
            isRead: read,
            createdAt: at
        )
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    func test_refresh_counts_unread_and_opening_marks_read_and_returns_the_message() async {
        let marker = RecordingMarker()
        let coordinator = NotificationsCoordinator(
            transport: ScriptedNotifications([.success(SentiNotificationsPage(notifications: [
                note("n1", url: "https://sentinelayer.com/dashboard/sessions/room_1?message=4242"),
                note("n2", read: true, at: "2026-10-27T18:00:00Z")
            ]))]),
            marker: marker,
            roomTitle: { _ in "Senti-expansion-proj" },
            onReauthenticationRequired: {}
        )
        await coordinator.refresh()
        XCTAssertEqual(coordinator.unreadCount, 1)
        XCTAssertEqual(coordinator.state.unread.first?.roomTitle, "Senti-expansion-proj")
        XCTAssertEqual(coordinator.state.earlier.map(\.id), ["n2"])

        let link = coordinator.open("n1")
        XCTAssertEqual(link?.sessionId, "room_1")
        XCTAssertEqual(link?.messageSequence, 4242)
        XCTAssertEqual(coordinator.unreadCount, 0, "opening reads it at once")
        await waitUntil("marked on the server") { marker.marked() == ["n1"] }
    }

    func test_a_notification_without_a_link_opens_its_room_and_mark_all_read_marks_each() async {
        let marker = RecordingMarker()
        let coordinator = NotificationsCoordinator(
            transport: ScriptedNotifications([.success(SentiNotificationsPage(notifications: [note("a"), note("b"), note("c", read: true)]))]),
            marker: marker,
            onReauthenticationRequired: {}
        )
        await coordinator.refresh()
        XCTAssertEqual(coordinator.open("a")?.sessionId, "room_1", "no link: open the room itself")
        coordinator.markAllRead()
        XCTAssertEqual(coordinator.unreadCount, 0)
        await waitUntil("each marked once") { Set(marker.marked()) == ["a", "b"] && marker.marked().count == 2 }
    }

    func test_an_expired_sign_in_stops_the_bell() async {
        var asked = 0
        let coordinator = NotificationsCoordinator(
            transport: ScriptedNotifications([.failure(SessionTransportError.reauthenticationRequired)]),
            marker: nil,
            onReauthenticationRequired: { asked += 1 }
        )
        await coordinator.refresh()
        await coordinator.refresh()
        XCTAssertEqual(asked, 1, "a signed-out bell asks once and stops")
        XCTAssertEqual(coordinator.state.failure, .reauthenticationRequired)
    }

    /// Carter: the phone's bell stopped updating while the server had new mentions. A failed read must say so, and
    /// a later read must recover.
    func test_a_failed_read_keeps_the_list_says_so_and_the_next_read_recovers() async {
        let stamp = Date(timeIntervalSince1970: 1_793_300_000)
        let coordinator = NotificationsCoordinator(
            transport: ScriptedNotifications([
                .success(SentiNotificationsPage(notifications: [note("n1")])),
                .failure(URLError(.timedOut)),
                .success(SentiNotificationsPage(notifications: [note("n2", at: "2026-10-28T19:00:00Z"), note("n1")]))
            ]),
            marker: nil,
            now: { stamp },
            onReauthenticationRequired: {}
        )
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.updatedAt, stamp)
        XCTAssertFalse(coordinator.state.couldNotUpdate)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.unread.map(\.id), ["n1"], "the list stays")
        XCTAssertTrue(coordinator.state.couldNotUpdate, "and says it could not update")
        XCTAssertNil(coordinator.state.failure)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.unread.map(\.id), ["n2", "n1"])
        XCTAssertFalse(coordinator.state.couldNotUpdate)
    }

    func test_after_an_expired_sign_in_opening_the_bell_reads_again_and_a_success_brings_it_back() async {
        var asked = 0
        let coordinator = NotificationsCoordinator(
            transport: ScriptedNotifications([
                .failure(SessionTransportError.reauthenticationRequired),
                .success(SentiNotificationsPage(notifications: [note("n1")]))
            ]),
            marker: nil,
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            onReauthenticationRequired: { asked += 1 }
        )
        await coordinator.refresh()
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.failure, .reauthenticationRequired, "the poll does not keep asking")
        await coordinator.refresh(force: true)
        XCTAssertNil(coordinator.state.failure, "opening the bell tries again")
        XCTAssertEqual(coordinator.state.unread.map(\.id), ["n1"])
        XCTAssertEqual(asked, 1)
        coordinator.stopPolling()
    }

    func test_the_bell_reads_as_often_as_the_web_and_says_how_fresh_it_is() {
        XCTAssertEqual(NotificationsCoordinator.pollInterval, 30)
        let now = Date(timeIntervalSince1970: 1_793_300_000)
        XCTAssertEqual(NotificationsPresentationState.freshness(updatedAt: now.addingTimeInterval(-20), now: now), "Updated just now")
        XCTAssertEqual(NotificationsPresentationState.freshness(updatedAt: now.addingTimeInterval(-250), now: now), "Updated 4 min ago")
    }
}
