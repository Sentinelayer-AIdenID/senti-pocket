import Foundation
import PocketContracts
import SwiftUI
import UIKit
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
    var reads = 0
    var writes: [Bool] = []
    var failure: RoomCallsClient.Failure?
    var readFailure: RoomCallsClient.Failure?
    var holdRead = false
    private var readWaiter: CheckedContinuation<Void, Never>?
    func preference() async throws -> Bool {
        reads += 1
        if holdRead { await withCheckedContinuation { readWaiter = $0 } }
        if let readFailure { throw readFailure }
        return value
    }
    func savePreference(_ enabled: Bool) async throws -> Bool {
        writes.append(enabled)
        if let failure { throw failure }
        value = enabled
        return value
    }
    func fail(_ failure: RoomCallsClient.Failure) { self.failure = failure }
    func failRead(_ failure: RoomCallsClient.Failure?) { self.readFailure = failure }
    func holdNextRead(value: Bool = false) { holdRead = true; self.value = value }
    func isReadHeld() -> Bool { readWaiter != nil }
    func releaseRead() {
        holdRead = false
        readWaiter?.resume()
        readWaiter = nil
    }
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

    func test_redacted_duplicate_answer_is_a_final_refusal_not_an_uncertain_retry() async throws {
        let initial = try XCTUnwrap(RoomQuestion(json: JSONDecoder().decode(JSONValue.self, from: encoded(payload()))))
        for status in ["cancelled", "expired"] {
            var redacted = payload(status: status, answerID: "0d312baa-b7b8-4e4d-b111-e069a059b1ea")
            redacted["text"] = ""
            redacted["choices"] = [] as [[String: String]]
            let data = try encoded(["ok": true, "duplicate": true, "question": redacted])
            let client = makeClient { _ in (200, data) }
            do { _ = try await client.answer(.choice("ship"), question: initial); XCTFail("expected final refusal") }
            catch { XCTAssertEqual(error as? RoomCallsClient.Failure, .refused(409)) }
        }
    }

    func test_valid_unicode_room_identifier_is_encoded_before_url_components() async throws {
        let room = "café"
        let data = try encoded(payload(room: room))
        let client = makeClient { _ in (200, data) }
        let result = try await client.question(sessionId: room, questionId: id)
        XCTAssertEqual(result.sessionId, room)
        XCTAssertEqual(QuestionHTTPStub.sent.first?.url?.absoluteString,
                       "https://api.example.invalid/api/v1/sessions/caf%C3%A9/questions/\(id)")
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

    func test_flag_off_read_hides_the_setting_and_refuses_writes() async {
        let client = makeClient { _ in (404, Data()) }
        let preferences = QuestionCallPreferences(api: client)
        await preferences.load()
        XCTAssertTrue(preferences.unavailable)
        XCTAssertFalse(preferences.loaded)
        XCTAssertFalse(preferences.enabled)
        XCTAssertNil(preferences.notice)
        await preferences.save(true)
        XCTAssertEqual(QuestionHTTPStub.sent.map(\.httpMethod), ["GET"])
    }

    func test_loading_remains_visible_and_cannot_write_until_enabled_read_is_confirmed() async {
        let api = QuestionPreferencesStub()
        await api.holdNextRead(value: true)
        let preferences = QuestionCallPreferences(api: api)
        let load = Task { await preferences.load() }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await api.isReadHeld() { break }
            await Task.yield()
        }
        let held = await api.isReadHeld()
        XCTAssertTrue(held)
        XCTAssertTrue(preferences.working)
        XCTAssertFalse(preferences.loaded)
        XCTAssertFalse(preferences.enabled)
        XCTAssertFalse(preferences.unavailable)
        await preferences.save(true)
        let writes = await api.writes
        XCTAssertTrue(writes.isEmpty)
        await api.releaseRead()
        await load.value
        XCTAssertFalse(preferences.working)
        XCTAssertTrue(preferences.loaded)
        XCTAssertTrue(preferences.enabled)
        XCTAssertFalse(preferences.unavailable)
        XCTAssertNil(preferences.notice)
    }

    func test_non404_read_failures_keep_a_visible_retry_without_claiming_a_setting() async {
        for failure in [RoomCallsClient.Failure.unreachable, .unreadable, .refused(401), .refused(403), .refused(503)] {
            let api = QuestionPreferencesStub()
            await api.failRead(failure)
            let preferences = QuestionCallPreferences(api: api)
            await preferences.load()
            XCTAssertFalse(preferences.unavailable, "only 404 hides the feature")
            XCTAssertFalse(preferences.loaded)
            XCTAssertFalse(preferences.enabled)
            XCTAssertFalse(preferences.working)
            XCTAssertNotNil(preferences.notice)
            await preferences.save(true)
            let writes = await api.writes
            XCTAssertTrue(writes.isEmpty)
            await api.failRead(nil)
            await preferences.load()
            XCTAssertTrue(preferences.loaded)
            XCTAssertFalse(preferences.enabled)
            XCTAssertFalse(preferences.unavailable)
            XCTAssertNil(preferences.notice)
        }
    }

    func test_flag_disabled_during_save_hides_the_section_and_drops_stale_opt_in() async {
        let api = QuestionPreferencesStub()
        let preferences = QuestionCallPreferences(api: api)
        await preferences.load()
        await preferences.save(true)
        XCTAssertTrue(preferences.enabled)
        await api.fail(.refused(404))
        await preferences.save(false)
        XCTAssertTrue(preferences.unavailable)
        XCTAssertFalse(preferences.loaded)
        XCTAssertFalse(preferences.enabled)
        XCTAssertNil(preferences.notice)
        await preferences.save(true)
        let writes = await api.writes
        XCTAssertEqual(writes, [true, false])
    }

    func test_a_new_successful_read_can_restore_an_available_setting() async {
        let api = QuestionPreferencesStub()
        let preferences = QuestionCallPreferences(api: api)
        await api.failRead(.refused(404))
        await preferences.load()
        XCTAssertTrue(preferences.unavailable)
        await api.failRead(nil)
        await preferences.load()
        XCTAssertFalse(preferences.unavailable)
        XCTAssertTrue(preferences.loaded)
        XCTAssertFalse(preferences.enabled)
    }

    func test_hosted_settings_removes_the_toggle_and_explanation_after404() async throws {
        let api = QuestionPreferencesStub()
        await api.holdNextRead()
        let preferences = QuestionCallPreferences(api: api)
        let window = try HostedSummary.host(WhisperModelSettingsView(
            coordinator: WhisperModelProvisioningCoordinator(), onSignOut: {},
            offersModelFile: false, questionCallPreferences: preferences
        ), height: 2_400)
        defer { HostedSummary.close(window) }
        guard HostedSummary.wait(for: "settings.questionCalls.enabled", in: window) != nil else {
            await api.releaseRead()
            return XCTFail("the loading section never appeared")
        }
        XCTAssertFalse(preferences.loaded)
        let before = QuestionSettingsAccessibility.snapshot(in: window)
        XCTAssertNotNil(before.element("settings.questionCalls.enabled"))
        XCTAssertNotNil(before.element("settings.account.sign-out"))
        XCTAssertNotNil(before.element("settings.inapp.sounds"))
        XCTAssertTrue(before.labels.contains("Question calls"))
        XCTAssertTrue(before.labels.contains { $0.contains("Off until you enable it") })
        attachSettingsAccessibility(before, name: "settings-before-question-404-ancestry")
        attachSettingsImage(window, name: "settings-before-question-404")
        await api.failRead(.refused(404))
        await api.releaseRead()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && (preferences.working || QuestionSettingsAccessibility.snapshot(in: window).element("settings.questionCalls.enabled") != nil) {
            await Task.yield()
            HostedSummary.pump(0.02)
        }
        let after = QuestionSettingsAccessibility.snapshot(in: window)
        attachSettingsAccessibility(after, name: "settings-after-question-404-ancestry")
        attachSettingsImage(window, name: "settings-after-question-404")
        XCTAssertTrue(preferences.unavailable)
        XCTAssertNil(after.element("settings.questionCalls.enabled"))
        XCTAssertNotNil(after.element("settings.account.sign-out"))
        XCTAssertNotNil(after.element("settings.inapp.sounds"))
        let labels = after.labels
        XCTAssertFalse(labels.contains("Question calls"))
        XCTAssertFalse(labels.contains { $0.contains("Off until you enable it") })
        XCTAssertFalse(labels.contains("Read call preferences"))
    }

    func test_settings_accessibility_retains_active_offscreen_controls_and_explains_inactive_caches() throws {
        let window = try HostedSummary.host(Text("Accessibility fixture"))
        defer { HostedSummary.close(window) }
        func label(_ identifier: String, in parent: UIView, y: CGFloat = 20) -> UILabel {
            let view = UILabel(frame: CGRect(x: 20, y: y, width: 200, height: 40))
            view.text = identifier
            view.accessibilityIdentifier = identifier
            parent.addSubview(view)
            return view
        }
        let visible = label("fixture.visible", in: window)
        let offscreen = label("fixture.offscreen", in: window, y: window.bounds.height + 100)
        let hiddenParent = UIView(frame: window.bounds)
        window.addSubview(hiddenParent)
        let hidden = label("fixture.hidden", in: hiddenParent)
        hiddenParent.isHidden = true
        let axHiddenParent = UIView(frame: window.bounds)
        window.addSubview(axHiddenParent)
        let axHidden = label("fixture.ax-hidden", in: axHiddenParent)
        axHiddenParent.accessibilityElementsHidden = true
        let detached = label("fixture.detached", in: UIView())
        let hiddenElement = UIAccessibilityElement(accessibilityContainer: hiddenParent)
        hiddenElement.accessibilityIdentifier = "fixture.hidden-element"
        let offscreenElement = UIAccessibilityElement(accessibilityContainer: window)
        offscreenElement.accessibilityIdentifier = "fixture.offscreen-element"
        offscreenElement.accessibilityFrame = CGRect(x: 20, y: window.bounds.height + 200, width: 100, height: 40)
        let cached = UIView(frame: .zero)
        window.addSubview(cached)
        cached.accessibilityElements = [visible, offscreen, hidden, axHidden, detached, hiddenElement, offscreenElement]

        attachSettingsAccessibility(QuestionSettingsAccessibility.snapshot(in: window),
                                    name: "settings-fixture-after-cache-assignment-ancestry")
        // The fixture intentionally caches references outside this view's ownership.
        // Establish each synthetic AX element's declared container after populating that cache.
        hiddenElement.accessibilityContainer = hiddenParent
        offscreenElement.accessibilityContainer = window
        XCTAssertTrue((hiddenElement.accessibilityContainer as? UIView) === hiddenParent)
        XCTAssertTrue((offscreenElement.accessibilityContainer as? UIView) === window)
        let snapshot = QuestionSettingsAccessibility.snapshot(in: window)
        attachSettingsAccessibility(snapshot, name: "settings-fixture-declared-containers-ancestry")
        XCTAssertTrue((hiddenElement.accessibilityContainer as? UIView) === hiddenParent)
        XCTAssertTrue((offscreenElement.accessibilityContainer as? UIView) === window)
        for identifier in ["fixture.visible", "fixture.offscreen", "fixture.offscreen-element"] {
            XCTAssertNotNil(snapshot.element(identifier), "active controls remain discoverable, including offscreen controls")
        }
        for identifier in ["fixture.hidden", "fixture.ax-hidden", "fixture.detached", "fixture.hidden-element"] {
            XCTAssertNil(snapshot.element(identifier), "inactive fixture element: \(identifier)")
        }
        XCTAssertTrue(snapshot.diagnostics.contains("hidden UIView"))
        XCTAssertTrue(snapshot.diagnostics.contains("detached UIView"))
        XCTAssertTrue(snapshot.diagnostics.contains("accessibilityElementsHidden ancestor"))
    }

    func test_signed_out_settings_never_reads_and_a_new_signed_in_scope_reads_again() async throws {
        let api = QuestionPreferencesStub()
        let preferences = QuestionCallPreferences(api: api)
        let coordinator = WhisperModelProvisioningCoordinator()
        func settings(signedIn: Bool) -> WhisperModelSettingsView {
            let signOut: (@MainActor () -> Void)?
            if signedIn {
                signOut = {}
            } else {
                signOut = nil
            }
            return WhisperModelSettingsView(coordinator: coordinator, onSignOut: signOut,
                                            offersModelFile: false, questionCallPreferences: preferences)
        }
        let window = try HostedSummary.host(settings(signedIn: false), height: 2_400)
        defer { HostedSummary.close(window) }
        XCTAssertNotNil(HostedSummary.wait(for: "settings.inapp.sounds", in: window))
        XCTAssertNil(HostedSummary.element("settings.questionCalls.enabled", in: window))
        let none = await api.reads
        XCTAssertEqual(none, 0)
        let controller = try XCTUnwrap(window.rootViewController as? UIHostingController<WhisperModelSettingsView>)
        for expectedReads in 1...2 {
            controller.rootView = settings(signedIn: true)
            XCTAssertNotNil(HostedSummary.wait(for: "settings.questionCalls.enabled", in: window))
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let reads = await api.reads
                if reads == expectedReads && preferences.loaded && !preferences.working { break }
                await Task.yield()
            }
            let reads = await api.reads
            XCTAssertEqual(reads, expectedReads, "each newly signed-in scope performs a fresh read")
            XCTAssertTrue(preferences.loaded)
            XCTAssertFalse(preferences.working)
            controller.rootView = settings(signedIn: false)
            let removalDeadline = Date().addingTimeInterval(5)
            while Date() < removalDeadline && HostedSummary.element("settings.questionCalls.enabled", in: window) != nil {
                await Task.yield()
                HostedSummary.pump(0.02)
            }
            XCTAssertNil(HostedSummary.element("settings.questionCalls.enabled", in: window))
            XCTAssertNotNil(HostedSummary.element("settings.inapp.sounds", in: window))
        }
    }

    private func attachSettingsImage(_ window: UIWindow, name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachSettingsAccessibility(_ snapshot: QuestionSettingsAccessibility.Snapshot, name: String) {
        let attachment = XCTAttachment(string: snapshot.diagnostics)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Scoped to this acceptance case. UIKit may retain reusable views and AX objects after a Form removes a section.
/// Keep unknown ownership and offscreen elements discoverable; exclude only public hidden/detached ancestry.
/// The existing broad HostedSummary traversal remains unchanged for other suites.
@MainActor
private enum QuestionSettingsAccessibility {
    @MainActor
    struct Snapshot {
        let objects: [NSObject]
        let diagnostics: String
        var labels: [String] { objects.compactMap(\.accessibilityLabel) }
        func element(_ identifier: String) -> NSObject? {
            objects.first { HostedSummary.identifier(of: $0) == identifier }
        }
    }

    private struct Entry {
        let object: NSObject
        let path: [String]
        let excludedBy: String?
    }

    static func snapshot(in window: UIWindow) -> Snapshot {
        var queue = [Entry(object: window, path: [], excludedBy: nil)]
        if let presented = window.rootViewController?.presentedViewController?.view {
            queue.append(Entry(object: presented, path: [], excludedBy: nil))
        }
        var visited = Set<String>()
        var active = Set<ObjectIdentifier>()
        var objects: [NSObject] = []
        var rows: [[String: Any]] = []
        while !queue.isEmpty {
            let entry = queue.removeFirst()
            let chain = ancestry(of: entry.object)
            let reason = exclusion(in: chain, window: window) ?? entry.excludedBy
            let identity = String(describing: ObjectIdentifier(entry.object))
            // An object cached under an inactive view can also have a legitimate active path.
            guard visited.insert(identity + (reason == nil ? ":active" : ":inactive")).inserted else { continue }
            if reason == nil, active.insert(ObjectIdentifier(entry.object)).inserted { objects.append(entry.object) }
            rows.append([
                "object": describe(entry.object, window: window),
                "traversalAncestors": entry.path,
                "publicAncestry": chain.map { describe($0, window: window) },
                "includedViaThisPath": reason == nil,
                "excludedBy": reason ?? "none: unknown ownership is retained",
            ])
            var children: [NSObject] = []
            if let view = entry.object as? UIView { children.append(contentsOf: view.subviews) }
            if let elements = entry.object.accessibilityElements { children.append(contentsOf: elements.compactMap { $0 as? NSObject }) }
            let count = entry.object.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let child = entry.object.accessibilityElement(at: index) as? NSObject { children.append(child) }
                }
            }
            let childReason = reason ?? (entry.object.accessibilityElementsHidden
                ? "accessibilityElementsHidden ancestor \(identity)" : nil)
            for child in children {
                queue.append(Entry(object: child, path: entry.path + [identity], excludedBy: childReason))
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            return Snapshot(objects: objects, diagnostics: String(decoding: data, as: UTF8.self))
        } catch {
            XCTFail("Accessibility ancestry diagnostics could not be encoded: \(error)")
            return Snapshot(objects: objects, diagnostics: "Diagnostic encoding failed: \(error)")
        }
    }

    private static func ancestry(of object: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var current: NSObject? = object
        var visited = Set<ObjectIdentifier>()
        while let item = current, visited.insert(ObjectIdentifier(item)).inserted {
            result.append(item)
            if let view = item as? UIView { current = view.superview }
            else if let element = item as? UIAccessibilityElement { current = element.accessibilityContainer as? NSObject }
            else if item.responds(to: NSSelectorFromString("accessibilityContainer")) {
                // The public UIAccessibilityElement property is also implemented by SwiftUI's AX objects.
                current = item.value(forKey: "accessibilityContainer") as? NSObject
            } else { current = nil }
        }
        return result
    }

    private static func exclusion(in chain: [NSObject], window: UIWindow) -> String? {
        for (index, object) in chain.enumerated() {
            let identity = String(describing: ObjectIdentifier(object))
            if let view = object as? UIView {
                if view.isHidden { return "hidden UIView \(identity)" }
                if view !== window, view.window !== window { return "detached UIView \(identity)" }
            }
            if index > 0, object.accessibilityElementsHidden { return "accessibilityElementsHidden ancestor \(identity)" }
        }
        return nil
    }

    private static func describe(_ object: NSObject, window: UIWindow) -> [String: Any] {
        var result: [String: Any] = [
            "identity": String(describing: ObjectIdentifier(object)),
            "class": NSStringFromClass(type(of: object)),
            "identifier": HostedSummary.identifier(of: object) ?? "",
            "label": object.accessibilityLabel ?? "",
            "isAccessibilityElement": object.isAccessibilityElement,
            "accessibilityElementsHidden": object.accessibilityElementsHidden,
            "accessibilityFrame": NSCoder.string(for: object.accessibilityFrame),
        ]
        if let view = object as? UIView {
            result["isHidden"] = view.isHidden
            result["alpha"] = view.alpha
            result["attachedToTestWindow"] = view === window || view.window === window
            result["frame"] = NSCoder.string(for: view.frame)
        }
        return result
    }
}
