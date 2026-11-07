import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private actor RecordingChatLifecycle: ChatLifecycleServing {
    private(set) var calls: [String] = []
    let failure: ChatLifecycleError?
    init(failure: ChatLifecycleError? = nil) { self.failure = failure }
    func archiveChat(_ roomId: String, accountId: String) async throws {
        calls.append("archive:" + roomId)
        if let failure { throw failure }
    }
    func endChat(_ roomId: String, accountId: String) async throws {
        calls.append("end:" + roomId)
        if let failure { throw failure }
    }
    func leaveChat(_ roomId: String, accountId: String) async throws {
        calls.append("leave:" + roomId)
        if let failure { throw failure }
    }
}

/// Holds the in-flight result until the test changes the center's account, without sleeps or a blocked thread.
private actor SuspendedLifecycleAuthenticationFailure: ChatLifecycleServing {
    private var response: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func waitUntilCalled() async {
        if response != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        let held = response
        response = nil
        held?.resume()
    }

    private func failAfterRelease() async throws {
        await withCheckedContinuation { continuation in
            response = continuation
            started?.resume()
            started = nil
        }
        throw ChatLifecycleError.reauthenticationRequired
    }

    func archiveChat(_ roomId: String, accountId: String) async throws { try await failAfterRelease() }
    func endChat(_ roomId: String, accountId: String) async throws { try await failAfterRelease() }
    func leaveChat(_ roomId: String, accountId: String) async throws { try await failAfterRelease() }
}

@MainActor
final class ChatLifecycleCenterTests: XCTestCase {
    func test_archive_asks_first_cancel_does_nothing_and_only_a_current_owner_can_confirm() async throws {
        let client = RecordingChatLifecycle()
        var permission: ChatRowLifecycleAction? = .end
        let center = ChatLifecycleCenter(client: client, lookup: { _ in permission })
        center.setAccountId("account-a")
        center.request("owned", action: .archive)
        let cancelled = try XCTUnwrap(center.confirmation)
        XCTAssertEqual(cancelled.action, .archive)
        let before = await client.calls
        XCTAssertTrue(before.isEmpty)
        center.cancel()
        let cancelledAccepted = await center.confirm(cancelled)
        XCTAssertFalse(cancelledAccepted)

        center.request("owned", action: .archive)
        let stale = try XCTUnwrap(center.confirmation)
        permission = .leave
        let staleAccepted = await center.confirm(stale)
        XCTAssertFalse(staleAccepted, "losing ownership removes the archive permission")
        center.request("member", action: .archive)
        XCTAssertNil(center.confirmation, "a leave-only row cannot request Archive")
        let afterRefusals = await client.calls
        XCTAssertTrue(afterRefusals.isEmpty)

        permission = .end
        center.request("owned", action: .archive)
        let current = try XCTUnwrap(center.confirmation)
        let accepted = await center.confirm(current)
        XCTAssertTrue(accepted)
        let calls = await client.calls
        XCTAssertEqual(calls, ["archive:owned"], "Archive never sends End")
    }

    func test_request_only_asks_cancel_writes_nothing_and_confirm_is_single_use() async throws {
        let client = RecordingChatLifecycle()
        let center = ChatLifecycleCenter(client: client, lookup: { $0 == "owned" ? .end : nil })
        center.setAccountId("account-a")
        center.request("owned")
        let cancelled = try XCTUnwrap(center.confirmation)
        let before = await client.calls
        XCTAssertTrue(before.isEmpty, "opening the menu must never end a chat")
        center.cancel()
        let acceptedCancel = await center.confirm(cancelled)
        XCTAssertFalse(acceptedCancel)
        let afterCancel = await client.calls
        XCTAssertTrue(afterCancel.isEmpty)

        center.request("owned")
        let pending = try XCTUnwrap(center.confirmation)
        center.confirmation = nil // The alert may clear its presentation before its button runs.
        let accepted = await center.confirm(pending)
        let replayed = await center.confirm(pending)
        XCTAssertTrue(accepted)
        XCTAssertFalse(replayed)
        let calls = await client.calls
        XCTAssertEqual(calls, ["end:owned"])
    }

    func test_member_and_stale_owner_cannot_end_a_chat() async throws {
        let client = RecordingChatLifecycle()
        var currentAction: ChatRowLifecycleAction? = nil
        let center = ChatLifecycleCenter(client: client, lookup: { _ in currentAction })
        center.setAccountId("account-a")
        center.request("chat")
        XCTAssertNil(center.confirmation)
        currentAction = .end
        center.request("chat")
        let pending = try XCTUnwrap(center.confirmation)
        currentAction = nil
        let accepted = await center.confirm(pending)
        XCTAssertFalse(accepted)
        XCTAssertNotNil(center.notice)
        let calls = await client.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func test_a_new_chat_selection_invalidates_an_old_confirmation() async throws {
        let client = RecordingChatLifecycle()
        let center = ChatLifecycleCenter(client: client, lookup: { _ in .end })
        center.setAccountId("account-a")
        center.request("first")
        let old = try XCTUnwrap(center.confirmation)
        center.request("second")
        let current = try XCTUnwrap(center.confirmation)
        let staleAccepted = await center.confirm(old)
        let currentAccepted = await center.confirm(current)
        XCTAssertFalse(staleAccepted)
        XCTAssertTrue(currentAccepted)
        let calls = await client.calls
        XCTAssertEqual(calls, ["end:second"])
    }

    func test_network_failure_does_not_remove_the_chat_or_claim_success() async throws {
        let client = RecordingChatLifecycle(failure: .network)
        let center = ChatLifecycleCenter(client: client, lookup: { _ in .end })
        center.setAccountId("account-a")
        center.request("owned")
        let pending = try XCTUnwrap(center.confirmation)
        let accepted = await center.confirm(pending)
        XCTAssertFalse(accepted)
        XCTAssertEqual(center.notice, "The change could not be confirmed. Check your connection and refresh your chats before trying again.")
        XCTAssertFalse(center.isSaving)
    }

    func test_an_expired_sign_in_uses_the_existing_sign_in_gate() async throws {
        let client = RecordingChatLifecycle(failure: .reauthenticationRequired)
        var expired = false
        let center = ChatLifecycleCenter(client: client, lookup: { _ in .end }, onReauthenticationRequired: { expired = true })
        center.setAccountId("account-a")
        center.request("owned")
        let pending = try XCTUnwrap(center.confirmation)
        let accepted = await center.confirm(pending)
        XCTAssertFalse(accepted)
        XCTAssertTrue(expired)
        XCTAssertNil(center.notice)
    }

    func test_an_old_pending_authentication_failure_does_not_revoke_the_new_account() async throws {
        let nextAccounts: [String?] = ["account-b", nil]
        for nextAccount in nextAccounts {
            let client = SuspendedLifecycleAuthenticationFailure()
            var signIns = 0
            let center = ChatLifecycleCenter(client: client, lookup: { _ in .end },
                                             onReauthenticationRequired: { signIns += 1 })
            center.setAccountId("account-a")
            center.request("owned")
            let pending = try XCTUnwrap(center.confirmation)
            let completion = Task { await center.confirm(pending) }
            await client.waitUntilCalled()

            center.setAccountId(nextAccount)
            await client.release()
            let accepted = await completion.value

            XCTAssertFalse(accepted)
            XCTAssertEqual(signIns, 0, "the old account's failure must not reopen sign-in for another account")
            XCTAssertNil(center.notice)
            XCTAssertFalse(center.isSaving)
        }
    }

    func test_leave_requires_the_feature_flag_even_if_a_caller_offers_it() async throws {
        let client = RecordingChatLifecycle()
        let disabled = ChatLifecycleCenter(client: client, lookup: { _ in .leave })
        disabled.setAccountId("account-a")
        disabled.request("member")
        XCTAssertNil(disabled.confirmation)
        let enabled = ChatLifecycleCenter(client: client, leaveEnabled: true, lookup: { _ in .leave })
        enabled.setAccountId("account-a")
        enabled.request("member")
        let pending = try XCTUnwrap(enabled.confirmation)
        let accepted = await enabled.confirm(pending)
        XCTAssertTrue(accepted)
        let calls = await client.calls
        XCTAssertEqual(calls, ["leave:member"])
    }

    func test_an_account_change_invalidates_a_confirmation_and_unknown_accounts_cannot_request() async throws {
        let client = RecordingChatLifecycle()
        let center = ChatLifecycleCenter(client: client, lookup: { _ in .end })
        center.request("owned")
        XCTAssertNil(center.confirmation)
        center.setAccountId("account-a")
        center.request("owned")
        let pending = try XCTUnwrap(center.confirmation)
        center.setAccountId("account-b")
        XCTAssertNil(center.confirmation)
        let accepted = await center.confirm(pending)
        XCTAssertFalse(accepted)
        let calls = await client.calls
        XCTAssertTrue(calls.isEmpty)
    }

}
