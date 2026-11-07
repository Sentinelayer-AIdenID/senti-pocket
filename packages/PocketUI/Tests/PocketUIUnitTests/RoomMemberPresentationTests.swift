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
        // Ticket f7254a3b: hosted MCP, the CLI's own MCP server and the CLI are told apart.
        XCTAssertEqual(RoomMemberMessagesState(connection: .hostedMCP).connectionLine, "Connected through MCP")
        XCTAssertEqual(RoomMemberMessagesState(connection: .cliMCP).connectionLine, "Connected through the CLI (MCP)")
        XCTAssertEqual(RoomMemberMessagesState(connection: .cli).connectionLine, "Connected through the CLI")
        XCTAssertEqual(RoomMemberMessagesState(connection: .box).connectionLine, "Runs in a box")
        XCTAssertEqual(RoomMemberMessagesState(connection: .app).connectionLine, "Posts from the Pocket app")
        XCTAssertEqual(RoomMemberMessagesState(connection: .web).connectionLine, "Posts from the web")
    }

    func test_what_the_list_says_when_it_has_no_rows() {
        XCTAssertEqual(RoomMemberMessagesState(isPrivate: true).emptyLine(name: "x"),
                       "You're reading this public room as a visitor, so this person shows under a stand-in name, and "
                       + "their messages can't be listed.")
        XCTAssertNil(RoomMemberMessagesState(canLoadMore: true).emptyLine(name: "pat"), "before the first page: nothing yet")
        XCTAssertNil(RoomMemberMessagesState(phase: .loading).emptyLine(name: "pat"))
        XCTAssertEqual(RoomMemberMessagesState().emptyLine(name: "pat"), "No messages from pat in this room yet.")
        let rows = [RoomMemberMessageRow(sequenceId: 5, text: "", date: nil, attachments: 2)]
        XCTAssertNil(RoomMemberMessagesState(rows: rows).emptyLine(name: "pat"))
        XCTAssertEqual(rows.first?.shownText, "2 files", "a message of files alone is never a blank row")
    }

    /// "Load older" shows only once pages stopped bringing their messages, while older ones may be there and nothing is
    /// being read.
    func test_load_older_shows_only_after_reading_on_stopped() {
        XCTAssertTrue(RoomMemberMessagesState(canLoadMore: true, olderNeedsTap: true).showsLoadOlder)
        XCTAssertFalse(RoomMemberMessagesState(canLoadMore: true).showsLoadOlder, "the last row reads on by itself")
        XCTAssertFalse(RoomMemberMessagesState(phase: .loading, canLoadMore: true, olderNeedsTap: true).showsLoadOlder)
        XCTAssertFalse(RoomMemberMessagesState(phase: .failed("x"), canLoadMore: true, olderNeedsTap: true).showsLoadOlder,
                       "Retry instead")
        XCTAssertFalse(RoomMemberMessagesState(canLoadMore: false, olderNeedsTap: true).showsLoadOlder, "the room's start")
        XCTAssertFalse(RoomMemberMessagesState(canLoadMore: true, olderNeedsTap: true, isBlocked: true).showsLoadOlder)
        XCTAssertEqual(RoomMemberMessagesState(canLoadMore: true, olderNeedsTap: true).emptyLine(name: "pat"),
                       "No messages from pat found so far.")
        let rows = [RoomMemberMessageRow(sequenceId: 5, text: "hi", date: nil)]
        XCTAssertNil(RoomMemberMessagesState(rows: rows, canLoadMore: true, olderNeedsTap: true).emptyLine(name: "pat"))
    }

    /// Block keeps the Message rules: never your own profile (the API answers 422), never the orchestrator, the ticket
    /// keeper or Senti (reserved ids), never before the room knows who you are, never twice.
    func test_block_is_offered_only_where_message_would_be() {
        let own: Set<String> = ["human-alex"]
        XCTAssertTrue(RoomMemberBlock.offers(senderId: "human-pat", ownAuthorIds: own, alreadyBlocked: false))
        XCTAssertTrue(RoomMemberBlock.offers(senderId: "agent-a1", ownAuthorIds: own, alreadyBlocked: false))
        for never in ["human-alex", "Human-Alex", "respawn-orchestrator", "ticket-keeper", "Ticket-Keeper", "senti", "",
                      "human-"] {
            XCTAssertFalse(RoomMemberBlock.offers(senderId: never, ownAuthorIds: own, alreadyBlocked: false), never)
        }
        XCTAssertFalse(RoomMemberBlock.offers(senderId: "human-pat", ownAuthorIds: [], alreadyBlocked: false),
                       "the room doesn't know who you are yet")
        XCTAssertFalse(RoomMemberBlock.offers(senderId: "human-pat", ownAuthorIds: own, alreadyBlocked: true))
    }

    /// Someone you blocked: the list shows none of their messages and says so.
    func test_a_blocked_authors_messages_are_not_listed() {
        let rows = [RoomMemberMessageRow(sequenceId: 900, text: "hi", date: nil),
                    RoomMemberMessageRow(sequenceId: 800, text: "there", date: nil)]
        let blocked = RoomMemberMessagesState(rows: rows, canLoadMore: true, olderNeedsTap: true, isBlocked: true)
        XCTAssertTrue(blocked.listedRows.isEmpty)
        XCTAssertEqual(blocked.emptyLine(name: "pat"), "You blocked them.")
        XCTAssertFalse(blocked.showsLoadOlder)
        XCTAssertEqual(RoomMemberMessagesState(rows: rows).listedRows, rows)
    }

    /// Block from a profile names a message, the newest of theirs in the list: never their id alone.
    func test_block_names_the_newest_message_never_the_id_alone() {
        let rows = [RoomMemberMessageRow(sequenceId: 800, text: "older", date: nil),
                    RoomMemberMessageRow(sequenceId: 900, text: "newest", date: nil)]
        XCTAssertEqual(RoomMemberMessagesState(rows: rows).blockReference, 900)
        var named: [Int64] = []
        let block = RoomMemberMessagesState(rows: rows).blockAction { named.append($0) }
        block?()
        XCTAssertEqual(named, [900])

        XCTAssertNil(RoomMemberMessagesState(canLoadMore: true).blockAction { named.append($0) },
                     "no message loaded: no Block")
        XCTAssertNil(RoomMemberMessagesState(rows: rows).blockAction(nil), "no block flow: no Block")
        XCTAssertNil(RoomMemberMessagesState(rows: rows, isPrivate: true).blockReference)
        XCTAssertNil(RoomMemberMessagesState(rows: rows, isBlocked: true).blockReference)
        XCTAssertEqual(named, [900])
    }

    /// Ticket 00bcfcef: an agent's card shows the model its newest post that declared one declared, as written.
    func test_the_card_shows_the_model_of_the_newest_post_that_declared_one() {
        func row(_ sequence: Int64, _ model: String?) -> RoomMemberMessageRow {
            RoomMemberMessageRow(sequenceId: sequence, text: "post \(sequence)", date: nil, model: model)
        }
        // Out of order on purpose: the newest is found by its sequence.
        let rows = [row(700, "gpt-6-astra"), row(950, nil), row(900, " claude-opus-5-5 "), row(800, "deepseek-v4-pro")]
        XCTAssertEqual(RoomMemberMessagesState(rows: rows).model, "claude-opus-5-5",
                       "the newest that declared one, trimmed")
        XCTAssertEqual(RoomMemberMessagesState(rows: [row(1, "Claude-Opus-5-5")]).model, "Claude-Opus-5-5",
                       "as written")
    }

    /// The stand-ins a post writes for no model never show, in any case, and blank ones neither.
    func test_the_card_hides_a_stand_in_model() {
        func row(_ sequence: Int64, _ model: String?) -> RoomMemberMessageRow {
            RoomMemberMessageRow(sequenceId: sequence, text: "post \(sequence)", date: nil, model: model)
        }
        for standIn in ["mcp", "agent", "human", "MCP", "Agent", "HUMAN", " agent ", "", "   ", "\n"] {
            XCTAssertNil(RoomMemberMessagesState.shownModel(standIn), "'\(standIn)'")
            XCTAssertNil(RoomMemberMessagesState(rows: [row(5, standIn)]).model, "'\(standIn)'")
        }
        let rows = [row(900, "agent"), row(850, "MCP"), row(800, "kimi-k3"), row(700, "human")]
        XCTAssertEqual(RoomMemberMessagesState(rows: rows).model, "kimi-k3", "past newer stand-ins to a real one")
        XCTAssertEqual(RoomMemberMessagesState.shownModel("agent-x1"), "agent-x1", "only the whole word is a stand-in")
    }

    /// No post declared a model: nothing is shown, never a guess.
    func test_the_card_invents_no_model() {
        XCTAssertNil(RoomMemberMessagesState().model, "no posts")
        let rows = [RoomMemberMessageRow(sequenceId: 2, text: "a", date: nil),
                    RoomMemberMessageRow(sequenceId: 1, text: "b", date: nil, model: "agent")]
        XCTAssertNil(RoomMemberMessagesState(rows: rows).model, "posts with no model or a stand-in")
        XCTAssertNil(RoomMemberMessagesState.shownModel(nil))
    }
}
