import Foundation
import XCTest
@testable import PocketSyncClient

/// The whole membership, as a check that nobody else can read a message needs it: every member row counts, with or
/// without a GitHub login, and every open invitation counts.
final class RoomMembershipTests: XCTestCase {
    private func decode(_ json: String) throws -> RoomMembershipSnapshot {
        try JSONDecoder().decode(RoomMembershipSnapshot.self, from: Data(json.utf8))
    }

    func test_every_member_row_counts_with_or_without_a_login() throws {
        let membership = try decode("""
        {"sessionId": "s", "visibility": "Private", "count": 3,
         "members": [
           {"userId": "00000000-0000-4000-8000-0000000000AA", "role": "owner", "githubLogin": "someone"},
           {"userId": "00000000-0000-4000-8000-0000000000bb", "role": "viewer", "githubLogin": null},
           {"role": "viewer"}
         ],
         "invitations": [], "pendingInvitationCount": 0}
        """)
        XCTAssertEqual(membership.visibility, "private")
        XCTAssertEqual(membership.memberUserIds,
                       ["00000000-0000-4000-8000-0000000000aa", "00000000-0000-4000-8000-0000000000bb", ""],
                       "lowercased; a row without a user id is kept as an empty id, never dropped")
        XCTAssertEqual(membership.pendingInvitationCount, 0)
    }

    func test_open_invitations_count_by_the_list_or_the_count() throws {
        let listed = try decode("""
        {"visibility": "private", "members": [],
         "invitations": [{"id": "i1", "status": "pending"}, {"id": "i2", "status": "accepted"}, {"id": "i3"}]}
        """)
        XCTAssertEqual(listed.pendingInvitationCount, 2, "pending, and a row with no status, are open")
        let counted = try decode(#"{"visibility": "private", "members": [], "pendingInvitationCount": 3}"#)
        XCTAssertEqual(counted.pendingInvitationCount, 3, "the count alone is enough")
    }

    func test_a_reply_without_its_member_list_is_no_membership() {
        XCTAssertThrowsError(try decode(#"{"visibility": "private", "invitations": []}"#))
        XCTAssertEqual(try decode(#"{"members": []}"#).visibility, "", "no visibility is not private")
    }
}
