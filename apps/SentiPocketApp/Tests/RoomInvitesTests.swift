import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class QuietRoom: RoomTransport, @unchecked Sendable {
    func roomEventsBefore(sessionId: String, beforeSequence: Int64?, limit: Int) async throws -> RoomEventPage { RoomEventPage(messages: []) }
    func roomEventsAfter(sessionId: String, fromSequence: Int64, limit: Int) async throws -> RoomEventPage { RoomEventPage(messages: []) }
    func roomStream(sessionId: String, fromSequence: Int64?) -> AsyncStream<RoomStreamEvent> { AsyncStream { _ in } }
}

private final class InvitingSender: RoomMessageSending, RoomInviting, @unchecked Sendable {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {}
    func createInviteLink(sessionId: String, role: RoomInviteRole) async throws -> URL { URL(string: "https://sentinelayer.com/x")! }
    func invite(sessionId: String, who: String, role: RoomInviteRole) async throws -> RoomInviteOutcome { .added(who) }
}

private final class PlainSender: RoomMessageSending, @unchecked Sendable {
    func sendHumanMessage(sessionId: String, text: String, clientId: String) async throws {}
}

/// Carter, #55414: "How do I invite people to rooms here like I used to do in web?"
@MainActor
final class RoomInvitesTests: XCTestCase {
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    func test_someone_with_an_account_is_added_at_once() throws {
        let outcome = RoomInviteOutcome(json: try json(["member": ["githubLogin": "simone", "role": "contributor"]]), who: "simone")
        XCTAssertEqual(outcome, .added("simone"))
        XCTAssertEqual(outcome?.message, "simone is in the room now.")
    }

    func test_an_email_invite_says_whether_the_email_went_out() throws {
        let sent = RoomInviteOutcome(json: try json(["invited": true, "invitation": ["id": "i1"], "emailDelivery": ["sent": true]]),
                                     who: "jake@example.com")
        XCTAssertEqual(sent, .invited(emailSent: true, reason: nil))

        // Carter's web invite at 08:18Z: saved, but the provider reported a delivery failure.
        let failed = RoomInviteOutcome(json: try json(["invited": true, "invitation": ["id": "i2"],
                                                       "emailDelivery": ["sent": false, "status": "failed", "reason": "delivery failure"]]),
                                       who: "jake@example.com")
        XCTAssertEqual(failed, .invited(emailSent: false, reason: "delivery failure"))
        XCTAssertTrue(failed?.message.contains("send them the link instead") == true)
        XCTAssertNil(RoomInviteOutcome(json: Data("nope".utf8), who: "x"))
    }

    func test_a_refusal_says_who_can_invite_or_what_the_api_said() {
        XCTAssertEqual(RoomInviteFailure.message(status: 403, data: Data()), "Only the room's owner or an admin can invite people.")
        XCTAssertEqual(RoomInviteFailure.message(status: 409, data: Data(#"{"detail":"The room is full (25 members)."}"#.utf8)),
                       "The room is full (25 members).")
        XCTAssertEqual(RoomInviteFailure.message(status: 500, data: Data()), "The invite didn't go through (error 500). Try again.")
    }

    func test_invite_is_offered_only_with_the_right_and_a_sender_that_can() {
        let owner = RoomChatCoordinator(sessionId: "r", title: "R", transport: QuietRoom(), sender: InvitingSender(),
                                        membershipRole: "owner", canInvite: true, onReauthenticationRequired: {})
        XCTAssertTrue(owner.state.canInvite)
        let viewer = RoomChatCoordinator(sessionId: "r", title: "R", transport: QuietRoom(), sender: InvitingSender(),
                                         membershipRole: "viewer", canInvite: false, onReauthenticationRequired: {})
        XCTAssertFalse(viewer.state.canInvite)
        let cannot = RoomChatCoordinator(sessionId: "r", title: "R", transport: QuietRoom(), sender: PlainSender(),
                                         membershipRole: "owner", canInvite: true, onReauthenticationRequired: {})
        XCTAssertFalse(cannot.state.canInvite, "a sender that cannot invite offers nothing")
    }
}
