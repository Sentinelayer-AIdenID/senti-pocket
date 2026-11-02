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
        loaded.remove(deviceIds: done)
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
}
