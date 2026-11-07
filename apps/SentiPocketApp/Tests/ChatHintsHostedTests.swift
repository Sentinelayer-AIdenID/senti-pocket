import PocketUI
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

/// Production room hooks, hosted at phone width. Mutants: remove the composer hook, ignore focus or typing, put
/// the tip in a safe-area inset (moving messages), or put it over the input rather than above it.
@MainActor
final class ChatHintsHostedTests: XCTestCase {
    private final class LaunchFlow: ObservableObject {
        @Published var folders: [RoomFolderItem] = []
        @Published var showsList = true
    }

    private struct LaunchHost: View {
        @ObservedObject var flow: LaunchFlow
        let hints: ChatHints
        let urgency: LaunchUrgency
        let room: RoomChatPresentationState

        var body: some View {
            VStack {
                if flow.showsList {
                    SessionListView(state: SessionListPresentationState(sessions: [], includesArchived: false,
                                                                        hasMore: false, provenance: .fixture),
                                    folders: flow.folders, onFolder: { _ in }, send: { _ in })
                } else {
                    RoomChatView(state: room, send: { _ in })
                }
                LaunchVisibilityProbe()
            }
            .modifier(ChatHintsAtLaunch(hints: hints, isReady: !flow.showsList,
                                        skipsSplash: false, urgency: urgency))
        }
    }

    private struct LaunchVisibilityProbe: View {
        @Environment(\.chatHintsVisible) private var visible
        var body: some View {
            Text(visible ? "Visible" : "Covered").accessibilityIdentifier("hint.surface.visibility")
        }
    }

    private func room() -> RoomChatPresentationState {
        let messages = (1...12).map { index in
            RoomChatMessageInput(id: "note-\(index)", sequenceId: Int64(index), kind: .message,
                                 authorId: "human-member", authorName: "Member", isHuman: true,
                                 text: "Planning note \(index).", timestamp: "", date: Date(timeIntervalSince1970: Double(index)))
        }
        return RoomChatPresentationState(sessionId: "hint-chat", title: "Planning", messages: messages,
                                         connection: .live, composer: .enabled)
    }

    private func host(_ hints: ChatHints) throws -> UIWindow {
        let roster = RoomRoster(members: [RoomRoster.Member(id: "helper", name: "Helper", kind: .agent, status: .here)])
        let window = try HostedSummary.host(RoomChatView(state: room(), roster: roster, send: { _ in })
            .environment(\.chatHints, hints))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        return window
    }

    private func storage() throws -> (String, UserDefaults) {
        let suite = "hosted-chat-hints-\(UUID().uuidString)"
        return (suite, try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    /// Check each rendered control as well as the containing banner, so a misleading container frame cannot pass.
    /// Mutant: remove the zero-height bottom-aligned frame and the text or actions overlap the input again.
    private func assertTipAboveComposer(in window: UIWindow, composer: CGRect,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        for id in ["pocket.hint", "pocket.hint.text", "pocket.hint.never", "pocket.hint.dismiss"] {
            let element = try XCTUnwrap(HostedSummary.element(id, in: window), file: file, line: line)
            let frame = element.accessibilityFrame
            XCTAssertGreaterThan(frame.height, 0, "\(id) has a visible frame", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, composer.minY,
                                     "\(id) stays entirely above the message box", file: file, line: line)
        }
    }

    func test_a_tip_sits_above_the_box_and_dismissing_it_keeps_the_messages_in_place() throws {
        let (suite, defaults) = try storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let hints = ChatHints(accountId: "account-a", defaults: defaults)
        let window = try host(hints)
        defer { HostedSummary.close(window) }
        _ = try XCTUnwrap(HostedSummary.wait(for: "pocket.hint", in: window))
        let input = try XCTUnwrap(HostedSummary.wait(for: "pocket.room.composer", in: window))
        let message = try XCTUnwrap(HostedSummary.wait(for: "pocket.room.message.12", in: window))
        HostedSummary.pump(0.5)
        let before = message.accessibilityFrame
        XCTAssertGreaterThan(input.accessibilityFrame.height, 0, "the message box has a visible frame")
        XCTAssertGreaterThan(before.height, 0, "the compared message is visible")
        try assertTipAboveComposer(in: window, composer: input.accessibilityFrame)
        let close = try XCTUnwrap(HostedSummary.element("pocket.hint.dismiss", in: window))
        XCTAssertTrue(close.accessibilityActivate(), "the visible close button is wired")
        HostedSummary.pump(0.3)
        XCTAssertNil(hints.current)
        XCTAssertNil(HostedSummary.element("pocket.hint.text", in: window))
        let after = try XCTUnwrap(HostedSummary.element("pocket.room.message.12", in: window)).accessibilityFrame
        XCTAssertEqual(before.minY, after.minY, accuracy: 1, "dismissing the overlay does not move the message list")
        XCTAssertEqual(before.height, after.height, accuracy: 1)
    }

    func test_the_real_empty_box_focusing_shows_mention_and_typing_hides_it() throws {
        let (suite, defaults) = try storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let hints = ChatHints(accountId: "account-a", defaults: defaults)
        let window = try host(hints)
        defer { HostedSummary.close(window) }
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.hint.text", in: window))
        XCTAssertEqual(hints.current?.tip, .messageActions)
        let box = try XCTUnwrap(HostedSummary.elements(in: window).compactMap { $0 as? UITextView }
            .first { $0.accessibilityIdentifier == "pocket.room.composer" })
        XCTAssertTrue(box.becomeFirstResponder())
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.hint.text", in: window, label: ChatHints.Tip.mention.text))
        XCTAssertEqual(hints.current?.tip, .mention, "the actual input's focus reaches the hint controller")
        HostedSummary.pump(0.5)
        try assertTipAboveComposer(in: window, composer: box.accessibilityFrame)
        box.insertText("Hello")
        HostedSummary.pump(0.3)
        XCTAssertNil(hints.current, "a nonempty input has no mention tip")
        box.resignFirstResponder()
    }

    func test_the_chat_list_offers_the_folder_tip_only_after_it_has_a_folder() throws {
        let (suite, defaults) = try storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let hints = ChatHints(accountId: "account-a", defaults: defaults)
        let state = SessionListPresentationState(sessions: [], includesArchived: false, hasMore: false,
                                                  provenance: .fixture)
        let empty = try HostedSummary.host(SessionListView(state: state, folders: [], onFolder: { _ in }, send: { _ in })
            .environment(\.chatHints, hints))
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.sessions.screen", in: empty))
        XCTAssertNil(hints.current)
        XCTAssertNil(HostedSummary.element("pocket.hint.text", in: empty))
        HostedSummary.close(empty)

        let folder = RoomFolderItem(id: "planning", name: "Planning", position: 0)
        let filed = try HostedSummary.host(SessionListView(state: state, folders: [folder], onFolder: { _ in }, send: { _ in })
            .environment(\.chatHints, hints))
        defer { HostedSummary.close(filed) }
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.hint.text", in: filed, label: ChatHints.Tip.moveToFolder.text))
        XCTAssertEqual(hints.current?.tip, .moveToFolder)
        let never = try XCTUnwrap(HostedSummary.element("pocket.hint.never", in: filed))
        XCTAssertTrue(never.accessibilityActivate(), "the visible persistent dismissal button is wired")
        HostedSummary.pump(0.3)
        XCTAssertNil(hints.current)
        XCTAssertNil(HostedSummary.element("pocket.hint.text", in: filed))
    }

    /// Mutant: remove the launch visibility environment or offer a hint without checking it. The hidden list
    /// consumes its folder tip before the restored room replaces it, and the later visible folder gets no tip.
    func test_folders_loaded_under_the_launch_splash_keep_their_tip_after_the_list_is_replaced() throws {
        let (suite, defaults) = try storage()
        defer { defaults.removePersistentDomain(forName: suite) }
        let hints = ChatHints(accountId: "account-a", defaults: defaults)
        let flow = LaunchFlow()
        let urgency = LaunchUrgency()
        let window = try HostedSummary.host(LaunchHost(flow: flow, hints: hints, urgency: urgency, room: room()))
        defer { HostedSummary.close(window) }
        XCTAssertNotNil(HostedSummary.wait(for: "hint.surface.visibility", in: window, label: "Covered"))

        flow.folders = [RoomFolderItem(id: "planning", name: "Planning", position: 0)]
        HostedSummary.pump(0.1)
        XCTAssertNil(hints.current, "folders loading behind the real splash cannot consume the first-folder tip")
        XCTAssertTrue((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty)

        flow.showsList = false
        HostedSummary.pump(0.1)
        XCTAssertNil(hints.current, "restoring a chat under the splash cannot consume the first-chat tip either")
        urgency.raise()
        XCTAssertNotNil(HostedSummary.wait(for: "hint.surface.visibility", in: window, label: "Visible"))
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.hint.text", in: window, label: ChatHints.Tip.messageActions.text))
        let close = try XCTUnwrap(HostedSummary.element("pocket.hint.dismiss", in: window))
        XCTAssertTrue(close.accessibilityActivate())
        HostedSummary.pump(0.1)

        flow.showsList = true
        XCTAssertNotNil(HostedSummary.wait(for: "pocket.hint.text", in: window, label: ChatHints.Tip.moveToFolder.text))
        XCTAssertEqual(hints.current?.tip, .moveToFolder, "the hidden list did not spend the account's one folder tip")
    }
}
