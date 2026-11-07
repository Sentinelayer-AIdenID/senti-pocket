import Foundation
import PocketContracts
import XCTest
@testable import SentiPocketApp

private final class QuestionHTTPStub: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) -> (Int, Data))?
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { () -> ((URLRequest) -> (Int, Data))? in
            Self.requests.append(request)
            return Self.handler
        }
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let (status, data) = reply(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset(_ handler: @escaping (URLRequest) -> (Int, Data)) {
        lock.withLock { requests = []; Self.handler = handler }
    }
    static var sent: [URLRequest] { lock.withLock { requests } }
}

private final class QuestionToken: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    init(_ token: String?) { self.token = token }
    var value: String? { lock.withLock { token } }
    func change(_ next: String?) { lock.withLock { token = next } }
}

private actor QuestionPreferencesStub: QuestionCallPreferencesAPI {
    var value = false
    var writes: [Bool] = []
    var failure: RoomCallsClient.Failure?
    func preference() async throws -> Bool { value }
    func savePreference(_ enabled: Bool) async throws -> Bool {
        writes.append(enabled)
        if let failure { throw failure }
        value = enabled
        return value
    }
    func fail(_ failure: RoomCallsClient.Failure) { self.failure = failure }
}

@MainActor
final class QuestionCallsClientTests: XCTestCase {
    private let roomID = "5b08ade7-c680-4fc9-8c63-af343072d476"
    private let id = "b01fc928-bd8e-48fc-9f23-c8f1b28a2c90"

    private func payload(status: String = "called", room: String? = nil, answerID: String? = nil) -> [String: Any] {
        ["questionId": id, "sessionId": room ?? roomID, "targetSequenceId": 91,
         "targetActionId": NSNull(), "text": "Ship?", "status": status,
         "choices": [["id": "ship", "label": "Ship it"], ["id": "wait", "label": "Wait"]],
         "expiresAt": "2030-01-01T00:00:00Z", "callId": "a63a9d6c-674f-4a3c-b115-9fc47a1a3439",
         "answerActionId": answerID as Any? ?? NSNull()]
    }

    private func encoded(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    private func makeClient(token: QuestionToken = QuestionToken("owner-session"),
                            reply: @escaping (URLRequest) -> (Int, Data)) -> RoomQuestionsClient {
        QuestionHTTPStub.reset(reply)
        let configuration = SentiHTTPTransportPolicy.makeProtectedReadConfiguration()
        configuration.protocolClasses = [QuestionHTTPStub.self]
        return RoomQuestionsClient(apiBaseURL: URL(string: "https://api.example.invalid"),
                                   urlSession: URLSession(configuration: configuration), tokenProvider: { token.value })
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let bytes = request.httpBody { data = bytes }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            data = bytes
        } else { data = Data() }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_tap_and_voice_send_only_answer_under_exact_question_with_owner_bearer() async throws {
        let initial = try XCTUnwrap(RoomQuestion(json: JSONDecoder().decode(JSONValue.self, from: encoded(payload()))))
        let response = try encoded(["ok": true, "duplicate": true,
                                    "question": payload(status: "answered", answerID: "0d312baa-b7b8-4e4d-b111-e069a059b1ea")])
        let client = makeClient { _ in (200, response) }
        let tap = try await client.answer(.choice("ship"), question: initial)
        let voice = try await client.answer(.voice("Tomorrow."), question: initial)
        XCTAssertEqual(tap.status, "answered")
        XCTAssertEqual(voice.answerActionId, tap.answerActionId)
        let requests = QuestionHTTPStub.sent
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/\(roomID)/questions/\(id)/answer")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-session")
        }
        XCTAssertEqual(try body(requests[0]) as NSDictionary, ["choiceId": "ship"] as NSDictionary)
        XCTAssertEqual(try body(requests[1]) as NSDictionary,
                       ["text": "Tomorrow.", "inputKind": "voice"] as NSDictionary)
    }

    func test_wrong_question_receipt_and_unconfirmed_status_never_become_success() async throws {
        let initial = try XCTUnwrap(RoomQuestion(json: JSONDecoder().decode(JSONValue.self, from: encoded(payload()))))
        let cases: [[String: Any]] = [
            ["ok": true, "question": payload(status: "answered", room: "different-room", answerID: id)],
            ["ok": true, "question": payload(status: "called")],
            ["ok": true, "question": payload(status: "answered")],
            ["ok": false, "question": payload(status: "answered", answerID: id)],
        ]
        for value in cases {
            let data = try encoded(value)
            let client = makeClient { _ in (200, data) }
            do { _ = try await client.answer(.choice("ship"), question: initial); XCTFail("expected refusal") }
            catch { XCTAssertEqual(error as? RoomCallsClient.Failure, .unreadable) }
        }
    }

    func test_signed_out_or_switched_account_sends_nothing_and_late_read_is_discarded() async throws {
        let data = try encoded(payload())
        for original: String? in [nil, ""] {
            let client = makeClient(token: QuestionToken(original)) { _ in (200, data) }
            do { _ = try await client.question(sessionId: roomID, questionId: id); XCTFail("expected sign-in refusal") }
            catch { XCTAssertEqual(error as? RoomCallsClient.Failure, .signedOut) }
            XCTAssertTrue(QuestionHTTPStub.sent.isEmpty)
        }
        let switched = QuestionToken("first-account")
        let client = makeClient(token: switched) { _ in (200, data) }
        switched.change("second-account")
        do { _ = try await client.question(sessionId: roomID, questionId: id); XCTFail("expected account refusal") }
        catch { XCTAssertEqual(error as? RoomCallsClient.Failure, .signedOut) }
        XCTAssertTrue(QuestionHTTPStub.sent.isEmpty)

        let midflight = QuestionToken("first-account")
        let late = makeClient(token: midflight) { _ in midflight.change("second-account"); return (200, data) }
        do { _ = try await late.question(sessionId: roomID, questionId: id); XCTFail("expected late response refusal") }
        catch { XCTAssertEqual(error as? RoomCallsClient.Failure, .signedOut) }
    }

    func test_invalid_path_and_invalid_answer_never_reach_transport() async throws {
        let data = try encoded(payload())
        let client = makeClient { _ in (200, data) }
        do { _ = try await client.question(sessionId: "../other", questionId: id); XCTFail("expected path refusal") }
        catch { XCTAssertEqual(error as? RoomCallsClient.Failure, .unreadable) }
        let initial = try XCTUnwrap(RoomQuestion(json: JSONDecoder().decode(JSONValue.self, from: data)))
        for answer in [RoomQuestionAnswer.choice("other"), .voice(" "), .voice(String(repeating: "x", count: 2_001))] {
            do { _ = try await client.answer(answer, question: initial); XCTFail("expected answer refusal") }
            catch { XCTAssertEqual(error as? RoomCallsClient.Failure, .unreadable) }
        }
        XCTAssertTrue(QuestionHTTPStub.sent.isEmpty)
    }

    func test_preference_read_never_enables_and_write_has_no_recipient_selector() async throws {
        let disabled = try encoded(["enabled": false]), enabled = try encoded(["enabled": true])
        let client = makeClient { request in (200, request.httpMethod == "PUT" ? enabled : disabled) }
        let read = try await client.preference()
        let saved = try await client.savePreference(true)
        XCTAssertFalse(read)
        XCTAssertTrue(saved)
        let requests = QuestionHTTPStub.sent
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT"])
        XCTAssertEqual(requests.map { $0.url?.path }, Array(repeating: "/api/v1/me/question-call-preferences", count: 2))
        XCTAssertEqual(try body(requests[1]) as NSDictionary, ["enabled": true] as NSDictionary)
        XCTAssertNil(SentiHTTPTransportPolicy.makeProtectedReadConfiguration().urlCache)
    }

    func test_preference_changes_are_confirmed_and_uncertain_write_requires_reread() async throws {
        let api = QuestionPreferencesStub()
        let preferences = QuestionCallPreferences(api: api)
        XCTAssertFalse(preferences.enabled)
        XCTAssertFalse(preferences.loaded)
        await preferences.save(true)
        let none = await api.writes
        XCTAssertTrue(none.isEmpty, "not before a server read")
        await preferences.load()
        XCTAssertTrue(preferences.loaded)
        XCTAssertFalse(preferences.enabled)
        await preferences.save(true)
        XCTAssertTrue(preferences.enabled)
        await api.fail(.unreachable)
        await preferences.save(false)
        XCTAssertFalse(preferences.loaded)
        XCTAssertTrue(preferences.enabled, "no optimistic claim that an uncertain opt-out saved")
        await preferences.save(false)
        let writes = await api.writes
        XCTAssertEqual(writes, [true, false], "an uncertain write cannot be repeated by toggling")
        await preferences.load()
        XCTAssertTrue(preferences.enabled)
    }
}
