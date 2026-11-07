import AuthenticationServices
import Foundation
import XCTest
@testable import SentiPocketApp

private let linkState = "link_" + String(repeating: "a", count: 43)
private let linkNonce = String(repeating: "n", count: 43)
private let linkChallenge = AppleLinkChallenge(state: linkState, nonce: linkNonce, expiresIn: 300)
private let linkProof = AppleLinkProof(state: linkState, identityToken: "signed.apple.proof", authorizationCode: "apple-code")

private final class LinkAccountFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    var value: Bool { lock.withLock { current } }
    func changeAccount() { lock.withLock { current = false } }
}

private actor LinkAPIStub: AppleIdentityLinkAPI {
    nonisolated let account = LinkAccountFlag()
    nonisolated var sessionIsCurrent: Bool { account.value }
    var links = LinkedSignIns(google: false, apple: false, github: true)
    var issued = 0
    var completed: [AppleLinkProof] = []
    var readFailure: IdentityLinkFailure?
    var completeFailure: IdentityLinkFailure?

    func identities() async throws -> LinkedSignIns {
        if let readFailure { throw readFailure }
        return links
    }
    func challenge() async throws -> AppleLinkChallenge { issued += 1; return linkChallenge }
    func complete(_ proof: AppleLinkProof) async throws {
        completed.append(proof)
        if let completeFailure { throw completeFailure }
        links.apple = true
    }
    func failRead(_ error: IdentityLinkFailure) { readFailure = error }
    func failComplete(_ error: IdentityLinkFailure) { completeFailure = error }
    func linkedElsewhere() { links.apple = true }
}

@MainActor
private final class LinkAuthorizerStub: AppleLinkAuthorizing {
    var requests: [(state: String, digest: String)] = []
    var result = linkProof
    var failure: Error?
    var hold = false
    var waiter: CheckedContinuation<Void, Never>?
    func authorize(state: String, nonceDigest: String) async throws -> AppleLinkProof {
        requests.append((state, nonceDigest))
        if hold { await withCheckedContinuation { waiter = $0 } }
        if let failure { throw failure }
        return result
    }
    func release() { hold = false; waiter?.resume(); waiter = nil }
}

@MainActor
final class AppleIdentityLinkTests: XCTestCase {
    private func until(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out: \(message)")
    }

    func test_apple_request_echoes_state_uses_hash_and_asks_for_no_profile_fields() {
        let digest = AppleSignInNonce.digest(linkNonce)
        let request = SentiNativeAuth.appleRequest(nonceDigest: digest, state: linkState)
        XCTAssertEqual(request.nonce, digest)
        XCTAssertNotEqual(request.nonce, linkNonce)
        XCTAssertEqual(request.state, linkState)
        XCTAssertEqual(request.requestedScopes, [])
        XCTAssertNil(SentiNativeAuth.appleRequest(nonceDigest: digest).state, "ordinary sign-in remains unchanged")
    }

    func test_challenge_requires_bounded_opaque_server_values_and_max_five_minute_lifetime() {
        XCTAssertTrue(linkChallenge.valid)
        let invalid = [
            AppleLinkChallenge(state: "plain", nonce: linkNonce, expiresIn: 300),
            AppleLinkChallenge(state: "link_" + String(repeating: "a", count: 129), nonce: linkNonce, expiresIn: 300),
            AppleLinkChallenge(state: linkState, nonce: "bad nonce", expiresIn: 300),
            AppleLinkChallenge(state: linkState, nonce: linkNonce, expiresIn: 0),
            AppleLinkChallenge(state: linkState, nonce: linkNonce, expiresIn: 301),
        ]
        XCTAssertTrue(invalid.allSatisfy { !$0.valid })
    }

    func test_link_is_explicit_and_double_tap_uses_one_server_challenge_and_one_native_proof() async {
        let api = LinkAPIStub(), authorizer = LinkAuthorizerStub()
        let model = AppleLinkSettings(api: api, authorizer: authorizer)
        model.link()
        let before = await api.issued
        XCTAssertEqual(before, 0, "not before reading the account's current links")
        await model.refresh()
        XCTAssertEqual(model.identities, LinkedSignIns(google: false, apple: false, github: true))
        XCTAssertTrue(authorizer.requests.isEmpty, "a settings read does not open Apple or link anything")
        model.link()
        model.link()
        await until("link complete") { model.phase != .linking }
        let issued = await api.issued, completed = await api.completed
        XCTAssertEqual(issued, 1)
        XCTAssertEqual(completed, [linkProof])
        XCTAssertEqual(authorizer.requests.map(\.state), [linkState])
        XCTAssertEqual(authorizer.requests.map(\.digest), [AppleSignInNonce.digest(linkNonce)])
        XCTAssertEqual(model.identities, LinkedSignIns(google: false, apple: true, github: true))
        XCTAssertEqual(model.phase, .ready)
    }

    func test_wrong_native_state_never_completes_and_requires_a_fresh_read() async {
        let api = LinkAPIStub(), authorizer = LinkAuthorizerStub()
        authorizer.result = AppleLinkProof(state: "link_" + String(repeating: "b", count: 43),
                                           identityToken: "another.proof", authorizationCode: "code")
        let model = AppleLinkSettings(api: api, authorizer: authorizer)
        await model.refresh()
        model.link()
        await until("mismatched state refused") { model.phase != .linking }
        model.link()
        let completed = await api.completed, issued = await api.issued
        XCTAssertTrue(completed.isEmpty)
        XCTAssertEqual(issued, 1)
        XCTAssertEqual(model.phase, .needsRead)
        XCTAssertEqual(model.identities?.apple, false)
    }

    func test_account_switch_expiry_and_cancellation_after_apple_sheet_never_complete() async {
        for boundary in ["account", "expiry", "cancel"] {
            let api = LinkAPIStub(), authorizer = LinkAuthorizerStub()
            authorizer.hold = true
            var now = Date(timeIntervalSince1970: 1_800_000_000)
            let model = AppleLinkSettings(api: api, authorizer: authorizer, now: { now })
            await model.refresh()
            model.link()
            await until("Apple sheet suspended") { authorizer.waiter != nil }
            switch boundary {
            case "account": api.account.changeAccount()
            case "expiry": now = now.addingTimeInterval(300)
            default: model.cancel()
            }
            authorizer.release()
            await until("late proof refused") { model.phase != .linking }
            // Let the cancelled operation consume the fake's response before inspecting its writes.
            for _ in 0..<10 { await Task.yield() }
            let completed = await api.completed
            XCTAssertTrue(completed.isEmpty, boundary)
            XCTAssertNotEqual(model.identities?.apple, true, boundary)
        }
    }

    func test_feature_off_hides_linking_without_opening_apple() async {
        let api = LinkAPIStub(), authorizer = LinkAuthorizerStub()
        await api.failRead(.refused(404))
        let model = AppleLinkSettings(api: api, authorizer: authorizer)
        await model.refresh()
        model.link()
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertNil(model.identities)
        XCTAssertTrue(authorizer.requests.isEmpty)
        let issued = await api.issued
        XCTAssertEqual(issued, 0)
    }

    func test_conflict_or_lost_completion_never_claims_linked_or_replays_proof() async {
        for failure in [IdentityLinkFailure.refused(409), .unreachable, .unreadable] {
            let api = LinkAPIStub(), authorizer = LinkAuthorizerStub()
            await api.failComplete(failure)
            let model = AppleLinkSettings(api: api, authorizer: authorizer)
            await model.refresh()
            model.link()
            await until("completion not confirmed") { model.phase != .linking }
            XCTAssertEqual(model.phase, .needsRead)
            XCTAssertEqual(model.identities?.apple, false)
            model.link()
            let completed = await api.completed
            XCTAssertEqual(completed, [linkProof], "a spent challenge is never retried")
            await api.linkedElsewhere()
            await model.refresh()
            XCTAssertEqual(model.identities?.apple, true, "an explicit server read can resolve a lost completion")
        }
    }

    func test_user_cancelling_native_apple_keeps_original_link_state() async {
        let api = LinkAPIStub(), authorizer = LinkAuthorizerStub()
        authorizer.failure = NativeAuthError.userCancelledWeb
        let model = AppleLinkSettings(api: api, authorizer: authorizer)
        await model.refresh()
        model.link()
        await until("Apple cancel") { model.phase != .linking }
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.identities?.apple, false)
        let completed = await api.completed
        XCTAssertTrue(completed.isEmpty)
    }
}
