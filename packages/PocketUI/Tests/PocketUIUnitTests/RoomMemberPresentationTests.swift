import Foundation
import XCTest
@testable import PocketUI

/// Someone's profile from any avatar or name: who opens, what Message reaches, and what the messages list says.
final class RoomMemberPresentationTests: XCTestCase {
    /// Tap anyone: every avatar and name with an id opens its profile, you and the room's own voices included. Message
    /// keeps its own rule.
    func test_every_avatar_and_name_opens_a_profile_and_message_keeps_its_rule() {
        var opened: [String] = []
        let opener = RoomProfileOpener.members(ownMentionHandles: ["alex", "all"]) { opened.append($0.senderId) }
        XCTAssertTrue(opener.opensEveryone)
        XCTAssertEqual(opener.ownAuthorIds, ["human-alex"])
        for id in ["agent-a1", "human-pat", "human-alex", "senti", "ticket-keeper", "human-g.0123abcd"] {
            XCTAssertTrue(opener.opens(id), id)
        }
        XCTAssertFalse(opener.opens("  "))
        XCTAssertFalse(opener.opens("human-"))
        XCTAssertTrue(opener(RoomProfileTarget(senderId: "human-alex", name: "alex", isAgent: false)), "your own too")
        XCTAssertEqual(opened, ["human-alex"])

        // Message is still never offered to yourself or the room's own voices.
        XCTAssertFalse(RoomProfile.opens(senderId: "human-alex", ownAuthorIds: opener.ownAuthorIds))
        XCTAssertFalse(RoomProfile.opens(senderId: "senti", ownAuthorIds: opener.ownAuthorIds))
        XCTAssertTrue(RoomProfile.opens(senderId: "human-pat", ownAuthorIds: opener.ownAuthorIds))

        // The direct-message opener keeps its own reach.
        let cards = RoomProfileOpener(ownAuthorIds: ["human-alex"]) { _ in }
        XCTAssertFalse(cards.opens("human-alex"))
        XCTAssertNotEqual(cards, RoomProfileOpener(ownAuthorIds: ["human-alex"], opensEveryone: true) { _ in })
    }

    func test_a_connection_is_said_only_when_the_api_knows_it() {
        XCTAssertNil(RoomMemberMessagesState().connectionLine, "unknown shows nothing")
        XCTAssertEqual(RoomMemberMessagesState(connection: .mcp).connectionLine, "Connected through MCP")
        XCTAssertEqual(RoomMemberMessagesState(connection: .box).connectionLine, "Runs in a box")
        XCTAssertEqual(RoomMemberMessagesState(connection: .app).connectionLine, "Posts from the Pocket app")
        XCTAssertEqual(RoomMemberMessagesState(connection: .web).connectionLine, "Posts from the web")
        XCTAssertEqual(RoomMemberMessagesState(connection: .cli).connectionLine, "Posts from the command line")
    }

    func test_what_the_list_says_when_it_has_no_rows() {
        XCTAssertEqual(RoomMemberMessagesState(isPrivate: true).emptyLine(name: "x"),
                       "Messages from people are private in public rooms")
        XCTAssertNil(RoomMemberMessagesState(canLoadMore: true).emptyLine(name: "pat"), "before the first page: nothing yet")
        XCTAssertNil(RoomMemberMessagesState(phase: .loading).emptyLine(name: "pat"))
        XCTAssertEqual(RoomMemberMessagesState().emptyLine(name: "pat"), "No messages from pat in this room yet.")
        let rows = [RoomMemberMessageRow(sequenceId: 5, text: "", date: nil, attachments: 2)]
        XCTAssertNil(RoomMemberMessagesState(rows: rows).emptyLine(name: "pat"))
        XCTAssertEqual(rows.first?.shownText, "2 files", "a message of files alone is never a blank row")
    }
}
