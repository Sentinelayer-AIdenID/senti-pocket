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

/// Fails the first marks, then lets them through; counts how many are in flight at once.
private final class TroubledMarker: NotificationReadMarking, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: Int
    private var inFlight = 0
    private(set) var mostAtOnce = 0
    private var ids: [String] = []

    init(failures: Int = 0) { self.failures = failures }

    func markRead(id: String) async throws {
        let fail: Bool = lock.withLock {
            inFlight += 1
            mostAtOnce = max(mostAtOnce, inFlight)
            if failures > 0 { failures -= 1; return true }
            return false
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        lock.withLock {
            inFlight -= 1
            if !fail { ids.append(id) }
        }
        if fail { throw RoomSendError.retryable(retryAfterSeconds: nil) }
    }

    func marked() -> [String] { lock.withLock { ids } }
    func peak() -> Int { lock.withLock { mostAtOnce } }
}

@MainActor
final class NotificationsCoordinatorTests: XCTestCase {
    private func note(_ id: String, read: Bool = false, url: String? = nil, at: String = "2026-10-28T18:00:00Z",
                      room: String = "room_1") -> SentiNotification {
        SentiNotification(
            id: id,
            kind: "mention",
            sessionId: room,
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

    /// Carter (10-30): "Notification numbers don't go down or the notification marked as read as I click and open
    /// them". A room on screen, however it was opened (a push, a banner, the side panel), reads its notifications.
    func test_a_room_on_screen_reads_its_notifications_and_leaves_other_rooms_alone() async {
        let marker = RecordingMarker()
        let coordinator = NotificationsCoordinator(
            transport: ScriptedNotifications([
                .success(SentiNotificationsPage(notifications: [
                    note("a1"), note("a2", read: true), note("b1", room: "room_2")
                ])),
                .success(SentiNotificationsPage(notifications: [
                    note("a3"), note("a1"), note("a2", read: true), note("b1", room: "room_2")
                ]))
            ]),
            marker: marker,
            onReauthenticationRequired: {}
        )
        await coordinator.refresh()
        XCTAssertEqual(coordinator.unreadCount, 2)

        coordinator.markRoomRead("room_1")
        XCTAssertEqual(coordinator.unreadCount, 1, "the badge goes down at once")
        await waitUntil("a1 marked on the server") { marker.marked() == ["a1"] }

        // A new one arrives while the room is on screen: read as it comes.
        coordinator.roomOnScreen = { "room_1" }
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.unread.map(\.id), ["b1"], "another room's stays unread")
        await waitUntil("a3 marked too") { Set(marker.marked()) == ["a1", "a3"] }
    }

    /// Warden (#267): read while the room's messages are on screen, not on the way in, and not under a sheet.
    func test_the_room_read_tracker_reads_only_a_shown_uncovered_room() async {
        let marker = RecordingMarker()
        let coordinator = NotificationsCoordinator(
            transport: ScriptedNotifications([
                .success(SentiNotificationsPage(notifications: [note("a1"), note("b1", room: "room_2")])),
                .success(SentiNotificationsPage(notifications: [note("a2"), note("a1"), note("b1", room: "room_2")]))
            ]),
            marker: marker,
            onReauthenticationRequired: {}
        )
        let reads = RoomReadTracker(notifications: coordinator)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.unreadCount, 2, "nothing read before a room is shown")

        reads.isCovered = true
        reads.shown("room_1")
        XCTAssertEqual(coordinator.unreadCount, 2, "under a sheet or the side panel nothing is read")
        reads.isCovered = false
        XCTAssertEqual(coordinator.state.unread.map(\.id), ["b1"], "uncovered: its room's are read")

        reads.isCovered = true
        await coordinator.refresh()
        XCTAssertEqual(Set(coordinator.state.unread.map(\.id)), ["a2", "b1"], "the poll reads nothing under the bell")

        reads.gone("room_2")
        XCTAssertEqual(reads.shownRoom, "room_1", "another room leaving keeps this one")
        reads.gone("room_1")
        reads.isCovered = false
        XCTAssertEqual(Set(coordinator.state.unread.map(\.id)), ["a2", "b1"], "a room gone reads nothing")
        await waitUntil("a1 marked") { marker.marked() == ["a1"] }
    }

    /// Warden (#267): one PATCH each, never fifty at once, and a failed one is retried rather than hidden.
    func test_marks_go_a_few_at_a_time_and_a_failed_one_is_unread_again_for_the_next_try() async {
        let marker = TroubledMarker(failures: 1)
        let page = SentiNotificationsPage(notifications: (0..<12).map { note("n\($0)") })
        let coordinator = NotificationsCoordinator(
            transport: ScriptedNotifications([.success(page)]),
            marker: marker,
            onReauthenticationRequired: {}
        )
        await coordinator.refresh()
        coordinator.markRoomRead("room_1")
        XCTAssertEqual(coordinator.unreadCount, 0)
        await waitUntil("all tried") { marker.marked().count == 11 }
        XCTAssertLessThanOrEqual(marker.peak(), NotificationsCoordinator.concurrentMarks)
        XCTAssertEqual(coordinator.unreadCount, 1, "the one that failed is unread again")

        coordinator.markRoomRead("room_1")
        await waitUntil("retried") { marker.marked().count == 12 }
        XCTAssertEqual(coordinator.unreadCount, 0)
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
