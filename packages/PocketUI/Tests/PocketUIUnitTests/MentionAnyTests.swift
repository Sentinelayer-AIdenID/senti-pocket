import XCTest
@testable import PocketUI

/// Ticket 2f95466a (Carter #62572, "I can decide who is going to read my message"): the @-mention picker offers @any
/// in a room that takes it, lists agents of one box together under the box, and keeps @all as it was. Under a
/// message, the line that says who picked up its @any.
final class MentionAnyTests: XCTestCase {
    private let agents = [
        MentionCandidate(handle: "build-agent", displayName: "build-agent", isHuman: false),
        MentionCandidate(handle: "review-agent", displayName: "review-agent", isHuman: false),
        MentionCandidate(handle: "griff", displayName: "Griff", isHuman: true),
    ]

    /// A room that has not said it takes @any never offers it, whatever is typed.
    func test_at_any_is_not_offered_unless_the_room_takes_it() {
        for query in ["", "a", "an", "any", "ANY"] {
            XCTAssertFalse(MentionSuggester.suggestions(for: query, among: agents).contains { $0.isAny }, query)
        }
    }

    /// A room that takes it offers @any right after @all, for nothing typed or a start of "any" in any case.
    func test_at_any_is_offered_after_at_all_when_the_room_takes_it() {
        let offered = [MentionCandidate.anyFree] + agents
        XCTAssertEqual(MentionSuggester.suggestions(for: "", among: offered).prefix(2).map(\.handle), ["all", "any"])
        XCTAssertEqual(MentionSuggester.suggestions(for: "a", among: offered).prefix(2).map(\.handle), ["all", "any"])
        XCTAssertEqual(MentionSuggester.suggestions(for: "an", among: offered).map(\.handle), ["any"])
        XCTAssertEqual(MentionSuggester.suggestions(for: "ANY", among: offered).map(\.handle), ["any"])
        XCTAssertFalse(MentionSuggester.suggestions(for: "al", among: offered).contains { $0.isAny })
        XCTAssertFalse(MentionSuggester.suggestions(for: "build", among: offered).contains { $0.isAny })
        let any = MentionCandidate.anyFree
        XCTAssertEqual(any.displayName, "Any free agent: the first one free picks it up")
        XCTAssertEqual(any.spokenChoice, "Mention any free agent")
        // An agent whose id is "any" would read as @any: it is not listed beside it.
        let named = offered + [MentionCandidate(handle: "any", displayName: "any", isHuman: false)]
        XCTAssertEqual(MentionSuggester.suggestions(for: "any", among: named).map(\.handle), ["any"])
        XCTAssertEqual(MentionSuggester.suggestions(for: "any", among: named).first?.isAny, true)
    }

    /// Picking @any puts "@any " in the draft where the mention was being typed.
    func test_picking_at_any_puts_at_any_and_a_space_in_the_draft() {
        XCTAssertEqual(MentionSuggester.apply(.anyFree, to: "can someone look @a", at: 19), "can someone look @any ")
        XCTAssertEqual(MentionSuggester.apply(.anyFree, to: "@an please", at: 3), "@any please")
        XCTAssertEqual(MentionSuggester.apply(.anyFree, to: "ask @"), "ask @any ")
    }

    /// Agents in a box come after the rest, each box together in its own order under "Box 3f2a"; an agent outside
    /// any box stays where it was, and a person is never put in a box.
    func test_agents_in_a_box_are_listed_under_it_and_the_rest_are_not() {
        let now = Date(timeIntervalSince1970: 1_793_990_000)
        let first = MentionGroup(id: "3f2a9c01", index: 1, label: "Box 3f2a")
        let second = MentionGroup(id: "3f2a9c01", index: 2, label: "Box 3f2a")
        let other = MentionGroup(id: "77aa0011", index: 1, label: "Box 77aa")
        let candidates = MentionSuggester.candidates(
            authors: [
                (id: "senti-3f2a9c01-2", name: "senti-3f2a9c01-2", isHuman: false, lastActive: now),
                (id: "senti-77aa0011-1", name: "senti-77aa0011-1", isHuman: false, lastActive: nil),
                (id: "build-agent", name: "build-agent", isHuman: false, lastActive: now),
                (id: "senti-3f2a9c01-1", name: "senti-3f2a9c01-1", isHuman: false, lastActive: nil),
                (id: "zed-agent", name: "zed-agent", isHuman: false, lastActive: nil),
                (id: "human-griff", name: "Griff", isHuman: true, lastActive: nil),
            ],
            ownHandles: [],
            now: now,
            groups: ["senti-3f2a9c01-2": second, "senti-77aa0011-1": other, "senti-3f2a9c01-1": first,
                     "griff": other]
        )
        XCTAssertEqual(candidates.map(\.handle), ["griff", "build-agent", "zed-agent",
                                                  "senti-3f2a9c01-1", "senti-3f2a9c01-2", "senti-77aa0011-1"])
        XCTAssertEqual(candidates.map { $0.group?.label }, [nil, nil, nil, "Box 3f2a", "Box 3f2a", "Box 77aa"])
        let shown = MentionSuggester.suggestions(for: "", among: candidates)
        let headers = shown.indices.map { MentionSuggester.groupStarting(at: $0, in: shown)?.label }
        XCTAssertEqual(headers, [nil, nil, nil, nil, "Box 3f2a", nil, "Box 77aa"],
                       "one label over each box, at its first agent; none over @all, people or agents outside a box")
    }

    /// @all is as it was: first, "Everyone", for nothing typed or a start of "all", put in as "@all ".
    func test_at_all_is_unchanged() {
        for candidates in [agents, [MentionCandidate.anyFree] + agents] {
            let first = MentionSuggester.suggestions(for: "", among: candidates).first
            XCTAssertEqual(first, .everyone)
            XCTAssertEqual(MentionSuggester.suggestions(for: "al", among: candidates).first, .everyone)
            XCTAssertFalse(MentionSuggester.suggestions(for: "an", among: candidates).contains { $0.isAll })
        }
        XCTAssertEqual(MentionCandidate.everyone.handle, "all")
        XCTAssertEqual(MentionCandidate.everyone.displayName, "Everyone")
        XCTAssertEqual(MentionCandidate.everyone.spokenChoice, "Mention everyone")
        XCTAssertEqual(MentionSuggester.apply(.everyone, to: "ship it @a", at: 10), "ship it @all ")
    }

    /// Under a message: who the server chose for its @any, or that nobody was free; nothing when its author was over
    /// their broadcast limit, or when it asked no one.
    func test_the_line_under_a_message_says_who_picked_up_its_at_any() {
        XCTAssertEqual(RoomAddressedLine.text(pickedBy: "build-agent", nobodyFree: false, throttled: false),
                       "Picked up by build-agent")
        XCTAssertEqual(RoomAddressedLine.text(pickedBy: nil, nobodyFree: true, throttled: false),
                       "Nobody free right now")
        XCTAssertNil(RoomAddressedLine.text(pickedBy: nil, nobodyFree: false, throttled: true))
        XCTAssertNil(RoomAddressedLine.text(pickedBy: "build-agent", nobodyFree: true, throttled: true),
                     "over the limit, nobody was asked: nothing extra")
        XCTAssertNil(RoomAddressedLine.text(pickedBy: nil, nobodyFree: false, throttled: false))
    }
}
