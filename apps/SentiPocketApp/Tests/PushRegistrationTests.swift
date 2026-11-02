import Foundation
import XCTest
@testable import SentiPocketApp

private final class PushDeviceURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var answer = Data("{}".utf8)
    private static var captured: [URLRequest] = []

    static func reset(status: Int, answer: String = "{}") {
        lock.lock()
        self.status = status
        self.answer = Data(answer.utf8)
        captured = []
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(request)
        let status = Self.status, answer = Self.answer
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Warden, #298 review: the phone signed its push rows out by the device token, a route the server does not have
/// (it takes the row id), so every sign-out failed and "previews off" never applied; nothing kept a failed sign-out;
/// and a call could ring for the last account before the new one had registered.
final class PushRegistrationTests: XCTestCase {
    private let rowId = "8f2c1d7e-3b4a-4c5d-9e6f-0a1b2c3d4e5f"

    private func client(bearer: String? = "bearer-a") -> PushDeviceClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushDeviceURLProtocol.self]
        return PushDeviceClient(apiBaseURL: URL(string: "https://api.pocket.test"), urlSession: URLSession(configuration: configuration),
                                tokenProvider: { bearer })
    }

    func test_rows_are_addressed_by_the_id_the_registration_returned_never_by_the_device_token() async throws {
        let token = String(repeating: "ab", count: 32)
        PushDeviceURLProtocol.reset(status: 200, answer: #"{"id":"8F2C1D7E-3B4A-4C5D-9E6F-0A1B2C3D4E5F","token":"\#(token)"}"#)
        let id = try await client().register(token: token, environment: "sandbox", bundleId: "com.example", appVersion: nil)
        XCTAssertEqual(id, rowId)

        PushDeviceURLProtocol.reset(status: 204)
        try await client().unregister(deviceId: rowId)
        try await client().setPreferences(deviceId: rowId, sound: true, vibrate: false, showPreviews: false)
        let requests = PushDeviceURLProtocol.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["DELETE", "PUT"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/v1/me/push-devices/\(rowId)", "/api/v1/me/push-devices/\(rowId)/preferences"])
        XCTAssertFalse(requests.contains { $0.url?.absoluteString.contains(token) == true }, "a device token never goes in a route")
    }

    func test_a_row_the_server_no_longer_has_for_this_person_is_signed_out_and_a_bad_id_sends_nothing() async throws {
        PushDeviceURLProtocol.reset(status: 404)
        try await client().unregister(deviceId: rowId)
        PushDeviceURLProtocol.reset(status: 401)
        do {
            try await client().unregister(deviceId: rowId)
            XCTFail("a refused credential has not signed the row out")
        } catch {}
        PushDeviceURLProtocol.reset(status: 204)
        try await client().unregister(deviceId: "../../sessions")
        XCTAssertTrue(PushDeviceURLProtocol.requests().isEmpty, "only a UUID goes into the route")
        XCTAssertNil(PushDeviceClient.deviceId(in: Data(#"{"id":"not-a-uuid"}"#.utf8)))
    }

    func test_an_owed_sign_out_is_kept_until_its_own_accounts_credential_confirms_it() async {
        let defaults = UserDefaults(suiteName: "push-queue-\(UUID().uuidString)")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var queue = PushUnregisterQueue()
        queue.add(deviceId: rowId, account: "sub:a", now: now)
        queue.add(deviceId: rowId, account: "sub:a", now: now)
        queue.add(deviceId: "1d4c8b2a-0f3e-4a5b-8c7d-6e5f4a3b2c1d", account: "sub:b", now: now)
        queue.add(deviceId: "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d", account: nil, now: now)
        queue.save(to: defaults)

        var loaded = PushUnregisterQueue.load(from: defaults)
        XCTAssertEqual(loaded.entries.count, 2, "once each, and never one no credential could send")
        XCTAssertEqual(loaded.due(for: "sub:b", now: now).map(\.deviceId), ["1d4c8b2a-0f3e-4a5b-8c7d-6e5f4a3b2c1d"],
                       "another account's credential cannot sign A's row out")
        XCTAssertEqual(loaded.due(for: nil, now: now), [])

        let refused = await PushUnregisterQueue.confirmed(of: loaded.due(for: "sub:a", now: now)) { _ in
            throw PushDeviceClient.Failure.refused(401)
        }
        XCTAssertEqual(refused, [], "a refused credential confirms nothing: the row stays owed")
        let done = await PushUnregisterQueue.confirmed(of: loaded.due(for: "sub:a", now: now)) { _ in }
        loaded.remove(deviceIds: done, account: "sub:a")
        loaded.save(to: defaults)
        XCTAssertEqual(PushUnregisterQueue.load(from: defaults).entries.map(\.account), ["sub:b"])

        var aged = PushUnregisterQueue.load(from: defaults)
        XCTAssertEqual(aged.due(for: "sub:b", now: now.addingTimeInterval(PushUnregisterQueue.keptFor + 1)), [])
        aged.save(to: defaults)
        XCTAssertNil(defaults.data(forKey: PushUnregisterQueue.key), "an empty queue leaves nothing behind")
    }

    func test_a_call_rings_only_for_the_account_its_row_was_confirmed_for() {
        XCTAssertTrue(PushRegistrar.rings(callAccount: "sub:b", signedIn: "sub:b"))
        XCTAssertFalse(PushRegistrar.rings(callAccount: "sub:a", signedIn: "sub:b"), "B signed in before B's row landed")
        XCTAssertFalse(PushRegistrar.rings(callAccount: "", signedIn: "sub:b"), "no confirmed row yet")
        XCTAssertFalse(PushRegistrar.rings(callAccount: "sub:a", signedIn: nil), "no one signed in")
    }

    /// Warden, #298 review of build 09: an owed row is never deleted from under the account that reclaimed it.
    func test_a_row_is_owed_per_account_and_forgiven_when_reclaimed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var queue = PushUnregisterQueue()
        queue.add(deviceId: rowId, account: "sub:a", now: now)
        queue.add(deviceId: rowId, account: "sub:b", now: now)
        XCTAssertEqual(queue.due(for: "sub:b", now: now).map(\.deviceId), [rowId], "A's stale entry never stands in for B's")
        queue.remove(deviceIds: [rowId], account: "sub:b")
        XCTAssertEqual(queue.entries.map(\.account), ["sub:a"], "B's confirmation is B's alone")
        queue.add(deviceId: rowId, account: "sub:b", now: now)
        queue.forgive(account: "sub:a")
        XCTAssertEqual(queue.entries.map(\.account), ["sub:b"], "A signed in again: A's rows are A's again")
        queue.forgive(deviceId: rowId)
        XCTAssertEqual(queue.entries, [], "a registration returned the row: it is current, whoever owed it")
    }

    // MARK: - The registrar itself (its call sites, which the queue's own tests above cannot see)

    private func bearer(_ sub: String) -> String {
        let payload = Data(#"{"sub":"\#(sub)","exp":4102444800}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "e30.\(payload).sig"
    }

    private let otherRow = "1d4c8b2a-0f3e-4a5b-8c7d-6e5f4a3b2c1d"
    private let pushKeys = ["pocket.push.deviceId", "pocket.push.voipDeviceId", "pocket.push.voipAccount", "pocket.push.token",
                            PushUnregisterQueue.key]

    @MainActor
    private func withRegistrar(status: Int, _ body: (PushRegistrar) async throws -> Void) async rethrows {
        let registrar = PushRegistrar.shared
        let saved = registrar.client
        let keep = pushKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        PushDeviceURLProtocol.reset(status: status)
        registrar.client = client(bearer: nil)
        defer {
            registrar.client = saved
            for (key, value) in keep { UserDefaults.standard.set(value, forKey: key) }
        }
        for key in pushKeys { UserDefaults.standard.removeObject(forKey: key) }
        try await body(registrar)
    }

    @MainActor
    func test_signing_out_owes_both_rows_and_sends_them_with_its_own_credential() async {
        await withRegistrar(status: 503) { registrar in
            UserDefaults.standard.set(rowId, forKey: "pocket.push.deviceId")
            UserDefaults.standard.set(otherRow, forKey: "pocket.push.voipDeviceId")
            registrar.signOut(bearer: bearer("a"))
            var queue = PushUnregisterQueue.load()
            XCTAssertEqual(Set(queue.due(for: "sub:a").map(\.deviceId)), [rowId, otherRow],
                           "the server did not confirm: both rows stay owed, on the phone")
            XCTAssertNil(UserDefaults.standard.string(forKey: "pocket.push.deviceId").flatMap { $0.isEmpty ? nil : $0 })

            PushDeviceURLProtocol.reset(status: 204)
            for _ in 0..<80 where !PushUnregisterQueue.load().entries.isEmpty {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            queue = PushUnregisterQueue.load()
            XCTAssertEqual(queue.entries, [], "sent again while the app runs, and confirmed")
            let deletes = PushDeviceURLProtocol.requests().filter {
                $0.httpMethod == "DELETE" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(bearer("a"))"
            }
            XCTAssertEqual(Set(deletes.compactMap { $0.url?.lastPathComponent }), [rowId, otherRow],
                           "by id, with the credential of the sign-out that owed them")
        }
    }

    @MainActor
    func test_signing_in_again_reclaims_the_accounts_rows_and_a_late_registration_is_owed() async {
        await withRegistrar(status: 503) { registrar in
            let lateRow = "5b6c7d8e-9f0a-4b1c-8d2e-3f4a5b6c7d8e", movedRow = "2e3f4a5b-6c7d-4e8f-9a0b-1c2d3e4f5a6b"
            var queue = PushUnregisterQueue()
            queue.add(deviceId: lateRow, account: "sub:a")
            queue.add(deviceId: movedRow, account: "sub:b")
            queue.save()
            registrar.signedIn(account: "sub:a")
            XCTAssertEqual(PushUnregisterQueue.load().entries.map(\.account), ["sub:b"],
                           "A is back: A's own rows are never deleted from under it")

            // C's registration lands after the phone moved on (no one is signed in here now): owed at once, as C's.
            // The server handed back the row B still owed, so B's entry goes: the row is C's now.
            XCTAssertFalse(registrar.registered(movedRow, account: "sub:c", bearer: bearer("c"), stillCurrent: true))
            let entries = PushUnregisterQueue.load().entries
            XCTAssertFalse(entries.contains { $0.account == "sub:b" }, "B's stale entry never deletes C's row")
            XCTAssertEqual(entries.filter { $0.account == "sub:c" }.map(\.deviceId), [movedRow])
        }
    }

    @MainActor
    func test_a_phone_no_one_is_signed_in_on_keeps_no_bell_registration() async {
        await withRegistrar(status: 204) { registrar in
            UserDefaults.standard.set("ab12", forKey: "pocket.push.token")
            registrar.launched(signedIn: true)
            XCTAssertTrue(registrar.hasToken)
            registrar.launched(signedIn: false)
            XCTAssertFalse(registrar.hasToken, "an older build's leftover registration goes at launch")
        }
    }
}
