import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class AdmissionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var captured: [(URLRequest, Data)] = []

    static func reset(status: Int) {
        lock.lock()
        self.status = status
        captured = []
        lock.unlock()
    }

    static func requests() -> [(URLRequest, Data)] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.captured.append((request, body))
        let status = Self.status
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SessionMutationCSRFTests: XCTestCase {
    // Known answers computed with the API's own rule (Python hmac over the same message).
    func test_the_token_matches_the_api_rule_byte_for_byte() {
        let route = HTTPAdmissionDecider.routeTemplate
        XCTAssertEqual(
            SessionMutationCSRF.token(bearer: "test-bearer-token", sessionId: "0B1C2D3E-4F50-4A6B-8C7D-9E0F1A2B3C4D",
                                      routeTemplate: route, idempotencyKey: "adm-key-1"),
            "bff30e49fdebbbbf51293b44ea9bad908a4431c6132c35621f047a7a565553f4"
        )
        XCTAssertEqual(
            SessionMutationCSRF.token(bearer: "test-bearer-token", sessionId: "0b1c2d3e4f504a6b8c7d9e0f1a2b3c4d",
                                      routeTemplate: route, idempotencyKey: "adm-key-1"),
            "bff30e49fdebbbbf51293b44ea9bad908a4431c6132c35621f047a7a565553f4",
            "an undashed UUID canonicalises to the same ref"
        )
        XCTAssertEqual(
            SessionMutationCSRF.token(bearer: "test-bearer-token", sessionId: "Room_1",
                                      routeTemplate: route, idempotencyKey: "adm-key-1"),
            "b4502621351a4cf3c7ec2699ffcf21f2362a5a7d6f106cd7ec8f9240798bdb58"
        )
    }

    func test_canonical_session_refs() {
        XCTAssertEqual(SessionMutationCSRF.canonicalSessionRef(" 0B1C2D3E-4F50-4A6B-8C7D-9E0F1A2B3C4D "),
                       "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d")
        XCTAssertEqual(SessionMutationCSRF.canonicalSessionRef("Room_1"), "room_1")
        XCTAssertEqual(SessionMutationCSRF.canonicalSessionRef(""), "unavailable")
        XCTAssertEqual(SessionMutationCSRF.canonicalSessionRef("0b1c2d3e4f504a6b8c7d9e0f1a2b3c4z"),
                       "0b1c2d3e4f504a6b8c7d9e0f1a2b3c4z", "not hex: just lowercased")
    }
}

final class AdmissionDeciderTests: XCTestCase {
    private let admission = "6a0b1f7e-1111-4c4c-8888-0123456789ab"

    private func makeDecider(status: Int = 200) -> HTTPAdmissionDecider {
        AdmissionURLProtocol.reset(status: status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdmissionURLProtocol.self]
        return HTTPAdmissionDecider(
            apiBaseURL: URL(string: "https://api.example.test"),
            urlSession: URLSession(configuration: configuration),
            tokenProvider: { "test-bearer-token" }
        )
    }

    func test_an_approval_carries_the_intent_header_and_a_token_bound_to_its_key() async throws {
        let decider = makeDecider()
        try await decider.decide(sessionId: "room_1", admissionId: admission, approve: true,
                                 grantedActions: ["session.read", "session.post"], ttlSeconds: 3600)
        let (request, body) = try XCTUnwrap(AdmissionURLProtocol.requests().first)
        XCTAssertEqual(request.url?.path, "/api/v1/sessions/room_1/admissions/\(admission)/decision")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Sentinelayer-Session-Mutation"), "session-mutation")
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"), "a native client sends no browser headers")
        let key = try XCTUnwrap(request.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-CSRF-Token"),
            SessionMutationCSRF.token(bearer: "test-bearer-token", sessionId: "room_1",
                                      routeTemplate: HTTPAdmissionDecider.routeTemplate, idempotencyKey: key)
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["decision"] as? String, "approve")
        XCTAssertEqual(json["grantedActions"] as? [String], ["session.read", "session.post"])
        XCTAssertEqual(json["ttlSeconds"] as? Int, 3600)
        XCTAssertEqual(Set(json.keys), ["decision", "grantedActions", "ttlSeconds"], "the API forbids extra fields")
    }

    func test_a_denial_sends_only_the_decision() async throws {
        let decider = makeDecider()
        try await decider.decide(sessionId: "room_1", admissionId: admission, approve: false, grantedActions: [], ttlSeconds: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(AdmissionURLProtocol.requests().first).1) as? [String: Any])
        XCTAssertEqual(json as? [String: String], ["decision": "deny"])
    }

    func test_unknown_scopes_and_bad_ids_are_refused_before_the_network() async {
        let decider = makeDecider()
        for (id, actions) in [(admission, ["session.admin"]), (admission, [String]()), ("not-a-uuid", ["session.read"])] {
            do {
                try await decider.decide(sessionId: "room_1", admissionId: id, approve: true, grantedActions: actions, ttlSeconds: nil)
                XCTFail("expected a refusal")
            } catch {
                XCTAssertEqual(error as? RoomSendError, .rejected)
            }
        }
        XCTAssertTrue(AdmissionURLProtocol.requests().isEmpty)
    }
}

private final class ScriptedAdmissions: RoomAdmissionsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [Result<RoomAdmissionsPage, Error>]
    init(_ pages: [Result<RoomAdmissionsPage, Error>]) { self.pages = pages }

    func roomAdmissions(sessionId: String) async throws -> RoomAdmissionsPage {
        let next: Result<RoomAdmissionsPage, Error> = {
            lock.lock()
            defer { lock.unlock() }
            return pages.count > 1 ? pages.removeFirst() : (pages.first ?? .success(RoomAdmissionsPage(admissions: [])))
        }()
        return try next.get()
    }
}

private final class RecordingDecider: AdmissionDeciding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(id: String, approve: Bool, actions: [String], ttl: Int?)] = []
    private let failure: RoomSendError?
    init(failure: RoomSendError? = nil) { self.failure = failure }

    func decide(sessionId: String, admissionId: String, approve: Bool, grantedActions: [String], ttlSeconds: Int?) async throws {
        lock.lock()
        calls.append((admissionId, approve, grantedActions, ttlSeconds))
        lock.unlock()
        if let failure { throw failure }
    }

    func recorded() -> [(id: String, approve: Bool, actions: [String], ttl: Int?)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@MainActor
final class AdmissionsCoordinatorTests: XCTestCase {
    private func pending(_ id: String) -> RoomAdmission {
        RoomAdmission(admissionId: id, status: "pending", agentId: "slate-forge", goalSummary: "Review PRs",
                      requestedActions: ["session.read", "session.post"], requestedTTLSeconds: 7200)
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for: \(description)")
    }

    func test_pending_requests_list_and_an_approval_goes_out_with_the_narrowed_scope() async {
        let id = "6a0b1f7e-1111-4c4c-8888-0123456789ab"
        let decider = RecordingDecider()
        let coordinator = AdmissionsCoordinator(
            sessionId: "room_1",
            transport: ScriptedAdmissions([
                .success(RoomAdmissionsPage(mode: "required", admissions: [pending(id)])),
                .success(RoomAdmissionsPage(mode: "required", admissions: []))
            ]),
            decider: decider,
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            onReauthenticationRequired: {}
        )
        await coordinator.refresh()
        XCTAssertEqual(coordinator.state.pending.map(\.agentId), ["slate-forge"])
        XCTAssertEqual(coordinator.state.mode, "required")

        coordinator.send(.approve(id: id, actions: ["session.read"], ttlSeconds: 3600))
        await waitUntil("decided and refreshed") { decider.recorded().count == 1 && coordinator.state.pending.isEmpty }
        let call = decider.recorded()[0]
        XCTAssertTrue(call.approve)
        XCTAssertEqual(call.actions, ["session.read"])
        XCTAssertEqual(call.ttl, 3600)
    }

    func test_a_refused_decision_explains_and_access_denied_stops() async {
        let id = "6a0b1f7e-1111-4c4c-8888-0123456789ab"
        let coordinator = AdmissionsCoordinator(
            sessionId: "room_1",
            transport: ScriptedAdmissions([.success(RoomAdmissionsPage(admissions: [pending(id)]))]),
            decider: RecordingDecider(failure: .notAllowed),
            sleep: { _ in try? await Task.sleep(nanoseconds: 3_600_000_000_000) },
            onReauthenticationRequired: {}
        )
        await coordinator.refresh()
        coordinator.send(.deny(id: id))
        await waitUntil("error shown") { coordinator.state.errorText != nil }
        XCTAssertTrue(coordinator.state.deciding.isEmpty)

        let denied = AdmissionsCoordinator(
            sessionId: "room_1",
            transport: ScriptedAdmissions([.failure(SessionTransportError.accessDenied)]),
            decider: RecordingDecider(),
            onReauthenticationRequired: {}
        )
        await denied.refresh()
        XCTAssertEqual(denied.state.failure, .accessDenied)
        XCTAssertTrue(denied.state.pending.isEmpty)
    }
}
