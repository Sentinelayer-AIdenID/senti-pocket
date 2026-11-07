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

/// Runs the production alert modifier and activates its rendered buttons. Mutants: lose the first of the two
/// alerts, wire Cancel to confirm, or require the presentation binding to remain set when End's task starts.
@MainActor
final class ChatLifecycleHostedTests: XCTestCase {
    func test_the_rendered_alert_cancel_writes_nothing_and_end_confirms_once() async throws {
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
        let cancel = try await button("Cancel", in: window)
        let labels = HostedSummary.elements(in: window).compactMap(\.accessibilityLabel).joined(separator: " ")
        XCTAssertTrue(labels.contains("End this chat for everyone?"))
        XCTAssertTrue(labels.contains("No one can post in it after this."))
        let beforeCancel = await client.calls
        XCTAssertTrue(beforeCancel.isEmpty, "presenting the confirmation makes no write")
        XCTAssertTrue(changed.isEmpty)
        XCTAssertTrue(cancel.accessibilityActivate(), "the actual Cancel button is actionable")
        let cancelDismissed = try await waitUntil {
            center.confirmation == nil && window.rootViewController?.presentedViewController == nil
        }
        XCTAssertTrue(cancelDismissed, "Cancel dismisses the real alert")
        let afterCancel = await client.calls
        XCTAssertTrue(afterCancel.isEmpty, "Cancel makes no write")
        XCTAssertTrue(changed.isEmpty, "Cancel does not tell the root to change chats")

        center.request("owned")
        let end = try await button("End", in: window)
        XCTAssertTrue(end.accessibilityActivate(), "the actual End button is actionable")
        let acknowledged = try await waitUntil { changed == ["owned"] }
        XCTAssertTrue(acknowledged, "End's task survives SwiftUI clearing the presentation binding")
        let afterEnd = await client.calls
        XCTAssertEqual(afterEnd, ["end:account-a:owned"], "one confirmation makes one account-bound write")
        let endDismissed = try await waitUntil {
            center.confirmation == nil && window.rootViewController?.presentedViewController == nil
        }
        XCTAssertTrue(endDismissed)
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
