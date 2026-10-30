import XCTest
@testable import PocketUI

/// Carter, #55354: rename the room from its name, and two floating avatars (agents, people) with counts and a note
/// when someone joins or leaves.
final class RoomRenameAndPeopleTests: XCTestCase {
    // MARK: - The name the API takes

    func test_a_name_is_trimmed_and_its_spaces_collapsed() {
        XCTAssertEqual(RoomTitle.cleaned("  Senti   Pocket\tlaunch \n"), "Senti Pocket launch")
        XCTAssertEqual(RoomTitle.cleaned("#hashtag room"), "#hashtag room", "a hash without a space is not a heading")
        XCTAssertEqual(RoomTitle.cleaned("Q4 - plans"), "Q4 - plans")
    }

    func test_names_the_api_refuses_are_refused_here() {
        XCTAssertNil(RoomTitle.cleaned("   "))
        XCTAssertNil(RoomTitle.cleaned("null"))
        XCTAssertNil(RoomTitle.cleaned(String(repeating: "a", count: 81)))
        XCTAssertNotNil(RoomTitle.cleaned(String(repeating: "a", count: 80)))
        for pasted in ["# Heading", "### Notes", "> quoted", "* bullet", "*bold*", "- item"] {
            XCTAssertNil(RoomTitle.cleaned(pasted), pasted)
        }
    }

    func test_only_the_owner_state_offers_rename() {
        XCTAssertFalse(RoomChatPresentationState(sessionId: "r", title: "R", messages: []).canRename)
        XCTAssertTrue(RoomChatPresentationState(sessionId: "r", title: "R", messages: [], canRename: true).canRename)
    }

    // MARK: - Who is here, and who came and went

    private func presence(_ people: [(String, Bool)], available: Bool = true) -> RoomChatPresence {
        RoomChatPresence.make(
            isAvailable: available,
            humansOnline: available ? people.filter(\.1).count : nil,
            people: people.map { RoomChatPresence.Person(id: $0.0, name: $0.0.replacingOccurrences(of: "human-", with: ""),
                                                         isHuman: $0.1, isIdle: false) }
        )
    }

    func test_counts_take_each_agent_once() {
        let here = presence([("human-carter", true), ("warden", false), ("Warden", false), ("forge", false)])
        XCTAssertEqual(here.humanCount, 1)
        XCTAssertEqual(here.agentCount, 2, "one agent holding two leases is one agent")
    }

    func test_one_arrival_and_one_departure_each_make_a_note_on_their_side() {
        let before = presence([("human-carter", true), ("warden", false)])
        let after = presence([("human-carter", true), ("human-simone", true), ("forge", false)])
        XCTAssertEqual(RoomChatPresence.changes(from: before, to: after), [
            RoomPresenceChange(isHuman: true, joined: true, text: "simone joined"),
            RoomPresenceChange(isHuman: false, joined: true, text: "forge joined"),
            RoomPresenceChange(isHuman: false, joined: false, text: "warden left")
        ])
    }

    func test_a_crowd_is_one_note() {
        let before = presence([("human-carter", true)])
        let after = presence([("human-carter", true), ("a", false), ("b", false), ("c", false), ("d", false)])
        XCTAssertEqual(RoomChatPresence.changes(from: before, to: after).map(\.text), ["a and 3 more joined"])
        let two = presence([("human-carter", true), ("a", false), ("b", false)])
        XCTAssertEqual(RoomChatPresence.changes(from: before, to: two).map(\.text), ["a and b joined"])
    }

    func test_opening_the_room_or_an_outage_is_not_a_crowd_arriving() {
        let here = presence([("human-carter", true), ("warden", false)])
        XCTAssertEqual(RoomChatPresence.changes(from: nil, to: here), [])
        XCTAssertEqual(RoomChatPresence.changes(from: presence([], available: false), to: here), [])
        XCTAssertEqual(RoomChatPresence.changes(from: here, to: presence([], available: false)), [])
        XCTAssertEqual(RoomChatPresence.changes(from: here, to: here), [])
    }
}
