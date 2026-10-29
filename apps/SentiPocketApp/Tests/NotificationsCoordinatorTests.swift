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
}
