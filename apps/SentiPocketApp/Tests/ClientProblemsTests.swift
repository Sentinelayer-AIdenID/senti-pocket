import Foundation
import XCTest
@testable import SentiPocketApp

/// Carter, #55375: a failure should reach the agents without anyone posting it. What the phone sends, and how often.
final class ClientProblemsTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_793_000_000)
    }

    func test_only_the_servers_own_request_id_is_kept() {
        let server = HTTPURLResponse(url: URL(string: "https://api.example.invalid")!, statusCode: 503, httpVersion: nil,
                                     headerFields: ["X-Request-Id": "req-9d2aa0b1c2d3"])
        XCTAssertEqual(ClientProblems.serverRequestId(server), "req-9d2aa0b1c2d3")
        let edge = HTTPURLResponse(url: URL(string: "https://api.example.invalid")!, statusCode: 503, httpVersion: nil,
                                   headerFields: [:])
        XCTAssertNil(ClientProblems.serverRequestId(edge), "an answer that never reached the server has none")
        let ours = HTTPURLResponse(url: URL(string: "https://api.example.invalid")!, statusCode: 500, httpVersion: nil,
                                   headerFields: ["X-Request-Id": "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"])
        XCTAssertNil(ClientProblems.serverRequestId(ours), "an id the phone made is not the server's")
    }

    func test_one_report_per_route_and_status_a_window_and_a_cap_an_hour() {
        let clock = Clock()
        let problems = ClientProblems(apiBaseURL: nil, tokenProvider: { nil }, now: { clock.now })
        let route = "/api/v1/sessions/{session_id}/summary/generate"
        XCTAssertTrue(problems.shouldSend(route: route, status: 503))
        XCTAssertFalse(problems.shouldSend(route: route, status: 503), "the same failure again is the same report")
        XCTAssertTrue(problems.shouldSend(route: route, status: 429), "another status is another report")
        clock.now += ClientProblems.window + 1
        XCTAssertTrue(problems.shouldSend(route: route, status: 503), "after the window it is reported again")

        for index in 0..<20 { _ = problems.shouldSend(route: "/api/v1/sessions/{session_id}/r\(index)", status: 500) }
        XCTAssertFalse(problems.shouldSend(route: "/api/v1/sessions/{session_id}/new", status: 500),
                       "at most \(ClientProblems.hourlyLimit) an hour")
        clock.now += 3_601
        XCTAssertTrue(problems.shouldSend(route: "/api/v1/sessions/{session_id}/new", status: 500))
    }
}
