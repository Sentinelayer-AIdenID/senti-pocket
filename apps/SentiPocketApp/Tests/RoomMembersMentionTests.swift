import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class MembersRoomTransport: RoomTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let history: [RoomMessage]
    private let page: RoomMembersPage
    private var memberReads = 0

    init(history: [RoomMessage], page: RoomMembersPage) {
        self.history = history
        self.page = page
    }

    func reads() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return memberReads
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: beforeSequence == nil ? history : [])
    }

    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }

    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }

    func roomMembers(sessionId: String) async throws -> RoomMembersPage {
        lock.lock()
        memberReads += 1
        lock.unlock()
        return page
    }
}

/// A room where some only answer in threads: their replies come from the actions read.
private final class RepliesRoomTransport: RoomTransport, @unchecked Sendable {
    let history: [RoomMessage]
    let actions: RoomActionsPage

    init(history: [RoomMessage], actions: RoomActionsPage) {
        self.history = history
        self.actions = actions
    }

    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: beforeSequence == nil ? history : [])
    }
    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage {
        RoomEventPage(messages: [])
    }
    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }
    func roomActions(sessionId: String, targetSequenceId: Int64?, limit: Int) async throws -> RoomActionsPage { actions }
}

private struct AcceptingSender: RoomMessageSending {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {}
}

@MainActor
final class RoomMembersMentionTests: XCTestCase {
    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    private func room(role: String, transport: MembersRoomTransport) -> RoomChatCoordinator {
        RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            sender: AcceptingSender(),
            membershipRole: role,
            ownAuthorIds: ["human-owner1"],
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            onReauthenticationRequired: {}
        )
    }

    private static let history = [
        RoomMessage(id: "1", sequenceId: 1, kind: .message, authorId: "review-agent", authorName: "review-agent",
                    isHuman: false, text: "hi", timestamp: "2026-10-28T20:00:00Z")
    ]

    private static let members = RoomMembersPage(members: [
        RoomMember(login: "owner1", displayName: "owner1", role: "owner"),
        RoomMember(login: "newperson1", displayName: "newperson1", role: "contributor")
    ])

    func test_an_owner_can_mention_someone_who_has_not_posted_yet_by_login() async {
        let transport = MembersRoomTransport(history: Self.history, page: Self.members)
        let coordinator = room(role: "owner", transport: transport)
        coordinator.resume()
        await waitUntil("member offered") { coordinator.state.mentionCandidates.contains { $0.handle == "newperson1" } }
        XCTAssertFalse(coordinator.state.mentionCandidates.contains { $0.handle == "owner1" }, "you are never offered")
        XCTAssertTrue(coordinator.state.mentionCandidates.contains { $0.handle == "review-agent" }, "people who posted stay")
        coordinator.pause()
    }

    /// Carter: an agent that answers in threads (most agents and boxes) was missing from the @ list.
    func test_people_and_agents_who_only_answer_in_threads_can_be_mentioned() async {
        let transport = RepliesRoomTransport(
            history: Self.history,
            actions: RoomActionsPage(replies: [
                RoomReply(id: "r1", targetSequenceId: 1, authorId: "pocket-agent", text: "on it",
                          createdAt: "2026-10-28T20:05:00Z"),
                RoomReply(id: "r2", targetSequenceId: 1, authorId: "human-griff", text: "thanks",
                          createdAt: "2026-10-28T20:06:00Z"),
                RoomReply(id: "r3", targetSequenceId: 1, authorId: "human-owner1", text: "mine",
                          createdAt: "2026-10-28T20:07:00Z")
            ])
        )
        let coordinator = RoomChatCoordinator(
            sessionId: "room_1",
            title: "Room",
            transport: transport,
            sender: AcceptingSender(),
            ownAuthorIds: ["human-owner1"],
            sleep: { seconds in if seconds > 5 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) } },
            onReauthenticationRequired: {}
        )
        coordinator.resume()
        await waitUntil("reply authors offered") { coordinator.state.mentionCandidates.contains { $0.handle == "pocket-agent" } }
        let handles = coordinator.state.mentionCandidates.map(\.handle)
        XCTAssertTrue(handles.contains("griff"), "a person who only replied, by login")
        XCTAssertTrue(handles.contains("review-agent"), "people who posted stay")
        XCTAssertFalse(handles.contains("owner1"), "you are never offered")
        coordinator.pause()
    }

    func test_a_contributor_does_not_ask_for_the_member_list() async {
        let transport = MembersRoomTransport(history: Self.history, page: Self.members)
        let coordinator = room(role: "contributor", transport: transport)
        coordinator.resume()
        await waitUntil("loaded") { !coordinator.state.isLoadingInitial }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.reads(), 0, "the API serves the member list to owners and admins only")
        XCTAssertFalse(coordinator.state.mentionCandidates.contains { $0.handle == "newperson1" })
        coordinator.pause()
    }

    func test_member_rows_carry_the_login_and_bad_rows_are_dropped() throws {
        let page = try JSONDecoder().decode(RoomMembersPage.self, from: Data("""
        {"members": [
          {"userId": "u1", "role": "owner", "githubLogin": "Owner1", "displayName": "owner1", "online": true},
          {"userId": "u2", "role": "viewer", "githubLogin": null, "displayName": "No Login"},
          {"userId": "u3", "role": "viewer", "githubLogin": "bad login!"},
          {"userId": "u4", "role": "viewer", "githubLogin": "owner1"}
        ]}
        """.utf8))
        XCTAssertEqual(page.members.map(\.login), ["owner1"], "logins are lowercased; no login means no mention handle")
        XCTAssertEqual(page.members.first?.isOnline, true)
    }
}
