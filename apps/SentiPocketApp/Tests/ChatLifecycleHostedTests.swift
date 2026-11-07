import PocketSyncClient
import SwiftUI
import UIKit
import XCTest
@testable import SentiPocketApp

private actor HostedChatLifecycle: ChatLifecycleServing {
    private(set) var calls: [String] = []

    func archiveChat(_ roomId: String, accountId: String) async throws {
        calls.append("archive:\(accountId):\(roomId)")
    }

    func endChat(_ roomId: String, accountId: String) async throws {
        calls.append("end:\(accountId):\(roomId)")
    }

    func leaveChat(_ roomId: String, accountId: String) async throws {
        calls.append("leave:\(accountId):\(roomId)")
    }
}

/// The real alert presents both actions and its message before any write. Native button taps are exercised by
/// ChatLifecycleUITests, because UIKit alert actions are not driven by NSObject.accessibilityActivate().
@MainActor
final class ChatLifecycleHostedTests: XCTestCase {
    func test_the_rendered_alert_shows_both_actions_and_makes_no_preconfirmation_write() async throws {
        let client = HostedChatLifecycle()
        let center = ChatLifecycleCenter(client: client, lookup: { $0 == "owned" ? .end : nil })
        center.setAccountId("account-a")
        var changed: [String] = []
        let window = try HostedSummary.host(Text("Chats")
            .accessibilityIdentifier("chat-lifecycle-host")
            .modifier(ChatLifecycleAlerts(center: center) { changed.append($0) }))
        defer {
            window.rootViewController?.presentedViewController?.dismiss(animated: false)
            HostedSummary.close(window)
        }
        XCTAssertNotNil(HostedSummary.wait(for: "chat-lifecycle-host", in: window))

        center.request("owned")
        _ = try await button("Cancel", in: window)
        _ = try await button("End", in: window)
        let labels = HostedSummary.elements(in: window).compactMap(\.accessibilityLabel).joined(separator: " ")
        XCTAssertTrue(labels.contains("End this chat for everyone?"))
        XCTAssertTrue(labels.contains("No one can post in it after this."))
        let beforeConfirmation = await client.calls
        XCTAssertTrue(beforeConfirmation.isEmpty, "presenting the confirmation makes no write")
        XCTAssertTrue(changed.isEmpty)
        XCTAssertEqual(center.confirmation?.roomId, "owned")
        XCTAssertNil(center.notice)
    }

    private func button(_ label: String, in window: UIWindow) async throws -> NSObject {
        var found: NSObject?
        _ = try await waitUntil {
            found = HostedSummary.elements(in: window).first {
                $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button)
            }
            return found != nil
        }
        return try XCTUnwrap(found, "the presented alert has a \(label) button")
    }

    /// Yield the main actor while SwiftUI presents/dismisses the alert and its confirmation task runs.
    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { return false }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
}
