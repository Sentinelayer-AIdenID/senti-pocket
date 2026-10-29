import Foundation
import XCTest
@testable import PocketUI

final class AdmissionsPresentationTests: XCTestCase {
    func test_grant_durations_can_only_shorten_the_request() {
        XCTAssertEqual(AdmissionRow.ttlOptions(forRequested: 2 * 3600), [15 * 60, 3600, 2 * 3600])
        XCTAssertEqual(AdmissionRow.ttlOptions(forRequested: 8 * 3600), [15 * 60, 3600, 2 * 3600, 8 * 3600])
        XCTAssertEqual(AdmissionRow.ttlOptions(forRequested: 10 * 60), [10 * 60], "only the request when nothing is shorter")
        XCTAssertEqual(AdmissionRow.ttlOptions(forRequested: 0), [])
        XCTAssertEqual(AdmissionRow.durationLabel(7200), "2h")
        XCTAssertEqual(AdmissionRow.durationLabel(900), "15m")
        XCTAssertEqual(AdmissionRow.actionLabel("session.post"), "Post messages")
    }

    func test_an_approval_sends_a_duration_only_when_one_was_offered() {
        let timed = AdmissionRow(id: "a1", status: "pending", agentId: "slate-forge", requestedTTLSeconds: 2 * 3600)
        XCTAssertEqual(timed.grantedTTL(choosing: 3600), 3600)
        XCTAssertNil(timed.grantedTTL(choosing: 8 * 3600), "a grant is never longer than the request")
        let untimed = AdmissionRow(id: "a2", status: "pending", agentId: "slate-forge")
        XCTAssertNil(untimed.grantedTTL(choosing: untimed.requestedTTLSeconds), "no duration requested: none is sent, never 0")
    }

    func test_pending_and_live_split_and_protected_failures_show_nothing() {
        let rows = [
            AdmissionRow(id: "a", status: "pending", agentId: "one"),
            AdmissionRow(id: "b", status: "active", agentId: "two", grantedActions: ["session.read"]),
            AdmissionRow(id: "c", status: "approved", agentId: "three"),
            AdmissionRow(id: "d", status: "expired", agentId: "four")
        ]
        let state = AdmissionsPresentationState(rows: rows, mode: "legacy")
        XCTAssertEqual(state.pending.map(\.id), ["a"])
        XCTAssertEqual(state.live.map(\.id), ["b", "c"])
        let denied = AdmissionsPresentationState(rows: rows, failure: .accessDenied)
        XCTAssertTrue(denied.pending.isEmpty && denied.live.isEmpty)
    }
}
