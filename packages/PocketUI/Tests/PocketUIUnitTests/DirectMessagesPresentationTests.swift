import Foundation
import PocketContracts
import XCTest
@testable import PocketUI

/// Direct messages in the room and the list: whose avatar opens a card, the direct message's header (the memory switch
/// shows only the server's value), and how a direct row reads. People and rooms are made up.
final class DirectMessagesPresentationTests: XCTestCase {
    // MARK: - Whose card opens

    func test_a_card_never_opens_on_yourself_or_the_rooms_voice() {
        let own: Set<String> = ["human-alex"]
        XCTAssertTrue(RoomProfile.opens(senderId: "review-agent", ownAuthorIds: own))
        XCTAssertTrue(RoomProfile.opens(senderId: "human-priya", ownAuthorIds: own))
        XCTAssertFalse(RoomProfile.opens(senderId: "human-alex", ownAuthorIds: own))
        XCTAssertFalse(RoomProfile.opens(senderId: "HUMAN-Alex", ownAuthorIds: own), "you, written another way")
        XCTAssertFalse(RoomProfile.opens(senderId: "senti", ownAuthorIds: own))
        XCTAssertFalse(RoomProfile.opens(senderId: "Senti", ownAuthorIds: own))
        XCTAssertFalse(RoomProfile.opens(senderId: "  ", ownAuthorIds: own))
        XCTAssertFalse(RoomProfile.opens(senderId: "human-", ownAuthorIds: own))
        XCTAssertTrue(RoomProfile.opens(senderId: "senti-helper", ownAuthorIds: own), "only the room's own voice is out")
    }

    func test_the_opener_opens_nothing_for_yourself_and_the_card_for_anyone_else() {
        var opened: [RoomProfileTarget] = []
        let opener = RoomProfileOpener(ownAuthorIds: ["human-alex"]) { opened.append($0) }
        XCTAssertFalse(opener(RoomProfileTarget(senderId: "human-alex", name: "Alex", isAgent: false)))
        XCTAssertFalse(opener(RoomProfileTarget(senderId: "senti", name: "senti", isAgent: true)))
        XCTAssertTrue(opener(RoomProfileTarget(senderId: "review-agent", name: "review-agent", isAgent: true)))
        XCTAssertEqual(opened.map(\.senderId), ["review-agent"])
    }

    func test_a_room_has_an_opener_only_with_dms_on_and_once_it_knows_who_you_are() {
        XCTAssertNil(RoomProfileOpener.forRoom(directMessagesOn: false, ownMentionHandles: ["alex", "all"]) { _ in },
                     "direct messages off (a 404): avatars are pictures, the ring opens the people list")
        XCTAssertNil(RoomProfileOpener.forRoom(directMessagesOn: true, ownMentionHandles: []) { _ in },
                     "before the room knows who you are, your own avatar could be tapped: no opener yet")
        XCTAssertNil(RoomProfileOpener.forRoom(directMessagesOn: true, ownMentionHandles: ["all"]) { _ in })
        let opener = RoomProfileOpener.forRoom(directMessagesOn: true, ownMentionHandles: ["alex", "all"]) { _ in }
        XCTAssertEqual(opener?.ownAuthorIds, ["human-alex"])
        XCTAssertEqual(opener?.opens("human-alex"), false)
        XCTAssertEqual(opener?.opens("review-agent"), true)
        // A new opener each time the room draws is the same opener, so the avatars that read it are not drawn again.
        XCTAssertEqual(opener, RoomProfileOpener.forRoom(directMessagesOn: true, ownMentionHandles: ["alex"]) { _ in })
        XCTAssertNotEqual(opener, RoomProfileOpener.forRoom(directMessagesOn: true, ownMentionHandles: ["sam"]) { _ in })
    }

    func test_a_persons_card_shows_their_name_not_their_id() {
        XCTAssertEqual(RoomProfileTarget(senderId: "human-priya", name: "human-priya", isAgent: false).name, "priya")
        XCTAssertEqual(RoomProfileTarget(senderId: "human-priya", name: "Priya D", isAgent: false).name, "Priya D")
        XCTAssertEqual(RoomProfileTarget(senderId: "Review-Agent", name: "x", isAgent: true).id, "review-agent")
    }

    func test_the_card_lists_a_few_shared_rooms_and_counts_the_rest() {
        XCTAssertEqual(RoomProfileCardView.sharedLines(["A", "B"]), ["A", "B"])
        XCTAssertEqual(RoomProfileCardView.sharedLines(["A", "B", "C", "D", "E", "F"]), ["A", "B", "C", "D", "and 2 more"])
        XCTAssertEqual(RoomProfileCardState.refusal(name: "Sam"), "You can't message Sam right now.")
    }

    // MARK: - The direct message's header

    private func header(isAgent: Bool = true, origin: (id: String, title: String)? = ("room-1", "Design review"),
                        mutual: [(id: String, title: String)] = [], memory: [String: Bool]?, ownLast: Bool = false)
        -> DirectRoomHeaderState {
        DirectRoomHeaderState.make(name: "review-agent", isAgent: isAgent, origin: origin, mutual: mutual,
                                   memoryShare: memory, isSaving: false, lastMessageIsOwn: ownLast)
    }

    func test_the_memory_switch_shows_only_the_servers_value_and_is_off_by_default() {
        XCTAssertNil(header(memory: nil).memory, "before the server answers there is no switch, not an assumed one")
        let off = header(memory: [:]).memory
        XCTAssertEqual(off?.roomId, "room-1")
        XCTAssertEqual(off?.isOn, false, "no entry for the room is the server's default: off")
        XCTAssertEqual(header(memory: ["room-1": false]).memory?.isOn, false)
        XCTAssertEqual(header(memory: ["room-1": true]).memory?.isOn, true)
        XCTAssertEqual(header(memory: ["room-9": true]).memory?.isOn, false, "another room's switch is not this one")
    }

    func test_only_an_agent_has_the_switch_and_is_notified() {
        let person = header(isAgent: false, memory: ["room-1": true], ownLast: true)
        XCTAssertNil(person.memory)
        XCTAssertFalse(person.notified)
        XCTAssertTrue(header(memory: [:], ownLast: true).notified)
        XCTAssertFalse(header(memory: [:], ownLast: false).notified, "the agent answered last")
    }

    func test_the_shared_room_is_where_it_started_else_one_you_share_now() {
        let started = header(memory: [:])
        XCTAssertEqual(started.sharedRoomId, "room-1")
        XCTAssertEqual(started.sharedRoomTitle, "Design review")
        let gone = header(origin: nil, mutual: [("room-2", "Release train"), ("room-3", "Weekly")], memory: [:])
        XCTAssertEqual(gone.sharedRoomId, "room-2")
        XCTAssertEqual(gone.memory?.roomId, "room-2", "the switch is for the room the chip names")
        let none = header(origin: nil, mutual: [], memory: [:])
        XCTAssertNil(none.sharedRoomId)
        XCTAssertNil(none.memory, "no room, no switch")
    }

    func test_the_switch_says_what_turning_it_on_shares() {
        XCTAssertEqual(DirectRoomHeaderState.memoryLabel(agent: "review-agent", room: "Design review"),
                       "review-agent can use this chat in Design review")
        XCTAssertTrue(DirectRoomHeaderState.memoryFootnote(agent: "review-agent", room: "Design review").contains("Off by default"))
        XCTAssertFalse(DirectRoomHeaderState.notifiedLine(agent: "review-agent").localizedCaseInsensitiveContains("typing"))
    }

    func test_your_message_last_means_the_agent_was_notified() {
        func message(_ seq: Int64, own: Bool) -> RoomChatMessageInput {
            RoomChatMessageInput(id: "m\(seq)", sequenceId: seq, kind: .message,
                                 authorId: own ? "human-alex" : "review-agent", authorName: own ? "alex" : "review-agent",
                                 isHuman: own, text: "message \(seq)", timestamp: "",
                                 date: Date(timeIntervalSince1970: Double(seq) * 600))
        }
        func rows(_ inputs: [RoomChatMessageInput]) -> [RoomChatRow] {
            RoomChatPresentationState(sessionId: "dm-1", title: "review-agent", messages: inputs,
                                      ownAuthorIds: ["human-alex"]).rows
        }
        XCTAssertTrue(DirectRoomActivity.lastMessageIsOwn(rows([message(1, own: false), message(2, own: true)])))
        XCTAssertFalse(DirectRoomActivity.lastMessageIsOwn(rows([message(1, own: true), message(2, own: false)])))
        XCTAssertFalse(DirectRoomActivity.lastMessageIsOwn([]))
    }

    // MARK: - A direct row in the list

    func test_a_direct_row_is_named_for_whom_it_is_with_and_is_in_no_folder() throws {
        let page = try JSONDecoder().decode(SessionListPage.self, from: Data("""
        {"sessions":[
          {"sessionId":"room-1","status":"active","archiveStatus":"active","visibility":"private","membershipRole":"owner",
           "title":"Design review","agentCount":2,"eventCount":9,"totalCostUsd":0,"kind":"room","folderId":"f-1"},
          {"sessionId":"dm-1","status":"active","archiveStatus":"active","visibility":"private","membershipRole":"owner",
           "title":"dm-room-title","agentCount":1,"eventCount":2,"totalCostUsd":0,"kind":"direct","folderId":"f-1",
           "counterpart":{"senderId":"review-agent","kind":"agent","displayName":"Review Agent"},"originRoomId":"room-1"}
        ],"count":2,"include_archived":false,"next_cursor":null,"has_more":false}
        """.utf8))
        let rows = SessionListPresentationState(page: page, provenance: .fixture).rows
        XCTAssertFalse(rows[0].isDirect)
        XCTAssertEqual(rows[0].folderId, "f-1")
        XCTAssertNil(rows[0].originRoomId)
        XCTAssertTrue(rows[1].isDirect)
        XCTAssertEqual(rows[1].title, "Review Agent")
        XCTAssertEqual(rows[1].originRoomId, "room-1")
        XCTAssertNil(rows[1].folderId, "a direct message lives under its room, never in a folder of its own")
    }
}
