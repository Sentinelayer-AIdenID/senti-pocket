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
        XCTAssertTrue(RoomProfile.opens(senderId: "senti-helper", ownAuthorIds: own), "only the room's own voices are out")
    }

    /// The server refuses the room's own voices as it refuses you (the same 404), so they get no card and no Message.
    func test_the_orchestrator_and_the_ticket_keeper_open_no_card() {
        XCTAssertFalse(RoomProfile.opens(senderId: "respawn-orchestrator", ownAuthorIds: []))
        XCTAssertFalse(RoomProfile.opens(senderId: "Ticket-Keeper", ownAuthorIds: []))
        var opened = 0
        let opener = RoomProfileOpener(ownAuthorIds: ["human-alex"]) { _ in opened += 1 }
        XCTAssertFalse(opener(RoomProfileTarget(senderId: "ticket-keeper", name: "ticket-keeper", isAgent: true)))
        XCTAssertEqual(opened, 0)
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
                        mutual: [(id: String, title: String)] = [], memory: [String: Bool]?) -> DirectRoomHeaderState {
        DirectRoomHeaderState.make(name: "review-agent", isAgent: isAgent, origin: origin, mutual: mutual,
                                   memoryShare: memory, isSaving: false)
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

    func test_only_an_agent_has_the_switch() {
        let person = header(isAgent: false, memory: ["room-1": true])
        XCTAssertNil(person.memory)
        XCTAssertNil(person.memoryPill)
        XCTAssertNil(person.memoryLabel)
        XCTAssertEqual(person.subtitle, "Direct message")
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

    /// The switch asks, so it never reads as already on beside its Off; its note says what the value means now.
    func test_the_switch_asks_and_its_note_says_what_off_and_on_mean() {
        let off = header(memory: [:])
        XCTAssertEqual(off.memoryLabel, "Let review-agent use this chat in Design review")
        XCTAssertEqual(off.memoryNote, "Off: review-agent can't see this chat anywhere else.")
        XCTAssertEqual(off.memoryPill, "Memory: Off")
        let on = header(memory: ["room-1": true])
        XCTAssertEqual(on.memoryLabel, "Let review-agent use this chat in Design review", "the label stays the question")
        XCTAssertEqual(on.memoryNote, "On: review-agent can use this chat when it works in Design review.")
        XCTAssertEqual(on.memoryPill, "Memory: On")
    }

    func test_the_compact_header_says_where_it_came_from_and_the_expanded_one_names_the_shared_room() {
        let state = header(memory: [:])
        XCTAssertEqual(state.fromChip, "From Design review")
        XCTAssertEqual(state.sharedRoomChip, "Shared room: Design review")
        XCTAssertEqual(state.subtitle, "Direct message · agent")
        XCTAssertNil(header(origin: nil, memory: [:]).fromChip)
    }

    /// Nothing in the contract says what the other side did with a message, so the header never says it: no
    /// "notified", no "typing", whoever wrote last.
    func test_the_header_never_claims_what_the_agent_is_doing() {
        for state in [header(memory: [:]), header(memory: ["room-1": true]), header(isAgent: false, memory: nil),
                      header(origin: nil, mutual: [("room-2", "Release train")], memory: [:])] {
            XCTAssertFalse(state.texts.isEmpty)
            for text in state.texts {
                for claim in ["notified", "typing", "is reading", "will answer", "answers when"] {
                    XCTAssertFalse(text.localizedCaseInsensitiveContains(claim), "\(text) claims \(claim)")
                }
            }
        }
        XCTAssertEqual(header(memory: [:]).texts, [
            "review-agent", "Direct message · agent", "Shared room: Design review", "From Design review", "Memory: Off",
            "Let review-agent use this chat in Design review", "Off: review-agent can't see this chat anywhere else."
        ], "every word the header shows")
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

    /// Ticket ab3c079b: with the server's count, the card lists the newest few rooms you share, says how many in all,
    /// and offers See all; without one it lists what it knows, as before.
    func test_the_cards_rooms_you_share_with_and_without_the_servers_count() {
        let who = RoomProfileTarget(senderId: "review-agent", name: "review-agent", isAgent: true)
        let here = RoomProfileCardState(target: who, sharedRooms: ["Design review"], canMessage: false)
        XCTAssertEqual(here.sharedRoomsSource, .thisRoom)
        XCTAssertEqual(here.sharedRoomsHeader, "In this room", "no server answer: never a false one")
        XCTAssertEqual(here.sharedRoomLines, ["Design review"])
        XCTAssertFalse(here.canSeeAllRooms)

        let twelve = here.with(sharedRooms: ["Room 12", "Room 11", "Room 10", "Room 9"], total: 12, from: .server)
        XCTAssertEqual(twelve.sharedRoomsHeader, "Rooms you share · 12")
        XCTAssertEqual(twelve.sharedRoomLines, ["Room 12", "Room 11", "Room 10", "Room 9"], "the newest few, no 'and more'")
        XCTAssertTrue(twelve.canSeeAllRooms)

        let three = here.with(sharedRooms: ["A", "B", ""], total: 3, from: .server)
        XCTAssertEqual(three.sharedRoomsHeader, "Rooms you share · 3")
        XCTAssertEqual(three.sharedRoomLines, ["A", "B", "Untitled room"])
        XCTAssertFalse(three.canSeeAllRooms, "all of them are on the card")

        let one = here.with(sharedRooms: ["Design review"], total: 1, from: .server)
        XCTAssertEqual(one.sharedRoomsHeader, "Room you share", "the server says one: one, and no count")
        XCTAssertFalse(one.canSeeAllRooms)

        // By where the list came from, never by how many are known: one room the server listed without a count is
        // not "In this room", and neither is a direct message's one room.
        let oneUncounted = here.with(sharedRooms: ["Pocket build"], total: nil, from: .server)
        XCTAssertEqual(oneUncounted.sharedRoomsHeader, "Rooms you share")
        let oneFromChat = here.with(sharedRooms: ["Pocket build"], total: nil, from: .directMessage)
        XCTAssertEqual(oneFromChat.sharedRoomsHeader, "Rooms you share")

        let known = here.with(sharedRooms: ["A", "B", "C", "D", "E", "F"], total: nil, from: .directMessage)
        XCTAssertEqual(known.sharedRoomsHeader, "Rooms you share")
        XCTAssertEqual(known.sharedRoomLines, ["A", "B", "C", "D", "and 2 more"], "no count: as before")
        XCTAssertFalse(known.canSeeAllRooms)

        XCTAssertEqual(RoomSharedRoomsState(name: "review-agent").title, "Rooms you share with review-agent")
        XCTAssertEqual(RoomSharedRoomsState(name: "review-agent", total: 12).title,
                       "Rooms you share with review-agent · 12")
        XCTAssertEqual(RoomSharedRoomsState.Row(id: "r", title: "", lastActive: nil).title, "Untitled room")
    }
}
