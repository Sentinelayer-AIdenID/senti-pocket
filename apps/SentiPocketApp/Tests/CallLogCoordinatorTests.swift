import Foundation
import PocketSyncClient
import PocketUI
import XCTest
@testable import SentiPocketApp

private final class ScriptedCalls: CallLogTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [Result<SentiCallLogPage, Error>]
    private(set) var cursors: [String?] = []

    init(_ pages: [Result<SentiCallLogPage, Error>]) { self.pages = pages }

    func calls(limit: Int, cursor: String?) async throws -> SentiCallLogPage {
        let next: Result<SentiCallLogPage, Error> = lock.withLock {
            cursors.append(cursor)
            return pages.count > 1 ? pages.removeFirst() : (pages.first ?? .success(SentiCallLogPage(calls: [])))
        }
        return try next.get()
    }
}

/// Carter (10-30): "there should be ... past ones like when I called yall and the details I asked for".
@MainActor
final class CallLogCoordinatorTests: XCTestCase {
    private func voiceRoom(_ id: String, with agents: [String] = ["pocket-forge"], meeting: Bool = false,
                           status: String = "ended") -> SentiCall {
        SentiCall(kind: .voiceRoom, id: id, sessionId: "room-1", roomTitle: "Senti-expansion-proj", status: status,
                  startedAt: "2026-10-30T17:38:19Z", with: agents, isMeeting: meeting, durationText: "2 min 40 s",
                  turns: 7, timingsText: "Timings: you stop → answer heard 2.1 s",
                  summaries: [SentiCall.Summary(author: "pocket-forge", text: "Next build rings first.")],
                  startSequenceId: 55589, endSequenceId: 55598)
    }

    func test_calls_read_as_who_you_talked_with_how_long_and_what_was_decided() async {
        let missed = SentiCall(kind: .ring, id: "r-1", sessionId: "room-2", roomTitle: "Lab", status: "missed",
                               startedAt: "2026-10-30T12:00:00Z", direction: "incoming", callerName: "claude-warden",
                               reason: "Review is ready")
        let outgoing = SentiCall(kind: .ring, id: "r-2", sessionId: "room-2", status: "answered",
                                 startedAt: "2026-10-30T11:00:00Z", direction: "outgoing", calleeName: "mrrCarter")
        let log = CallLogCoordinator(transport: ScriptedCalls([.success(SentiCallLogPage(calls: [
            voiceRoom("v1"), voiceRoom("v2", with: ["pocket-forge", "claude-warden"]),
            voiceRoom("v3", with: [], meeting: true, status: "ongoing"), missed, outgoing
        ]))]))
        await log.refresh()
        let rows = log.state.rows
        XCTAssertEqual(rows.map(\.title), ["pocket-forge", "pocket-forge and claude-warden", "Meeting",
                                           "claude-warden called you", "You called mrrCarter"])
        XCTAssertEqual(rows[0].detail, "2 min 40 s · 7 turns")
        XCTAssertEqual(rows[0].summaries.first?.text, "Next build rings first.")
        XCTAssertEqual(rows[2].detail, "In progress · 2 min 40 s · 7 turns")
        XCTAssertTrue(rows[2].isOngoing)
        XCTAssertTrue(rows[3].isMissed)
        XCTAssertEqual(rows[3].direction, .incoming)
        XCTAssertEqual(rows[3].reason, "Review is ready")
        XCTAssertFalse(rows[4].isMissed)
        XCTAssertEqual(log.readable("v1")?.markdown, "pocket-forge: Next build rings first.")
    }

    func test_a_call_opens_in_its_room_at_the_message_that_ended_it() async {
        let log = CallLogCoordinator(transport: ScriptedCalls([.success(SentiCallLogPage(calls: [voiceRoom("v1")]))]))
        await log.refresh()
        let link = log.link(for: "v1")
        XCTAssertEqual(link?.sessionId, "room-1")
        XCTAssertEqual(link?.messageSequence, 55598)
    }

    func test_earlier_calls_page_in_without_repeats_and_an_older_server_says_so() async {
        let transport = ScriptedCalls([
            .success(SentiCallLogPage(calls: [voiceRoom("v1")], nextCursor: "c-2")),
            .success(SentiCallLogPage(calls: [voiceRoom("v1"), voiceRoom("v0")]))
        ])
        let log = CallLogCoordinator(transport: transport)
        await log.refresh()
        XCTAssertTrue(log.state.canLoadMore)
        await log.loadMore()
        XCTAssertEqual(log.state.rows.map(\.id), ["v1", "v0"])
        XCTAssertFalse(log.state.canLoadMore)
        XCTAssertEqual(transport.cursors, [nil, "c-2"])

        let older = CallLogCoordinator(transport: ScriptedCalls([.failure(SessionTransportError.accessDenied)]))
        await older.refresh()
        XCTAssertFalse(older.state.isAvailable)
    }
}
