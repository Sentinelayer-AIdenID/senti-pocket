import XCTest
@testable import PocketUI

final class ChatRowLifecycleTests: XCTestCase {
    func test_move_is_first_and_end_is_last_after_a_divider() {
        XCTAssertEqual(ChatRowMenuItem.ordered(foldersAvailable: true, filedInFolder: true, lifecycle: .end),
                       [.moveToFolder, .removeFromFolder, .divider, .archiveChat, .endChat])
        XCTAssertEqual(ChatRowMenuItem.ordered(foldersAvailable: true, filedInFolder: false, lifecycle: .end),
                       [.moveToFolder, .divider, .archiveChat, .endChat])
        XCTAssertEqual(ChatRowMenuItem.archiveChat.lifecycleAction, .archive)
    }

    func test_folders_off_does_not_hide_an_owners_end_action() {
        XCTAssertEqual(ChatRowMenuItem.ordered(foldersAvailable: false, filedInFolder: true, lifecycle: .end), [.archiveChat, .endChat])
        XCTAssertEqual(ChatRowMenuItem.ordered(foldersAvailable: false, filedInFolder: false, lifecycle: nil), [])
    }

    func test_a_non_owner_never_gets_end_and_leave_is_off_by_default() {
        XCTAssertEqual(ChatRowLifecycleAction.available(membershipRole: "owner", status: "active"), .end)
        for role in ["member", "admin", "viewer", "contributor", "", "unknown"] {
            XCTAssertNil(ChatRowLifecycleAction.available(membershipRole: role, status: "active"), role)
        }
        XCTAssertEqual(ChatRowLifecycleAction.available(membershipRole: "member", status: "active", leaveEnabled: true), .leave)
        XCTAssertNil(ChatRowLifecycleAction.available(membershipRole: "unknown", status: "active", leaveEnabled: true))
        XCTAssertNil(ChatRowLifecycleAction.available(membershipRole: "owner", status: "killed"))
    }

    func test_end_confirmation_explains_everyone_is_affected_without_claiming_permanent_deletion() {
        XCTAssertEqual(ChatRowLifecycleAction.end.label, "End chat")
        XCTAssertEqual(ChatRowLifecycleAction.end.confirmationTitle, "End this chat for everyone?")
        XCTAssertEqual(ChatRowLifecycleAction.end.confirmationMessage, "No one can post in it after this.")
        XCTAssertEqual(ChatRowLifecycleAction.end.confirmLabel, "End")
        XCTAssertEqual(ChatRowLifecycleAction.archive.label, "Archive chat")
        XCTAssertEqual(ChatRowLifecycleAction.archive.confirmationTitle, "Archive this chat?")
        XCTAssertEqual(ChatRowLifecycleAction.archive.confirmationMessage, "It leaves everyone's chat list.")
        XCTAssertEqual(ChatRowLifecycleAction.archive.confirmLabel, "Archive")
    }

    func test_the_menu_context_only_requests_confirmation_for_an_allowed_chat() {
        var requested: [String] = []
        let context = ChatRowLifecycleContext(choices: ["owned": .end, "leave-only": .leave]) { roomId, action in
            requested.append("\(action.rawValue):\(roomId)")
        }
        context.ask(for: "member")
        context.ask(for: "leave-only", action: .archive)
        XCTAssertTrue(requested.isEmpty)
        context.ask(for: "owned")
        context.ask(for: "owned", action: .archive)
        XCTAssertEqual(requested, ["end:owned", "archive:owned"])
    }
}
