import Combine
import Foundation
import SwiftUI
import XCTest
@testable import SentiPocketApp

/// The API's answers for each request, in order (202 once they run out), and every request as it went out.
private final class CrashReportURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var answers: [(status: Int, headers: [String: String])] = []
    private static var captured: [(request: URLRequest, body: Data)] = []

    static func reset(answers: [(status: Int, headers: [String: String])] = []) {
        lock.lock()
        self.answers = answers
        captured = []
        lock.unlock()
    }

    static func requests() -> [(request: URLRequest, body: Data)] {
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
        let answer = Self.answers.isEmpty ? (status: 202, headers: [:]) : Self.answers.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A scripted API: what it answers, the credential stored now, and every report sent with the credential it carried.
private final class ScriptedCrashReports: CrashReportSending, @unchecked Sendable {
    struct Sent: Equatable {
        let payload: CrashReportPayload
        let token: String
    }

    private let lock = NSLock()
    private var token: String?
    private var answers: [CrashReportSendResult]
    private var log: [Sent] = []
    /// Runs once each report has gone out (with how many have): a sign-out or another sign-in mid-send.
    var afterSend: ((Int) -> Void)?

    init(token: String?, answers: [CrashReportSendResult] = []) {
        self.token = token
        self.answers = answers
    }

    var sent: [Sent] { lock.withLock { log } }

    func store(_ token: String?) { lock.withLock { self.token = token } }

    func currentToken() -> String? { lock.withLock { token } }

    func send(_ payload: CrashReportPayload, token: String) async -> CrashReportSendResult {
        let (count, answer) = lock.withLock { () -> (Int, CrashReportSendResult) in
            log.append(Sent(payload: payload, token: token))
            return (log.count, answers.isEmpty ? .accepted : answers.removeFirst())
        }
        afterSend?(count)
        return answer
    }
}

/// The tests' clock.
private let testNow = Date(timeIntervalSince1970: 1_793_000_000)

/// A credential with an account in it, as `RoomSendOutbox.account(token:)` reads one. Made up.
private func credential(_ subject: String) -> String {
    let claims = Data("{\"sub\":\"\(subject)\"}".utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return "e30.\(claims).sig"
}

/// Carter, 11-06: crash reports go to the team through the API, which posts them in the team's feedback room, never
/// into a room from the phone. Only the API's fields, inside its bounds, with no room, message, name or address.
@MainActor
final class CrashReportUploadTests: XCTestCase {
    private let now = testNow

    private func report(_ id: String, minutesAgo: Double, kind: CrashReport.Kind = .crash,
                        reason: String = "EXC_BAD_ACCESS (SIGSEGV)", trail: [String] = ["12:00:01 room opened"]) -> CrashReport {
        CrashReport(id: id, kind: kind, at: now.addingTimeInterval(-minutesAgo * 60), build: "2026110601",
                    system: "iOS 26.1", device: "iPhone17,5", reason: reason, frames: ["SentiPocketApp +0x10"],
                    binaries: [], trail: trail)
    }

    private func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CrashReportURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func test_the_payload_has_the_apis_fields_inside_its_bounds() throws {
        let long = CrashReport(
            id: "long", kind: .hang, at: now, build: String(repeating: "9", count: 40),
            system: "iOS " + String(repeating: "2", count: 40), device: String(repeating: "d", count: 40),
            reason: "Not responding " + String(repeating: "x", count: 300),
            frames: (0..<100).map { "frame \($0) " + String(repeating: "f", count: 200) }, binaries: [],
            trail: (0..<30).map { String(format: "12:00:%02d step %d ", $0, $0) + String(repeating: "s", count: 150) }
        )
        let payload = CrashReportPayload(long)
        XCTAssertEqual(payload.kind, "hang")
        XCTAssertEqual([payload.build, payload.os, payload.device].map(\.unicodeScalars.count), [32, 32, 32])
        XCTAssertEqual(payload.headline.unicodeScalars.count, 200)
        XCTAssertEqual(payload.frames.count, 64)
        XCTAssertTrue(payload.frames.allSatisfy { $0.unicodeScalars.count <= 160 })
        XCTAssertEqual(payload.frames.first.map { $0.hasPrefix("frame 0 ") }, true, "the innermost frames")
        XCTAssertEqual(payload.lastSteps.count, 20)
        XCTAssertTrue(payload.lastSteps.allSatisfy { $0.unicodeScalars.count <= 120 })
        XCTAssertEqual(payload.lastSteps.first.map { $0.hasPrefix("12:00:10 step 10 ") }, true, "the newest twenty steps")
        XCTAssertEqual(payload.occurredAt, "2026-10-26T07:33:20+00:00", "ISO 8601 with its offset")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["kind", "build", "os", "device", "occurredAt", "headline", "frames", "lastSteps"],
                       "the API's keys and no others: it refuses the rest")

        XCTAssertNil(payload.binaries, "no binaries listed: none sent, and the key left out")
        XCTAssertEqual(CrashReportPayload.cut(String(repeating: "\u{1F1FA}\u{1F1F8}", count: 150), to: 200).unicodeScalars.count,
                       200, "counted in code points, as the API counts")
    }

    /// The API knows crashes and hangs: a run closed while open (the main thread stuck, then the system ended it) goes as
    /// a hang and its headline says so; a crash stays a crash.
    func test_each_kind_goes_as_the_api_names_it() {
        XCTAssertEqual(CrashReportPayload(report("crash", minutesAgo: 1, kind: .crash)).kind, "crash")
        XCTAssertEqual(CrashReportPayload(report("hang", minutesAgo: 1, kind: .hang)).kind, "hang")
        let closed = CrashReportPayload(report("closed", minutesAgo: 1, kind: .closed, reason: "On screen, then gone."))
        XCTAssertEqual(closed.kind, "hang")
        XCTAssertEqual(closed.headline, "Closed while open: On screen, then gone.")
    }

    /// The binaries the frames are in go with them, so the team can symbolicate the frames: name and UUID, as the API
    /// takes them, the first 16.
    func test_the_binaries_go_with_the_frames() throws {
        let uuid = { (index: Int) in String(format: "00000000-0000-4000-8000-%012d", index) }
        var listed = ["SentiPocketApp \(uuid(1))", "? \(uuid(2))", "bad name! \(uuid(3))", "UIKitCore not-a-uuid",
                      "SentiPocketApp \(uuid(1))", String(repeating: "n", count: 65) + " \(uuid(4))",
                      "UIKitCore \(uuid(31))\n", "Foundation\n \(uuid(32))"]
        listed += (5...30).map { "libsystem_\($0).dylib \(uuid($0))" }
        var crash = report("binaries", minutesAgo: 1)
        crash.binaries = listed
        let payload = CrashReportPayload(crash)
        let binaries = try XCTUnwrap(payload.binaries)
        XCTAssertEqual(binaries.count, 16, "the first 16 the API takes")
        XCTAssertEqual(binaries.first, CrashReportPayload.Binary(name: "SentiPocketApp", uuid: uuid(1)))
        XCTAssertEqual(binaries[1], CrashReportPayload.Binary(name: "libsystem_5.dylib", uuid: uuid(5)),
                       "a name outside the API's characters or over 64, a UUID that is not one, a final newline the API "
                       + "refuses, and a repeat are left out")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        let first = try XCTUnwrap((object["binaries"] as? [[String: String]])?.first)
        XCTAssertEqual(first, ["name": "SentiPocketApp", "uuid": uuid(1)])
    }

    /// The merged API (#1191) refuses, with a 422, a build, os or device outside [A-Za-z0-9 ._()+,-] or of 0 or over 32
    /// characters, and an empty headline: none of them is ever sent.
    func test_the_labels_and_headline_are_ones_the_api_takes() throws {
        let label = try NSRegularExpression(pattern: #"^[A-Za-z0-9 ._()+,-]{1,32}$"#)
        func taken(_ text: String) -> Bool {
            text.unicodeScalars.count <= 32
                && label.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        var odd = report("odd", minutesAgo: 1, reason: "")
        odd.build = "1.4 (212)"
        odd.system = "iOS 26.1 \u{AB} beta \u{BB}"
        odd.device = "iPhone17,2<script>"
        let payload = CrashReportPayload(odd)
        XCTAssertEqual(payload.build, "1.4 (212)", "what the API takes stays as it is")
        XCTAssertEqual(payload.os, "iOS 26.1 - beta -")
        XCTAssertEqual(payload.device, "iPhone17,2-script-")
        XCTAssertEqual(payload.headline, "Pocket closed unexpectedly", "never an empty headline")
        var empty = report("empty", minutesAgo: 1)
        empty.build = ""
        empty.system = "   "
        empty.device = String(repeating: "\u{1F600}", count: 40)
        let blank = CrashReportPayload(empty)
        XCTAssertEqual(blank.build, "unknown")
        XCTAssertEqual(blank.os, "unknown")
        for value in [payload.build, payload.os, payload.device, blank.build, blank.os, blank.device] {
            XCTAssertTrue(taken(value), "\(value) is one the API takes")
        }
    }

    /// Review, #352: no room's id or title, no message's number or text, no person's name or address, ever.
    func test_breadcrumbs_never_carry_a_room_a_message_a_name_or_an_address() {
        let steps = [
            "12:00:01 room opened 3f1c2b9e-1234-4abc-8def-0123456789ab",
            "12:00:02 reply opened #62604",
            "12:00:03 closeThread (101 rows)",
            "12:00:04 opened Launch Planning",
            "12:00:05 shared with alex@example.com",
            "12:00:06 link https://sentinelayer.com/dashboard/sessions/abc",
            "12:00:07 sent \"see you at the launch\"",
            "12:00:08 joined Caf\u{E9} cr\u{E8}me",
            "12:00:09 main thread stalled 2.1 s after drawerOpened (12 rows)"
        ]
        let payload = CrashReportPayload(report("steps", minutesAgo: 1, trail: steps))
        XCTAssertEqual(payload.lastSteps, [
            "12:00:01 room opened <room>",
            "12:00:02 reply opened <msg>",
            "12:00:03 closeThread (101 rows)",
            "12:00:04 opened <name>",
            "12:00:05 shared with <email>",
            "12:00:06 link <link>",
            "12:00:07 sent <text>",
            "12:00:08 joined <name>",
            "12:00:09 main thread stalled 2.1 s after drawerOpened (12 rows)"
        ])
        let headline = CrashReportPayload(report("headline", minutesAgo: 1,
                                                 reason: "EXC_BREAKPOINT (SIGTRAP) in 3f1c2b9e-1234-4abc-8def-0123456789ab #62604"))
            .headline
        XCTAssertEqual(headline, "EXC_BREAKPOINT (SIGTRAP) in <room> <msg>", "the headline keeps its words, not the ids")
    }

    func test_reports_go_only_to_the_crash_report_route_with_the_credential_of_the_send() async throws {
        CrashReportURLProtocol.reset()
        let alex = credential("alex")
        let api = HTTPCrashReports(apiBaseURL: URL(string: "https://api.example.test"), urlSession: stubbedSession(),
                                   tokenProvider: { alex })
        let done = await CrashReportDelivery(api: api, now: { testNow }, note: { _ in })
            .deliver([report("older", minutesAgo: 30), report("newer", minutesAgo: 10)])
        XCTAssertEqual(Set(done.map(\.id)), ["older", "newer"])
        let requests = CrashReportURLProtocol.requests()
        XCTAssertEqual(requests.map { $0.request.httpMethod }, ["POST", "POST"])
        XCTAssertEqual(requests.map { $0.request.url?.path }, ["/api/v1/crash-reports", "/api/v1/crash-reports"],
                       "one request each, to the team's route: no room is made, read or posted in")
        XCTAssertEqual(requests.map { $0.request.value(forHTTPHeaderField: "Authorization") }, ["Bearer \(alex)", "Bearer \(alex)"])
        let stamps = try requests.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body) as? [String: Any])["occurredAt"] as? String ?? ""
        }
        XCTAssertEqual(stamps, [CrashReportPayload.stamp(now.addingTimeInterval(-600)), CrashReportPayload.stamp(now.addingTimeInterval(-1800))],
                       "newest first")
    }

    /// A request already on its way when another account signs in still carries the credential the send started with:
    /// never the new account's.
    func test_a_report_goes_out_with_the_credential_the_send_started_with() async {
        CrashReportURLProtocol.reset()
        let alex = credential("alex")
        let api = HTTPCrashReports(apiBaseURL: URL(string: "https://api.example.test"), urlSession: stubbedSession(),
                                   tokenProvider: { credential("sam") })
        let answer = await api.send(CrashReportPayload(report("a", minutesAgo: 1)), token: alex)
        XCTAssertEqual(answer, .accepted)
        XCTAssertEqual(CrashReportURLProtocol.requests().map { $0.request.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer \(alex)"])
    }

    func test_a_report_the_api_cannot_take_now_stays_on_the_phone() async {
        let alex = credential("alex")
        let cases: [(String, Int, [String: String], [String])] = [
            ("not set up yet", 503, [:], []),
            ("no route yet", 404, [:], []),
            ("too many lately", 429, ["Retry-After": "600"], []),
            ("credential refused", 401, [:], []),
            ("refused for good, dropped so it is not offered again and again", 422, [:], ["newer"])
        ]
        for (name, status, headers, expected) in cases {
            CrashReportURLProtocol.reset(answers: [(status, headers)])
            var notes: [String] = []
            let api = HTTPCrashReports(apiBaseURL: URL(string: "https://api.example.test"), urlSession: stubbedSession(),
                                       tokenProvider: { alex })
            let done = await CrashReportDelivery(api: api, now: { testNow }, note: { notes.append($0) })
                .deliver([report("older", minutesAgo: 30), report("newer", minutesAgo: 10)])
            if status == 422 {
                XCTAssertEqual(done.map(\.id), ["newer", "older"], name)
                XCTAssertEqual(notes, ["crash report refused by the API"], name)
            } else {
                XCTAssertEqual(done.map(\.id), expected, "\(name): kept, and offered again at the next launch")
                XCTAssertEqual(CrashReportURLProtocol.requests().count, 1, "\(name): nothing more is sent this time")
            }
        }
    }

    /// Review, #352: the send keeps the credential and account it started with, and stops once another is stored.
    func test_a_send_stops_when_the_signed_in_account_changes() async {
        let alex = credential("alex")
        let api = ScriptedCrashReports(token: alex)
        api.afterSend = { [unowned api] count in if count == 1 { api.store(credential("sam")) } }
        let done = await CrashReportDelivery(api: api, now: { testNow }, note: { _ in })
            .deliver([report("a", minutesAgo: 30), report("b", minutesAgo: 20), report("c", minutesAgo: 10)])
        XCTAssertEqual(api.sent.map(\.token), [alex], "nothing more goes out once another account signed in")
        XCTAssertEqual(done.map(\.id), ["c"], "the one the API took is done with; the others stay on the phone")

        let signedOut = ScriptedCrashReports(token: alex)
        signedOut.afterSend = { [unowned signedOut] _ in signedOut.store(nil) }
        _ = await CrashReportDelivery(api: signedOut, now: { testNow }, note: { _ in })
            .deliver([report("a", minutesAgo: 30), report("b", minutesAgo: 20)])
        XCTAssertEqual(signedOut.sent.count, 1, "nor after a sign-out")

        let nobody = ScriptedCrashReports(token: nil)
        let none = await CrashReportDelivery(api: nobody, now: { testNow }, note: { _ in }).deliver([report("a", minutesAgo: 1)])
        XCTAssertTrue(none.isEmpty && nobody.sent.isEmpty, "signed out: nothing is sent")
    }

    func test_a_report_too_old_for_the_api_is_dropped_unsent() async {
        let api = ScriptedCrashReports(token: credential("alex"))
        let done = await CrashReportDelivery(api: api, now: { testNow }, note: { _ in })
            .deliver([report("old", minutesAgo: 15 * 24 * 60)])
        XCTAssertEqual(done.map(\.id), ["old"])
        XCTAssertTrue(api.sent.isEmpty, "the API takes nothing older than 14 days")
    }

    /// The API posts each report with the sender's name and, when verified, GitHub username: the offer says so, and
    /// promises only what is true (never the messages or what is in the rooms).
    func test_the_offer_says_where_the_report_goes_and_who_it_comes_from() {
        XCTAssertEqual(CrashReportOffer.message, "Send a report so the team can fix it? It goes from your account, with "
                       + "your name and GitHub username (if verified), where the app stopped and your last few steps. "
                       + "Never your messages or anything in your rooms.")
        XCTAssertNil(CrashReportOffer.message.range(of: "names", options: .caseInsensitive),
                     "the name goes with every report: the offer never says it does not")
    }
}

/// Carter, 11-06: the crash report offer is never an alert over a live call. It waits for the call to end, with the app
/// in front; a call that starts while it is up takes it down, and it comes back after.
@MainActor
final class CrashOfferTimingTests: XCTestCase {
    private var calls = CurrentValueSubject<Bool, Never>(false)
    private var reports = CurrentValueSubject<Int, Never>(1)

    override func setUp() {
        super.setUp()
        calls = CurrentValueSubject(false)
        reports = CurrentValueSubject(1)
    }

    private func timing(available: Bool = true) -> CrashOfferTiming {
        CrashOfferTiming(available: available, calls: calls.eraseToAnyPublisher(), reports: reports.eraseToAnyPublisher())
    }

    func test_the_offer_waits_for_a_call_to_end_and_never_shows_over_one() {
        calls.send(true)
        let offer = timing()
        offer.inFront(true)
        offer.settle()
        XCTAssertFalse(offer.presented, "never over a call")
        calls.send(false)
        XCTAssertTrue(offer.presented, "once the call ends, with the app in front")
        calls.send(true)
        XCTAssertFalse(offer.presented, "a call that starts takes it down")
        calls.send(false)
        XCTAssertTrue(offer.presented, "and it comes back after, still unanswered")
        offer.answer()
        calls.send(true)
        calls.send(false)
        XCTAssertFalse(offer.presented, "once answered, not again this launch")
    }

    func test_the_offer_waits_for_a_moment_the_app_in_front_and_a_report() {
        reports.send(0)
        let offer = timing()
        offer.inFront(true)
        XCTAssertFalse(offer.presented, "not before a moment has passed")
        offer.settle()
        XCTAssertFalse(offer.presented, "nothing to offer")
        offer.inFront(false)
        reports.send(1)
        XCTAssertFalse(offer.presented, "not while the app is in the background")
        offer.inFront(true)
        XCTAssertTrue(offer.presented)

        let unavailable = timing(available: false)
        unavailable.inFront(true)
        unavailable.settle()
        XCTAssertFalse(unavailable.presented, "nowhere to send them: no offer")
    }

    /// Pocket's own call screen counts as a call while it is up, as a call CallKit knows of does.
    func test_pockets_call_screen_is_a_call_while_it_is_up() {
        XCTAssertTrue(VoiceCallWindow.shared.show(Color.black), "the call screen opens over the test host")
        XCTAssertTrue(CallPresence.shared.isOn)
        VoiceCallWindow.shared.hide()
        XCTAssertFalse(CallPresence.shared.isOn, "and the call is over when it goes")
    }
}
