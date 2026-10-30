import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class QuietTransport: RoomTransport, @unchecked Sendable {
    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }
    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage { RoomEventPage(messages: []) }
    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }
}

/// Records the names it is asked to save and answers as the API would.
private final class TitleSender: RoomMessageSending, RoomTitleSetting, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    let failure: RoomSendError?
    init(failing failure: RoomSendError? = nil) { self.failure = failure }

    var saved: [String] { lock.lock(); defer { lock.unlock() }; return names }

    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {}

    func setTitle(sessionId: String, title: String) async throws -> String {
        lock.lock()
        names.append(title)
        lock.unlock()
        if let failure { throw failure }
        return title
    }
}

/// Carter, #55354: "Clicking on the name of the project should have a rename option."
@MainActor
final class RoomRenameTests: XCTestCase {
    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    private func room(_ sender: TitleSender, canRename: Bool = true) -> RoomChatCoordinator {
        RoomChatCoordinator(sessionId: "room_1", title: "Old name", transport: QuietTransport(), sender: sender,
                            membershipRole: "owner", canRename: canRename,
                            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
                            onReauthenticationRequired: {})
    }

    func test_the_owner_renames_and_the_room_shows_the_saved_name() async {
        let sender = TitleSender()
        let coordinator = room(sender)
        XCTAssertTrue(coordinator.state.canRename)

        coordinator.send(.renameRoom(title: "  Launch   week "))
        await waitUntil("renamed") { coordinator.state.title == "Launch week" }
        XCTAssertEqual(sender.saved, ["Launch week"])
        XCTAssertNil(coordinator.state.notice)
    }

    func test_a_name_the_api_would_refuse_is_not_sent_and_says_why() async {
        let sender = TitleSender()
        let coordinator = room(sender)
        coordinator.send(.renameRoom(title: "# pasted heading"))
        XCTAssertEqual(sender.saved, [])
        XCTAssertEqual(coordinator.state.title, "Old name")
        XCTAssertTrue(coordinator.state.notice?.contains("80 characters") == true)

        coordinator.send(.renameRoom(title: "Old name"))
        XCTAssertEqual(sender.saved, [], "the same name is not saved again")
    }

    func test_a_refused_rename_keeps_the_old_name_and_says_who_can() async {
        let sender = TitleSender(failing: .notAllowed)
        let coordinator = room(sender)
        coordinator.send(.renameRoom(title: "Mine now"))
        await waitUntil("refused") { coordinator.state.notice != nil }
        XCTAssertEqual(coordinator.state.title, "Old name")
        XCTAssertEqual(coordinator.state.notice, "Only the room's owner can rename it.")
    }

    func test_without_the_right_nothing_is_offered_or_sent() {
        let sender = TitleSender()
        let coordinator = room(sender, canRename: false)
        XCTAssertFalse(coordinator.state.canRename)
        coordinator.send(.renameRoom(title: "Sneaky"))
        XCTAssertEqual(sender.saved, [])
    }
}
