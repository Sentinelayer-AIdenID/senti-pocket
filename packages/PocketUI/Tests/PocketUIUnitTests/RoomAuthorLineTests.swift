#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import PocketUI

/// Ticket 00bcfcef: an agent's name in the room carries its lab's badge, a small square of fixed size, and the line the
/// name sits on stays exactly as tall as it was, so no row grows and nothing in the room's list moves.
final class RoomAuthorLineTests: XCTestCase {
    /// The first message of a run by `author`, named `name`, as the room shows it.
    private func row(author: String, name: String, isHuman: Bool) -> RoomChatMessageRow {
        let input = RoomChatMessageInput(id: "m-\(author)", sequenceId: 1, kind: .message, authorId: author,
                                         authorName: name, isHuman: isHuman, text: "Shipped the fix.", timestamp: "",
                                         date: Date(timeIntervalSince1970: 1_800_000_000))
        let state = RoomChatPresentationState(sessionId: "room", title: "Room", messages: [input])
        let messages = state.rows.compactMap { row -> RoomChatMessageRow? in
            if case .message(let message) = row { return message }
            return nil
        }
        return messages[0]
    }

    private var agent: RoomChatMessageRow { row(author: "forge", name: "forge", isHuman: false) }
    private var person: RoomChatMessageRow { row(author: "human-forge", name: "forge", isHuman: true) }

    /// The line's height as a row lays it out, at a phone's width.
    private func height(_ line: RoomAuthorLine) -> CGFloat {
        NSHostingView(rootView: line.frame(width: 390)).fittingSize.height
    }

    /// The line at its own size: the name, any badge after it, and the time.
    private func width(_ line: RoomAuthorLine) -> CGFloat {
        NSHostingView(rootView: line.fixedSize()).fittingSize.width
    }

    func test_an_agent_of_a_known_lab_gets_the_badge_after_its_name_and_a_person_or_an_unknown_lab_none() {
        let plain = width(RoomAuthorLine(row: agent, lab: nil))
        XCTAssertGreaterThan(plain, 20, "the line was laid out")
        XCTAssertEqual(width(RoomAuthorLine(row: agent, lab: .anthropic)) - plain,
                       AgentNameBadge.size + AgentNameBadge.gap, accuracy: 1,
                       "the badge and the room before it follow the agent's name")
        XCTAssertEqual(width(RoomAuthorLine(row: agent, lab: .xai)) - plain,
                       AgentNameBadge.size + AgentNameBadge.gap, accuracy: 1,
                       "a lab with no logo carried shows its initial in the same square")
        XCTAssertEqual(width(RoomAuthorLine(row: person, lab: .anthropic)),
                       width(RoomAuthorLine(row: person, lab: nil)), "never on a person's name, whatever is passed")
        // What the room passes for an agent whose lab is not known, and for one known only by a name the who-is-here
        // row reads a lab from.
        for id in ["sol-max", "gemini-reviewer"] {
            let unknown = AgentLab.Known().badge(authorId: id, isHuman: false, declared: nil)
            let unknownRow = row(author: id, name: id, isHuman: false)
            XCTAssertEqual(width(RoomAuthorLine(row: unknownRow, lab: unknown)),
                           width(RoomAuthorLine(row: unknownRow, lab: nil)),
                           "\(id): no badge after the name of an agent whose lab is not known")
        }
    }

    func test_the_badge_leaves_the_line_as_tall_as_the_same_name_without_it() {
        let badged = RoomAuthorLine(row: agent, lab: .anthropic)
        XCTAssertGreaterThan(width(badged), width(RoomAuthorLine(row: agent, lab: nil)), "the badge is drawn")
        let personHeight = height(RoomAuthorLine(row: person, lab: nil))
        XCTAssertGreaterThan(personHeight, 8, "the line was laid out")
        XCTAssertEqual(height(badged), personHeight, "an agent's badged name is as tall as the same name of a person")
        XCTAssertEqual(height(badged), height(RoomAuthorLine(row: agent, lab: nil)), "and as the name with no badge")
        XCTAssertEqual(height(RoomAuthorLine(row: agent, lab: .xai)), personHeight, "an initial in the square too")
    }
}
#endif
