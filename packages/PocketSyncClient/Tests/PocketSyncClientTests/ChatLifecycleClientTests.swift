import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PocketContracts
import XCTest
@testable import PocketSyncClient

private final class ChatLifecycleCredentialState: @unchecked Sendable {
    private let lock = NSLock()
    private var accountId = "account-a"
    private var token = "test-bearer-before"
    func get() -> ChatLifecycleCredential {
        lock.lock(); defer { lock.unlock() }
        return ChatLifecycleCredential(accountId: accountId, token: token)
    }
    func changeAccount() { lock.lock(); accountId = "account-b"; token = "test-bearer-other"; lock.unlock() }
    func rotateToken() { lock.lock(); token = "test-bearer-rotated"; lock.unlock() }
}

final class ChatLifecycleClientTests: XCTestCase {
    private let success = #"{"ok":true,"sessionId":"chat-1","status":"killed"}"#

    private func client(leave: Bool = false, credential: ChatLifecycleCredentialState = ChatLifecycleCredentialState(),
                        during: (() -> Void)? = nil,
                        response: @escaping (PersonalRoutesURLProtocol.Seen) -> (Int, String)) -> HTTPChatLifecycleClient {
        PersonalRoutesURLProtocol.reset(during: during, handler: response)
        return HTTPChatLifecycleClient(apiBaseURL: URL(string: "https://api.example.test"),
            urlSession: PersonalRoutesURLProtocol.session(), credentialProvider: { credential.get() }, leaveEnabled: leave)
    }

    func test_archive_uses_the_website_contract_and_the_same_account_guard() async throws {
        let success = #"{"ok":true,"archiveStatus":"archived","s3ArchivePath":null}"#
        let credential = ChatLifecycleCredentialState()
        let api = client(credential: credential, during: { credential.rotateToken() }) { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/api/v1/sessions/chat-1/archive")
            XCTAssertEqual(request.authorization, "Bearer test-bearer-before")
            XCTAssertEqual(request.body, .object([:]))
            return (200, success)
        }
        try await api.archiveChat("chat-1", accountId: "account-a")
        XCTAssertEqual(PersonalRoutesURLProtocol.requests.count, 1)
        credential.changeAccount()
        do { try await api.archiveChat("chat-1", accountId: "account-a"); XCTFail("archived as another account") }
        catch { XCTAssertEqual(error as? ChatLifecycleError, .accountChanged) }
        XCTAssertEqual(PersonalRoutesURLProtocol.requests.count, 1, "a stale account makes no second write")

        for response in [#"{"ok":false,"archiveStatus":"archived"}"#,
                         #"{"ok":true,"archiveStatus":"active"}"#, "{}"] {
            let refused = client { _ in (200, response) }
            do { try await refused.archiveChat("chat-1", accountId: "account-a"); XCTFail("accepted an unconfirmed archive") }
            catch { XCTAssertEqual(error as? ChatLifecycleError, .invalidResponse) }
        }
    }

    func test_end_uses_the_existing_website_call_and_checks_the_acknowledged_chat() async throws {
        let api = client { [success] request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/api/v1/sessions/chat-1/kill")
            XCTAssertEqual(request.authorization, "Bearer test-bearer-before")
            XCTAssertEqual(request.body, .object(["reason": .string("human_dashboard_kill")]))
            return (200, success)
        }
        try await api.endChat("chat-1", accountId: "account-a")
        XCTAssertEqual(PersonalRoutesURLProtocol.requests.count, 1)
    }

    func test_a_wrong_chat_or_unconfirmed_response_is_not_success() async {
        for response in [#"{"ok":true,"sessionId":"other","status":"killed"}"#,
                         #"{"ok":false,"sessionId":"chat-1","status":"killed"}"#,
                         #"{"ok":true,"sessionId":"chat-1","status":"active"}"#, "{}"] {
            let api = client { _ in (200, response) }
            do { try await api.endChat("chat-1", accountId: "account-a"); XCTFail("accepted an unconfirmed end") }
            catch { XCTAssertEqual(error as? ChatLifecycleError, .invalidResponse) }
        }
    }

    func test_leave_is_never_sent_until_the_flag_is_on() async throws {
        let api = client { _ in (200, "{}") }
        do { try await api.leaveChat("chat-1", accountId: "account-a"); XCTFail("sent leave before rollout") }
        catch { XCTAssertEqual(error as? ChatLifecycleError, .unavailable) }
        XCTAssertTrue(PersonalRoutesURLProtocol.requests.isEmpty)
        let enabled = client(leave: true) { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/api/v1/sessions/chat-1/leave")
            return (200, "{}")
        }
        try await enabled.leaveChat("chat-1", accountId: "account-a")
    }

    func test_an_account_switch_before_the_write_sends_nothing() async {
        let credential = ChatLifecycleCredentialState()
        let api = client(credential: credential) { [success] _ in (200, success) }
        credential.changeAccount()
        do { try await api.endChat("chat-1", accountId: "account-a"); XCTFail("sent the former account's intent") }
        catch { XCTAssertEqual(error as? ChatLifecycleError, .accountChanged) }
        XCTAssertTrue(PersonalRoutesURLProtocol.requests.isEmpty)
    }

    func test_an_account_switch_while_waiting_drops_the_answer() async {
        let credential = ChatLifecycleCredentialState()
        let api = client(credential: credential, during: { credential.changeAccount() }) { [success] _ in (200, success) }
        do { try await api.endChat("chat-1", accountId: "account-a"); XCTFail("used the former account's answer") }
        catch { XCTAssertEqual(error as? ChatLifecycleError, .accountChanged) }
    }

    func test_the_same_account_can_end_after_its_token_rotates() async throws {
        let credential = ChatLifecycleCredentialState()
        let api = client(credential: credential) { [success] request in
            XCTAssertEqual(request.authorization, "Bearer test-bearer-rotated")
            return (200, success)
        }
        credential.rotateToken()
        try await api.endChat("chat-1", accountId: "account-a")
        XCTAssertEqual(PersonalRoutesURLProtocol.requests.count, 1)
    }

    func test_token_rotation_during_the_write_keeps_the_same_accounts_answer() async throws {
        let credential = ChatLifecycleCredentialState()
        let api = client(credential: credential, during: { credential.rotateToken() }) { [success] request in
            XCTAssertEqual(request.authorization, "Bearer test-bearer-before")
            return (200, success)
        }
        try await api.endChat("chat-1", accountId: "account-a")
        XCTAssertEqual(PersonalRoutesURLProtocol.requests.count, 1)
    }

    func test_errors_are_not_success_and_response_bodies_are_not_shown() async {
        for (status, expected) in [(401, ChatLifecycleError.reauthenticationRequired), (403, .notAllowed),
                                   (404, .gone), (500, .network)] {
            let api = client { _ in (status, #"{"error":{"message":"private content"}}"#) }
            do { try await api.endChat("chat-1", accountId: "account-a"); XCTFail("accepted HTTP \(status)") }
            catch { XCTAssertEqual(error as? ChatLifecycleError, expected) }
        }
    }

    func test_invalid_identifiers_never_reach_the_network() async {
        let api = client { [success] _ in (200, success) }
        for id in ["", "..", "chat/other", "chat?x=1"] {
            do { try await api.endChat(id, accountId: "account-a"); XCTFail("sent an invalid id") }
            catch { XCTAssertEqual(error as? ChatLifecycleError, .notAllowed) }
        }
        XCTAssertTrue(PersonalRoutesURLProtocol.requests.isEmpty)
    }
}
