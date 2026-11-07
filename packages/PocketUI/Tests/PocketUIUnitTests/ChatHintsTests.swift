#if canImport(Combine)
import Foundation
import XCTest
@testable import PocketUI

/// These exercise the controller used by every banner, including persistence and competing visible surfaces.
/// Mutants: remove the focused/empty/agent checks; increment on every update; remove the three-show cap; use one
/// shared defaults key; forget to save permanent dismissal; keep a tip after its surface is hidden.
@MainActor
final class ChatHintsTests: XCTestCase {
    private func storage() throws -> (String, UserDefaults) {
        let suite = "chat-hints-tests-\(UUID().uuidString)"
        return (suite, try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    private func close(_ hints: ChatHints, permanently: Bool = false) throws {
        hints.dismiss(try XCTUnwrap(hints.current), permanently: permanently)
    }

    private func openChat(_ hints: ChatHints, anchor: UUID) throws {
        hints.update(anchor: anchor, context: .chat(hasAgents: false, isEmpty: true, isFocused: false))
        if hints.current?.tip == .messageActions { try close(hints) }
    }

    func test_the_mention_tip_requires_agents_an_empty_box_and_focus() throws {
        let (suite, defaults) = try storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let hints = ChatHints(accountId: "account-a", defaults: defaults)
        let anchor = UUID()
        try openChat(hints, anchor: anchor)

        for context in [ChatHints.Context.chat(hasAgents: false, isEmpty: true, isFocused: true),
                        .chat(hasAgents: true, isEmpty: false, isFocused: true),
                        .chat(hasAgents: true, isEmpty: true, isFocused: false)] {
            hints.update(anchor: anchor, context: context)
            XCTAssertNil(hints.current, "no mention tip outside its moment")
        }
        hints.update(anchor: anchor, context: .chat(hasAgents: true, isEmpty: true, isFocused: true))
        XCTAssertEqual(hints.current?.tip, .mention)
        hints.update(anchor: anchor, context: .chat(hasAgents: true, isEmpty: false, isFocused: true))
        XCTAssertNil(hints.current, "typing ends the tip's moment")
    }

    func test_three_qualifying_intervals_show_the_tip_and_redraws_do_not_consume_the_cap() throws {
        let (suite, defaults) = try storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let hints = ChatHints(accountId: "account-a", defaults: defaults)
        let anchor = UUID()
        try openChat(hints, anchor: anchor)

        for index in 1...3 {
            hints.update(anchor: anchor, context: .chat(hasAgents: true, isEmpty: true, isFocused: false))
            hints.update(anchor: anchor, context: .chat(hasAgents: true, isEmpty: true, isFocused: true))
            let shown = try XCTUnwrap(hints.current)
            XCTAssertEqual(shown.tip, .mention, "showing \(index)")
            for _ in 0..<20 {
                hints.update(anchor: anchor, context: .chat(hasAgents: true, isEmpty: true, isFocused: true))
                XCTAssertEqual(hints.current, shown, "the same interval does not count again")
            }
            try close(hints)
            hints.update(anchor: anchor, context: .chat(hasAgents: true, isEmpty: true, isFocused: true))
            XCTAssertNil(hints.current, "Close does not reopen in the same interval")
        }
        hints.update(anchor: anchor, context: .chat(hasAgents: true, isEmpty: true, isFocused: false))
        hints.update(anchor: anchor, context: .chat(hasAgents: true, isEmpty: true, isFocused: true))
        XCTAssertNil(hints.current, "a fourth qualifying interval has no tip")

        let relaunched = ChatHints(accountId: "account-a", defaults: defaults)
        relaunched.update(anchor: UUID(), context: .chat(hasAgents: true, isEmpty: true, isFocused: true))
        XCTAssertNil(relaunched.current, "the cap and first-chat impression survive relaunch")
    }

    func test_permanent_dismissal_survives_relaunch_for_only_that_account() throws {
        let (suite, defaults) = try storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let anchor = UUID()
        let hints = ChatHints(accountId: "account-a", defaults: defaults)
        try openChat(hints, anchor: anchor)
        hints.update(anchor: anchor, context: .chat(hasAgents: true, isEmpty: true, isFocused: true))
        try close(hints, permanently: true)

        let relaunched = ChatHints(accountId: "account-a", defaults: defaults)
        relaunched.update(anchor: anchor, context: .chat(hasAgents: true, isEmpty: true, isFocused: true))
        XCTAssertNil(relaunched.current, "the dismissed mention does not return after relaunch")

        let other = ChatHints(accountId: "account-b", defaults: defaults)
        other.update(anchor: anchor, context: .chat(hasAgents: true, isEmpty: true, isFocused: true))
        XCTAssertEqual(other.current?.tip, .mention, "another account still gets the tip")
        try close(other)
        XCTAssertEqual(other.current?.tip, .messageActions, "another account also gets its first-chat tip")
    }

    func test_the_first_chat_and_first_folder_tips_are_shown_once_at_their_moments() throws {
        let (suite, defaults) = try storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let hints = ChatHints(accountId: "account-a", defaults: defaults)
        let list = UUID()
        hints.update(anchor: list, context: .folders(hasFolders: false))
        XCTAssertNil(hints.current, "no folder, no folder tip")
        hints.update(anchor: list, context: .folders(hasFolders: true))
        XCTAssertEqual(hints.current?.tip, .moveToFolder)
        try close(hints)
        hints.remove(anchor: list)
        hints.update(anchor: UUID(), context: .folders(hasFolders: true))
        XCTAssertNil(hints.current, "opening another folder surface does not repeat the tip")

        let chat = UUID()
        hints.update(anchor: chat, context: .chat(hasAgents: false, isEmpty: false, isFocused: false))
        XCTAssertEqual(hints.current?.tip, .messageActions, "opening a chat is the first-chat moment")
        try close(hints)
        hints.remove(anchor: chat)
        hints.update(anchor: UUID(), context: .chat(hasAgents: false, isEmpty: true, isFocused: false))
        XCTAssertNil(hints.current, "a second chat does not repeat it")

        let relaunched = ChatHints(accountId: "account-a", defaults: defaults)
        relaunched.update(anchor: UUID(), context: .folders(hasFolders: true))
        relaunched.update(anchor: UUID(), context: .chat(hasAgents: false, isEmpty: true, isFocused: false))
        XCTAssertNil(relaunched.current, "first-time tips stay seen across relaunch")
    }

    func test_only_one_tip_is_current_and_mention_takes_the_place_of_the_first_chat_tip() throws {
        let (suite, defaults) = try storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let hints = ChatHints(accountId: "account-a", defaults: defaults)
        let chat = UUID(), list = UUID()
        hints.update(anchor: chat, context: .chat(hasAgents: true, isEmpty: true, isFocused: false))
        let first = try XCTUnwrap(hints.current)
        XCTAssertEqual(first.tip, .messageActions)
        hints.update(anchor: list, context: .folders(hasFolders: true))
        XCTAssertEqual(hints.current, first, "the other surface cannot display a second tip")

        hints.update(anchor: chat, context: .chat(hasAgents: true, isEmpty: true, isFocused: true))
        XCTAssertEqual(hints.current?.tip, .mention)
        XCTAssertEqual(hints.current?.anchor, chat)
        hints.update(anchor: chat, context: .chat(hasAgents: true, isEmpty: true, isFocused: true), visible: false)
        XCTAssertEqual(hints.current?.tip, .moveToFolder)
        XCTAssertEqual(hints.current?.anchor, list, "the covered chat no longer owns a visible tip")
        hints.remove(anchor: list)
        XCTAssertNil(hints.current, "removed surfaces leave no tip behind")
    }

    func test_a_pending_opportunity_is_dropped_when_it_is_no_longer_relevant() throws {
        let (suite, defaults) = try storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let hints = ChatHints(accountId: "account-a", defaults: defaults)
        let chat = UUID(), list = UUID()
        hints.update(anchor: chat, context: .chat(hasAgents: false, isEmpty: true, isFocused: false))
        hints.update(anchor: list, context: .folders(hasFolders: true))
        hints.update(anchor: list, context: .folders(hasFolders: false))
        try close(hints)
        XCTAssertNil(hints.current, "a folder tip does not show after the last folder disappeared")
        hints.update(anchor: list, context: .folders(hasFolders: true))
        XCTAssertEqual(hints.current?.tip, .moveToFolder, "an unseen opportunity was not counted")
    }

    func test_an_unknown_account_consumes_nothing_and_account_switches_cannot_bleed_dismissals() throws {
        let (suite, defaults) = try storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let hints = ChatHints(defaults: defaults)
        let anchor = UUID()
        hints.update(anchor: anchor, context: .chat(hasAgents: false, isEmpty: true, isFocused: false))
        XCTAssertNil(hints.current)
        XCTAssertTrue((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty, "there is no anonymous shared key")
        hints.setAccount("account-a")
        let old = try XCTUnwrap(hints.current)
        XCTAssertEqual(old.tip, .messageActions)
        hints.setAccount(nil)
        XCTAssertNil(hints.current)
        hints.setAccount("account-b")
        let next = try XCTUnwrap(hints.current)
        XCTAssertEqual(next.tip, .messageActions, "the new account sees its own first-chat tip")
        hints.dismiss(old, permanently: true)
        XCTAssertEqual(hints.current, next, "a callback from the previous account changes nothing")
        hints.setAccount("account-a")
        XCTAssertNil(hints.current, "the first account still has its own impression count")
    }

    func test_hidden_surfaces_do_not_consume_first_time_tips() throws {
        let (suite, defaults) = try storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let hints = ChatHints(accountId: "account-a", defaults: defaults)
        let anchor = UUID()
        hints.update(anchor: anchor, context: .folders(hasFolders: true), visible: false)
        XCTAssertNil(hints.current)
        hints.update(anchor: anchor, context: .folders(hasFolders: true), visible: true)
        XCTAssertEqual(hints.current?.tip, .moveToFolder)
    }
}
#endif
